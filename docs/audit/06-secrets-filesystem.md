# 06 — Secrets, filesystem and ML model safety

**Host:** `ubuntu@<instance>` — Lambda Cloud A100, Ubuntu 24.04.4 LTS, kernel `6.8.0-1046-nvidia`,
default Lambda Stack image. First boot 2026-10-30 20:30 UTC; audit 20:42–21:00 UTC.
**Mode:** read-only — no file, mode, package or service changed, no reboot. No second account was
created: second-user checks use `sudo -u nobody` (uid 65534), which needs no writes. The tunnel was
not hijacked; public exposure was measured with unauthenticated HTTPS `GET`s only.
**Values:** all secrets are redacted; only paths, modes and lengths appear.
**Severity counts: Critical 0 · High 2 · Medium 4 · Low 3.**

## Summary

| ID | Finding | Severity |
|---|---|---|
| SEC-01 | Cloudflare tunnel credentials are world-readable (`0644`); any local account can run a replica connector | High |
| SEC-02 | JupyterLab is publicly reachable through the tunnel with token-only auth; no Cloudflare Access, terminal enabled | High |
| SEC-03 | Jupyter token sits in a `0644` file; only the `0750` home directory stops other users | Medium |
| SEC-04 | `cloudflared` self-updates from the network as root daily (unsigned, unpinned, overwrites a dpkg file) | Medium |
| SEC-05 | No model-safety tooling: `safetensors`, `modelscan`, `picklescan` absent; Keras 3.10.0 has safe-mode bypass CVEs | Medium |
| SEC-06 | System-wide `break-system-packages = true` lets pip mutate the OS Python | Medium |
| SEC-07 | Live tunnel credentials and token persist on disk and in the cloud-init seed; snapshots/clones inherit them | Medium |
| SEC-08 | `cloudflared` runs as root with no sandboxing (`systemd-analyze security` 9.6 UNSAFE) | Low |
| SEC-09 | umask `0002` makes new files group/world-readable (`0664`/`0775`) | Low |
| SEC-10 | Jupyter auth config is deprecated and unrotatable (`ServerApp.token`, `allow_password_change=False`) | Low |

## SEC-01 — Cloudflare tunnel credentials are world-readable

```text
$ stat -c '%A %U:%G %n' /etc/cloudflared /etc/cloudflared/*
drwxr-xr-x root:root /etc/cloudflared
-rw-r--r-- root:root /etc/cloudflared/config.yml
-rw-r--r-- root:root /etc/cloudflared/jupyter-tunnel.json
$ sudo -u nobody sh -c 'cat /etc/cloudflared/jupyter-tunnel.json >/dev/null' && echo readable
readable      # JSON keys: AccountTag, TunnelID, TunnelName, TunnelSecret
```
Any uid — a second account, a service user, a container with `/etc` mounted, or a process that
escaped its own account — can read the connector credential. **Impact:** copying the file and
running `cloudflared tunnel run` elsewhere registers a second connector for the tunnel. Cloudflare
balances requests across connectors, so the attacker receives real traffic for the public Jupyter
URL: request URIs (which carry `?token=` on first load), cookies and POST bodies, and can serve fake
login pages. It cannot delete the tunnel or change DNS (that needs the account API token /
`cert.pem`). Only file modes were read; no replica was started.

**Remediation.** `chmod 600` the JSON and `700` the directory, or chown to a dedicated `cloudflared`
user with `0400`, plus `UMask=0077` in the unit. The file is written by cloud-init
(`/var/lib/cloud/instances/*/scripts/vendor/30-cloudflare`), so a plain `chmod` returns on a new
instance: put the mode in the vendor-data or add `tmpfiles.d` rules (`z /etc/cloudflared 0700 root
root`, `z /etc/cloudflared/jupyter-tunnel.json 0600 root root`). Rotate the tunnel secret afterwards.
Ref: Cloudflare Tunnel credentials docs; CWE-276.

## SEC-02 — JupyterLab is public, token-only, and gives a shell

