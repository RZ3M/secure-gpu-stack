# deepseek/deepseek-v4.1-flash-1017

# Round C findings — delivery, profile, pins, Python policy, tests

Ranked most severe first.

---

**1. HIGH — `tests/attack-demo.sh` password-auth check can never fail**
`tests/attack-demo.sh:36-38` runs `ssh … -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=0`. With `NumberOfPasswordPrompts=0`, ssh will not prompt for a password at all, so password auth cannot succeed regardless of `sshd_config`. The test therefore prints "password login refused" on a machine where `PasswordAuthentication yes` is set.
Scenario: operator leaves password auth enabled; `attack-demo.sh` reports PASS; the box is brute-forceable.
Fix: don't test by connecting. Read the effective config (`sshd -T | grep -i passwordauthentication`) or attempt a real password login with a known-bad password and distinguish "auth failed" from "method disabled".

---

**2. HIGH — Release checksum provides no tamper protection; README claims it does**
`scripts/release.sh:24` writes `SHA256SUMS` into the same `dist/` directory as the tarball, and `README.md:34,79` tells users to `sha256sum -c SHA256SUMS` from that same download. A checksum published next to the artifact only detects corruption, not tampering: anyone who can replace `secure-gpu-stack-0.1.0.tar.gz` can replace `SHA256SUMS` too. The README's "with a published checksum to verify first" (line 34) and "check the tarball, then install" (line 76-79) overstate this.
Scenario: distribution host or its TLS is compromised; attacker swaps both files; user's `sha256sum -c` passes and `install.sh` runs attacker code as root.
Fix: sign `SHA256SUMS` with a release key (minisign/GPG) and have the README/cloud-init verify the signature, or publish the hash out-of-band (the cloud-init path embedding `SGS_SHA256` in user-data is the right model — make that the documented default).

---

**3. MEDIUM — NVIDIA driver apt pin likely does nothing (`origin` vs hostname)**
`files/apt-pin-nvidia-cuda:9` uses `Pin: origin developer.download.nvidia.com`. In apt, `Pin: origin` matches the **`Origin:` field of the Release file**, not the hostname. NVIDIA's CUDA repository Release file uses `Origin: NVIDIA`, so this pin probably matches nothing and the `Pin-Priority: -1` never applies — NVIDIA's own `nvidia-driver-*`/`cuda-drivers*` packages remain installable at normal priority, defeating the stated goal (comment lines 1-7). *Unverified* on the exact `Origin:` string, but the mechanism is wrong either way.
Scenario: installer or a later `apt install cuda-drivers` pulls NVIDIA's driver build instead of Ubuntu's, reintroducing the "security fixes blocked" problem the README claims to fix (README:36).
Fix: pin by the actual Release `Origin:` value (e.g. `Pin: origin "NVIDIA"`) or by `Pin: release o=NVIDIA,a=...`, and add an `sgs-check` assertion that `apt-cache policy nvidia-driver-*` shows the Ubuntu candidate.

---

**4. MEDIUM — `attack-demo.sh` root-SSH check gives false PASS**
`tests/attack-demo.sh:35` runs `ssh root@$HOST true` using the ubuntu user's key. If root login is *enabled* but that key isn't in root's `authorized_keys`, ssh fails for authentication reasons and the test prints "root login refused". The check conflates "auth failed" with "root login disabled".
Scenario: `PermitRootLogin yes` with a different key/password; demo reports PASS.
Fix: query `sshd -T | grep -i permitrootlogin` (expect `no`/`prohibit-password`), or attempt root login with a deliberately wrong credential and inspect the failure reason.

---

**5. MEDIUM — `user-checks.sh` "read-only stack" check passes on any pip failure**
`tests/user-checks.sh:28-32` treats *any* non-zero `pip install` as proof the stack is read-only. A network outage, a missing index, or a broken pip all make the install fail and the test print "pip install into the stack is refused (it's read-only)".
Scenario: machine has no outbound network; the venv is actually writable; test PASSes.
Fix: assert the failure is a permission error (grep stderr for `Permission denied`/`Read-only file system`), or directly test writability of `/opt/sgs/venv/lib/python3.12/site-packages` as the normal user.

---

**6. MEDIUM — README claim "Jupyter requires its token on every endpoint" is contradicted by the test**
`README.md:38` says Jupyter "requires its token on every endpoint", but `tests/user-checks.sh:43-44` asserts `http://127.0.0.1:8888/api` returns **200 without a token** — Jupyter's `/api` is an unauthenticated endpoint. The test itself demonstrates the claim is false.
Scenario: a user relies on the claim and exposes 8888 (e.g. via a Docker `-p 0.0.0.0:8888`), believing every endpoint needs the token; `/api` leaks server version/config unauthenticated.
Fix: correct the README to "the token is required for the UI and kernel endpoints; `/api` is public", and/or have the test assert `/api` is the *only* unauthenticated path.

