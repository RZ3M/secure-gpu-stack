# Lambda Stack 24.04 on a real A100: security assessment

**Date:** 2026-10-30
**Target:** Lambda Cloud `gpu_1x_a100_sxm4` — Ubuntu 24.04.4 LTS, kernel
6.8.0-1046-nvidia, NVIDIA A100-SXM4-40GB, driver 580.105.08,
`lambda-stack-cuda 0.1.17~24.04.1`; image files dated 2026-02-25.
**Access:** SSH as `ubuntu`; passwordless sudo. Read-only audit: no fixes were
applied, no packages installed, no reboot, no exploit. Only this host and its own
public hostname were tested.
**Supporting evidence:** eight raw domain reports in `docs/audit/` and
`docs/audit/sgs-check-lambda-baseline.txt`. The raw reports contain the full
commands and outputs; this document is the deduplicated synthesis.
**Secrets:** the Jupyter token, Cloudflare `TunnelSecret`, account tag and SSH
key material are not reproduced here. The public tunnel hostname is masked as
`<instance>.lambdaspaces.com`.

> **How to read severity.** *Critical* = a realistic path from the internet (or
> a normal user action) to root or code execution. *High* = root/sensitive data
> with a local or authenticated step, a publicly exposed management plane, or a
> known exploitable CVE with no patch path. *Medium* = defence-in-depth,
> local DoS, information leak, or a patch/upgrade trap. *Low* = hardening gap.
> *Info* = observation or good practice.

## Bottom line

The default Lambda Stack image is built for convenience, not for security. It
works: all three frameworks run on the A100, and `sgs-check` scores it
**24 PASS / 30 WARN / 1 SKIP**. But the same image:

1. **Publishes JupyterLab to the internet over plain HTTP with a bearer token in
   the URL** (`http://<instance>.lambdaspaces.com/login` returns 200; there is no
   HSTS and no HTTPS redirect). The token is the only gate; the Jupyter process
   runs as `ubuntu`, who has `NOPASSWD: ALL` sudo. A token leak — an on-path
   attacker, a browser history, a screenshot, a shared link, a proxy/edge log —
   is root on the GPU host. **This was executed end-to-end (POC-1): token →
   kernel as `ubuntu` → `sudo -n` → root; POC-2 shows the public HTTP
   transport.**
2. **Is 228 security updates behind, with automatic security updates disabled.**
   The management plane, OpenSSH on port 22, is in that backlog; the pending
   OpenSSH update is reported to fix CVE-2026-60002 (CVSS 9.4, network vector).
   The Lambda repository itself is a frozen 2025-12-31 snapshot over plain HTTP.
3. **Ships a Jupyter/ML stack with more than 100 OSV advisories**, including
   token-theft XSS and one-click command execution in JupyterLab, a Critical
   stored XSS in Jupyter Server, an unauthenticated Tornado DoS, Keras
   `safe_mode` bypass code execution, and an fsspec SSTI RCE. JupyterLab is
   installed in a pipx venv outside apt, so neither `dpkg` nor
   unattended-upgrades sees it.
4. **Leaves the GPU and RDMA devices open to every local account**: `/dev/nvidia*`,
   `/dev/infiniband/uverbs0`, `/dev/infiniband/rdma_cm` and `/dev/knem` are
   0666. `nobody` can run `nvidia-smi`, allocate GPU memory and open RDMA. RDMA
   traffic bypasses the IP firewall/egress path, and the kernel driver is pinned
   to a version with NVIDIA's September 2026 fixes blocked by Lambda's apt pin.
5. **Has no host firewall and no audit/detection layer.** UFW is inactive,
   `iptables` is `INPUT ACCEPT`, and the instance is on a shared `10.19.80.0/20`
   private network. `auditd` is absent, logs are local and wipeable with sudo,
   there is no IDS/FIM/alerting, and the Cloudflare `TunnelSecret` is 0644 so any
   local account can clone the public endpoint.

For a single trusted user on a private network, the box is usable. For the
company's stated use — selling inference and letting ML engineers run code on
rented GPUs — the defaults are not safe. The Secure GPU Stack already fixes most
of these by design (Unix-socket Jupyter, no public tunnel, sandboxed service,
GPU modes, auditd, automatic updates); this report is the before picture and the
checklist for the remaining gaps.

## Baseline score

```text
$ sudo sgs-check --gpu-test
== Result: 24 PASS, 30 WARN, 1 SKIP

GPU 0: NVIDIA A100-SXM4-40GB
[PASS] PyTorch 2.7.0: 14.6 TFLOP/s (fp32 matmul); convolution OK
[PASS] JAX 0.6.0: 132.9 TFLOP/s (fp32 matmul); convolution OK
[PASS] TensorFlow 2.19.0: 19.4 TFLOP/s (fp32 matmul); convolution OK
```

The 30 WARNs are all reproduced below. The SKIP is the Python vulnerability
audit (`pip-audit` not installed); OSV was queried directly instead. `sgs-check`
is a host posture checklist, not an exploitability score: this run cannot see
the public Cloudflare edge, and its Python audit skipped, so **24 PASS** coexists
with the verified token → root chain. The scoring changes are in
[`sgs-check-gaps.md`](sgs-check-gaps.md). The secure
stack's own reference scores are 58 PASS / 0 WARN on the M2 VM and 55 / 3 on
krabs; a same-GPU "after" score will come from instance B.

## The attack chain in one picture (verified)

```text
Internet
  └─ http://<instance>.lambdaspaces.com      (Cloudflare Tunnel; no HTTPS
       │                                      redirect, no HSTS, no Access/MFA)
       └─ JupyterLab 4.5.5 / jupyter_server 2.17.0 / tornado 6.5.4
            ├─ token in URL; 0644 config; no rotation/revocation
            ├─ known XSS + token-theft (CVE-2026-40171, CVE-2026-42557,
            │   CVE-2026-44727, ...)
            └─ notebook or web terminal as ubuntu
                 └─ sudo -n  (NOPASSWD: ALL)
                      └─ root: GPU driver, Docker, SSH keys, tunnel secret,
                         model data, audit logs

Local / container
  ├─ /dev/nvidia* 0666 ─────────────► GPU DoS + driver 580.105.08 attack surface
  ├─ /dev/infiniband/uverbs0 0666 ──► RDMA outside the IP firewall/egress policy
  ├─ /dev/knem 0666 ────────────────► HPC kernel module attack surface
  └─ /etc/cloudflared/jupyter-tunnel.json 0644
       └─ run a second connector for the public hostname, harvest ?token=,
          serve a fake login, or sit on sessions
```

**This was executed, not just inferred.** POC-1 used the real token (read from
the config as `ubuntu`) to create a kernel, ran `sudo -n id`, and read
`/etc/shadow`; the kernel was deleted afterwards. POC-2 served the public login
page over `http://` and showed a dummy token in the request line. POC-3/5 showed
the unprivileged GPU/RDMA/`knem` primitives. The OpenSSH/kernel/driver CVEs were
not exploited and the live tunnel was not hijacked; those remain documented,
version-mapped risks. Full transcripts:
[`lambda-instance-pocs.md`](lambda-instance-pocs.md).

## Findings at a glance

