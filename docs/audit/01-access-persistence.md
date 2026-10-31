# Audit 01 — access, identity, privilege, persistence

**Target:** live Lambda Cloud instance, DEFAULT Lambda Stack 24.04 image (Ubuntu 24.04.4, kernel
`6.8.0-1046-nvidia`, A100-SXM4-40GB, driver 580.105.08, `lambda-stack-cuda 0.1.17~24.04.1`; image
built 2026-02-25, audited 2026-10-30). **Method:** read-only over SSH as `ubuntu` (passwordless
sudo); `apt-get update` ran at 20:40 UTC so candidates are current. No fixes, no exploits, temp
`/tmp` file removed. Jupyter token, tunnel secret, account tag and key material are redacted
(path/mode/presence only); tunnel hostname/ID masked — this repository is public.

## Summary

| ID | Severity | Finding | Status |
|---|---|---|---|
| ACC-01 | High | JupyterLab published to the internet via a Lambda Cloudflare tunnel; only auth is a bearer token in the URL, and Jupyter runs as `ubuntu` (passwordless sudo) → token leak = root | Verified |
| ACC-02 | High | Image 8 months stale (303 pending updates, 228 security) and `APT::Periodic::Unattended-Upgrade "0"` disables automatic security updates | Verified |
| ACC-03 | High | Internet-facing `cloudflared` runs as root, unsandboxed (systemd-analyze 9.6 UNSAFE), 8 months old, with a root self-update timer that cannot update a dpkg install | Verified |
| ACC-04 | Medium | Cloudflare tunnel credentials are world-readable (0644); the Jupyter token is 0644 but sits behind a 0750 home | Verified |
| ACC-05 | Medium | `lambda-jupyter.service` executes user-writable code (`~/.local/bin/jupyter` → pipx venv) as ubuntu every boot, unsandboxed, `Restart=always` | Verified |
| ACC-06 | Medium | SSH: agent forwarding on, no idle timeout (`ClientAliveInterval 0`), unrestricted TCP forwarding (`PermitOpen any`, `PermitListen any`) | Verified |
| ACC-07 | Low | No host firewall (`ufw` inactive, `INPUT ACCEPT`); `rpcbind:111` and postfix `:25` on 0.0.0.0, protected only by Lambda's upstream rules; `glances` runs as root | Verified |
| ACC-08 | Low | `PermitRootLogin without-password` with root's key identical to ubuntu's; only a forced command prevents a root shell | Verified |
| ACC-09 | Low | SSH hygiene: legacy `.ssh/authorized_keys2` honoured, `hmac-sha1`/`umac-64` accepted, `RequiredRSASize 1024`, `DebianBanner yes`, no login banner | Verified |
| ACC-10 | Low | No lockout/rate limiting (no fail2ban, no `pam_faillock`), `pam_unix.so nullok`, no password quality or aging policy | Verified |
| ACC-11 | Low | Legacy `%admin` group grants full sudo to any member; cloud-init grants `NOPASSWD:ALL` (broader than needed) | Verified |
| ACC-12 | Info | Hygiene: umask 0002 vs `login.defs` 022, `memlock unlimited` for all, `/var/crash` 3777, no sudo I/O logging, logs local only (~5 weeks) | Verified |

**Counts:** Critical 0 · High 3 · Medium 3 · Low 5 · Info 1.

## Confirmed known findings (real-instance evidence, not duplicated)

- **confirms #1** — `apt-cache policy nvidia-driver-580-server-open`: Lambda `580.105.08-0lambda0.24.04.1`
  at priority **1001**, Ubuntu `580.178.04-0ubuntu0.24.04.1` (noble-updates + noble-security) at
  **500**; installed driver 580.105.08. **#5** — Lambda source line is plain HTTP. **#6** —
  `/etc/apt/trusted.gpg.d/lambda-keyring.gpg` symlinks into `/usr/share/keyrings`.
- **confirms #9** — `kernel.apparmor_restrict_unprivileged_unconfined = 0` (`..._userns = 1`);
  **#10** — `io_uring_disabled = 0`; **#12** — `sshd -T`: `x11forwarding yes`; **#14** — lockdown `[none]`.
- **confirms #13 (partly)** — `ubuntu` reaches `169.254.169.254`, but `/latest/meta-data/`,
  `/latest/user-data`, `/latest/vendor-data` return 404, so no IMDSv1 secret exposure confirmed;
  Lambda's own metadata API was not enumerated (out of scope).