---

**7. MEDIUM — cloud-init reboots on manifest existence, not install success**
`cloud-init/lambda-user-data.yaml:29` runs `install.sh … > /var/log/sgs-install.log 2>&1` under `set -e`, but `power_state` (lines 32-34) reboots whenever `/opt/sgs/manifest.txt` exists. If `install.sh` writes the manifest early and then fails (driver build, package fetch), the instance reboots into a half-installed state with no signal to the operator.
Scenario: transient apt failure after manifest creation → reboot → driver not loaded, stack broken, user sees a "successful" first boot.
Fix: have `install.sh` write the manifest only as its final step, and gate `power_state` on a success marker (e.g. `/opt/sgs/install-ok`) that is created last; also surface the log path in the failure case.

---

**8. MEDIUM — Login profile prepends stack dirs to PATH for every user, including root, without ownership checks**
`files/profile-sgs.sh:4-11` unconditionally prepends `/usr/local/cuda/bin` and `/opt/sgs/venv/bin` to `PATH` for every login shell (root included) based only on `[ -d … ]`. There is no check that these directories are root-owned and non-group/world-writable. If the venv or CUDA bin dir ever becomes writable (mis-set permissions, a package that drops files there, a future `sgs-venv`-style mistake), any user who can write there gets code execution as root in root's next login shell.
Scenario: `/opt/sgs/venv/bin` ends up group-writable; a member of that group drops a `python3` shim; root logs in and runs it.
Fix: in the profile, only prepend if `stat -c '%U:%a'` shows root-owned and not group/world-writable; otherwise skip and warn. Add the same assertion to `sgs-check`.

---

**9. LOW/MEDIUM — Profile leaves ML secrets readable to other local users**
`files/profile-sgs.sh` sets `HF_HUB_DISABLE_TELEMETRY=1` (line 14) but does not set a restrictive `umask` or `HF_HOME`. On a shared Lambda instance, notebooks, checkpoints, and the Hugging Face token cache (`~/.cache/huggingface/token`) are created with the default umask (022), so another local user can read them. The stack's "secure defaults" claim (README:3-5) doesn't cover this.
Scenario: two researchers share an instance; user B reads user A's `~/.cache/huggingface/token` and W&B credentials.
Fix: `umask 077` in the profile (or a documented `HF_HOME` under a 0700 dir), and have `sgs-check` verify the token cache is not group/world-readable.

---

**10. LOW — `torch.load` safety test can false-PASS on unrelated errors**
`tests/user-checks.sh:69-71` runs `torch.load(model.pt)` and passes if `$work/pwned` was not created. If `torch.load` fails for any reason other than refusing the pickle (import error, missing CUDA, corrupt file), `pwned` is absent and the test prints "torch.load refuses to run the model's hidden code".
Scenario: torch import broken; test PASSes while the actual `weights_only` default is unsafe.
Fix: capture the exit status and require a specific `weights_only`/`UnpicklingError` failure, or assert `torch.load.__defaults__`/`inspect.signature` shows `weights_only=True`.

---

**11. LOW — cloud-init `--proto '=https'` does not restrict redirects**
`cloud-init/lambda-user-data.yaml:26` uses `curl --proto '=https'`, which only constrains the initial URL; `--proto-redir` defaults to allowing `http`, so an HTTPS→HTTP redirect is followed. The subsequent `sha256sum -c` still catches a modified tarball, so this is a downgrade/leak risk rather than a full compromise.
Scenario: attacker controls the release host and redirects to plain HTTP; tarball is served over cleartext (integrity saved only by the embedded SHA).
Fix: add `--proto-redir '=https'` (and `--tlsv1.2` is already present).

---

**12. LOW — `tf-cuda12.in` uses version ranges; "hash-verified wheels only" depends on an unshown lock**
`python/tf-cuda12.in:6-17` specifies `>=,<` ranges, not pinned versions. README criterion 7 (README:24) and the "hash-locked" claim (README:37) only hold if `python/lock.sh` produces a hash-pinned lockfile for `tf-cuda12` and the installer consumes it. *Unverified* — the lockfile and installer aren't in this round's material.
Scenario: if `tf-cuda12` is installed from the `.in` ranges without a hash lock, a compromised PyPI package (or a resolver picking a malicious version in range) is installed and loaded into TensorFlow.
Fix: confirm `lock.sh` emits `tf-cuda12` hashes and that the installer uses `--require-hashes` for it; add an `sgs-check` assertion that every installed dist has a recorded hash.