| ID | Severity | Finding | Status |
|---|---|---|---|
| **C-01** | **Critical** | Public JupyterLab over plain HTTP, token in URL, no HSTS/redirect; token = root via NOPASSWD sudo | Verified |
| **C-02** | **Critical** | 228 security updates pending, automatic updates off; internet-facing OpenSSH in the backlog (CVE-2026-60002, CVSS 9.4, AV:N) | Verified |
| H-01 | High | Jupyter runs as `ubuntu` with `NOPASSWD: ALL`, terminals enabled, unsandboxed unit | Verified |
| H-02 | High | Jupyter/ML stack: >100 OSV advisories, incl. token-theft XSS, Critical stored XSS, Keras safe-mode bypass, fsspec RCE; no pipx update path | Verified |
| H-03 | High | Cloudflare `TunnelSecret` 0644; cloudflared root, unsandboxed, debug endpoints on loopback; no Cloudflare Access/MFA | Verified |
| H-04 | High | Driver 580.105.08 pinned; Ubuntu 580.178.04 (NVIDIA bulletin 5861) blocked; toolkit 1.18.1 CVE-2026-24260; kernel 18 releases behind; DKMS trap | Verified |
| H-05 | High | Lambda repo HTTP, frozen 2025-12-31, no `Valid-Until`; global key trust; Mellanox/PPA HTTP; pin 1001 | Verified |
| H-06 | High | GPU/RDMA/knem devices 0666; any user can use the GPU and RDMA; no MIG/memory isolation; RDMA bypasses firewall | Verified |
| H-07 | High | No host firewall; `INPUT ACCEPT`; shared /20 VPC; postfix/rpcbind on all interfaces; Docker bypass | Verified (east-west inferred) |
| H-08 | High | No auditd/IDS/FIM/off-host logs/alerting; logs wipeable; no detection of token use | Verified |
| H-09 | High | Token is per-instance but static for life; 0644 config; URL login; no rotation/revocation; clones/snapshots inherit it | Verified |
| M-01 | Medium | CPU microcode behind; SRSO/TSA "Vulnerable, no microcode" (shared cloud CPU) | Verified |
| M-02 | Medium | AppArmor userns bypass; io_uring open; ldisc autoload; lockdown none; kexec/panic; no Secure Boot/IMA/TPM | Verified |
| M-03 | Medium | SSH: root login without-password, X11/agent forwarding, no idle timeout, weak MACs, no fail2ban/pam_faillock | Verified |
| M-04 | Medium | Root services unsandboxed: cloudflared 9.6, glances root/no auth, postfix, rpcbind; Jupyter 9.2 | Verified |
| M-05 | Medium | Docker rootful, no userns-remap, bridge ICC/masq, uncapped logs; runc/containerd advisories | Verified |
| M-06 | Medium | Egress/DNS/NTP unrestricted and unlogged; RDMA path bypasses policy | Verified |
| M-07 | Medium | `pip.conf` overrides PEP 668; no hashes/index allowlist/scanners/SBOM; apt/dpkg history missing; token/runtime artefacts 0644; classic snaps | Verified |
| L-01 | Low | Metadata endpoint 169.254.169.254 exists but returns 404/405 to standard paths; no data found; still reachable by every user | Verified |
| L-02 | Low | `torch.compile` writes 0775 cache under `/tmp`; shared read, group-writable | Verified |
| L-03 | Low | `pam_unix nullok`, umask 0002, `memlock unlimited`, `/var/crash` 3777, no Jupyter idle culling | Verified |
| L-04 | Low | Classic snaps (`aws-cli`, `gcloud`), `azure-cli`, `gst-ptp-helper` cap_net_admin, snap-confine cap_sys_admin | Verified |

Counts: **2 Critical, 9 High, 7 Medium, 4 Low.**

---

## Critical

### C-01 — Public JupyterLab over plain HTTP; token in URL; token = root

**What happens.** Lambda publishes the instance's JupyterLab through a
Cloudflare Tunnel. The origin is `http://localhost:7000`; Cloudflare terminates
TLS but does not force HTTPS, and the origin sets no HSTS. The login page is
served over HTTP, and Jupyter accepts the bearer token as a `?token=` query
parameter.

```text
$ curl -sS -L -o /dev/null -w '%{http_code} %{url_effective}\n' \
    http://<instance>.lambdaspaces.com/lab
200 http://<instance>.lambdaspaces.com/login?next=%2Flab

$ curl -sS -D- -o /dev/null https://<instance>.lambdaspaces.com/login \
    | grep -ci strict-transport-security
0

$ curl -sS http://127.0.0.1:7000/api
{"version": "2.17.0"}

$ stat -c '%a %U:%G' /home/ubuntu/.jupyter/jupyter_config.py
644 ubuntu:ubuntu
```

`c.ServerApp.token` is a 32-hex (128-bit) per-instance value, but it is a
long-lived bearer credential: `allow_password_change=False`, logout only clears
the cookie, and there is no rotation or server-side revocation. Jupyter runs as
`ubuntu`, whose sudoers entry is `(ALL) NOPASSWD: ALL`, and the web terminal is
enabled. A token is therefore a root shell on the GPU host. No Cloudflare Access,
SSO, MFA, IP allowlist or login rate limit is in front of the endpoint.

Two smaller issues compound it. `allow_remote_access=True` disables Jupyter's
Host-header check (`Host: evil.example` → 200), which re-enables DNS-rebinding
risk; `/api` discloses the exact Jupyter Server version (2.17.0) before login.
The `_xsrf` cookie has no `Secure`/`SameSite`, and the session cookie is not
`Secure`/`SameSite` because the origin request is HTTP with `trust_xheaders=False`.

**Why this is Critical, not just High.** The plain-HTTP endpoint is not a
misconfiguration the user has to opt into: a user who types the hostname without
`https://` is served the login page over HTTP, and an on-path attacker can read
the token or strip the upgrade. There is no HSTS to prevent that. The token is
also accepted in the URL, so it lands in browser history, chat/screenshots,
edge/proxy logs and (if a tokenised URL is ever requested) Jupyter's access log.
The audit's own `sudo grep` of the token put it in `auth.log`; that is a
side-effect to rotate away (see "Audit side effects").

**What is *not* true.** The real token is **not** printed in the journal at
startup: Jupyter substitutes a literal `...` for config-sourced tokens. The
startup lines are `http://127.0.0.1:7000/lab?token=...`, not the secret. The
leak paths are the 0644 config (protected only by the 0750 home), the URL, the
tunnel credential, and any log that records a request URL.

**Fix (documented, not applied).**
- Prefer the Secure GPU Stack pattern: Jupyter on a private Unix socket, reached
  through an SSH tunnel; no public tunnel at all.
- If a public endpoint is a product requirement: Cloudflare Access/SSO with MFA,
  or a service token + IP allowlist; force HTTPS and HSTS at the edge; disable
  the HTTP listener/redirect; put an identity-aware proxy in front.
- Stop using URL tokens: POST login, short-lived per-user tokens or OIDC,
  rotation and revocation; `allow_password_change=False` is not a substitute.
- Break the root chain: dedicated non-sudo Jupyter user, no web terminal, no
  passwordless sudo, sandboxed systemd unit (H-01).
- Rotate the token and tunnel secret now; treat both as exposed.

**Verified end-to-end:** POC-1 (token → kernel as `ubuntu` → `sudo -n` root;
`/etc/shadow` read; kernel deleted 204) and POC-2 (public HTTP login page, dummy
token in the request line). Transcripts:
[`lambda-instance-pocs.md`](lambda-instance-pocs.md),
[`poc-jupyter-root.txt`](audit/poc-jupyter-root.txt),
[`poc-http-cleartext.txt`](audit/poc-http-cleartext.txt).

**Evidence:** `docs/audit/07-jupyter-ml.md` JUP-01/02/03/08;
`docs/audit/02-network-exposure.md` NET-01/13;
`docs/audit/06-secrets-filesystem.md` SEC-02/03.

### C-02 — 228 security updates pending, automatic updates off; internet-facing OpenSSH in the backlog

**What happens.** The image ships with `APT::Periodic::Unattended-Upgrade "0"`,
so the "active" unattended-upgrades unit never installs security updates. After
refreshing apt lists, **303 packages are upgradable, 228 from
`noble-security`**. The host is eight months behind its own image date.

```text
$ apt-config shell U APT::Periodic::Unattended-Upgrade
U='0'
$ apt list --upgradable 2>/dev/null | tail -n +2 | wc -l
303
$ apt list --upgradable 2>/dev/null | grep -c security
228
$ apt-cache policy openssh-server
  Installed: 1:9.6p1-3ubuntu13.14
  Candidate: 1:9.6p1-3ubuntu13.20
```

High-value pending updates include:

| Package | Installed | Candidate | Max CVSS / note |
|---|---|---|---|
| `openssh-server` | 13.14 | 13.20 | **9.4**, CVE-2026-60002, `AV:N/AC:L/PR:N` (pre-auth network; per OSV/Ubuntu data) |
| `libc6` | 2.39-0ubuntu8.7 | 2.39-0ubuntu8.9 | 9.8, CVE-2026-5450 |
| `libssl3t64` | 3.0.13-0ubuntu3.7 | 3.0.13-0ubuntu3.16 | 9.8, CVE-2026-31789 |
| `curl`/`libcurl4t64` | 8.5.0-2ubuntu10.7 | 8.5.0-2ubuntu10.16 | 9.8, CVE-2026-8925 |
| `libxml2` | 2.9.14+dfsg-1.3ubuntu3.7 | 2.9.14+dfsg-1.3ubuntu3.10 | 9.8, CVE-2026-6653 |
| `bind9-libs` | 1:9.18.39-0ubuntu0.24.04.2 | 1:9.18.39-0ubuntu0.24.04.8 | 8.6, CVE-2026-13321 |
| `python3.12` | 3.12.3-1ubuntu0.11 | 3.12.3-1ubuntu0.17 | 8.2, CVE-2025-69534 |
| `sudo` | 1.9.15p5-3ubuntu5.24.04.1 | 1.9.15p5-3ubuntu5.24.04.4 | 7.8, CVE-2026-96512 |
| `linux-image-nvidia` | 6.8.0-1046.49 | 6.8.0-1064.67 | 18 releases behind; Ubuntu's changelog lists 1,457 CVE IDs (indicative) |
| `amd64-microcode` | 2025-03-11 | 2025-12-02 | SRSO/TSA fixes (see M-01) |

