# deepseek/deepseek-v4.1-flash-1017

## Findings (round D)

### 1. Medium — Signed path silently discards a user-pinned `SGS_SHA256`, enabling rollback
`cloud-init/lambda-user-data.yaml:45` unconditionally overwrites `SGS_SHA256` with the value from `SHA256SUMS`. The template tells users to take the hash from the git tag, but if they also set `SGS_ALLOWED_SIGNER`, that pin is thrown away.
**Scenario:** user pins `SGS_SHA256` to the current release's hash and sets `SGS_ALLOWED_SIGNER`. The download host is compromised and serves an *older, validly signed* release plus its matching `SHA256SUMS`/`.sig`. Signature verifies, `SGS_SHA256` is replaced with the old hash, old tarball installs — a downgrade to a release with known bugs, despite the pin.
**Fix:** if `SGS_SHA256` is set to a real value (not `REPLACE-ME`), require the awk-extracted hash to equal it; only fall back to the signed hash when the pin is unset.

### 2. Medium — `sgs-sbom` hashes `RECORD`, not the files it lists, so tampering is invisible
`bin/sgs-sbom:70-77` computes SHA-256 of the `RECORD` file itself. The comment at 71-72 claims "one value that changes if any of them do" — false: editing an installed `.py` leaves `RECORD` byte-identical.
**Scenario:** attacker with write access to `/opt/sgs/venv/.../site-packages` backdoors `torch/__init__.py`. `sgs-sbom` reports the same `hashes` entry as before; a consumer diffing SBOMs sees no change and trusts the machine.
**Fix:** hash the files enumerated in `RECORD` (or at minimum label the property `sgs:hash-of: RECORD-file` and stop claiming it covers installed files).

### 3. Medium — `tf-cuda12` site glob is wrong; TensorFlow/JAX packages are omitted
`bin/sgs-sbom:28` uses `"/opt/sgs/tf-cuda12"` directly, while the other two entries use `lib/python3*/site-packages`. If `tf-cuda12` is a venv (as the docstring implies), its `*.dist-info` live under `lib/python3*/site-packages` and are never found.
**Scenario:** a machine with a backdoored TensorFlow wheel in `tf-cuda12` produces an SBOM that lists no TensorFlow at all — the SBOM misdescribes the machine and the malicious package is invisible to inventory.
**Fix:** use `"/opt/sgs/tf-cuda12/lib/python3*/site-packages"` (and keep a fallback for a flat layout). *Unverified layout — confirm where `tf-cuda12` actually stores dist-info.*

### 4. Medium — Malicious package metadata can hang or crash `sgs-sbom` (runs as root during install)
`bin/sgs-sbom:59` and `:76` `open()` paths under `*.dist-info` with no regular-file check, and `record_digest` (`:70-77`) is not wrapped in the `try/except OSError` that guards `dist_name_version`.
**Scenario:** a package installs `foo.dist-info/METADATA` as a FIFO, or `RECORD` as a symlink to `/dev/zero`, or `RECORD` with mode 000. `sgs-sbom` blocks forever, OOMs, or raises `PermissionError` and aborts the installer mid-run.
**Fix:** `os.stat`/`stat.S_ISREG` before opening, open with `O_NOFOLLOW`, cap read size, and wrap `record_digest` in the same `try/except OSError`.

### 5. Medium — `sgs-sbom --output` follows symlinks as root
`bin/sgs-sbom:142` uses `os.open(..., O_WRONLY|O_CREAT|O_TRUNC, 0o644)` with no `O_NOFOLLOW`. If the caller passes a path in a shared directory (e.g. `/tmp`), a pre-planted symlink is followed.
**Scenario:** install script invokes `sgs-sbom -o /tmp/sbom.json`; another local user pre-creates `/tmp/sbom.json -> /etc/shadow`. Root truncates and overwrites `/etc/shadow` with JSON.
**Fix:** add `O_NOFOLLOW` (and `O_EXCL` when creating), or refuse to write if the target is a symlink. *Unverified whether the installer uses a shared path.*