```text
$ getent hosts <host>-0.lambdaspaces.com        -> 104.18.0.121 (Cloudflare edge)
$ curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://<host>/lab
302 https://<host>/login?next=%2Flab
$ curl -s -o /dev/null -w '%{http_code}\n' https://<host>/api/contents
403            # no cf-access-* headers: Cloudflare Access is not in front
963: c.ServerApp.token = <REDACTED>     964: allow_password_change = False
982: c.ServerApp.allow_remote_access = True    90: # terminals_enabled = True (default)
```
`ubuntu` has `(ALL) NOPASSWD: ALL` (cloud-init sudoers rule) and is in `admin`, so a valid token is
a root shell, not just notebook execution. **Impact:** a public shell protected by one 128-bit
bearer token that the user cannot change (SEC-10) and that is capturable through SEC-01 or from
browser history, a proxy or a URL referrer. No MFA, IP allowlist or Cloudflare policy.

**Remediation.** Put Cloudflare Access (or a service token) in front; or stop publishing Jupyter and
reach it through an SSH tunnel to the loopback port (what Secure GPU Stack does). Disable terminals
if unused; rotate the token. Ref: Jupyter Server "Securing the public server".

## SEC-03 — Jupyter token is in a `0644` file behind a `0750` home

```text
$ stat -c '%A %U:%G %n' /home/ubuntu /home/ubuntu/.jupyter /home/ubuntu/.jupyter/jupyter_config.py
drwxr-x--- ubuntu:ubuntu /home/ubuntu
drwxr-xr-x ubuntu:ubuntu /home/ubuntu/.jupyter
-rw-r--r-- ubuntu:ubuntu /home/ubuntu/.jupyter/jupyter_config.py
$ sudo -u nobody sh -c 'cat /home/ubuntu/.jupyter/jupyter_config.py >/dev/null' || echo denied
denied          # only because /home/ubuntu is 0750
```
The runtime copies are `600` (`jpserver-*.json`) and `644` inside a `700` directory
(`jpserver-*-open.html`, a meta-refresh URL containing `?token=`); the two copies under
`/var/lib/cloud/...` are `0600`/`0700` root. **Impact:** a home-mode or ACL change, a backup/copy
tool running as another user, a bind mount or `docker run -v /home/ubuntu` hands over a token that is
a root shell. The user cannot rotate it (`allow_password_change = False`, no `IdentityProvider.token`,
no password).

**Remediation.** `chmod 600` the config and `700` `.jupyter`; keep home `0700` (or `0750` and
documented); move the token into a `0600` file referenced by `c.IdentityProvider.token`; exclude
`.jupyter` from backups.

## SEC-04 — cloudflared updates itself as root every day

```text
$ systemctl is-enabled cloudflared-update.timer   -> disabled
$ systemctl is-active  cloudflared-update.timer   -> active   (Trigger: 2026-10-31 00:00 UTC)
# /etc/systemd/system/cloudflared-update.service  (no User=, so root)
ExecStart=/bin/bash -c '/usr/bin/cloudflared update; code=$?; ...'
```
`/usr/bin/cloudflared` is dpkg-owned (2026.2.0), but `cloudflared update` fetches the latest GitHub
release and replaces the binary in place — no signature, checksum, pin or package record. The timer
is `disabled` for boot but was started on this instance and is active. **Impact:** root code
execution if the release, DNS or TLS path is compromised; silent binary drift that `dpkg --verify`
will flag.

**Remediation.** `systemctl disable --now cloudflared-update.timer`; ship cloudflared as a pinned,
verified package and update under operator control.

## SEC-05 — No model-safety tooling; Keras safe mode is bypassable