Also pending: `snapd` 2.73 → 2.77.1, `cloudflared` 2026.2.0 → 2026.10.7,
Docker/containerd, and `apparmor` (updates-only). The full list is in
`docs/audit/03-patching-supply-chain.md` SUP-01.

Port 22 is the one port Lambda exposes to the internet. Key-only SSH reduces
the attack surface, but it does not help against a pre-auth OpenSSH bug or a
local glibc/OpenSSL/curl bug. The host has no reboot-required flag, no update
notification, and no vulnerability scanner, so an operator sees none of this.
The counts vary by data source (Ubuntu's changelog lists 11 OpenSSH CVEs; OSV's
Ubuntu data lists 28 fixed by 13.20); the exact count is less important than the
presence of a 9.4 network-vector fix in an exposed service. Verify the USN
before treating CVE-2026-60002 as a proven pre-auth exploit.

**Fix.** Enable `APT::Periodic::Unattended-Upgrade "1"`; keep
`Update-Package-Lists "1"`; add Docker/Cloudflare/Microsoft/NVIDIA origins once
they are on signed HTTPS repos; add a working alert; stage and test the kernel +
driver + microcode together; reboot; verify `nvidia-smi`, DKMS and the
frameworks; expose `/run/reboot-required`/`needrestart` in the login banner and
monitoring.

**Evidence:** `docs/audit/03-patching-supply-chain.md` SUP-01/02;
`docs/audit/sgs-check-lambda-baseline.txt`.

---

## High

### H-01 — Jupyter runs as a passwordless sudoer, with a web terminal, unsandboxed

**What happens.** `lambda-jupyter.service` runs as `User=ubuntu`, the same
account that has `(ALL) NOPASSWD: ALL` in `/etc/sudoers.d/90-cloud-init-users`.
The web terminal is enabled, notebooks run as the same user, and the unit has no
`NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp`,
`RestrictAddressFamilies` or `SystemCallFilter`. `systemd-analyze security`
scores it **9.2 UNSAFE**; `cloudflared` is **9.6 UNSAFE**.

```text
$ ps -o user,pid,args -p 2713
ubuntu 2713 /home/ubuntu/.local/share/pipx/venvs/jupyter-core/bin/jupyter-lab ...

$ sudo -n -l | tail -2
(ALL) ALL
(ALL) NOPASSWD: ALL

$ systemd-analyze security lambda-jupyter.service --no-pager | tail -1
→ Overall exposure level for lambda-jupyter.service: 9.2 UNSAFE :-{
```

The unit also executes a user-writable binary from `~/.local/bin` at every boot,
with `Restart=always`; a malicious pip/pipx package in the user's venv is
boot-persistent code as `ubuntu`.

**Impact.** Any Jupyter RCE — a token leak, a token-theft XSS, a malicious
notebook, a compromised extension — is root, not a sandboxed notebook. That is
the difference between "a compromised notebook" and "a compromised GPU host".

**Fix.** A dedicated `jupyter` user with no sudo, no docker/GPU/RDMA groups;
disable the terminal or put it behind a separate policy; run the service with
`NoNewPrivileges=yes`, `ProtectSystem=strict`, a read-only venv, `ProtectHome`
with an explicit bind mount, `PrivateTmp=yes`, syscall/address-family filters,
`UMask=0077`, and a non-user-writable entrypoint. Don't run a network-facing
service as the admin account.

**Evidence:** `docs/audit/07-jupyter-ml.md` JUP-02/09;
`docs/audit/01-access-persistence.md` ACC-01/05.

### H-02 — The Jupyter/ML application stack is far behind, with exploitable advisories, and lives outside apt

**What happens.** The Jupyter stack is installed in a pipx venv
(`/home/ubuntu/.local/share/pipx/venvs/jupyter-core`), not as a system package.
That means `dpkg -l`, Ubuntu security updates, `unattended-upgrades`,
`apt list --upgradable`, and a naive vulnerability scanner **do not see it**. A
system-only scan can report "no JupyterLab installed" while the public management
plane is running. There is no pipx/cron updater.

OSV exact-version results (2026-10-30) include:

| Component | Installed | Advisories / CVEs | Notable |
|---|---|---|---|
| JupyterLab | 4.5.5 | 21 advisories | token theft via CommandLinker XSS (CVE-2026-40171), one-click command execution (CVE-2026-42557), pasted-cell/image/settings XSS |
| jupyter_server | 2.17.0 | 14 advisories | Critical stored XSS in nbconvert handlers (CVE-2026-44727), token-in-Referer log leak (CVE-2026-86049), path traversal (CVE-2026-35397), cookies survive reset/restart (CVE-2026-40934) |
| Tornado | 6.5.4 | 21 advisories | unauthenticated event-loop DoS (CVE-2026-82397), cookie injection, symlink path traversal |
| notebook | 7.5.4 | 6 | CommandLinker XSS/token theft |
| nbconvert | 7.17.0 | 5 | arbitrary file write via cell-output path traversal (CVE-2026-114140) |
| mistune | 3.2.0 | 33 | markdown/TOC XSS, quadratic parse |
| bleach | 6.3.0 | 3 | URI-scheme bypass |
| Keras | 3.10.0 | 30 advisories / 16 CVEs, max 9.8 | `safe_mode=True` bypass → code execution (CVE-2026-12481, CVE-2025-12060); HDF5 file disclosure; archive traversal |
| PyTorch | 2.7.0 | 15 advisories / 14 CVEs, max 8.8 | memory corruption/DoS (CVE-2026-24747, CVE-2026-4538) |
| fsspec | 2024.3.1 | 2 advisories / 1 CVE, 8.8 | SSTI → RCE (CVE-2026-104851) |
| certifi (venv) | 2026.2.25 | 2 | bundles emSign roots with compromised intermediate keys (GHSA-6q48-6c7w-9gw2), fixed 2026.10.18 |
| urllib3 (venv) | 2.6.3 | 10 | proxy TLS ignored, decompression bomb, header forwarding, unbounded buffering |
| Pillow (system) | 10.2.0-1ubuntu1 | 78 upstream advisories; Ubuntu candidate 10.2.0-1ubuntu1.3 | five Critical upstream; Ubuntu's update is pending (part of C-02); OSV overstates un-backported counts |
| TensorFlow / JAX / Triton / NumPy | 2.19.0 / 0.6.0 / 3.3.0 / 1.26.4 | 0 | good |

**Why it matters.** The public endpoint's only auth is a token, and JupyterLab
has token-theft XSS. A malicious notebook, image, settings file or language pack
can run script in the Jupyter origin, read the session/token, and execute
commands as `ubuntu`. Separately, Keras and fsspec can execute code while
loading an untrusted model/file even with the documented "safe" defaults; loading
a model from Hugging Face or a shared checkpoint is routine. Unauthenticated
Tornado form parsing gives a remote DoS of the management plane.

**Fix.** Upgrade the suite together (`jupyter_server ≥ 2.21.1`, JupyterLab
≥ 4.6.5, Tornado ≥ 6.6, nbconvert ≥ 7.17.2, mistune ≥ 3.4, bleach ≥ 6.4);
install it from a hash-locked lockfile into a versioned venv; include the venv
in the SBOM and vulnerability scan; add pipx/venv updates to the release
pipeline. Upgrade Keras/PyTorch/fsspec to fixed wheels, or rebuild Lambda's
debs. Treat model files as untrusted input; prefer safetensors and
`weights_only=True`; scan with `modelscan`.

**Evidence:** `docs/audit/07-jupyter-ml.md` JUP-03/05/06/07/12;
`docs/audit/03-patching-supply-chain.md` SUP-04/05; OSV.dev exact-version queries.

### H-03 — The Cloudflare tunnel credential is world-readable; cloudflared is a root, unsandboxed daemon with open debug endpoints

**What happens.** `/etc/cloudflared/jupyter-tunnel.json` is `0644 root:root` and
contains `AccountTag`, `TunnelID`, `TunnelName` and `TunnelSecret`. `sudo -u
nobody cat` succeeds. The companion `config.yml` is also 0644. `cloudflared`
runs as **root** with no `User=`, no capabilities/seccomp/NoNewPrivileges and no
filesystem sandbox; `systemd-analyze security` scores it **9.6 UNSAFE**. Its
loopback admin server exposes unauthenticated `/config`, `/debug/pprof/*` and
`/metrics` on `127.0.0.1:20241`; `/debug/pprof/heap` returns a profile of the
root process. The binary is 2026.2.0 while apt offers 2026.10.7; a daily root
timer runs `cloudflared update`, which cannot update a dpkg install and mainly
restarts the tunnel.

