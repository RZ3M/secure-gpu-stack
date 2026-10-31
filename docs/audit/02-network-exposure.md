# 02 — Network exposure and services: Lambda Stack 24.04 on a live instance

**Audited:** 2026-10-30, 20:42–20:56 UTC, `ubuntu@<instance>` — Ubuntu
24.04.4, kernel 6.8.0-1046-nvidia, A100-SXM4-40GB, default Lambda Stack image.
It booted at 20:30 UTC, so every socket and service below is the image's own.
**Method:** read-only SSH (passwordless `sudo`), `ss`/`nft`/`iptables`/`sshd
-T`, loopback HTTP, and requests to this host's public hostname only. No
packages, firewall, sshd or network config changed; no reboot; no exploits; no
other host contacted. Two wrong-password `POST`s (not a brute-force run) tested
throttling. Secrets (Jupyter token, `TunnelSecret`, IDs, audit egress IP) are
`<redacted>`; `/tmp` files removed.
**Scope:** sockets, host firewall and bypasses, Cloudflare tunnel and public
endpoint, Postfix, rpcbind, Glances, cloud metadata, DNS/egress/NTP/IPv6, SSH.
Kernel/package: `docs/lambda-stack-findings.md`; GPU/Docker:
`05-gpu-containers.md`; logs: `08-logging-monitoring.md`.

## Summary