```text
torch 2.7.0 · tensorflow 2.19.0 · jax 0.6.0 · keras 3.10.0 · numpy 1.26.4
transformers: ABSENT   safetensors: ABSENT
modelscan: absent   picklescan: absent   bandit: absent   pip-audit: absent   gitleaks: absent
$ python3 -c "import torch,inspect;print(inspect.signature(torch.load))"
(..., *, weights_only: Optional[bool] = None, ...)
```
Behaviour test with a pickle whose `__reduce__` prints a marker: default `torch.load(path)` refused
with `UnpicklingError`; `weights_only=False` executed it — torch 2.7's default is already safe. Keras
`load_model(..., safe_mode=True)` is the default, but 3.10.0 predates the fixes for CVE-2025-9905,
CVE-2025-8747 and CVE-2026-12481, which bypass `safe_mode` (`docs/lambda-stack-findings.md` §3).
**Impact:** `safetensors` — the safe default format — is not installed, so the safe path does not
exist out of the box; there is no scanner for a pickle, `.h5` or `.keras` file before it is loaded.
Loading a checkpoint from Hugging Face or a colleague is code-execution territory, mitigated only by
torch's default.

**Remediation.** Install `safetensors`, `modelscan`, `picklescan`; document safetensors as the
default; keep `weights_only=True`; upgrade Keras; add a pre-load scan step.

## SEC-06 — pip is allowed to mutate the OS Python

```text
$ cat /etc/pip.conf   ->  [global] break-system-packages = true
```
**Impact:** PEP 668 protection is gone system-wide: `pip install` writes into apt-managed framework
directories, can break the NVIDIA/CUDA Python packages, and hides changes from `dpkg --verify`. A
typo-squatted package installed this way persists across reboots.

**Remediation.** Remove the flag; use a virtualenv (or `pipx`, already used for `jupyter-core`) and
document it.

## SEC-07 — Credentials persist on disk and in the boot seed

