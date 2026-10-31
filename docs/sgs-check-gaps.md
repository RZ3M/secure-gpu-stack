# `sgs-check` gaps and scoring changes

**For:** the builder agent working on the Secure GPU Stack after instance B finishes.
**Basis:** `sgs-check` run on the live default Lambda Stack 24.04 A100 instance
on 2026-10-30, plus the source in `bin/sgs-check` and the PoCs in
[`lambda-instance-pocs.md`](lambda-instance-pocs.md).
**Baseline:** **24 PASS / 30 WARN / 1 SKIP**, while the same host has
**2 Critical / 9 High / 7 Medium / 4 Low** findings and a verified
token → root chain. That gap is the point of this document.

> **Short version.** `sgs-check` is a good *host posture checklist*; it is not
> an *exploitability score*. It sees many individual weaknesses but does not
> connect them, cannot see the public Cloudflare edge, and treats a skipped
> vulnerability audit as a clean result. Add severity weighting, chain checks,
> a public/tunnel mode and a pipx/venv inventory; then the same machine should
> produce **2 Critical** at the top instead of "24 PASS".

## What it already catches (keep these)

On this instance `sgs-check` correctly flagged:

- Lambda's HTTP repository, the global `trusted.gpg.d` key, and the `1001` pin;
  the driver not being Ubuntu's; the blocked 580.178.04 update.
- GPU nodes 0666; the unsigned/out-of-tree modules; the toolkit 1.18.1 CVE.
- 228 security updates, automatic updates off, and the Docker/NVIDIA packages
  outside unattended-upgrades; the apt timers without a time limit.
- Firewall off and postfix/rpcbind on `0.0.0.0`; Jupyter on localhost and token
  required; "code in Jupyter can become root"; metadata reachable.
- `kernel.io_uring_disabled=0`, `ldisc_autoload=1`, redirects, lockdown off,
  the `aa-exec` userns bypass, auditd absent.
- Root login/X11, password login off, home/token permissions, the pip index,
  `dpkg --verify`, and all three frameworks on the GPU.

Those checks are valuable and should stay. The problems below are mostly
*missing*, *mis-weighted*, or *imprecise* checks, not a bad foundation.

## Gaps

Priority: **P0** = the next release must surface it; **P1** = next hardening
round; **P2** = hygiene.