**Why it matters.** Cloudflare balances a tunnel across connectors. Anyone who
can read the secret can run a second connector for the same hostname from
anywhere, receive a share of public traffic (including `?token=` URLs, cookies
and POST bodies), serve a fake login page on the legitimate hostname to harvest
the token, or sit on sessions. The root daemon means a cloudflared bug is host
root, and the pprof endpoint lets any local user sample root memory.

**Fix.** `chmod 600`/`chmod 700`, a dedicated `cloudflared` user, systemd
hardening (`NoNewPrivileges`, empty `CapabilityBoundingSet`, `ProtectSystem`,
`ProtectHome`, `PrivateTmp`, address-family/syscall filters), metrics/debug on a
private Unix socket or disabled, and a current package from Cloudflare's signed
repo. Rotate the tunnel secret; assume it is exposed. Put Cloudflare Access/MFA
in front if the tunnel stays.

**Evidence:** `docs/audit/02-network-exposure.md` NET-02/05/06;
`docs/audit/06-secrets-filesystem.md` SEC-01/04; `docs/audit/07-jupyter-ml.md`
JUP-04.

### H-04 — The GPU driver, container toolkit and kernel are pinned to vulnerable versions, with no working patch path

**What happens.** Lambda's apt pin (`Pin-Priority: 1001` for everything from
`archive.lambdalabs.com`) holds the driver at **580.105.08** while Ubuntu's
`noble-security` offers **580.178.04**. NVIDIA bulletin 5861 (September 2026)
lists R580 "all versions prior to 580.178.04" as affected, including
CVE-2026-47561 (unvalidated ioctl size → kernel OOB write), CVE-2026-47559
(read another user's process memory), CVE-2026-47599/-47601 (open-module DMA
mapping) and CVE-2026-47572 (type confusion), many CVSS 7.8 and requiring only
an unprivileged local user. The kernel is `6.8.0-1046.49`; `noble-security`
offers `6.8.0-1064.67` (18 releases later; Ubuntu's changelog lists 1,457 CVE
IDs between the two bases — treat the count as indicative, not as an audited
set). The container toolkit
is 1.18.1, affected by CVE-2026-24260 (NVIDIA bulletin 5850, TOCTOU, CVSS 8.5,
fixed 1.19.1; NVIDIA's repo carries 1.20.1), but the pin holds it too.

`apt upgrade` keeps the kernel packages back; `apt-get -s full-upgrade` resolves
cleanly (Lambda's documented failure did not reproduce) and installs 1064 while
**leaving the pinned 580.105.08 driver in place**, forcing a rebuild of eight
unsigned DKMS modules. Secure Boot is absent and lockdown is `[none]`, so there
is no module-signing backstop. The GPU works today, but the next kernel update
is an untested driver/kernel pair.

**Why it matters.** The GPU device nodes are 0666 (H-06), so "requires an
unprivileged local user" is every local account and every GPU container. The
driver bugs are kernel-level: OOB writes, cross-process memory disclosure, DMA
mapping. The toolkit CVE is a container-escape class. The pin means none of the
fixes can arrive through apt, and the kernel path changes the DKMS target.

**Fix.** Move to Ubuntu's signed `nvidia-driver-580-server-open` 580.178.04 (or
NVIDIA's repo) and toolkit 1.20.1; scope or drop the origin-wide 1001 pin; add
the origin to unattended-upgrades; stage kernel + driver + microcode together;
verify `nvidia-smi`, DKMS and all three frameworks before reboot; keep a tested
driver/kernel pair and a rollback. Enable lockdown once no local DKMS module is
required.

**Evidence:** `docs/audit/05-gpu-containers.md` GPU-02/03/07;
`docs/audit/03-patching-supply-chain.md` SUP-02/03/11;
`docs/audit/04-kernel-host.md` KRN-01/05.

### H-05 — Lambda's repository is HTTP, frozen, globally trusted, and its key never expires

**What happens.** The Lambda source is
`deb http://archive.lambdalabs.com/ubuntu noble main` (HTTPS times out). Its
`InRelease` is dated **2025-12-31**, has no `Valid-Until`, and the signing key is
linked into `/etc/apt/trusted.gpg.d/` so it is trusted for **every** repository,
not just Lambda's. The key is RSA-4096 from 2018 with no expiry. The global pin
is `Package: * / Pin: origin archive.lambdalabs.com / Pin-Priority: 1001`.
Mellanox's repo is also plain HTTP, and `mellanox.gpg` is in
`trusted.gpg.d`; the deadsnakes PPA and azure-cli add more third-party keys.
`sgs-check` independently flags all of this.

**Why it matters.** A network attacker cannot forge packages without the key, but
they can serve an old signed snapshot forever (no `Valid-Until`), see which ML
packages a machine installs, and — if the globally trusted key is ever stolen —
vouch for Ubuntu packages too. The frozen metadata is why the ML packages are
ten months old and why "the repo has no newer build" is a real dead end.

**Fix.** HTTPS-only sources, per-repo `signed-by=` (remove the global
`trusted.gpg.d` symlink), expiring/rotated keys, a `Valid-Until` in the repo
metadata, a scoped pin (or none), and removal of unused PPAs/repos. Publish a
release manifest/SBOM and verify package provenance.

**Evidence:** `docs/audit/03-patching-supply-chain.md` SUP-06/07;
`docs/audit/01-access-persistence.md` ACC-02; `sgs-check` WARNs.

### H-06 — GPU, RDMA and knem devices are 0666; any local user/container can use them, and RDMA bypasses the IP firewall

**What happens.** The NVIDIA device nodes are world-writable because the driver
packaging uses `NVreg_DeviceFileMode=438` (0666) and `manage-device-nodes` runs
`mknod -m 0666`:

```text
$ ls -l /dev/nvidia*
crw-rw-rw- 1 root root 195, 0   /dev/nvidia0
crw-rw-rw- 1 root root 195, 255 /dev/nvidiactl
crw-rw-rw- 1 root root 234, 0   /dev/nvidia-uvm
crw-rw-rw- 1 root root 234, 1   /dev/nvidia-uvm-tools
crw-rw-rw- 1 root root 195, 254 /dev/nvidia-modeset

$ sudo -u nobody nvidia-smi -L
GPU 0: NVIDIA A100-SXM4-40GB ...
$ sudo -u nobody env HOME=/tmp python3 -c 'import torch; ...'
torch cuda ok ... NVIDIA A100-SXM4-40GB   # 64 MiB; an 8 GB allocation also worked
```

MIG is disabled (and `lambda-first-boot.service` re-disables it at boot), there
is no cgroup cap for GPU memory, no MPS, and no per-user accounting: the first
process can take all 40 GB. The same image loads Mellanox OFED, `knem` and
`nvidia_peermem`, and the device nodes are open:

```text
$ stat -c '%a %U:%G %n' /dev/knem /dev/infiniband/uverbs0 /dev/infiniband/rdma_cm
666 root:root /dev/knem
666 root:root /dev/infiniband/uverbs0
666 root:root /dev/infiniband/rdma_cm

$ sudo -u nobody ibv_devinfo
hca_id: mlx5_0 ... state ACTIVE
```

**Why it matters.** Any local account, service account, Jupyter kernel or
non-root container can allocate GPU memory, submit driver ioctls (the
precondition for H-04's local driver bugs) and use RDMA. RDMA traffic runs
outside the kernel IP stack, so `iptables`/nftables and an IP-based egress policy
do not see it; a tenant can move data laterally or exfiltrate outside the host
firewall. The OFED/knem/xpmem modules are unsigned out-of-tree code (kernel
taint `0x3000`), adding attack surface on a single-GPU box that does not need
multi-node RDMA.

Also, `/run/nvidia-persistenced/socket` is `0777` and is bind-mounted into GPU
containers (read-only does not block `connect()`), and `/var/run/cdi/nvidia.yaml`
is 0644 and lists host paths. These are low-severity next to the 0666 nodes, but
they survive a node-mode fix.

**Fix.** Make the CUDA nodes `0660 root:video` and add trusted users to `video`,
or use the Secure GPU Stack's read-only bind-mount lock (`docs/design.md` §10);
`nvidia-persistenced` needs the `video` group. Restrict `/dev/infiniband/*` and
`/dev/knem` to a dedicated RDMA group or hide them; disable/remove OFED, knem
and xpmem where multi-node RDMA is not used; enable MIG or MPS with per-instance
limits for multi-tenant GPU work; make the egress policy RDMA-aware. Verify that
a plain container gets no GPU (it does not today) and that `--gpus all` is an
explicit grant.

**Evidence:** `docs/audit/05-gpu-containers.md` GPU-01/04/08;
`docs/audit/04-kernel-host.md` KRN-05; direct `nobody` tests.

### H-07 — No host firewall; shared /20 VPC; postfix and rpcbind on every interface

**What happens.** UFW is inactive (`ENABLED=no`; the "active" service is the
init oneshot). `iptables -S` is `-P INPUT ACCEPT` with no rules; there is no nft
`inet` table. The instance's `eno1` is `<instance-private-ip>/20` (a shared Lambda VPC
subnet). `ss` shows `0.0.0.0:22` (SSH), `0.0.0.0:25` (postfix) and
`0.0.0.0:111` (rpcbind), plus loopback-only Jupyter/glances/cloudflared. Only
Lambda's external filter keeps 25/111 off the internet. Docker publishes via
`nat PREROUTING`/`filter FORWARD`, so a future UFW rule would not filter
containers.

**Why it matters.** The host enforces nothing. Any peer in `10.19.80.0/20` can
reach 22/25/111; a single cloud-firewall mistake exposes SMTP and rpcbind to the
internet; a container can reach host services and the metadata stub. We could
not test east-west traffic from a second instance (see "What we could not
test"), so the /20 reachability is inferred, not proven. Postfix is a loopback
open relay (`250` from 127.0.0.1, `454` from the LAN), so a local account can
send mail with any sender; rpcbind is portmapper-only (no NFS); both are
unnecessary.

**Fix.** Default-deny inbound with nftables/ufw, allowing SSH only (or SSH from
known ranges); `DOCKER-USER` rules for containers; bind postfix/rpcbind/glances
to loopback or remove them; keep the cloud firewall as layer two. Add the host
firewall check to `sgs-check` (it already warns).

**Evidence:** `docs/audit/02-network-exposure.md` NET-03/08/09;
`docs/audit/01-access-persistence.md` ACC-07; `sgs-check` WARN.

### H-08 — No audit trail, no detection, no off-host logs; sudo can erase the evidence

**What happens.** `auditd` is absent, `auditctl` is missing, `/etc/audit` and
`/var/log/audit` do not exist, and `systemd-journald-audit.socket` is disabled.
The kernel generates audit records (`kauditd_printk_skb: ... suppressed`) but
they are dropped; only AppArmor denials survive in `dmesg`/`kern.log`. There is
no remote syslog/journal upload, no `chattr +a`, no sealing/hashes, no IDS/EDR,
no AIDE/Tripwire/IMA policy, no rootkit scanner, no vulnerability scanner, no
SIEM, no alert transport (postfix `relayhost` is empty; `/var/mail` is empty),
and no `fail2ban`/`pam_faillock`. `sudo` can `journalctl --vacuum-time=1s` or
`rm -rf /var/log/journal`. The image also ships without
`/var/log/dpkg.log`/`/var/log/apt/history.log`, so package changes cannot be
reconstructed.

**Why it matters.** A stolen Jupyter token is used through `cloudflared`, so
every request is logged as `@127.0.0.1`; a wrong token is an ordinary 302, not a
401, and nothing alerts. A compromise of the public management plane — or a
local privilege escalation — is effectively invisible, and the first responder
cannot reconstruct what happened. The audit's own token-in-`auth.log` side
effect shows how easily a secret lands in a log.

**Fix.** `auditd` with CIS/identity/sudoers/SSH/module/admin-path rules; ship
logs off-host over TLS (rsyslog `omfwd` or `systemd-journal-upload`); append-only
or sealed storage; AIDE/file-hash baseline and a daily diff; `fail2ban`;
`update-notifier-common`/`needrestart` reporting; a working alert transport;
an `sgs-check`-style daily posture check with an accepted-state baseline.
`401`/`403` bursts, new tunnel connectors, new `authorized_keys`/sudoers/units
and Jupyter config edits should alert.

**Evidence:** `docs/audit/08-logging-monitoring.md` LOG-01..10;
`docs/audit/04-kernel-host.md` KRN-02; `docs/audit/03-patching-supply-chain.md`
SUP-09.

### H-09 — The Jupyter token is per-instance but static for life, stored too broadly, and never rotated or revocable

**What happens.** The token is a 32-hex (128-bit) value rendered by Lambda's
control plane at launch (not image-baked; the NoCloud seed `/dev/vdb` was
created one minute before boot, and the vendor bundle contains the instance's
own IP mask/GPU count). It is written once into
`/home/ubuntu/.jupyter/jupyter_config.py` (`0644`, but the home is `0750`) and
into root-only vendor-data (`0600`); Jupyter re-reads the same file on restart,
so it never rotates. `allow_password_change=False`; logout only clears the
cookie; CVE-2026-40934 keeps auth cookies valid across restart/reset. The token
is accepted as `?token=` in the URL, so it lands in browser history and
edge/proxy logs. The token and the Cloudflare `TunnelSecret` also persist in the
NoCloud seed `/dev/vdb` (`0660 root:disk`) and cloud-init data, so a snapshot or
clone carries live credentials; two clones can answer the same hostname with
Cloudflare balancing between them.

**Why it matters.** One sighting of the token — a screenshot, browser sync, chat,
proxy, edge log — is valid for the life of the instance; there is no revocation
short of editing the file and restarting, and no way to invalidate a stolen
session. A clone inherits the credential and the public identity.

**Fix.** Per-user, short-lived tokens or OIDC through an identity-aware proxy;
rotate on a schedule and on clone; `POST` login instead of URL tokens;
`0600` config and `0700` dirs; exclude `.jupyter`, `/etc/cloudflared` and
`/var/lib/cloud` from images/backups; on clone, rotate the tunnel secret and
regenerate the Jupyter token and session key. Treat the current token and tunnel
secret as exposed.

**Evidence:** `docs/audit/07-jupyter-ml.md` JUP-03/15;
`docs/audit/06-secrets-filesystem.md` SEC-03/07; `docs/audit/01-access-persistence.md`
ACC-04.

---

## Medium

### M-01 — CPU microcode is behind; SRSO and TSA report vulnerable

The CPU is an AMD EPYC 7J13. The kernel reports:

```text
spec_rstack_overflow: Vulnerable: Safe RET, no microcode
tsa:                 Vulnerable: Clear CPU buffers attempted, no microcode
```

`amd64-microcode` is 3.20250311; `noble-security` offers 3.20251202. The guest
does not load microcode itself (host/provider responsibility), but the instance
still reports the vulnerability. SMT is off (good) and the kernel has the
"Safe RET" mitigation, but TSA has no microcode mitigation. On a shared cloud
CPU this is a data-leakage risk across processes/tenants, not a direct root bug.
**Fix:** apply the microcode update and reboot; track the provider's host
microcode; verify `/sys/devices/system/cpu/vulnerabilities/*`; consider
disabling SMT (already off). **Evidence:** `docs/audit/04-kernel-host.md`
KRN-10; `docs/audit/03-patching-supply-chain.md` SUP-01.

### M-02 — AppArmor userns bypass, io_uring, ldisc autoload, no lockdown/kexec limits

`unshare -Ur id -u` is blocked, but `aa-exec -p docker-default -- unshare -Ur
id -u` returns **0**; `kernel.apparmor_restrict_unprivileged_unconfined=0`, with
91 unconfined/11 complain profiles. The namespace is functional (mount/netns and
`nft` work), so `CAP_NET_ADMIN` and the unpatched nf_tables CVEs are reachable.
`kernel.io_uring_disabled=0` and an unprivileged `io_uring_setup` succeeds.
`dev.tty.ldisc_autoload=1`; an unprivileged `TIOCSETD` loaded `ppp_async` and
`slip`. Lockdown is `[none]`, Secure Boot is impossible (legacy BIOS), 19
out-of-tree/unsigned modules are loaded, `kexec_load_disabled=0`,
`panic_on_oops=0`. `fs.suid_dumpable=0`, `kptr_restrict=1`, `dmesg_restrict=1`,
`unprivileged_bpf_disabled=2`, `ptrace_scope=1`, ASLR=2 and userfaultfd=0 are
good. **Fix:** `kernel.apparmor_restrict_unprivileged_unconfined=1`;
`io_uring_disabled=1`; `ldisc_autoload=0`; `lockdown=integrity` once DKMS allows;
`kexec_load_disabled=1`; noexec/nodev/nosuid on `/tmp`, `/var/tmp`, `/dev/shm`;
tighten redirects/RA; add auditd. **Evidence:** `docs/audit/04-kernel-host.md`
KRN-03/05/06/07/08/09.

### M-03 — SSH and account hygiene

`PermitRootLogin without-password`; `/root/.ssh/authorized_keys` contains the
same ed25519 key as `ubuntu`'s, with a forced command (auth succeeds, no shell;
exit 142). X11 forwarding and agent forwarding are on; `PermitOpen any`,
`PermitListen any`; `ClientAliveInterval 0` (no idle timeout); `hmac-sha1`/
`umac-64` accepted; `RequiredRSASize 1024`; `.ssh/authorized_keys2` honoured;
`DebianBanner yes`; no fail2ban/`pam_faillock`; `pam_unix.so nullok`; umask
0002; `memlock unlimited` for all; `/var/crash` 3777; `%admin` grants full sudo
and cloud-init adds `NOPASSWD: ALL`. **Fix:** `PermitRootLogin no`; remove the
root key; X11/agent forwarding off; idle timeout; strong MACs/KEX; RSA ≥3072;
`AllowUsers ubuntu`; fail2ban + pam_faillock; umask 027; limit memlock; tighten
`/var/crash`; narrow NOPASSWD to the commands actually needed. **Evidence:**
`docs/audit/01-access-persistence.md` ACC-06/08/09/10/11/12;
`docs/audit/02-network-exposure.md` NET-11.

### M-04 — Root services are unsandboxed, and some are unnecessary

`cloudflared` (root, 9.6 UNSAFE), `glances` (root, no auth, loopback XML-RPC,
`Access-Control-Allow-Origin: *`, logs into a user-owned directory), `postfix`
(root, all interfaces, loopback open relay, `VRFY`), `rpcbind` (root, all
interfaces, no NFS), and `lambda-jupyter` (ubuntu, 9.2 UNSAFE, `Restart=always`,
user-writable entrypoint). None of them sets `NoNewPrivileges`, `ProtectSystem`,
`ProtectHome` or `PrivateTmp`. **Fix:** remove glances/postfix/rpcbind if not
needed; run cloudflared as a dedicated user; sandbox Jupyter and cloudflared;
move logs to `/var/log`; bind remaining services to loopback. **Evidence:**
`docs/audit/08-logging-monitoring.md` LOG-11; `docs/audit/02-network-exposure.md`
NET-05/08/09/10; `docs/audit/07-jupyter-ml.md` JUP-09/14.

### M-05 — Docker is rootful with permissive defaults

No `/etc/docker/daemon.json`: no `userns-remap`, no default
`no-new-privileges`, bridge `enable_icc:true`/`enable_ip_masquerade:true`,
json-file logs uncapped. `--gpus all` works out of the box (Docker 29 via CDI)
and injects every 0666 node into a uid-0 container; a plain container gets no
GPU. The `docker` group is empty and the socket is `660 root:docker`, which is
good; seccomp/AppArmor/cgroupns are on. runc 1.3.4 (fixed 1.3.6) and containerd
2.2.1 (several image-triggered DoS fixes) are behind. **Fix:** keep the docker
group empty (sudo docker) or go rootless/userns-remap; default
`no-new-privileges`; cap logs; update runc/containerd/docker; add
`DOCKER-USER` firewall rules; grant `--gpus` explicitly. **Evidence:**
`docs/audit/05-gpu-containers.md` GPU-05/06/07.

### M-06 — Egress, DNS and time are unrestricted; the RDMA path bypasses them

Outbound HTTP/HTTPS is open; DNS goes to `1.1.1.1`/`8.8.8.8` in plaintext with
no DNSSEC; NTP is unauthenticated; there is no egress allowlist or logging. RDMA
(`/dev/infiniband/uverbs0`) runs outside the IP stack, so an IP firewall/egress
policy does not cover it. **Impact:** data exfiltration (models, tokens,
datasets), C2, DNS spoofing; the strict-egress mode in the Secure GPU Stack must
explicitly account for RDMA. **Fix:** egress allowlist with logging; DNS over
TLS/HTTPS + DNSSEC; authenticated NTP; RDMA device/group restriction and a
fabric-level policy; test `sgs-egress strict` with RDMA workloads. **Evidence:**
`docs/audit/02-network-exposure.md` NET-14; H-06.

### M-07 — Supply-chain controls are missing: pip override, no hashes/index allowlist/scanners/SBOM, apt history stripped

`/etc/pip.conf` sets `[global] break-system-packages = true`, removing PEP 668's
guard; there is no hash checking, constraints file, index allowlist, `pip-audit`
or SBOM. `pip` 24.0 has six open CVEs (including CVE-2025-8869 and
CVE-2026-8643, 8.0); setuptools' two well-known CVEs
(CVE-2024-6345/CVE-2025-47273) are Ubuntu-backported, and only
CVE-2026-59890 (6.1) remains open. `safetensors`, `modelscan`, `picklescan`,
`gitleaks`, `trivy`/`grype`, `aide` and `auditd` are absent. `/var/log/dpkg.log`
and `/var/log/apt/history.log` are missing from the image, so package provenance
is unreconstructable. `~/.jupyter/jupyter_config.py` is 0644, the runtime
`open.html` is 0644 (with token URLs) in a 0700 dir, the kernel spec is 0664,
and `file_id_manager.db` is 0644. `torch.compile` creates a 0775
`/tmp/torchinductor_ubuntu` cache (shared read, group-writable). Classic snaps
`aws-cli` and `google-cloud-sdk` are unconfined, and `azure-cli` is installed;
none had credentials. **Fix:** remove `break-system-packages`; use a
hash-locked venv with an index allowlist; install `pip-audit`, `modelscan`,
`gitleaks`, `trivy`/`grype`, AIDE/auditd; publish an SBOM; restore apt/dpkg
history; 0600 secret artefacts; private `TMPDIR`/`TORCHINDUCTOR_CACHE_DIR`;
remove unused classic snaps/CLIs. **Evidence:**
`docs/audit/03-patching-supply-chain.md` SUP-05/08/09;
`docs/audit/06-secrets-filesystem.md` SEC-03/05/06;
`docs/audit/07-jupyter-ml.md` JUP-12/15; `docs/audit/08-logging-monitoring.md`
LOG-08; direct `torch.compile` test.

---

## Low / informational

### L-01 — Metadata endpoint exists but exposes no data

`169.254.169.254` returns a 128-byte 404 (`Server: server`, `X-Request-Id`) for
AWS IMDSv1 paths, IMDSv2 `PUT` returns 405, and GCP/Azure/OpenStack paths and
`nobody` get the same stub. No instance data, user-data, token or credential was
found. The endpoint is reachable by every local user and container, so it is
still worth blocking/allowlisting for defence in depth, but it is not a live
credential leak on this instance. This resolves the existing
`lambda-stack-findings.md` #13 ("whether Lambda serves metadata there"): a
service exists, but no sensitive path answered. **Evidence:**
`docs/audit/02-network-exposure.md`; `docs/audit/06-secrets-filesystem.md`.

### L-02 — `torch.compile` cache is shared in `/tmp`

`torch.compile` created `/tmp/torchinductor_ubuntu` as `0775 ubuntu:ubuntu`
(subdirs 0775). Other users can read compiled graphs/code; any member of the
`ubuntu` group can write. With a single user this is low, but a second admin or a
container in that group could inject/replace artifacts. **Fix:** set a private
`TORCHINDUCTOR_CACHE_DIR` and `TMPDIR` in the login/Jupyter environment (the Secure
GPU Stack does this), or use systemd `PrivateTmp=yes`. **Evidence:** direct test;
`docs/audit/05-gpu-containers.md`; `docs/audit/07-jupyter-ml.md` JUP-12.

### L-03 — Low hygiene: nullok, umask, memlock, crash dir, no idle culling

`pam_unix.so nullok` (empty passwords accepted by PAM, though the accounts are
locked); login shell umask 0002 vs `login.defs` 022; `* soft/hard memlock
unlimited` for every user; `/var/crash` 3777; Jupyter
`shutdown_no_activity_timeout=0`, culling 0, 512 MB request bodies; no
`fail2ban`; systemd is running stale unit definitions (journald, cloudflared,
lambda-jupyter and lambda-first-boot "changed on disk"; no `daemon-reload`);
`/var/log/package-list.md` is 0644. **Fix:** remove `nullok`; umask 027; cap
memlock; 0755/0700 crash dir; cull idle kernels and cap body size; run
`systemctl daemon-reload` at the end of provisioning; 0640 the package list.
**Evidence:** `docs/audit/01-access-persistence.md` ACC-10/12;
`docs/audit/07-jupyter-ml.md` JUP-17; `docs/audit/08-logging-monitoring.md`
LOG-13.

### L-04 — Classic snaps and over-privileged helper capabilities

`aws-cli` 2.35.21 and `google-cloud-sdk` 558.0.0 are classic snaps (no
confinement); `azure-cli` is installed; `gst-ptp-helper` has
`cap_net_admin`, and `snap-confine` has a broad capability set including
`cap_sys_admin`/`cap_sys_ptrace`. No cloud credentials were present. **Fix:**
remove unused cloud CLIs; prefer confined packages or pipx; review setcap
helpers. This is attack-surface reduction, not a live compromise. **Evidence:**
`docs/audit/01-access-persistence.md`; direct `snap list`/`getcap`.

---

## What is already good

These are worth preserving; they are the reason the box is usable for one
trusted user and the baseline for the Secure GPU Stack comparison.

- **SSH:** password authentication off; keyboard-interactive off; ubuntu/root
  passwords locked; `authorized_keys` 0600; host keys 0600 and unique per
  instance; `UsePAM`, `PermitEmptyPasswords no`, `PermitTunnel no`,
  `GatewayPorts no`, `PermitUserEnvironment no`, `IgnoreRhosts yes`.
- **Accounts:** only `ubuntu`; docker group empty; `/etc/shadow` 0640;
  `/etc/sudoers` 0440; `/root` 0700; home 0750; `.ssh` 0700; no unexpected
  setuid (no `nvidia-modprobe`, no `pkexec`), no `ld.so.preload`, no custom
  cron/rc.local/PAM exec.
- **Jupyter auth:** token required; `/api/contents`, `/api/kernels`,
  `/api/sessions`, `/api/terminals`, `/metrics` all 403 without auth; no CORS
  wildcard (`allow_origin` unset); CSRF on; `allow_root=False`; no trusted
  notebooks; token 128-bit; TLS 1.2/1.3 valid certificate.
- **Containers:** seccomp (builtin), AppArmor `docker-default`, cgroupns on;
  Docker socket 660 root:docker, no TCP API; plain container gets no GPU;
  GPU memory is zeroed between processes (8 GB marker test: 0 bytes read);
  ECC on; no Xid; `dpkg --verify` clean.
- **Kernel:** `fs.suid_dumpable=0`, `kptr_restrict=1`, `dmesg_restrict=1`,
  `unprivileged_bpf_disabled=2`, `ptrace_scope=1`, ASLR=2, userfaultfd=0,
  `perf_event_paranoid=4`, no swap; SMT off.
- **Data:** no cloud credentials, no HF/W&B tokens, no `.bash_history`, no
  `~/.aws`/`~/.config/gcloud`; `/var/backups` empty; metadata stub returns no
  data; journal access control and rsyslog perms are correct.
- **Operations:** no failed units, no OOM, no GPU Xid, cloud-init done, chrony
  synced, disk 5%, logrotate healthy; all three frameworks run on the A100.

## What we could not test / did not reproduce

- **East-west VPC reachability** from a second instance: not tested. The host is
  on `10.19.80.0/20` with no host firewall; 22/25/111 bind all interfaces. Treat
  intra-VPC exposure as likely until proven otherwise.
- **Token uniqueness across two instances**: the token is rendered per instance
  by Lambda's control plane (NoCloud seed, instance-specific IP/GPU count), but
  one instance cannot prove two differ. If it ever proves shared, H-09 becomes
  Critical. A second instance comparing `jupyter_config.py` settles it.
- **Cloudflare dashboard/Access**: no dashboard access. "No Access" is inferred
  from the absence of a `cf-access` challenge/redirect and from a direct
  Jupyter login page; confirm in the Lambda/Cloudflare console.
- **`apt-get full-upgrade` real install**: only simulated. It resolves cleanly
  (Lambda's documented failure did not reproduce), but it would install kernel
  1064 while leaving the pinned driver and rebuilding 8 DKMS modules; a real
  upgrade could still fail in a post-install script.
- **CVE exploitation**: the token chain and local primitives were executed
  (POC-1..5); the OpenSSH, kernel/nf_tables and NVIDIA driver CVEs were **not**
  exploited, and the live tunnel was **not** hijacked. CVE mapping is by version
  from OSV/Ubuntu/NVIDIA data; treat CVE-2026-60002 as "verify the USN" before
  calling it a proven pre-auth exploit.
- **GPU memory exhaustion / MIG**: no full 40 GB exhaustion; MIG is disabled.
- **Container metadata**: inferred from Docker bridge/masquerade; no local image
  with network tools was used.
- **`pip-audit`**: `sgs-check` SKIPped it (not installed); OSV exact-version
  queries were used instead. Ubuntu backports can make upstream OSV counts
  pessimistic (notably Pillow and apt-packaged pip/setuptools).
- **`flash-attn`**: not installed on this image; existing finding #8 does not
  apply to this build.
- **Existing finding #15** (one-line install fails on a fresh Ubuntu 24.04):
  not tested here; the image already has a working driver. The observed
  driver/kernel skew is the related risk (H-04).

## Audit side effects (disclose and rotate)

- `apt-get update` was run (lists refreshed, 206 MB; **no packages installed**).
  `apt-get -s`/`unattended-upgrade --dry-run` were simulations; they wrote
  `eipp.log.xz`/unattended-upgrades debug lines.
- `sgs-check` wrote its startup-file record; it was removed afterwards.
- `torch.compile` created `/tmp/torchinductor_ubuntu`; removed.
- The ldisc probe made the kernel load `ppp_async` and `slip` (refcount 0, no
  device). They were unloaded during cleanup (`sudo modprobe -r slip ppp_async`);
  `lsmod` is clean.
- **PoCs (2026-10-30):** a Jupyter kernel was created and deleted (204); an
  8 GB GPU allocation by `nobody` was released (0 MiB); the userns/netns was
  ephemeral; PoC temp files were removed; no users, packages, SSH, firewall,
  sudo or service config changed; the live tunnel was not hijacked. The token
  and tunnel secret remain exposed by the default image (see the rotation note
  below).
- **The audit's own `sudo grep` of the Jupyter token put the token in
  `/var/log/auth.log` and the root journal** (sudo argv logging). The file is
  0640 `syslog:adm`; `ubuntu` is not in `adm`, but this is still a secret at
  rest. Treat the token and tunnel secret as exposed: **rotate both, or
  terminate this disposable instance, after the audit.** Do not reuse this
  instance for the "after" measurement without rotation.
- One wrong-token `GET /lab` and one failed `POST /login` were logged by
  Jupyter; two accepted root SSH logins (forced command, no shell) were logged
  by sshd. No configuration, firewall, SSH, sudoers, user or package changes
  were made.
- No secret values are printed in this report or the raw reports.

## What the Secure GPU Stack should do (documented; not implemented)

**P0 — before calling the image safe**
1. **Remove the public Jupyter surface.** Use the Unix socket + SSH tunnel
   (already designed), not a Cloudflare tunnel. If a public endpoint is a
   product requirement, force HTTPS/HSTS, put Cloudflare Access/SSO+MFA or an
   identity-aware proxy in front, and stop using URL bearer tokens.
2. **Break Jupyter → root.** Dedicated non-sudo `jupyter` user, no web terminal,
   sandboxed systemd unit, read-only venv, `NoNewPrivileges`.
3. **Patch the exposed management plane.** Enable unattended security updates;
   install OpenSSH 13.20, glibc .9, OpenSSL .16, curl .16, libxml2 .10, bind9
   .8, python3.12 .17, sudo .4, kernel 1064, microcode; reboot; verify.
4. **Fix the GPU patch trap.** Ubuntu's signed 580.178.04 driver (or NVIDIA's),
   toolkit 1.20.1, scoped pin, matched kernel/driver, DKMS validation, lockdown
   after.
5. **Rotate/terminate the credentials.** Token, tunnel secret, session key;
   assume the tunnel secret is leaked (0644); rotate on clone/snapshot.
6. **Add a host firewall** (SSH-only, `DOCKER-USER`); bind/remove postfix,
   rpcbind, glances; 0660 GPU nodes; restrict RDMA/knem/OFED.

**Regression tests for the stack:** the PoCs in
[`lambda-instance-pocs.md`](lambda-instance-pocs.md) must fail on the Secure GPU
Stack — a token (or the Jupyter socket) must not yield code as a sudoer, `nobody`
must not be able to use the GPU/RDMA devices, and the public HTTP/tunnel path
must be absent. Close the checks listed in
[`sgs-check-gaps.md`](sgs-check-gaps.md) so the next Lambda baseline cannot
score 24 PASS while carrying the same chain.

**P1 — defence in depth**
- auditd + off-host logs + AIDE/FIM + fail2ban + alert transport; daily
  `sgs-check` with accepted-state baseline.
- SSH: root login off, remove root key, X11/agent forwarding off, idle timeout,
  strong MACs/KEX, RSA ≥3072, pam_faillock.
- AppArmor `unprivileged_unconfined=1`; io_uring=1; ldisc=0;
  lockdown=integrity; kexec=1; noexec/nodev/nosuid on tmp; redirects/RA.
- Docker: rootless or userns-remap, no-new-privileges, log caps, update
  runc/containerd/docker, `DOCKER-USER`.
- pip: remove `break-system-packages`; hash-locked venv; index allowlist;
  `pip-audit`/`gitleaks`/`modelscan`/`safetensors`; SBOM; restore apt/dpkg
  history.
- Jupyter/ML: upgrade the whole suite (server ≥2.21.1, lab ≥4.6.5, tornado
  ≥6.6, nbconvert ≥7.17.2, mistune ≥3.4, bleach ≥6.4, Keras ≥3.15, PyTorch
  fixed, fsspec fixed); include pipx in scans/updates.

**P2 — hygiene**
- Remove unused classic snaps/cloud CLIs/setcap helpers; egress allowlist + DoT/
  DNSSEC + authenticated NTP; MIG/MPS for multi-tenant; cull idle kernels; cap
  request bodies; 0600 token/config; private TMPDIR/torch cache; no idle
  timeout; log retention policy; per-clone rotation; document the single-tenant
  assumption.

## Mapping to `lambda-stack-findings.md` #1–#15

| Existing | Real-instance result |
|---|---|
| #1 driver pin blocks Ubuntu security updates | **Confirmed.** Lambda 580.105.08 at pin 1001; Ubuntu 580.178.04 at 500; no NVIDIA package in `apt upgrade`. |
| #2 default driver branch end-of-life | **Update.** The public install script hardcodes R570, but this image uses R580 (supported LTS through 2028); the installed build is 73 patch releases behind, not EOL. |
| #3 ML packages stale with CVEs | **Confirmed.** Repo `InRelease` 2025-12-31; Keras 3.10.0, torch 2.7.0, fsspec 2024.3.1; 16/14/1 CVEs (OSV, dedup), max 9.8; no newer Lambda build. |
| #4 Container Toolkit 1.18.1 CVE | **Confirmed at NVIDIA's source.** Bulletin 5850, CVE-2026-24260, CVSS 8.5, fixed 1.19.1; NVIDIA repo has 1.20.1; pin holds 1.18.1. |
| #5 HTTP repo, no metadata expiry | **Confirmed.** HTTP only; `InRelease` 2025-12-31; no `Valid-Until`. |
| #6 Lambda key trusted globally | **Confirmed.** `trusted.gpg.d` symlink; RSA-4096, 2018, no expiry. Mellanox key also global. |
| #7 install chain verifies nothing | **Not tested** on this instance; unchanged from the public-script analysis. |
| #8 flash-attn insecure deserialization | **Not applicable** to this image: `flash-attn` is not installed. |
| #9 userns restriction bypassable | **Confirmed.** `aa-exec -p docker-default -- unshare -Ur id -u` → 0; unconfined=0; 91 unconfined/11 complain profiles; namespace has CAP_NET_ADMIN. |
| #10 io_uring open | **Confirmed.** `io_uring_disabled=0`; unprivileged `io_uring_setup` succeeds. |
| #11 ldisc autoload / ICMP redirects | **Partly.** `ldisc_autoload=1` and `TIOCSETD` loaded `ppp_async`/`slip`; `all.accept_redirects=0` here, but `default`/`eno1`/`docker0` are 1 and `send_redirects=1` (sgs-check flags). |
| #12 SSH X11 forwarding | **Confirmed.** `x11forwarding yes`. |
| #13 metadata reachable / credentials | **Updated.** Endpoint exists but returns a generic 404/405 for AWS/GCP/Azure/OpenStack paths; no data found; still reachable by all users; block for defence in depth. |
| #14 kernel lockdown off | **Confirmed.** `[none]`; no Secure Boot/EFI; unsigned modules load; kexec allowed. |
| #15 one-line install fails on fresh 24.04 | **Not tested** here; image already has a working driver. Related risk: `apt upgrade` holds the kernel, `full-upgrade` leaves the pinned driver and forces 8 DKMS rebuilds. |

**New with this audit (not in #1–#15):** public HTTP Jupyter/token→root,
Jupyter-as-sudoer, the Jupyter/ML CVE backlog and pipx-outside-apt,
Cloudflare `TunnelSecret` 0644/root daemon/no-Access, 228 pending updates with
automatic updates off, CPU microcode/SRSO/TSA, GPU/RDMA/knem 0666 and RDMA
firewall bypass, no host firewall/shared VPC, no audit/detection, token
lifecycle/clones, pip `break-system-packages`/no hashes, Docker defaults,
egress/DNS, apt history stripped, classic snaps.

## Glossary (plain language)

- **Bearer token / Jupyter token:** a password-like string; whoever has it is
  treated as the logged-in user. No separate username or MFA.
- **NOPASSWD sudo:** `sudo -n` works without a password; any process running as
  `ubuntu` can become root.
- **HSTS:** an HTTP header that tells browsers "always use HTTPS for this name".
  Without it, a first visit or a link can be downgraded to HTTP.
- **DKMS:** Dynamic Kernel Module Support; it rebuilds the NVIDIA (and other)
  kernel modules when the kernel changes. A kernel update without a matching
  driver rebuild can leave the GPU dead.
- **MIG:** Multi-Instance GPU; splits one A100 into isolated slices. Disabled
  here, so one job can take the whole card.
- **RDMA:** Remote Direct Memory Access; network transfers that bypass the
  kernel IP stack (and therefore `iptables`/nftables).
- **User namespace (userns):** a kernel feature that gives an unprivileged
  process a fake "root" inside a namespace; it exposes kernel code and is a
  common privilege-escalation starting point.
- **io_uring:** a high-performance async I/O interface; historically a rich
  source of kernel bugs, and not needed by this ML stack.
- **seccomp / AppArmor:** kernel sandboxes that restrict syscalls and file
  access. Docker uses both by default.
- **SBOM / OSV:** Software Bill of Materials (a package inventory) and the Open
  Source Vulnerabilities database used to map versions to CVEs.

## Evidence and references

- PoCs and attack chain: [`lambda-instance-pocs.md`](lambda-instance-pocs.md)
  and the raw `docs/audit/poc-*.txt` transcripts.
- `sgs-check` scoring gaps: [`sgs-check-gaps.md`](sgs-check-gaps.md).
- Raw reports: `docs/audit/01-access-persistence.md`,
  `02-network-exposure.md`, `03-patching-supply-chain.md`,
  `04-kernel-host.md`, `05-gpu-containers.md`,
  `06-secrets-filesystem.md`, `07-jupyter-ml.md`,
  `08-logging-monitoring.md`.
- Baseline: `docs/audit/sgs-check-lambda-baseline.txt` (24 PASS / 30 WARN /
  1 SKIP; PyTorch 14.6, JAX 132.9, TF 19.4 TFLOP/s fp32 matmul; convolutions OK).
- OSV.dev exact-version queries (2026-10-30): JupyterLab 4.5.5 (21),
  jupyter-server 2.17.0 (14), tornado 6.5.4 (21), notebook 7.5.4 (6), nbconvert
  7.17.0 (5), mistune 3.2.0 (33), bleach 6.3.0 (3), Keras 3.10.0 (30/16 CVEs),
  torch 2.7.0 (15/14), fsspec 2024.3.1 (2/1), certifi 2026.2.25 (2), urllib3
  2.6.3 (10), Pillow 10.2.0 (78 upstream; Ubuntu 10.2.0-1ubuntu1.3 pending).
- NVIDIA product-security bulletins:
  [5861 (Sept 2026, R580 driver)](https://github.com/NVIDIA/product-security/blob/main/2026/5861/5861.md)
  and [5850 (June 2026, Container Toolkit)](https://github.com/NVIDIA/product-security/blob/main/2026/5850/5850.md).
- Ubuntu security pockets/`apt` candidates as observed on 2026-10-30;
  CVE/CVSS values from OSV's Ubuntu data, with the caveat that Ubuntu may
  backport without changing the upstream version.
- CIS Ubuntu Linux 24.04 LTS Benchmark (auditd, file permissions, services,
  package integrity); NIST SP 800-92 (log management); Jupyter Server security
  docs (`allow_remote_access`, `local_hostnames`, `trust_xheaders`,
  `cookie_options`); Cloudflare Tunnel credentials/Access docs.
- Existing project docs: `docs/lambda-stack-findings.md`,
  `docs/lambda-test-plan.md`, `docs/design.md` §10, `docs/threat-model.md`.