```text
$ sudo cat /var/lib/cloud/instances/<id>/datasource
DataSourceNoCloud: DataSourceNoCloud [seed=/dev/vdb]
$ sudo blkid /dev/vdb -> ... UUID="2026-10-30-20-29-43-00" LABEL="cidata" TYPE="iso9660"
600 root  .../vendor-data.txt (token + TunnelSecret) · .../vendor-data.txt.i
700 root  .../scripts/vendor/30-cloudflare     400 root  .../obj.pkl
644 root  /etc/cloudflared/{config.yml,jupyter-tunnel.json}   644 ubuntu  ~/.jupyter/jupyter_config.py
```
The NoCloud seed ISO was created at 20:29:43, one minute before boot; the files above are copies of
it. `/var/backups` is empty and no log contains the secret, so there is no live backup leak — the
problem is the lifecycle. **Impact:** a disk image, snapshot or clone carries the working tunnel
credential and Jupyter token. Two machines then answer the same hostname (with Cloudflare balancing
between them, so one sees the other's traffic), and the token stays valid on the clone. Nothing
rotates either.

**Remediation.** On clone: `cloudflared tunnel rotate-secret`, regenerate the Jupyter token, re-run
the seed. Exclude `/etc/cloudflared` and `~/.jupyter` from images; document that a snapshot is a
credential copy.

## SEC-08 — cloudflared runs as root, unsandboxed

```text
$ ps -o user=,args= -p $(pidof cloudflared)
root  /usr/bin/cloudflared --no-autoupdate --config /etc/cloudflared/config.yml tunnel run
$ systemd-analyze security cloudflared.service --no-pager | tail -1
→ Overall exposure level for cloudflared.service: 9.6 UNSAFE :-{
```
The unit sets no `User=`, `NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp` or
capability bound; `lambda-jupyter.service` scores 9.2 with the same gaps (a default-exposure
indicator, not a CVSS). **Impact:** a bug in cloudflared's HTTP/2 or QUIC stack runs as root; a
Jupyter or extension bug runs with `ubuntu`'s full rights (root via `NOPASSWD:ALL`).

**Remediation.** `User=cloudflared` (or `DynamicUser=yes`) with the credential readable only by it;
`ProtectSystem=strict`, `ProtectHome=tmpfs`, `NoNewPrivileges=yes`,
`RestrictAddressFamilies=AF_INET AF_INET6`, `CapabilityBoundingSet=`.

## SEC-09 — umask `0002` makes new files group/world-readable

```text
$ umask -> 0002     $ touch /tmp/x && stat -c '%a' /tmp/x -> 664
$ grep -E '^(UMASK|USERGROUPS_ENAB|HOME_MODE)' /etc/login.defs
UMASK 022 · HOME_MODE 0750 · USERGROUPS_ENAB yes
```
Stock Debian/Ubuntu `pam_umask` behaviour (022 becomes 002 for user-private groups), not a Lambda
change; listed for its effect on ML data. **Impact:** datasets, checkpoints, logs and exported keys
written by notebooks are readable and group-writable by every local account; today only the `0750`
home contains that. Anything written to `/tmp`, `/srv`, a mounted dataset disk or a shared directory
is exposed to any other uid. The world-writable scan is clean: 0 files outside
`/tmp|/var/tmp|/dev/shm`, 0 directories without the sticky bit, and those three are `1777`.

**Remediation.** `UMASK 027` in `/etc/login.defs` (or `umask 0027` in `/etc/profile.d/`); keep homes
`0750`; use `install -m 600` for secret files.

## SEC-10 — Jupyter auth config is deprecated and unrotatable

```text
963: c.ServerApp.token = <REDACTED>     964: c.ServerApp.allow_password_change = False
982: c.ServerApp.allow_remote_access = True
```
The service log warns: `ServerApp.token config is deprecated in 2.0. Use IdentityProvider.token.`
There is no password, no `IdentityProvider.token`, no client certificate, and terminals are enabled
(`960: ip = '127.0.0.1'`, `1061: local_hostnames = ['<host>-0.lambdaspaces.com']`). **Impact:** the
token cannot be changed from the UI, and the setting is on a deprecation path: a Jupyter Server that
drops `ServerApp.token` would fall back to a generated token printed in the journal (or to no auth if
misconfigured) — which is why the journal is worth watching. Today rotation means editing a
cloud-init-generated file.

**Remediation.** Move to `c.IdentityProvider.token` sourced from a `0600` file; disable terminals if
unused; keep `allow_remote_access` only while the tunnel exists; document rotation.

## Is the Jupyter token per-instance or baked into the image?

**Conclusion: per-instance, rendered by Lambda's control plane at launch. It is neither baked into
the image filesystem nor generated at boot on the host.** It persists for the life of the instance
(and across reboots) because the NoCloud seed and cloud-init cache are reused.

1. **The payload is rendered per instance.** `30-cloudflare` writes `jupyter-tunnel.json`,
   `config.yml` and `jupyter_config.py` from `cat > ... << 'EOF'` heredocs, with the token as a
   literal at line 986. The same bundle carries `90-first-boot`, whose constants match this machine:
   `IP_MASK = "<instance-private-ip>/20"` (equal to `eno1`) and `EXPECTED_GPU_COUNT = 1`. A shared static
   artifact cannot contain the instance's IP.
2. **The seed is created at launch.** `/dev/vdb` is ISO9660 `cidata` with UUID
   `2026-10-30-20-29-43-00`; boot was 20:30.
3. **Nothing generates it on the host.** No `openssl rand`, `uuidgen`, `/dev/urandom`, `head -c` or
   `sed -i` in `30-cloudflare` or `90-first-boot`; `jupyter_config.py` is written verbatim at 20:30
   and never touched (`.jupyter/migrated` is from the image build, 2026-02-25).
4. **It is not in the image.** A whole-filesystem search for the live value (pattern fed on stdin,
   never printed) matched only boot-generated files: cloud-init cache, live config, Jupyter runtime
   JSON/HTML. Nothing under `/usr`, `/opt`, `/etc` or `/var/lib/dpkg`.
5. **It is not derived from identifiers.** Unrelated to `AccountTag`, `TunnelID`, the instance UUID
   and the hostname prefix (md5/sha256 combinations checked), so not predictable from them.

Residual uncertainty: one instance cannot prove two instances differ. To settle it, launch a second
instance from the same image and compare the token in `~/.jupyter/jupyter_config.py` (compare
locally; do not copy the value anywhere). If it is a shared constant, SEC-03 becomes Critical — a
public, reusable root shell on every Lambda Stack machine.

**Correction to earlier notes:** Jupyter does **not** log the token.
`journalctl -u lambda-jupyter | grep -c <token>` is 0, and startup only reports the
`ServerApp.token` deprecation warning. The only hits in `/var/log/auth.log` and the user journal are
the audit's own `sudo grep` command lines.

## Checked and not a finding

- `/etc/shadow`, `/etc/gshadow` `0640 root:shadow`; `/etc/sudoers` `0440`; `/etc/sudoers.d` `0750`
  with `0440` files; `/root` and `/root/.ssh` `0700`. `/root/.ssh/authorized_keys` has a forced
  command refusing root login (`Please login as the user "ubuntu"`), so
  `PermitRootLogin prohibit-password` is inert. The `ubuntu` key is one ed25519 key injected at boot
  (`authorized_keys` mtime 20:30), `0600`.
- `ubuntu`'s password is locked (`passwd -S` → `L`); sshd is key-only (`passwordauthentication no`,
  `kbdinteractive no`, `permitemptypasswords no`). SSH host keys `0600 root`, generated at first
  boot; `/etc/machine-id` rewritten at 20:30 → per-instance, not a shared image value.