| ID | P | Gap | Why it matters here | Proposed check | Expected on this instance |
|---|---|---|---|---|---|
| **G-01** | P0 | No public-edge check: it never resolves `/etc/cloudflared/config.yml`, tests `http://` vs `https://`, HSTS, redirect, `cf-access`/MFA, or token-in-URL | C-01: public Jupyter over HTTP; no Access/MFA; the host-local "localhost port" WARN looks mild | If a cloudflared ingress exists, `curl -D- http://host/`, `https://host/`, `/login`, `/api`; check 200/302, `Location`, `Strict-Transport-Security`, `cf-access-*`, `_xsrf` flags; report **CRITICAL** if public + HTTP + token/URL | `http://` 302 `/lab?`, login 200 over HTTP, no HSTS, no Access → CRITICAL |
| **G-02** | P0 | Never inspects the tunnel credential, cloudflared's user/sandbox/version, or `/debug/pprof`/`/config` | H-03: `TunnelSecret` 0644; root daemon 9.6 UNSAFE; any local user reads root memory/config | `stat` `/etc/cloudflared/*`; `systemctl show -p User`; `systemd-analyze security cloudflared`; curl `127.0.0.1:20241/{config,debug/pprof/,metrics}`; version vs apt candidate | creds 0644, root, 9.6, endpoints 200, 2026.2.0 vs 2026.10.7 → HIGH |
| **G-03** | P0 | Jupyter check is generic: it looks at `NoNewPrivs` and PID, not the Lambda unit, the service user's sudoers/groups, terminals, `Restart=always`, or a user-writable entrypoint | H-01: Jupyter runs as `ubuntu` (`NOPASSWD: ALL`), terminal enabled, no sandbox; the current WARN is one line among 30 | Parse the unit for `User=`, `ExecStart=`; `sudo -l -U user`; `systemctl show`; `jupyter server extension list` or config for terminals; `systemd-analyze security`; **CRITICAL/HIGH** if the service user can sudo or is in docker/video/RDMA groups | unit `User=ubuntu`, `NOPASSWD: ALL`, terminal enabled, 9.2 UNSAFE → CRITICAL chain |
| **G-04** | P0 | Vulnerability audit only sees `/usr/lib/python3` / `/opt/sgs`; pip-audit is `SKIP` if missing; JupyterLab is pipx so it is invisible | H-02: JupyterLab 4.5.5 / jupyter_server 2.17.0 / Tornado 6.5.4 / Keras 3.10.0 / torch 2.7.0 / fsspec 2024.3.1; >100 advisories; no updater | `pipx list --json`; enumerate every venv in `~/.local/share/pipx/venvs` and `~/.local/lib/python3*/site-packages`; run `pip-audit --path` per venv (root-owned tool); compare versions to fixed lists; include `modelscan`/`safetensors` | pip-audit SKIP today; pipx JupyterLab 4.5.5 21, server 2.17.0 14, Tornado 6.5.4 21, Keras 30/16, torch 15/14, fsspec 2/1 → HIGH |
| **G-05** | P0 | No token-lifecycle check: mode, URL login, rotation/revocation, `allow_password_change`, runtime `open.html`, config/backup/snapshot copies, `NoCloud` seed | H-09/C-01: token static, 0644, accepted in URLs, no rotation; a leak is root; snapshots/clones inherit it | `stat` config/runtime; parse `ServerApp.token`/`allow_password_change`/`allow_remote_access`; detect `?token=` acceptance; check token age/rotation (config mtime vs boot, repeated across snapshots); `open.html`; `/dev/vdb`; **CRITICAL** if token is URL/HTTP or world-readable | config 0644, token 32 hex static, `allow_password_change=False`, URL accepted, `/dev/vdb` seed → CRITICAL |
| **G-06** | P0 | Updates are a raw count plus `Unattended-Upgrade`; no CVSS/exposure/known-exploited mapping; 228 pending and a 9.4 network OpenSSH fix are one line | C-02: internet-facing OpenSSH 13.14→13.20, CVE-2026-60002 CVSS 9.4 `AV:N/AC:L/PR:N`; glibc/OpenSSL/curl 9.8; no severity | For pending security packages, map CVEs to CVSS and exposure (listening service? authenticated?); flag any `AV:N/PR:N/UI:N` ≥9.0 on an exposed port; **CRITICAL**; include a "not just counts" line | 228 security, OpenSSH 9.4, glibc 9.8, OpenSSL 9.8, curl 9.8 → CRITICAL |
| **G-07** | P1 | Repo age, `Valid-Until`, key expiry/rotation, and third-party origin coverage are not checked; it does catch HTTP/global/pin | H-05: Lambda `InRelease` 2025-12-31, no `Valid-Until`, HTTP, 2018 key no expiry; Mellanox/PPA HTTP | Parse `InRelease` for Date/Valid-Until; key `gpg --list-packets` expiry; list every source and whether `signed-by` is scoped; warn if Date older than 30/90 days | Date 2025-12-31, no Valid-Until, key 2018/no expiry, Mellanox HTTP → HIGH |
| **G-08** | P1 | No CPU microcode / speculative-vulnerability check | M-01: EPYC 7J13, `spec_rstack_overflow` and `tsa` "Vulnerable… no microcode"; `amd64-microcode` 2025-03-11 → 2025-12-02 | Read `/sys/devices/system/cpu/vulnerabilities/*`; any "Vulnerable" → WARN/HIGH; compare `amd64-microcode`/`intel-microcode` installed vs candidate; note SMT | SRSO/TSA vulnerable, microcode update pending → MEDIUM/HIGH |
| **G-09** | P1 | GPU check is mode-based; no functional `nobody` allocation, no MIG/memory cap, no RDMA/knem/IB device checks | H-06/POC-3/5: `nobody` took 8 GB; `/dev/knem`, `uverbs0`, `rdma_cm` 0666; RDMA bypasses IP firewall | As `nobody`: `nvidia-smi -L`, tiny torch alloc (64 MiB) then free; `stat` `/dev/infiniband/*`, `/dev/knem`; `ibv_devinfo`; `nvidia-smi mig -lgip`; MIG/memory cap | 8 GB allocated by `nobody`; RDMA/knem 0666; MIG disabled → HIGH |
| **G-10** | P1 | Firewall check is host-local; no external reachability, Docker `DOCKER-USER`, shared-VPC/east-west, or public tunnel bypass | H-07/POC-7: UFW inactive; 22/25/111 on 0.0.0.0; public Jupyter 200 while 7000 filtered; /20 VPC | Default-deny check; `nft`/iptables rules incl. `DOCKER-USER`; list 0.0.0.0 services; optional external port probe from a second host; resolve cloudflared ingress | firewall off, 25/111 exposed, Docker bypass, public tunnel 200 → HIGH |
| **G-11** | P1 | Auditd presence only; no off-host log, tamper-evidence, FIM, IDS, alert transport, or detection of token use/new connector | H-08: no auditd, local unsealed logs, sudo can wipe; token use logs `127.0.0.1`; no alert | auditd rules; `rsyslog`/journal remote; AIDE/IMA; fail2ban; alert hook; check Jupyter 401/403 counters and cloudflared connector changes; `sgs-check.timer` on Lambda | auditd absent, no remote, no FIM/alert → HIGH |
| **G-12** | P1 | SSH check covers password/root/X11/Match only; not weak MACs/KEX, agent forwarding, `ClientAliveInterval`, `RequiredRSASize`, `authorized_keys2`, root key/forced command, `pam_faillock` | M-03: hmac-sha1/umac-64 accepted; agent forwarding; no idle; RSA 1024; root key forced command; no lockout | `sshd -T` for macs/kex/agent/idle/rsa; `authorized_keys2`; `/root/.ssh/authorized_keys` + `command=`; `pam_faillock`; test root auth returns forced command, not shell | root forced (mitigated), X11 on, agent on, no idle, weak MACs, no fail2ban → MEDIUM |
| **G-13** | P1 | `pip.conf` only checked for index URLs; no `break-system-packages`, hash/constraints, SBOM, `pip-audit`/`gitleaks`/`modelscan`, model-loading defaults | H-02/H-10/M-07: `/etc/pip.conf break-system-packages=true`; no hashes/index allowlist; Keras safe_mode bypass; no safetensors/modelscan; no SBOM | Parse pip.conf; check `require-hashes`/constraints; scanners present; `torch.load` default; Keras safe_mode; `safetensors`/`modelscan`; SBOM | break-system-packages true; no hashes/scanners/modelscan → MEDIUM |
| **G-14** | P1 | Service sandbox only for `sgs-jupyter@`; no cloudflared/glances/postfix/rpcbind sandbox or removal; no postfix relay/glances auth | M-04/H-03/NET-08/10: cloudflared 9.6, glances root/no auth, postfix loopback relay, rpcbind no NFS | `systemd-analyze security` for every network service; `User=`/`NoNewPrivileges`/`Protect*`; postfix `mynetworks`/`VRFY`; glances auth | cloudflared 9.6, glances root, postfix/rpcbind → MEDIUM |
| **G-15** | P1 | No Jupyter Host-header/rate-limit/version-disclosure/pre-auth check | JUP-10/11/13: `allow_remote_access=True` → `Host: evil` 200; no login throttling; `/api` version 2.17.0 pre-auth | `curl -H 'Host: evil' /api`; rapid `/login`; `/api` version; `trust_xheaders`/`allow_remote_access` | Host 200, no rate limit, version 2.17.0 → MEDIUM |
| **G-16** | P2 | Missing low sysctls: kexec/panic/SysRq, `vm.unprivileged_userfaultfd`, `/tmp`/`/dev/shm` mount options, `pam_unix nullok`, umask, memlock, `/var/crash`; it checks `io_uring`/`ldisc`/redirects | M-02/M-03/L-03: kexec 0, panic 0, SysRq 176, `/tmp` no nodev/nosuid/noexec, nullok, umask 0002, memlock unlimited, `/var/crash` 3777 | Add each with the right strictest value; mount options; PAM/limits; `kernel.core_pattern` | several gaps → LOW/MEDIUM |
| **G-17** | P2 | No apt/dpkg history, `needrestart`/reboot-required reporting, or package-provenance check | H-08/M-07: `/var/log/dpkg.log` and `/var/log/apt/history.log` absent; no reboot flag; `needrestart` present but unreported | Check files exist/rotate; `needrestart -b`/`/run/reboot-required`; `dpkg --verify`; SBOM | history missing; no reboot notice → LOW/MEDIUM |
| **G-18** | P1 | No cloud-init/NoCloud seed/clone credential check | H-09/SEC-07: token/tunnel secret persist in `/var/lib/cloud` and `/dev/vdb` (`0660 root:disk`); clones inherit | Read `datasource`; `blkid` cidata; check `vendor-data`/`obj.pkl` modes; warn that snapshots carry credentials; test clone rotation | NoCloud `/dev/vdb` carries token/tunnel → MEDIUM |
| **G-19** | P2 | No classic snap/setcap helper check | L-04: `aws-cli`/`gcloud` classic, `azure-cli`, `gst-ptp-helper cap_net_admin`, `snap-confine` broad caps | `snap list` confinement; `getcap -r /`; flag classic/unused and unexpected caps | classic snaps, gst-ptp-helper cap_net_admin → LOW |
| **G-20** | P2 | No `nvidia-persistenced` socket/CDI spec permission check | GPU-09/POC-5: `/run/nvidia-persistenced/socket` 0777, CDI spec 0644, bind-mounted into GPU containers | `stat` socket/spec; check `ro` does not block `connect`; include in GPU finding | socket 0777, spec 0644 → LOW |