- Re-verified: `passwordauthentication no`, `permitrootlogin without-password`, `ubuntu`/`root`
  passwords locked (`L`), root's key = same ed25519 key as ubuntu's + forced command (exit **142**),
  host keys regenerated at boot, `docker` group empty.

## ACC-01 — JupyterLab published to the internet; token is the only barrier

**Component:** `cloudflared.service` → Cloudflare tunnel → `lambda-jupyter.service`.
```bash
sudo ss -ltnp | grep -E '7000|cloudflared'   # 127.0.0.1:20241 cloudflared ; 127.0.0.1:7000 jupyter-lab
sudo grep -vE '^\s*#' /etc/cloudflared/config.yml
# tunnel <tunnel-id>; hostname <instance>.lambdaspaces.com -> http://localhost:7000
curl -sI https://<instance>.lambdaspaces.com/      # HTTP/2 302 ; location: /lab?  (Jupyter's own redirect)
curl -s https://<instance>.lambdaspaces.com/login | head -4   # <title>Jupyter Server</title>
grep -E 'allow_remote_access|ServerApp.ip|ServerApp.port' /home/ubuntu/.jupyter/jupyter_config.py
# allow_remote_access = True ; ip = 127.0.0.1 ; port = 7000
```
No Cloudflare Access in front. Token is 32 hex chars (128-bit random, not a default — common
candidates tested by hash) in a 0644 file; `ubuntu` has `NOPASSWD:ALL`, Jupyter kernels are
arbitrary code as `ubuntu`.
**Impact:** the root-equivalent control plane is reachable from the whole internet. The only secret
is a bearer token in the URL (`/lab?token=…`), so it lands in browser history, Cloudflare edge logs,
shell history and screenshots. No MFA, rate limit, IP allowlist or Access policy; a leaked token
gives root without SSH. No pre-auth path found, so High, not Critical.
**Remediation:** Cloudflare Access or mTLS in front, or the Secure GPU Stack design (Jupyter on a
private Unix socket behind an SSH tunnel, Round I); if public ingress stays, run Jupyter as a
dedicated non-sudo account and rotate the token after suspected exposure. **Confidence:** high.

## ACC-02 — Stale image, automatic security updates disabled

**Component:** apt / `unattended-upgrades`.
```bash
cat /etc/apt/apt.conf.d/20auto-upgrades   # Update-Package-Lists "1" ; Unattended-Upgrade "0"  <- installs nothing
apt list --upgradable 2>/dev/null | grep -c /          # 303
apt list --upgradable 2>/dev/null | grep -c security   # 228
```
`20auto-upgrades` is dated 2026-02-25 21:23 (image build), so this is baked in. Unapplied:
openssh-server 13.14 → 13.20, libc6 8.7 → 8.9, sudo .1 → .4, snapd 2.73 → 2.77.1, kernel
`linux-nvidia` 1046.49 → 1064.67 (18 ABI revisions), cloudflared 2026.2.0 → 2026.10.7,
containerd.io 2.2.1 → 2.4.2. Ubuntu changelogs list **11 OpenSSH CVEs** fixed in 13.19/13.20
(CVE-2026-73281, -73282, -106552, -106553, -106555, -106582 … -106587), plus **CVE-2026-82474**
and **CVE-2026-96512** in sudo and CVE-2026-3888 in snapd.
**Impact:** every instance starts 8 months behind and nothing installs the next fix; pending sshd
and kernel fixes never land (sshd is internet-facing).
**Remediation:** `APT::Periodic::Unattended-Upgrade "1"` with `Allowed-Origins` plus a blacklist for
pinned NVIDIA/CUDA packages; rebuild the image monthly. **CVE/ref:** above (Ubuntu changelogs,
2026-10-30). **Confidence:** high.

## ACC-03 — Internet-facing cloudflared runs as root, unsandboxed, outdated

**Component:** `/etc/systemd/system/cloudflared.service`, `cloudflared-update.{service,timer}`.
```bash
systemctl show cloudflared -p User -p NoNewPrivileges -p ProtectSystem -p CapabilityBoundingSet
# User= (root) ; NoNewPrivileges=no ; ProtectSystem=no ; full capability set
sudo systemd-analyze security cloudflared.service | grep Overall      # 9.6 UNSAFE
cloudflared --version                                                  # 2026.2.0 (built 2026-02-06)
cat /etc/systemd/system/cloudflared-update.service
# ExecStart=/bin/bash -c '/usr/bin/cloudflared update; … exit 0 …'   (daily 00:00 UTC)
```
The daemon parsing attacker-controlled HTTP runs as uid 0 with every capability, no sandboxing,
8 months behind (2026.10.7 available). The timer runs `cloudflared update` as root from the network;
for a dpkg install that is not a supported updater (exit 11), so it just restarts the tunnel and
fixes never land.
**Impact:** any cloudflared bug or supply-chain compromise is immediate root; the self-update is a
root-level path fed from the network; daily restarts.
**Remediation:** dedicated user, `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`,
`PrivateTmp=yes`, `CapabilityBoundingSet=`, `RestrictAddressFamilies=AF_INET AF_INET6`; update via
apt; drop the timer. **Confidence:** high.