### 6. Medium (unverified) — `release.sh` uses a bsdtar-only flag; build aborts on Ubuntu
`scripts/release.sh:22` passes `--no-mac-metadata`, which GNU tar (Ubuntu 24.04) does not recognize. With `set -e`, the release build fails.
**Scenario:** maintainer runs `scripts/release.sh` on the Ubuntu build host; tar exits "unrecognized option", no tarball is produced, and any CI that ignores the failure could publish a stale/unsigned artifact.
**Fix:** detect tar flavor, or drop `--no-mac-metadata`/`COPYFILE_DISABLE` on Linux (they are macOS-only).

### 7. Low/Medium — `SHA256SUMS` filename match is fragile; signed installs fail on query-string URLs
`cloud-init/lambda-user-data.yaml:45` matches `$2 == "${SGS_URL##*/}"`. A URL like `https://host/dl?file=secure-gpu-stack-0.1.0.tar.gz` yields `f="dl?file=..."`, which never matches; a `SHA256SUMS` produced in binary mode (`hash *name`) also fails.
**Scenario:** user pastes a signed-download URL with a query string; `SGS_SHA256` comes back empty and the install aborts with "SHA256SUMS has no entry" even though the release is valid.
**Fix:** strip `?`/`#` from the basename and accept an optional leading `*` in `$2`.

### 8. Low — `power_state` reboots on a stale manifest from a previous run
`cloud-init/lambda-user-data.yaml:54-56` reboots whenever `/opt/sgs/manifest.txt` exists. A re-run on a machine that already has the manifest reboots even if this run's `install.sh` failed.
**Scenario:** operator re-runs cloud-init to fix a broken install; `install.sh` fails early, but the old manifest is still present, so the instance reboots into a half-installed state.
**Fix:** remove `/opt/sgs/manifest.txt` before invoking `install.sh`, or have `install.sh` write a run-specific marker.

### 9. Low — Malicious `Name`/`Version` can produce malformed purls and `bom-ref`s
`bin/sgs-sbom:96` interpolates `name`/`version` straight into `pkg:pypi/...@...`; `:115` appends `#env`. A package with `Name: foo@1.0?arch=evil` or a `/` in the name yields a purl that CycloneDX consumers misparse, and can collide with another component's `bom-ref`.
**Scenario:** a malicious wheel sets `Name` to mimic another package's purl; downstream SBOM tooling attributes the malicious component to the legitimate package.
**Fix:** percent-encode or reject names/versions containing `@`, `/`, `?`, `#`, whitespace; validate `bom-ref` uniqueness.

### 10. Low — `SGS_ALLOWED_SIGNER` accepts a wildcard principal, weakening identity binding
`cloud-init/lambda-user-data.yaml:42` verifies with `-I release@secure-gpu-stack`, but if the user's allowed_signers line uses `*` as the principal, any identity matches. The key is still required, so this is not a full bypass, but it removes the identity check the comment advertises.
**Scenario:** user copies a `* ssh-ed25519 AAAA...` line; a signature made by that key under a different identity/namespace context is accepted.
**Fix:** document that the principal must be exactly `release@secure-gpu-stack`, and optionally reject lines whose principal list is `*`.

### 11. Low — `release.sh` version extraction can yield a multi-line `NAME`
`scripts/release.sh:12` uses `sed -n 's/^SGS_VERSION="\(.*\)"/\1/p'` without `head -1`. If `install.sh` ever contains two matching lines, `NAME` contains a newline and the tar/shasum filenames become malformed.
**Scenario:** a merge accidentally leaves two `SGS_VERSION=` lines; `tar` writes a file with an embedded newline, `SHA256SUMS` is ambiguous, and cloud-init's `awk` match fails.
**Fix:** pipe through `head -1` and validate `VERSION` against `^[0-9A-Za-z._-]+$`.

### 12. Low — `dist_name_version` reads symlinked `METADATA`/`PKG-INFO` as root
`bin/sgs-sbom:59` opens `meta` without `O_NOFOLLOW`. A package can make `METADATA` a symlink to any root-readable file; only lines beginning `Name:`/`Version:` are emitted, but that is still an information leak if such a file exists.
**Scenario:** malicious package symlinks `foo.dist-info/METADATA -> /root/.config/some-file-with-Name:-lines`; `sgs-sbom` (root) copies those values into the SBOM.
**Fix:** `O_NOFOLLOW` + `S_ISREG` check before opening, as in finding 4.