- setuid/setgid inventory is stock Ubuntu (chage, chfn, chsh, crontab, mount, passwd, sudo, su, …);
  capabilities only snap-confine, ping, mtr-packet and gst-ptp-helper; `/etc/ld.so.preload` absent.
- No swap; `core_pattern=core`, `fs.suid_dumpable=0`, `ulimit -c 0`, `/var/crash` empty, no
  deleted-but-open files; `ptrace_scope=1`; `fs.protected_hardlinks/symlinks/fifos/regular` on.
- No `.netrc`, `.git-credentials`, `.aws`, `.config/gcloud`, `~/.docker/config.json`, HF/W&B
  variables, `.env` files, shell history or private keys in `/home/ubuntu`; `/etc/environment` is
  only `PATH`; no `Environment=` secret in any unit; no secrets in `/etc/profile.d`.
- `/var/backups` empty; dpkg database normal; no world-readable backup. `/etc/cloudflared/*`
  belongs to no package (clean `dpkg -S`, but a clone still copies it). The TunnelSecret is in no
  log; the hostname appears in `syslog` (harmless).
- Logs are `0640 root:adm`/`syslog:adm`; `nobody` cannot read them, cannot run `journalctl`, and
  cannot read `/etc/shadow` or `/home/ubuntu`. `/var/lib/cloud/instances` is `0755`, but its files
  are `0600`/`0700`/`0400`.
- torch 2.7's default `weights_only` refuses a malicious pickle in a live test; Keras defaults to
  `safe_mode=True`; no model files exist yet; no notebook trust database (`nbsignatures.db`
  absent); `~/.ipython` is empty (no profile, no `startup/`); no injected `.pth` or `usercustomize`,
  only the stock Ubuntu apport `sitecustomize.py` (`0644 root`); only the user's own
  `site-packages` is writable; `PYTHONPATH` unset; `crontab` empty.
- Docker socket `0660 root:docker`; `ubuntu` is not in `docker` group and `nobody` cannot write it
  (root is reachable through `sudo` regardless). No extended/default ACLs on home or `.jupyter`;
  `~/.local/bin` `0755`; pipx venvs and `~/.config` `0775` — group-writable, but the group has only
  `ubuntu`.
- `glances` runs as root on `127.0.0.1:61209` with no configured password — it exposes process
  metadata `/proc` already exposes; not counted. `user-data.txt` is empty (0 bytes), so no
  launch-time secrets; `/run/cloud-init/instance-data.json` `0644` but contains no token.
- Ports are another agent's scope: `rpcbind` 111 and `postfix` 25 listen on `0.0.0.0`; Jupyter 7000
  and glances 61209 are loopback-only.

## Method note

No values were printed. To find copies of the token without echoing it, the value was held in shell
variables and a short-lived `/tmp` file (`.audit-tok`, mode 664 for under a minute, then deleted; all
`.audit-*` temporaries removed). Three `sudo grep -F <token>` calls put the value on `sudo`'s command
line, which `sudo` logs to `/var/log/auth.log` and the journal: those entries now contain it. The
instance is rented and disposable — destroy it, or rotate both the tunnel secret and the Jupyter
token, after the audit.