## Scoring model changes

The current model is `passes/warns/skips` (three counters, all WARNs equal; a
`SKIP` is not a failure). That is why 24 PASS / 30 WARN can coexist with two
Critical findings.

**Proposed:**

1. **Severity on every result.** `bad "CRITICAL|..."`, `bad "HIGH|..."`,
   `bad "MEDIUM|..."`, `bad "LOW|..."`. Count `critical/high/medium/low`.
   Display the severities at the top **before** the PASS/WARN counts.
2. **Blocking checks.** Any `CRITICAL` = exit 2 (or `--fail-on critical`);
   `HIGH` = exit 1; `MEDIUM`/`LOW` = warn; `PASS` only if the check actually
   ran. A machine with a public HTTP management plane must not print "24 PASS"
   as its headline.
3. **Coverage, not just PASS.** Track `checks_run / checks_total`; show
   `coverage: 96% (1 SKIP: pip-audit)`. A missing pip-audit is not a clean
   Python stack. `--quick` should display the reduced coverage and never let a
   skipped check count as PASS.
4. **Chain checks.** Add a small set of compound checks whose result is
   CRITICAL/HIGH regardless of the individual checks:
   - public Jupyter + HTTP/no-HSTS + token/URL + service user sudo → **CRITICAL**
   - Jupyter service user sudo/terminal + known Jupyter CVE → **HIGH/CRITICAL**
   - tunnel secret readable + cloudflared root → **HIGH**
   - 228 security + auto-updates off + exposed OpenSSH 9.4 → **CRITICAL**
   - GPU/RDMA 0666 + driver CVE range → **HIGH**
   - no auditd + public management plane → **HIGH**