| ID | Finding | Severity | Status |
|---|---|---|---|
| NET-01 | JupyterLab is on the internet through Cloudflare Tunnel with no Access/MFA/IP allowlist and no login throttling; one static 32-hex token is the only gate | High | Verified |
| NET-02 | Cloudflare `TunnelSecret` is world-readable (0644): any local account can clone the public endpoint or serve a fake login | High | Verified |
| NET-03 | No host firewall (ufw disabled, iptables `INPUT ACCEPT`, no nft `inet`); 0.0.0.0 services open to the VPC, one Lambda rule from the internet; Docker publishes bypass ufw | High | Verified |
| NET-04 | Jupyter Server 2.17.0 has two CVEs fixed in 2.18.0 (CVE-2026-35397 traversal, CVE-2026-40934 cookie secret) and no update path | High | Verified, CVE at source |
| NET-05 | `cloudflared` runs as root with no sandbox (Seccomp 0, full caps, 9.6 UNSAFE) and unauthenticated `/debug/pprof/*` + `/config` on loopback | Medium | Verified |
| NET-06 | `cloudflared` 2026.2.0 vs repo 2026.10.7; `--no-autoupdate`, a no-op daily timer, and unattended-upgrades cannot update it | Medium | Verified |
| NET-07 | Jupyter accepts any `Host` (`allow_remote_access=True`) and, with `trust_xheaders=False`, logs every internet client as `127.0.0.1` | Low | Verified |
| NET-08 | Postfix on 0.0.0.0:25 with no auth; loopback is an open relay (spoofed sender, any recipient), `VRFY` on, snakeoil TLS | Low | Verified |
| NET-09 | rpcbind on 0.0.0.0:111 TCP+UDP with only the portmapper registered; no NFS in use | Low | Verified |
| NET-10 | Glances XML-RPC on 127.0.0.1:61209 runs as root with no password and sends `Access-Control-Allow-Origin: *` | Low | Verified |
| NET-11 | SSH allows key-based root login via the `ubuntu` login key (forced command only), no fail2ban/per-source limits, X11 on (confirms #12) | Low | Verified |
| NET-12 | IPv6 redirects accepted, host may send IPv4 redirects while forwarding, loose `rp_filter`, no martian logging | Low | Verified |
| NET-13 | Public endpoint has no HSTS and few security headers; `_xsrf` cookie lacks `Secure`/`HttpOnly`/`SameSite` | Low | Verified |
| NET-14 | Egress unrestricted and unlogged; plaintext DNS to 1.1.1.1/8.8.8.8 with no DNSSEC; unauthenticated NTP | Info | Verified |

**Counts: 0 Critical, 4 High, 2 Medium, 7 Low, 1 Info.** NET-02 duplicates
`08/LOG-06` and NET-10 `08/LOG-11`; count each once when merging.

## Detailed findings

### NET-01 Public JupyterLab behind one static token — High
Ingress is `http://localhost:7000`, so the loopback bind protects nothing. `/` →
`302 /lab?`; `/login` → `200` (Jupyter's page, not `cloudflareaccess.com`);
`/api` → `{"version": "2.17.0"}` unauthenticated; two wrong `POST /login` → `401`
in 0.13/0.20 s with no `429`, `Retry-After` or lockout. No `cf-access-*` header
and the audit IP is not allowlisted: no Cloudflare Access, SSO/MFA or IP
allowlist; `__cf_bm` never challenged.
**Impact.** Internet-wide code execution as `ubuntu` (`NOPASSWD: ALL` sudo →
root): one static token, no MFA, no per-user identity, no throttle. A token
leaked once (URL in chat, screen share, notebook output, history) works until
rebuild; `allow_password_change=False`.
**Fix.** Cloudflare Access (SSO/MFA) or service token + IP allowlist with
identity logged; edge rate limits and `401` alerts; per-instance rotation.
Refs: `08/LOG-01`; OWASP ASVS V2/V11.

### NET-02 The tunnel credential is world-readable — High
`stat -c '%a %U:%G %n' /etc/cloudflared/*` → both `644 root:root`; `sudo -u
nobody test -r …/jupyter-tunnel.json` → `READABLE`; keys `AccountTag, TunnelID,
TunnelName, TunnelSecret`. Vendor-data writes it with the default umask;
`cloudflared service install` later creates the root service.
**Impact.** Any local account or process — including a Jupyter kernel, the
image's own code-execution surface — can copy `TunnelSecret` and run `cloudflared
tunnel run` from anywhere without a Cloudflare login. Cloudflare balances across
a tunnel's connectors, so an attacker can receive public traffic, serve a fake
login on the real hostname to harvest the token, or sit on sessions.
**Fix.** `chmod 600` the JSON, `chmod 700 /etc/cloudflared`; dedicated user with
systemd `LoadCredential=`; `umask 077`; rotate the tunnel.
Refs: `08/LOG-06`; CIS 24.04 §6.1.

### NET-03 No host firewall; only Lambda's external rules — High
`ufw status verbose` → `inactive`; `ENABLED=no`; `iptables -S` → `-P INPUT
ACCEPT`, `-P FORWARD DROP`, `-P OUTPUT ACCEPT`; `iptables -L -n -v` → `Chain
INPUT (policy ACCEPT 0 packets, 0 bytes)`, no rules; `nft list tables` → only
`ip`/`ip6` nat+filter, no `inet`. `ss -lntu` binds 0.0.0.0 on 22, 25, 111 (and
`[::]`), 127.0.0.1 on 7000/20241/61209/53; `eno1` is `<instance-private-ip>/20`.
`ufw.service` "active" is the init oneshot only.
**Impact.** Any peer in `10.19.80.0/20` reaches 22, 25 and 111; one firewall
mistake exposes SMTP/rpcbind to the internet, and only 22 answers today, so
Lambda's filter is the only layer. Docker is installed (`ip_forward=1`) and
publishes ports in `nat PREROUTING`/`filter FORWARD`, never `INPUT`, so enabling
ufw later would not filter containers (latent: none today).
**Fix.** Default-deny inbound (nftables/ufw) allowing SSH only, plus
`DOCKER-USER`; bind SMTP/RPC/Glances to loopback; keep cloud rules as layer two.
Refs: Docker "Packet filtering and firewalls"; CIS §3.4–3.5; `05/GPU-06`.

### NET-04 The public Jupyter is a February build with two unpatched CVEs — High
`/api` → `{"version": "2.17.0"}`; the venv has `jupyter_server 2.17.0`
(`jupyterlab 4.5.5`) with directory mtime `2026-02-25`. Both advisories cover
"2.17.0 and earlier", fixed in **2.18.0**: **CVE-2026-35397** — path traversal in
`/api/contents`; an authenticated user can read/write/delete sibling directories
sharing the `root_dir` prefix (CVSS 7.1 High). **CVE-2026-40934** — the
cookie-signing secret is never rotated, so a stolen cookie survives a
token/password change (CVSS 6.8; v4 7.6).
**Impact.** With `root_dir=/home/ubuntu` a token holder can step into `/home/*`
siblings; a captured cookie (XSS, shared laptop, proxy log, `open.html`) gives
access that rotation does not revoke. The venv is outside apt
(unattended-upgrades covers Ubuntu origins only) and has no pipx/cron updater, so
the image never patches it.
**Fix.** Rebuild on jupyter_server ≥ 2.18.0, pin it in the build and a scheduled
upgrade; delete `runtime/jupyter_cookie_secret` on upgrade.
Refs: [CVE-2026-35397](https://ubuntu.com/security/CVE-2026-35397) ·
[CVE-2026-40934](https://ubuntu.com/security/CVE-2026-40934) · GHSA-5789-5fc7-67v3.

### NET-05 cloudflared: unsandboxed root daemon with debug endpoints — Medium
No `User=`, `CapabilityBoundingSet=` or `Protect*` in the unit; `/proc/2692/status`
→ `Uid: 0`, `CapEff: 000001ffffffffff`, `NoNewPrivs: 0`, `Seccomp: 0`;
`systemd-analyze security` → `9.6 UNSAFE`. On loopback, `/debug/pprof/heap` →
`200` (9 KB) and `/config` → ingress JSON.
**Impact.** A daemon Cloudflare can drive runs as root with every capability, no
seccomp, no `NoNewPrivileges`, no filesystem sandbox: a cloudflared bug becomes
host root. Any local user can read `/config`, pull heap/CPU profiles from a root
process proxying plaintext HTTP, and read tunnel counters/connector ID. A 23 KB
heap sample held no `TunnelSecret`.
**Fix.** `User=cloudflared`, `NoNewPrivileges=yes`, `CapabilityBoundingSet=`,
`ProtectSystem=strict`, `ProtectHome=tmpfs`, `PrivateTmp=yes`,
`RestrictAddressFamilies=AF_INET AF_INET6`, `SystemCallFilter=@system-service`;
metrics on a Unix socket or 20241 blocked; keep current (NET-06). Ref:
systemd.exec(5).

### NET-06 The tunnel daemon is stale and cannot update itself — Medium
`cloudflared --version` → `2026.2.0`; `apt-cache policy` → `Installed: 2026.2.0
/ Candidate: 2026.10.7`; the journal says "will not automatically update if
installed by a package manager"; `Allowed-Origins` covers Ubuntu/ESM only, not
`pkg.cloudflare.com`. The daily timer's `cloudflared update` exits 0.
**Impact.** Eight months of fixes are missing from a root daemon on the public
path, and the timer makes it look maintained. No specific CVE was confirmed at
the source; the finding is the missing patch path.
**Fix.** Add the Cloudflare origin to unattended-upgrades (or a pinned upgrade
job); record the version in the manifest; watch `/metrics` `build_info`.
Refs: `lambda-stack-findings` #1/#4; `08/LOG-10`.

### NET-07 Any Host header accepted; all clients logged as 127.0.0.1 — Low
`jupyter_config.py`: `allow_remote_access = True` (982), `local_hostnames =
['<host>']` (989), `trust_xheaders` left `False`. The journal shows
`302 GET /lab?token=[secret] (@127.0.0.1) 0.56ms` for an internet request.
**Impact.** `allow_remote_access` disables Jupyter's DNS-rebinding host check
(token still required: a weakened defence, not a bypass); every request arrives
via `cloudflared`, so the log can never say who connected — a stolen token looks
like the owner (`08/LOG-01`).
**Fix.** An authenticating proxy that sets `X-Forwarded-For` plus
`trust_xheaders=True`, or a Unix socket; alert on new tunnel connectors.
Ref: Jupyter Server security docs.

### NET-08 Postfix on all interfaces with a loopback open relay — Low
`ss -lntp` → `0.0.0.0:25` and `[::]:25`; `postconf -n` → `inet_interfaces = all`,
`mynetworks = 127.0.0.0/8 … [::1]/128`, `smtpd_tls_cert_file = …/snakeoil.pem`,
`smtpd_tls_security_level = may`. Banner `220 ubuntu ESMTP Postfix (Ubuntu)`;
`EHLO` advertises `VRFY`, `VRFY root` → `252`; `RCPT TO:<relaytest@example.net>`
from 127.0.0.1 → `250 2.1.5 Ok`, from `<instance-private-ip>` → `454 4.7.1 Relay access
denied`.
**Impact.** Not an internet open relay (non-loopback refused; 25 filtered
externally), but any local account or kernel can inject mail to any destination
with any envelope sender — phishing/spam from the host's IP. `VRFY` and the
hostname `ubuntu` are exposed to the VPC; TLS is self-signed; nothing
authenticates.
**Fix.** `systemctl disable --now postfix` unless mail is needed; otherwise
loopback-only, `disable_vrfy_command = yes`, reject unauthenticated mail.
Refs: Postfix `mynetworks` docs; CIS 24.04 §2.2.

### NET-09 Portmapper on all interfaces without NFS — Low
`ss -lunp` → `0.0.0.0:111` and `[::]:111`; `rpcinfo -p` → only `100000
portmapper` (tcp/udp, v2–4); no NFS mounts, no `/etc/exports`. `nfs-common` is
installed but unused, which is why the socket is enabled.
**Impact.** Only the portmapper is registered, so the leak is the RPC program
list and the surface is rpcbind itself; reachable from the VPC, filtered
externally only by Lambda. Port 111 is a known UDP reflection target (one entry
here, so small).
**Fix.** Disable `rpcbind.socket`/`rpcbind.service`, remove `nfs-common` if NFS
is not planned, or bind rpcbind to loopback. Refs: CIS 24.04 §2.2.17; US-CERT
rpcbind amplification advisory.

### NET-10 Glances: root, unauthenticated, readable from any web page — Low
`glances.service` → `/usr/bin/glances -s -B 127.0.0.1` (no `-P`);
`/proc/1635/status` → `Uid: 0`, `CapEff: 000001ffffffffff`. As `nobody`, `POST
/RPC2 getAll` → `200`, 180 298 bytes; a POST with `Origin:
https://evil.example` and `Content-Type: text/plain` returns
`Access-Control-Allow-Origin: *`.
**Impact.** `glances -s` has auth only with `-P/--password`, which is not passed,
so `nobody` gets the full system/process/network/GPU snapshot from a root
process. The wildcard CORS header plus `text/plain` acceptance (a CORS "simple
request", no preflight) lets a page the user visits POST to loopback and read it.
**Fix.** Disable it (it feeds nothing) or run as a dedicated user with
`--password`, on a Unix socket, dropping capabilities. Refs: `08/LOG-11`; Glances
server docs.

### NET-11 SSH allows a root key path, no rate limiting, X11 on — Low
`sshd -T`: `permitrootlogin without-password`, `x11forwarding yes`,
`maxstartups 10:30:100`, `persourcemaxstartups none`, `passwordauthentication
no`. `ssh-keygen -lf /root/.ssh/authorized_keys` → the same `SHA256:tZdx…`
ED25519 key as `ubuntu`, with a forced `command="echo 'Please login as the user
\"ubuntu\" …';sleep 10;exit 142"`. No `fail2ban`/`sshguard`/`crowdsec`.
**Impact.** Root login is permitted with a key, and it is the same key that logs
in as `ubuntu`; only the per-entry forced command stops a root shell, so a second
key in `/root/.ssh/authorized_keys` is a silent root backdoor. `X11Forwarding
yes` confirms #12; port 22 has no fail2ban, per-source limit or IDS.
**Fix.** `PermitRootLogin no` and delete `/root/.ssh/authorized_keys`;
`X11Forwarding no`; `PerSourceMaxStartups 3` or sshguard; `AllowUsers ubuntu`.
Refs: `lambda-stack-findings` #12; CIS 24.04 §5.2.

### NET-12 Redirects, reverse path and forwarding — Low
`sysctl`: `all.accept_redirects=0` but `eno1.accept_redirects=1` (ANDed → IPv4
effective 0); `eno1.send_redirects=1`; `all.rp_filter=2`; `ip_forward=1`;
`all.log_martians=0`; `tcp_syncookies=1`; IPv6 `all`/`eno1`
`accept_redirects=1` (effective 1).
**Impact.** IPv4 redirects are effectively off but one drift from on; IPv6
redirects are accepted (no global IPv6 today, so link-local peers only). The host
may send ICMP redirects while forwarding; `rp_filter=2` accepts asymmetric
routes; martians are not logged, so spoofed traffic leaves no trace.
**Fix.** Set `all` and each interface: `accept_redirects=0`,
`send_redirects=0`, `rp_filter=1`, `log_martians=1`, IPv6
`accept_redirects=0`. Refs: CIS 24.04 §3.2; `lambda-stack-findings` #11.

### NET-13 No HSTS, thin headers, weak `_xsrf` cookie — Low
`curl -sI https://<host>/login` → `200` with `content-security-policy:
frame-ancestors 'self'`, `x-content-type-options: nosniff`, `set-cookie:
_xsrf=2|…; Path=/` (no `Secure`, `HttpOnly` or `SameSite`), and no
`strict-transport-security`, `referrer-policy` or `permissions-policy`.
**Impact.** Without HSTS there is a downgrade/SSL-strip window on first visit
(the certificate itself is a valid GTS WE1 cert for the hostname until
2027-01-28). The CSP only sets `frame-ancestors`; the XSRF cookie is
script-readable and scheme-agnostic.
**Fix.** HSTS at Cloudflare, `Referrer-Policy: no-referrer`,
`Permissions-Policy`, a CSP restricting `script-src`, and Jupyter `cookie_options`
with `secure`/`httponly`/`samesite`. Ref: OWASP Secure Headers Project.

### NET-14 Egress, DNS and time are unrestricted — Info
`iptables -S OUTPUT` → `-P OUTPUT ACCEPT`, no rules; `curl https://example.com/`
→ `200`; `resolvectl status` → DNS `1.1.1.1 8.8.8.8`, `DNSSEC=no/unsupported`;
`chronyc sources` → public pool, no NTS.
**Impact.** Any process can reach any host/port with no logging or policy —
exfiltration, C2, mining and downloads are indistinguishable. DNS is plaintext
without DNSSEC, so an on-path attacker can redirect downloads (the Lambda apt
repo is HTTP anyway, #5); time is unauthenticated. This contradicts design rule
8; the image has no strict-egress equivalent.
**Fix.** Ship the documented egress allowlist (DNS, apt, tunnel, model hubs) with
denial logging; DoT/DNSSEC; NTS or an internal time source. Refs:
`docs/design.md` §11; `docs/threat-model.md`.

## Checked and not a finding

- **External filtering works.** Only 22/tcp answers from the internet; 25, 80,
  111, 443, 7000, 8888, 20241 and 61209 time out. The gap is that it is the only
  layer (NET-03).
- **Metadata is a 404 stub, not a credential source.** `/`, `/latest/meta-data/`,
  `/latest/meta-data/instance-id`, `/latest/user-data`, `/latest/api/token` (PUT
  → 405), `/2009-04-04/`, `/computeMetadata/v1/`, `/openstack/` and Azure's
  `/metadata/instance` all return the same 128-byte 404 (`Server: server`,
  `X-Request-Id`), including with GCP/Azure headers, for `ubuntu` and `nobody`.
  No cloud data exposed; `lambda-stack-findings` #13 stays defence-in-depth.
- **The Jupyter token is not in world-readable logs.** Startup logs
  `…/lab?token=...`; access logs show `?token=[secret]`; the literal token is 0
  times in the journal and both cloud-init logs. It is in `jupyter_config.py`
  (0644, but `/home/ubuntu` is 0750), `runtime/jpserver-*.json` (0600) and
  `-open.html` (0644, dir 0700). Artefact: one `sudo grep` line containing the
  token went to `/var/log/auth.log` (0640 `syslog:adm`). Corrects the "two
  persistent journal lines" part of `08/LOG-05`.
- **Postfix is not an internet open relay.** Non-loopback source gets
  `454 4.7.1 Relay access denied`; `EXPN` → `500`; queue empty.
- **No containers or published ports.** `docker ps -a` empty; `nat DOCKER` and
  `DOCKER-USER` empty; `docker0` DOWN. `docker` group has no members;
  `/run/docker.sock` is `0660 root:docker`, containerd/podman sockets `0660
  root:root`; `docker ps` as `ubuntu` denied. `snapd.socket` is `0666` but local.
- **Users, crypto and IPv6 are otherwise sane.** Only `root` and `ubuntu` have
  shells; `ubuntu` is locked (`!`); `PasswordAuthentication no` in both drop-ins;
  `PermitTunnel no`; `UseDNS no`; SYN cookies on; only strong KEX/ciphers/host
  keys; `ssh.socket` activation; `accept_ra=0` on `eno1`; no global IPv6, so
  `[::]` listeners are unreachable off-host; public TLS cert valid and matching.
- **Package/unit integrity is clean.** `dpkg -V cloudflared ufw` empty; "unit
  changed on disk" warnings are boot-time writes, not tampering.

## Limits

- One host, one subnet: intra-VPC reachability is inferred from the binds, the
  `/20` route and the empty firewall, not tested from a second instance.
- Cloudflare account-side configuration (WAF, Access, Logpush) is not readable
  from the host; the absence of Access is inferred from responses.
- Tunnel takeover with the copied `TunnelSecret` was not attempted (a second
  connector would divert live traffic); CVEs are matched by version, not run.