## ACC-04 — Tunnel credentials are world-readable; the Jupyter token is 0644 behind a 0750 home

**Component:** `/etc/cloudflared/jupyter-tunnel.json` (0644 root), `/etc/cloudflared/config.yml`,
`/home/ubuntu/.jupyter/jupyter_config.py` (0644).
```bash
ls -l /etc/cloudflared/jupyter-tunnel.json        # -rw-r--r-- 1 root root 265 …
test -r /etc/cloudflared/jupyter-tunnel.json && echo readable-by-ubuntu     # readable-by-ubuntu
sudo python3 -c 'import json;print(list(json.load(open("/etc/cloudflared/jupyter-tunnel.json"))))'
# ['TunnelID', 'AccountTag', 'TunnelName', 'TunnelSecret']
```
**Nuance (parent correction):** the tunnel file under `/etc` is genuinely readable by every local uid.
The Jupyter config is 0644, but `/home/ubuntu` is 0750, so a second user cannot traverse to it today;
any process running as `ubuntu` (a notebook, a pip package) can. It is still too broad for backups,
snapshots and support bundles.
**Impact:** any local account or process can read the tunnel secret and run its own connector;
Cloudflare sends a share of the public hostname's traffic to it, which can serve a fake Jupyter
login and harvest the next token — persistence and phishing surviving loss of local access.
Escalation today is limited (the only account already has root); it blocks multi-user use.
**Remediation:** 0600/0400 root on both files and the Jupyter config; move the credential out of a
traversable directory; rotate secret and token. **Confidence:** high for exposure; hijack inferred.

## ACC-05 — Boot-time execution of user-writable code (Jupyter)

**Component:** `/etc/systemd/system/lambda-jupyter.service`.
```bash
grep -E 'ExecStart|User=|Restart' /etc/systemd/system/lambda-jupyter.service
# ExecStart=/home/ubuntu/.local/bin/jupyter lab --config /home/ubuntu/.jupyter/jupyter_config.py
# User=ubuntu ; Restart=always
ls -l /home/ubuntu/.local/bin/jupyter   # -> ~/.local/share/pipx/venvs/jupyter-core/bin/jupyter
sudo systemd-analyze security lambda-jupyter.service | grep Overall      # 9.2 UNSAFE
```
No integrity check, no sandboxing (`ProtectSystem=no`, `NoNewPrivileges=no`, `PrivateTmp=no`),
`PATH` starts with `~/.local/bin`.
**Impact:** anyone who can write the venv or config gets execution at every boot as `ubuntu` —
persistence across reboots and SSH key removal. Persistence, not escalation (`ubuntu` has root).
**Remediation:** root-owned entry point outside `/home`; `NoNewPrivileges=yes`,
`ProtectSystem=strict`, `ProtectHome=read-only`, fixed `PATH`, dedicated non-sudo account; watch
the path in the integrity baseline. **Confidence:** high.

## ACC-06 — SSH: agent forwarding, no idle timeout, unrestricted forwarding