5. **Public/edge mode.** `--public <host>` or `--tunnel` (auto-read
   `/etc/cloudflared/config.yml`) with timeouts and no auth. Default host-local
   checks stay; public checks only run when asked (or when a tunnel exists),
   and report "not assessed" otherwise. Do not print tokens.
6. **JSON and baseline.** `--json` with `{id,severity,status,message,fix}`;
   `--baseline FILE` diff for drift; `--fail-on high`; CI-friendly. Keep the
   human output.
7. **Fix hints.** Each finding gets a one-line remediation, not just a
   description. The builder can map to the Secure GPU Stack tasks.
8. **Do not count a check as PASS because the tool is absent.** The current
   `pip-audit` SKIP is honest; the score should show the coverage loss.

## Precision fixes (avoid false positives and false comfort)

These were observed on this instance:

- **Metadata 404 is not "readable".** `sgs-check` printed
  `[WARN] Ordinary users can read the cloud metadata service` because
  `curl` returned 0; the service returns a 128-byte 404 for every standard path
  (and 405 for IMDSv2 `PUT`). Check status/body/known paths; treat 404/405 as
  "endpoint exists, no data" (INFO/LOW), not a credential leak.
- **`torch.compile` is a potential, not a proven, cross-user issue.** The cache
  is `/tmp/torchinductor_ubuntu` `0775`; `nobody` cannot write it. The real
  risks are pre-creation/DoS and a second user in the `ubuntu` group; test the
  actual ownership/permissions, not just the path.
- **Root login is forced-command.** The root key is the user's own key with
  `command="...exit 142"`, `no-port-forwarding`; auth succeeds but no shell
  (POC-8). Report "root login enabled (forced command)", not "root shell"; check
  the forced command explicitly.
- **Pillow/setuptools OSV counts overstate Ubuntu.** Ubuntu backports CVEs
  without changing `10.2.0`/`68.1.2`; use the Ubuntu CVE tracker/USN, or the
  package's changelog. `setuptools` only CVE-2026-59890 (6.1) is open here;
  CVE-2024-6345/CVE-2025-47273 are backported. Pillow 10.2.0-1ubuntu1.3 is the
  pending Ubuntu security update.
- **`flash-attn` is not installed**; do not carry finding #8 onto this image.
- **`apt full-upgrade` failure did not reproduce** on this instance; it resolves
  in simulation. Do not hard-code "full-upgrade is broken"; test the resolver
  and the DKMS rebuild, and report the kernel/driver skew.
- **JupyterLab is pipx-installed**, not a system package. A `pip list`/`dpkg`
  scan can say "not installed" while the public management plane runs; use
  `pipx list --json` and the venv path.
- **The token is not in the journal at startup.** Jupyter prints `token=...`
  (literal ellipsis) for config-sourced tokens; access logs can record a
  token-bearing URL if one is used. Check the config/URL/HTTP, not the startup
  banner.
- **Tunnel secret 0644 vs Jupyter config 0644.** The tunnel file is genuinely
  world-readable; the Jupyter config is protected by the 0750 home. Report
  them separately; don't say "the token is world-readable".
- **Postfix is a loopback relay, not an internet open relay.** It returns 250
  from 127.0.0.1 and 454 from the instance address; 25 is filtered externally.
  Report the local-only relay and `VRFY` as LOW.
- **R580 is not EOL.** The public install script's R570 is EOL; this image's
  R580 is supported through 2028. The issue is the pinned *build*
  (580.105.08 vs 580.178.04), not the branch.
- **`JupyterLab refuses requests without a token` is true but insufficient.**
  Pair it with token-at-rest/URL/HTTP/service-user checks; a PASS there is not
  a PASS for the management plane.
- **`JupyterLab listens on localhost` is misleading with a public tunnel.**
  Resolve the tunnel first; the localhost bind is not the exposure boundary.

## Suggested implementation order

1. **Scoring/severity/coverage/JSON** — so the next run cannot hide a Critical
   behind 24 PASS.
2. **Public edge + tunnel + Jupyter service/user/CVE/token** (G-01..G-05,
   G-15) — the verified chain.
3. **Patch severity + CPU + repo** (G-06..G-08) — the independent remote risk.
4. **GPU/RDMA/firewall/audit** (G-09..G-11, G-14) — local/multi-tenant.
5. **SSH/pip/model/clone/low** (G-12, G-13, G-16..G-20).
6. **Precision fixes** — rerun on this instance and on the secure stack; keep
   the secure stack's 58 PASS / 0 WARN and do not add false Criticals.

## Test fixtures / acceptance criteria

- **This instance** should produce, at minimum:
  - **CRITICAL:** public HTTP Jupyter + token/URL + sudo service user (chain);
    228 security + auto-off + OpenSSH 9.4 (chain).
  - **HIGH:** tunnel secret/root cloudflared; pipx Jupyter/ML CVEs; driver
    pin/toolkit CVE/kernel; GPU/RDMA 0666; host firewall; no audit; token
    lifecycle.
  - **MEDIUM/LOW:** userns, SSH hygiene, Docker defaults, egress, CPU microcode,
    apt history, classic snaps, persistenced socket.
- **Secure GPU Stack** should stay at **58 PASS / 0 WARN** (or better) on the
  M2 VM; a public check must report "not assessed" if there is no tunnel, not a
  failure. The `sgs-jupyter` Unix socket should PASS the Jupyter checks; the
  service user must not be a sudoer; pipx/system venv must be in the audit.
- **`--quick`** must show skipped coverage, not a clean PASS.
- **`--json`** must include severity/status; the summary should lead with
  Critical/High.
- **No secret output:** token/tunnel values must never be printed; use
  length/mode/key-name checks.
- **No destructive tests:** `nobody` GPU allocation ≤64 MiB and free; no
  tunnel hijack; no kernel exploit; no data exfiltration.

## Handoff to the builder

- Keep the existing checks; add the G-series and severity model.
- Use this instance and its PoCs as the regression fixture:
  [`lambda-instance-pocs.md`](lambda-instance-pocs.md); raw evidence
  [`docs/audit/poc-*.txt`](audit/).
- Re-run `sgs-check` after the secure stack installs on instance B and compare
  the severity summary, coverage and JSON baseline, not just PASS/WARN counts.
- The most important single change: **a Critical finding must dominate the
  headline and exit code**, even if the rest of the checklist passes.
- The most important missing check: **the public Cloudflare/Jupyter path** —
  the host-local "localhost" view cannot see the actual exposure.

**Related:** [`lambda-instance-audit.md`](lambda-instance-audit.md),
[`lambda-stack-findings.md`](lambda-stack-findings.md), raw reports in
[`docs/audit/`](audit/).