**Component:** `/etc/ssh/sshd_config` (stock).
```bash
sudo sshd -T | grep -E '^(allowagentforwarding|clientaliveinterval|clientalivecountmax|allowtcpforwarding|permitopen|permitlisten|gatewayports)'
# allowagentforwarding yes ; clientaliveinterval 0 ; clientalivecountmax 3
# allowtcpforwarding yes ; permitopen any ; permitlisten any ; gatewayports no
```
A pty session opened at 20:43 was still present ~20 minutes later; no timeout.
**Impact:** a compromised instance can use a forwarded agent to authenticate to the user's other
machines as long as the session lives, and sessions never expire; any account can tunnel anywhere
(including `169.254.169.254` and Lambda's private network) and bind loopback forwards to
Jupyter/glances.
**Remediation:** `AllowAgentForwarding no`, `ClientAliveInterval 300` + `ClientAliveCountMax 2`,
`AllowTcpForwarding local` with a `PermitOpen` allowlist (or `no`), `PermitListen none`.
`GatewayPorts no` is already correct. **Confidence:** high.

## ACC-07 — No host firewall; unneeded root services on 0.0.0.0

**Component:** ufw/nftables, rpcbind, postfix, glances.
```bash
sudo ufw status                       # Status: inactive
sudo iptables -S | head -2            # -P INPUT ACCEPT / -P FORWARD DROP
sudo ss -ltnp | grep -E ':111|:25'    # 0.0.0.0:111 rpcbind ; 0.0.0.0:25 postfix
nc -z -w5 <host> 111 ; nc -z -w5 <host> 25   # both filtered from the internet
ps -o user,args -C glances   # root /usr/bin/glances -s -B 127.0.0.1 (v3.4.0.3)
```
Only 22 and the tunnel work from outside; 111/25 are blocked upstream by Lambda, not the host.
Docker manages iptables chains that bypass ufw. `glances` runs as root and writes
`/tmp/glances-root.log` (root, 0644, predictable path).
**Impact:** no defense in depth — one firewall change, rescue-mode boot or `docker -p` publish
exposes RPC/SMTP; a root daemon writing to a predictable `/tmp` path is a symlink target if
restarted while an attacker pre-creates it.
**Remediation:** default-deny inbound except 22 and the tunnel; disable rpcbind/postfix; run glances
as its own user with `LogFile` under `/var/log`, or drop it. **Confidence:** high.

## ACC-08 — Root login by key, guarded only by a forced command

**Component:** `/root/.ssh/authorized_keys`, sshd.
```bash
sudo ssh-keygen -lf /root/.ssh/authorized_keys
# 256 SHA256:tZdxcyn… (ED25519) no-port-forwarding,no-agent-forwarding,no-X11-forwarding,
# command="echo 'Please login as the user \"ubuntu\" …';echo;sleep 10;exit 142"
ssh-keygen -lf /home/ubuntu/.ssh/authorized_keys   # same fingerprint, no options
ssh -o BatchMode=yes root@<host> true ; echo $?    # prints the message; 142
```
Forced command works — no shell, no forwarding. But the key is the same one that authorizes
`ubuntu`, root login is enabled, and the entry lacks `restrict`, `no-pty`, `from=` and `no-user-rc`;
the 10 s sleep holds session slots (`MaxStartups 10:30:100`).
**Impact:** a stolen user key is also a root credential; one sshd option is the only barrier, and
deleting `command=` (or adding a second key) silently yields a root shell.
**Remediation:** remove root's key, `PermitRootLogin no`; root only via sudo. **Confidence:** high.

## ACC-09 — SSH hygiene: authorized_keys2, weak MACs, banner

```bash
sudo sshd -T | grep -E '^(authorizedkeysfile|macs|requiredrsasize|debianbanner|banner)'
# authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2
# hmac-sha1-etm@openssh.com, umac-64, hmac-sha1 … ; requiredrsasize 1024 ; debianbanner yes ; banner none
sudo ls /root/.ssh/ /home/ubuntu/.ssh/     # only authorized_keys today
```
`authorized_keys2` is an inherited Debian/Ubuntu default: a second, legacy key file audits, key
rotations and integrity checks ignore — a stealth persistence slot surviving removal from
`authorized_keys`. SHA-1 MAC downgrade and 1024-bit RSA keys are accepted; the Ubuntu version is
disclosed; no pre-login warning.
**Remediation:** `AuthorizedKeysFile .ssh/authorized_keys`, `MACs hmac-sha2-256-etm@openssh.com,
hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com`, `RequiredRSASize 2048`, `DebianBanner no`,
`Banner /etc/issue.net`; report any `authorized_keys2`. **Confidence:** high (Low: defaults safe).

## ACC-10 — No lockout, no password policy, `nullok`

```bash
systemctl list-unit-files | grep -icE 'fail2ban|sshguard'   # 0
sudo faillock                                               # Error reading tally directory
grep pam_unix /etc/pam.d/common-auth                        # pam_unix.so nullok
grep -E '^PASS_(MAX|MIN)_DAYS' /etc/login.defs              # 99999 / 0
ls /etc/security/pwquality.conf                             # absent
```
`permitemptypasswords no` and locked passwords close the obvious hole.
**Impact:** empty-password accounts could authenticate on console/serial/`su`; unlimited failed
attempts on an internet-facing daemon; no expiry or complexity policy if a password is ever set.
**Remediation:** `pam_faillock` (deny=5, unlock_time=900), drop `nullok`, enable `pwquality`,
sensible `PASS_MAX_DAYS`, and fail2ban or sshd `PerSourcePenalties` if SSH stays exposed.
**Confidence:** high.

## ACC-11 — Legacy `%admin` group and an over-broad NOPASSWD rule

```bash
sudo grep -vE '^#|^$' /etc/sudoers | grep -E 'admin|sudo'   # %admin ALL=(ALL) ALL ; %sudo ALL=(ALL:ALL) ALL
sudo -l | tail -3            # (ALL) ALL ; (ALL) NOPASSWD: ALL
getent group admin sudo      # admin:x:110:ubuntu ; sudo:x:27: (empty)
```
`Defaults` are otherwise good: `env_reset`, `use_pty`, `secure_path`, `mail_badpass`, no `env_keep`
of `LD_*`. **Impact:** any future user added to `admin` (old docs, muscle memory) gets root without
being in `sudo`; NOPASSWD removes the last confirmation step for anyone who reaches `ubuntu` (e.g.
ACC-01/ACC-05). **Remediation:** delete `%admin`, keep `%sudo`, replace `NOPASSWD:ALL` with an
allowlist or password, or document the exception. **Confidence:** high.

## ACC-12 — Session, logging and umask hygiene (Info)
Login accounting works (pty sessions appear in `who`/`last`/`lastlog`; the earlier "never logged in"
was an artefact of non-pty `ssh host cmd`). `wtmp`/`btmp` 0660 `root:utmp`, `lastlog` 0664.
`auth.log` 0640 `syslog:adm`, weekly ×4 (~5 weeks), local only — no `auditd`, no remote syslog, so
root can erase traces; sudo logs commands but not I/O. `umask` is **0002**, not `login.defs` 022
(`pam_umask` + `USERGROUPS_ENAB`): private group, so not world-writable, but it contradicts the
documented default. `memlock unlimited` for all (NCCL choice) lets any account lock all RAM.
`systemctl status cloudflared`/`user@0` warn "unit file changed on disk" — cloud-init rewrites
cloudflared units at boot without `daemon-reload`, so loaded ≠ on-disk until the next boot. Good:
home 0750, `.ssh` 700, keys 600, `fs.suid_dumpable=0`, `ptrace_scope=1`; `/var/crash` 3777 stock.

## Checked and not a finding
- `ubuntu`/`root` passwords locked (`passwd -S` → `L`); no empty hashes. Modes: `/etc/passwd` 0644,
  `/etc/shadow` 0640 `root:shadow`, `/etc/shadow-` 0640, `/etc/group` 0644, `/etc/sudoers` 0440,
  `/etc/sudoers.d` 0750 + 0440. Host keys ed25519/ECDSA P-256/RSA-3072, 0600 root, unique per boot.
- `docker` group empty; `docker.sock` 0660 `root:docker`; `containerd.sock` 0660 `root:root`; no
  containers, no restart policies. Rootful `podman.socket` enabled but `/run/podman` is root-only.
- No Lambda-added setuid/setgid: stock list only. `nvidia-modprobe` and `pkexec` are **not
  installed**; `snap-confine` is not setuid and is AppArmor-confined (21 profiles enforcing).
- No world-writable dirs outside `/tmp`, `/var/tmp`, `/var/crash`; no writable `/etc` files;
  `/usr/local/{bin,sbin,lib}` and `/snap/bin` root-owned, so `secure_path` is safe;
  `/etc/ld.so.preload` absent; `ld.so.conf.d` clean.
- Persistence: no user/root crontabs; `/etc/cron.*` only stock; `at` not installed; no
  `/etc/rc.local`; no user units; linger off; no custom generators; `~/.pam_environment`,
  `~/.ssh/rc`, `/etc/ssh/sshrc` absent. `profile.d` all root-owned; `lambda-mpivars.sh` only sets
  MPI paths from root-owned `/usr/mpi`; `update-motd.d` root-owned; `motd-news` masked.
- PAM: no `pam_exec`/`pam_script`, no NIS/LDAP/sss; `pam_env` user_readenv=1 is stock.
  `PermitUserEnvironment no`, `GatewayPorts no`, `StreamLocalBindMask 0177`, `UsedNS no`,
  `StrictModes yes`, `ExposeAuthInfo no`.
- Jupyter token is high-entropy (128-bit), not a default; problem is exposure (ACC-01/04).
  `/etc/apt/auth.conf.d` empty. Cloud metadata reachable, but AWS-style user-data/vendor-data
  paths 404 (see #13).

## Limits
Read-only; no exploit, no forced-command bypass, no metadata API enumeration, no per-CVE
exploitability analysis (CVEs from Ubuntu changelogs, not proven exploitable here). Tunnel
hostname/ID masked; full values in the run notes.
