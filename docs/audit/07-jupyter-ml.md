# 07 — Jupyter and ML application security, default Lambda Stack 24.04

**Host:** `ubuntu@<instance>` — Ubuntu 24.04.4, kernel 6.8.0-1046-nvidia,
A100-SXM4-40GB, driver 580.105.08, Lambda Stack image. **Audited:** 2026-10-30,
over SSH, read-only: no config changed, no package installed, no notebook run,
no login with the real token, no reboot. Authorised test on an instance we rent.
Token, tunnel secret and Cloudflare account tag are redacted.

## Summary

| ID | Severity | Finding |
|---|---|---|
| JUP-01 | Critical | JupyterLab is published to the internet by a root cloudflared tunnel behind one bearer token; the tunnel bypasses Lambda's firewall |
| JUP-02 | Critical | Notebook/web terminal runs as `ubuntu` with `NOPASSWD: ALL` sudo in an unsandboxed unit — one click from the UI to root |
| JUP-03 | High | Token is a static, never-rotated secret baked into per-instance vendor-data, stored cleartext, accepted in URLs; logout does not revoke it |
| JUP-04 | High | Cloudflare tunnel credentials are 0644 and readable by `ubuntu`; cloudflared runs as root and is 8 months behind the available package |
| JUP-05 | High | jupyter-server 2.17.0 (4 releases behind): Critical stored XSS, High token-in-Referer log leak, High path traversal, non-revocable cookies |
| JUP-06 | High | JupyterLab 4.5.5, notebook 7.5.4, nbconvert 7.17.0, tornado 6.5.4, mistune 3.2.0: 89 OSV advisories incl. token-theft XSS and unauth DoS |
| JUP-07 | High | ML loaders: Keras 3.10.0 (30 advisories, `safe_mode` bypass), Pillow 10.2.0 (78, five Critical), venv certifi (Critical CA compromise), urllib3 2.6.3 |
| JUP-08 | High | No HTTPS enforcement or HSTS: `http://<host>/login` is cleartext; the Jupyter cookie has no `Secure` or `SameSite` |
| JUP-09 | Medium | Jupyter unit has no sandboxing (`systemd-analyze security`: 9.2 UNSAFE), `Restart=always`, and a PIDFile that does not exist |
| JUP-10 | Medium | `allow_remote_access=True` disables Host validation (`Host: evil.example` → 200), re-enabling DNS rebinding; `local_hostnames` is then moot |
| JUP-11 | Medium | `/login` has no rate limit, lockout or delay (401, no `Retry-After`); mitigated only by the token's 128 bits |
| JUP-12 | Medium | `/etc/pip.conf` sets `break-system-packages = true`; no hash-checking, no `pip-audit`/`modelscan`/`safetensors`; HTTP+HTTPS egress open |
| JUP-13 | Medium | Pre-auth version disclosure (`/api` → `2.17.0`), open redirect in `next` (CVE-2025-61669), no `Referrer-Policy` |
| JUP-14 | Medium | Root-run Glances and cloudflared's metrics API listen on localhost, reachable from a notebook; Glances has no auth |
| JUP-15 | Low | Token in a 0644 config, `open.html` 0644 with the token, writable kernel spec, 0644 file-ID DB |
| JUP-16 | Low | `/dev/nvidia*` are 0666: every local account can use the GPU |
| JUP-17 | Low | No idle shutdown or culling (`shutdown_no_activity_timeout=0`), 512 MB bodies: process holds resources until reboot |

**Counts:** 2 Critical, 6 High, 6 Medium, 3 Low. **Top 5:** JUP-01, JUP-02,
JUP-03, JUP-04, JUP-05.

## Effective Jupyter settings
`ip=127.0.0.1`, `port=7000`, `root_dir=/home/ubuntu`, `token`=32 lowercase hex
(redacted), `password` empty, `allow_password_change=False`,
`allow_remote_access=True`, `local_hostnames=[…-0.lambdaspaces.com]`,
`trust_xheaders=False`, `disable_check_xsrf=False`, `allow_origin`/`pat` unset,
`base_url=/`, `allow_root=False`, `open_browser=False`, `terminals_enabled=True`,
`contents_manager`/`kernel_manager` defaults, `shutdown_no_activity_timeout=0`,
culling 0. Unit: `User=ubuntu`, `Restart=always`, `RestartSec=10`, no sandbox
directives, `PIDFile=/run/lambda-jupyter-lab.pid` (never written).

## Detailed findings

### JUP-01 — Critical — Public JupyterLab behind one static token
`ss -ltnp | grep 7000` → `127.0.0.1:7000 users:(("jupyter-lab",pid=2713))`;
`curl -sS https://…/api` → `{"version": "2.17.0"}`; `/login` → 200; `ufw status` → inactive.
No Cloudflare Access (no `CF-Access-*` requirement), no MFA, no SSO, no IP allowlist; ten rapid `GET /login` all 200. Lambda's firewall admits only 22/tcp; the outbound tunnel makes that irrelevant. **Impact:** anyone with the URL reaches the login page; the only gate is a bearer token (JUP-03), and a leak is RCE as `ubuntu` (JUP-02). **Fix:** Cloudflare Access/SSO with MFA, or drop the tunnel for SSH forwarding. **Ref:** CWE-306/CWE-284.

### JUP-02 — Critical — Notebook or terminal → root
`ps -eo user,pid,args | grep '[j]upyter'` → `ubuntu 2713 … jupyter-lab --config /home/ubuntu/.jupyter/jupyter_config.py`; `sudo -n -l | tail -2` → `(ALL) ALL` / `(ALL) NOPASSWD: ALL`; `sudo -n true` → ok; `jupyter server extension list | grep terminals` → `jupyter_server_terminals enabled`.
The unit runs as `ubuntu` with no `NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp` or `SystemCallFilter` (JUP-09). The web UI offers a terminal and notebooks as `ubuntu`; `sudo` is root. No root command was run. **Impact:** token compromise, token-theft XSS (JUP-05/06) or a malicious notebook equals root on the GPU host: driver, Docker, tunnel credentials, keys. **Fix:** dedicated non-sudo account or container, no terminal, sandboxed unit. **Ref:** CWE-250/CWE-269.

### JUP-03 — High — Token lifecycle: static, cleartext, in URLs, no rotation
`stat -c '%a %U:%G %y' …/jupyter_config.py` → `644 ubuntu:ubuntu 2026-10-30 20:30:52`; `sudo grep -n 'ServerApp.token' /var/lib/cloud/instances/*/vendor-data.txt` → `1035:c.ServerApp.token = '<redacted>'`; `/lab?token=FAKE` → `302 …/login?next=%2Flab%3Ftoken%3DFAKE`.
32 hex chars, 128 bits, 14 distinct symbols; not derived from tunnel, instance or hostname (md5/sha1/sha256 tested). The token is baked into per-instance vendor-data (0600 root) and written to the config once; restarts re-read the same file, so it never rotates. `allow_password_change=False` blocks the UI path; `GET /logout` only clears the cookie (CVE-2026-40934 keeps auth cookies valid across restarts/resets). Startup logging is safe: `?token=...` prints a literal ellipsis for config-sourced tokens, and a fake token in `Referer` logged as `token=[secret]`. The URL form puts it in browser history and edge logs. **Impact:** one sighting (screenshot, browser sync, proxy, edge log) is valid forever; no revocation short of editing the file. **Fix:** per-user short-lived tokens/OIDC, rotation, login by POST, audit use. **Ref:** CWE-798/CWE-522; CVE-2026-40934.

### JUP-04 — High — Tunnel credentials readable; cloudflared root and outdated
`sudo stat -c '%a %n' /etc/cloudflared/*` → `644 config.yml, jupyter-tunnel.json`; `python3 -c 'open("/etc/cloudflared/jupyter-tunnel.json").read()'` → readable (TunnelSecret); `ps -eo user,args -p 2692` → `root /usr/bin/cloudflared --no-autoupdate … tunnel run`; `cloudflared --version` → `2026.2.0` (apt candidate `2026.10.7`).
**Impact:** the `TunnelSecret` lets a holder run a second connector for the same tunnel (Cloudflare balances across connectors), receive login POSTs or serve a phishing page on the legitimate hostname; the root network daemon is 8 months behind fixes. **Fix:** `chmod 600`, unprivileged user with `NoNewPrivileges`, patch, rotate the secret. **Ref:** CWE-732/CWE-250.

### JUP-05 — High — jupyter-server 2.17.0 is four releases behind, with a Critical
`jupyter --version` → `jupyter_server 2.17.0` (latest 2.21.1); OSV by exact version returns 14 advisories. **Critical** (GitHub/OSV severity; CVSS v3.1 5.9) GHSA-fcw5-x6j4-ccmp / CVE-2026-44727: stored XSS in `NbconvertFileHandler`/`NbconvertPostHandler`, fixed 2.20.0. **High** GHSA-c3mw-737p-c7g2 / CVE-2026-86049: 5xx logging leaks a token-bearing `Referer`, fixed 2.21.0. **High** GHSA-5789-5fc7-67v3 / CVE-2026-35397: path traversal via wrong `startswith()` root check, fixed 2.18.0. **High** GHSA-5mrq-x3x5-8v8f / CVE-2026-40934: auth cookies survive password reset and restart, fixed 2.18.0. **Moderate** GHSA-qh7q-6qm3-653w / CVE-2025-61669: open redirect in `next`, fixed 2.18.0. `GHSA-24qx-w28j-9m6p` (CORS bypass) does not apply: `allow_origin_pat` is unset.
**Impact:** a crafted notebook/link can run script in the JupyterLab origin and read the session; the 5xx bug is the one path that can still put the static token in the journal; traversal escapes `root_dir` but not the user. **Fix:** jupyter-server ≥ 2.21.1. **Ref:** OSV.dev, 2026-10-30.

### JUP-06 — High — JupyterLab/notebook/nbconvert/tornado/mistune backlog
OSV by exact version (installed → latest, advisories): JupyterLab 4.5.5 → 4.6.5, 21; notebook 7.5.4 → 7.6.4, 6; nbconvert 7.17.0 → 7.17.2, 5; tornado 6.5.4 → 6.6, 21; mistune 3.2.0 → 3.4.0, 33; bleach 6.3.0 → 6.4.0, 3.
- JupyterLab `GHSA-rch3-82jr-f9w9` (BIT-2026-40171, High): **auth token theft via CommandLinker XSS**, fixed 4.5.7 / notebook 7.5.6.
- JupyterLab `GHSA-mqcg-5x36-vfcg` (BIT-2026-42557, High): one-click command execution from untrusted notebook HTML, fixed 4.5.7; CVE-2026-42266 (extension-manager bypass) also fixed 4.5.7; CVE-2026-102831 (pasted-cell XSS) fixed 4.5.11.
- nbconvert CVE-2026-114140 (`GHSA-pjvx-prjx-h659`, High): arbitrary file write via path traversal in cell output filenames, fixed 7.17.2.
- tornado CVE-2026-82397 (High): urlencoded body omits `max_num_fields`, so one unauthenticated request stalls the event loop, fixed 6.5.8; CVE-2026-35536 cookie injection fixed 6.5.5.
- mistune XSS in TOC/Figure directives fixed 3.2.1, quadratic parse fixed 3.3.0; bleach URI-scheme bypass fixed 6.4.0.
**Impact:** with one bearer token as the only auth, an XSS is account takeover; an unauthenticated large form POST is a remote DoS of the only management plane. **Fix:** upgrade the suite together, track OSV in the release manifest. **Ref:** OSV.dev; GHSA-rch3-82jr-f9w9, GHSA-mqcg-5x36-vfcg, CVE-2026-42266, CVE-2026-102831, CVE-2026-114140, CVE-2026-82397.

### JUP-07 — High — Vulnerable ML runtimes: Keras, Pillow, certifi, urllib3
Kernel is `/usr/bin/python3` (system packages). OSV by exact version: **Keras 3.10.0** → 3.15.1, 30 advisories: `safe_mode` bypass/Lambda RCE (GHSA-5gwj-m78q-7pq3 fixed 3.12.3; GHSA-36fq-jgmw-4r9c fixed 3.11.0), HDF5 file disclosure, archive path traversal; `load_model` reports `safe_mode=True` but 3.10.0 is in the affected range of the bypasses. **Pillow 10.2.0** → 13.0.0, 78 advisories, five Critical heap overflows / Ghostscript argument injection (CVE-2026-112900, -112403, -112393, -112398), fixed 13.0.0. **certifi (venv) 2026.2.25** → 2026.10.23: Critical, bundles emSign roots with compromised intermediate keys (GHSA-6q48-6c7w-9gw2), fixed 2026.10.18. **urllib3 (venv) 2.6.3** → 2.8.0, 10 advisories (four High: proxy TLS ignored, decompression bomb, header forwarding, unbounded buffering), fixed 2.8.0. **torch 2.7.0** → 2.15.0, 15 Low/Moderate memory-corruption advisories, no High; `torch.load` is `weights_only=None`, which PyTorch 2.6+ resolves to `True` (`serialization.py`: "we changed the default … to `True`") — good, but `weights_only=False` is one argument away. **TensorFlow 2.19.0 / JAX 0.6.0 / numpy 1.26.4 / pandas 2.1.4**: 0 OSV entries. `safetensors`, `modelscan` and `transformers` are not installed.
**Impact:** untrusted checkpoints/images are routine; these versions execute code or corrupt memory; the compromised CA allows impersonation of PyPI/HF. **Fix:** patched wheels, safetensors/modelscan defaults, `weights_only=True`. **Ref:** OSV.dev; CVE-2025-1550 family; CVE-2026-112900.

### JUP-08 — High — No HTTPS enforcement, no HSTS, weak cookie flags
`curl http://…/login` → `200` (cleartext form); `curl http://…/` → `302 http://…/lab` (stays on HTTP); `curl -D - https://…/login | grep -ci strict-transport-security` → `0`.
`Set-Cookie: _xsrf=…; Path=/` — no `Secure`, `SameSite`, `HttpOnly` (JS needs it). The session cookie is `HttpOnly` but not `Secure`/`SameSite`: in `jupyter_server/auth/identity.py` `secure` is set only when `handler.request.protocol == "https"`, and behind cloudflared the origin request is HTTP with `trust_xheaders=False`. TLS 1.0/1.1 are refused, 1.2/1.3 work. **Impact:** a user who omits the scheme sends the token and then the session cookie in the clear; no HSTS prevents the downgrade; no `SameSite`. **Fix:** Cloudflare "Always Use HTTPS" + HSTS, `cookie_options` with `secure`/`samesite`. **Ref:** CWE-319/CWE-614.

### JUP-09 — Medium — Unsandboxed unit, restart loop, bogus PIDFile
`systemd-analyze security lambda-jupyter | tail -2` → `9.2 UNSAFE :-{`; same for `cloudflared` → `9.6 UNSAFE :-{`. Unit sets only `User`, `Group`, `WorkingDirectory`, `PATH`, `Restart=always`, `RestartSec=10`, and a `PIDFile` Jupyter never writes (wrong for `Type=simple`).
**Impact:** a Jupyter compromise gets the full home, `/tmp`, network and env with no containment; `Restart=always` restores an attacker's foothold after a kill. **Fix:** `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=tmpfs` with a bind mount, `PrivateTmp`, syscall/address-family filters, `UMask=0077`. **Ref:** `systemd.exec(5)`; CWE-250.

### JUP-10 — Medium — Host-header validation is disabled
`curl -H 'Host: evil.example' http://127.0.0.1:7000/api` → `200`; same for `127.0.0.1:7000` and the tunnel name. `allow_remote_access=True` disables the local-Host check; `local_hostnames` would have allowed the tunnel name without it. `trust_xheaders=False` and no CORS wildcard are correct. **Impact:** DNS rebinding from a browser on the host, or an SSRF that sets Host, reaches the loopback port; a stolen cookie then crosses the loopback boundary. **Fix:** `allow_remote_access=False` with the tunnel hostname in `local_hostnames`. **Ref:** CWE-350.

### JUP-11 — Medium — No login throttling or lockout
`curl -d "_xsrf=$X&password=wrong" http://127.0.0.1:7000/login` → `HTTP/1.1 401 Unauthorized`, no `Retry-After`, no lockout; one attempt only. `jupyter_server/auth/login.py` has no attempt counter, delay or backoff, and ten rapid `GET /login` returned 200. The 128-bit token makes online guessing infeasible (2^128), so this is defence-in-depth, not the main risk — a weak user password would change that (none can be set). **Impact:** unlimited, unlogged guessing; no alerting on failed logins. **Fix:** edge and app rate limits, 401 alerting, MFA via an identity proxy. **Ref:** CWE-307.

### JUP-12 — Medium — System Python is writable by pip, with open egress
`cat /etc/pip.conf` → `[global] break-system-packages = true`; `pip --version` → `24.0`; `curl https://pypi.org/simple/` → `200`; `curl http://example.com/` → `200`; `python3 -c 'import modelscan'` → `ModuleNotFoundError`. No hash-checking, constraints, `pip-audit` or egress filter. The kernel is `/usr/bin/python3`, and `~/.local/lib/python3.12/site-packages` precedes dist-packages, so a notebook can shadow `torch`/`keras`. **Impact:** dependency confusion or a malicious install replaces the ML stack (with sudo reachable); open HTTP/HTTPS egress is the exfiltration channel. **Fix:** locked venv with hashes, `require-hashes`, `pip-audit`, egress policy, `break-system-packages` off. **Ref:** CWE-494/CWE-1104.

### JUP-13 — Medium — Version disclosure, open redirect, no Referrer-Policy
`curl https://…/api` → `{"version": "2.17.0"}`; `curl 'https://…/lab?token=FAKE'` → `302 https://…/login?next=%2Flab%3Ftoken%3DFAKE`; `grep -ci referrer-policy` → `0`. Origin answers `Server: TornadoServer/6.5.4` (Cloudflare masks it externally). `next` is attacker-controlled and 2.17.0 is in the affected range of CVE-2025-61669 (open redirect, fixed 2.18.0); the token-bearing `next` is reflected into the login page. **Impact:** exact-version fingerprinting selects the CVE set; the redirect supports phishing; no `Referrer-Policy` for token-bearing URLs. **Fix:** 2.21.1, `Referrer-Policy: no-referrer`, drop the `/api` version. **Ref:** CVE-2025-61669; CWE-200/CWE-601.

### JUP-14 — Medium — Root-run Glances and metrics API on localhost
`ss -ltnp | grep -E '20241|61209'` → `20241 cloudflared(2692)`, `61209 glances(1635)`; `ps -o user,args -p 1635` → `root … /usr/bin/glances -s -B 127.0.0.1`; `curl http://127.0.0.1:61209/` → `501`; `curl http://127.0.0.1:20241/metrics` → `200` (build_info `version="2026.2.0"`). Glances runs as root with no auth and writes `/home/ubuntu/.local/share/glances/glances.log` (0664 in a user-owned dir); its HTTP paths returned 501 in this mode, so the data surface is limited. Cloudflared's metrics port is also unauthenticated; the Docker socket is 660 `root:docker` and `ubuntu` is not in it. **Impact:** a notebook can enumerate metrics the root service exposes; a root daemon logging into a user-writable directory is a latent symlink hazard. **Fix:** remove Glances or use a root-only socket with auth; move logs to `/var/log`; root-only metrics. **Ref:** CWE-306/CWE-732.

### JUP-15 — Low — Local secret artefacts and writable kernel spec
`stat -c '%a %n'` → config `644` (home 750), `runtime/jpserver-2713-open.html` `644` in a `700` dir with 2 token URLs, `kernels/python3/kernel.json` `664` (writable), `file_id_manager.db` `644`; `jupyter server list` prints the live token by design. Other local users cannot reach these (home 0750, runtime 0700); the exposure is backups, snapshots, support bundles and the file browser itself. **Impact:** the token lands in any home-directory backup or image; the writable kernel spec is a persistence point after a compromise (same user). **Fix:** 0600 config and `open.html`, root-own the kernel spec, exclude `.jupyter` from backups. **Ref:** CWE-732/CWE-312.

### JUP-16 — Low — GPU device nodes are world-writable
`ls -l /dev/nvidia*` → `crw-rw-rw-` on `nvidia0`, `nvidiactl`, `nvidia-uvm`, `nvidia-modeset`; `nvidia-cap1` is 0400; `nvidia-smi` reports an A100-SXM4-40GB on driver 580.105.08. **Impact:** any local account or container can allocate GPU memory, read left-over memory and disturb jobs; with one account the practical impact is low. **Fix:** restrict nodes to a `video`/GPU group (Secure GPU Stack round G), keep container device injection explicit. **Ref:** CWE-732.

### JUP-17 — Low — No idle shutdown or kernel culling
`shutdown_no_activity_timeout=0`, culling defaults 0, `max_body_size=512 MB`, `Restart=always`. **Impact:** idle kernels and large uploads hold GPU/RAM indefinitely; only a reboot or manual kill clears them; adds to the DoS surface. **Fix:** set shutdown/cull timeouts and a smaller body limit. **Ref:** CWE-400.

## Version / CVE baseline (OSV, by exact version, 2026-10-30)
`jupyter --version`: IPython 9.10.0, ipykernel 7.2.0, jupyter_client 8.8.0, jupyter_core 5.9.1, jupyter_server 2.17.0, jupyterlab 4.5.5, nbclient 0.10.4, nbconvert 7.17.0, nbformat 5.10.4, notebook 7.5.4, traitlets 5.14.3. The kernel is `/usr/bin/python3`: ipykernel 6.29.3, jupyter_client 7.4.9, tornado 6.4, pyzmq 24.0.1, plus the system ML packages above.

Remaining venv packages (OSV count only where non-zero): anyio 4.12.1, argon2-cffi 25.1.0, argon2-cffi-bindings 25.1.0, arrow 1.4.0, asttokens 3.0.1, async-lru 2.2.0, attrs 25.4.0, babel 2.18.0, beautifulsoup4 4.14.3, bleach 6.3.0 (3), certifi 2026.2.25 (2), cffi 2.0.0, charset-normalizer 3.4.4, comm 0.2.3, debugpy 1.8.20, decorator 5.2.1, defusedxml 0.7.1, executing 2.2.1, fastjsonschema 2.21.2, fqdn 1.5.1, h11 0.16.0, httpcore 1.0.9, httpx 0.28.1, idna 3.11, ipython_pygments_lexers 1.1.1, isoduration 20.11.0, jedi 0.19.2, Jinja2 3.1.6, json5 0.13.0, jsonpointer 3.0.0, jsonschema 4.26.0, jsonschema-specifications 2025.9.1, jupyter-collaboration 4.2.1, jupyter-collaboration-ui 2.2.1, jupyter-docprovider 2.2.1, jupyter-events 0.12.0, jupyter-lsp 2.3.0, jupyter_server_fileid 0.9.3, jupyter_server_terminals 0.5.4, jupyter-server-ydoc 2.2.1, jupyter-ydoc 3.4.0, jupyterlab_pygments 0.3.0, jupyterlab_server 2.28.0, lark 1.3.1, MarkupSafe 3.0.3, matplotlib-inline 0.2.1, mistune 3.2.0 (33), nest-asyncio 1.6.0, notebook_shim 0.2.4, packaging 26.0, pandocfilters 1.5.1, parso 0.8.6, pexpect 4.9.0, pip 26.2.2, platformdirs 4.9.2, prometheus_client 0.24.1, prompt_toolkit 3.0.52, psutil 7.2.2, ptyprocess 0.7.0, pure_eval 0.2.3, pycparser 3.0, pycrdt 0.12.46, pycrdt-store 0.1.3, pycrdt-websocket 0.16.0, Pygments 2.19.2, python-dateutil 2.9.0.post0, python-json-logger 4.0.0, PyYAML 6.0.3, pyzmq 27.1.0, referencing 0.37.0, requests 2.32.5 (2), rfc3339-validator 0.1.4, rfc3986-validator 0.1.1, rfc3987-syntax 1.1.0, rpds-py 0.30.0, Send2Trash 2.1.0, setuptools 82.0.0, six 1.17.0, soupsieve 2.8.3, sqlite-anyio 0.2.5, stack-data 0.6.3, terminado 0.18.1, tinycss2 1.4.0, typing_extensions 4.15.0, tzdata 2025.3, uri-template 1.3.0, urllib3 2.6.3 (10), wcwidth 0.6.0, webcolors 25.10.0, webencodings 0.5.1, websocket-client 1.9.0.

## Checked and not a finding
- **Token not in the journal.** Startup logs `…/lab?token=...` with a literal ellipsis, because `serverapp.py` substitutes `"..."` when `token_generated == False`; `t in journal` → `False`, and a fake token in `Referer` was logged as `token=[secret]`. This corrects the earlier note that the token is printed. Residual: CVE-2026-86049 (5xx) on 2.17.0.
- **No token in cloudflared logs** (one 32-hex string = tunnel ID).
- **All data APIs need auth:** `/api/contents`, `/api/kernels`, `/api/sessions`, `/api/terminals`, `/api/status`, `/metrics`, `/lab/api/workspaces` → 403; only `/api` is 200 (version only).
- **WebSocket auth:** upgrade to `/api/kernels/abc/channels` without a cookie → 404, not 101. **Traversal:** `..`, `..%2f`, `%2e%2e` forms → 404.
- **No CORS wildcard:** `OPTIONS` with `Origin: https://evil.example` returns no `Access-Control-Allow-Origin`; `allow_origin`/`pat` unset.
- **CSRF:** `disable_check_xsrf=False`; a POST without `_xsrf` is rejected.
- **`allow_root=False`**, `open_browser=False`, `base_url=/`, `trust_xheaders=False`.
- **No trusted notebooks:** no `nbsignatures.db`; no IPython startup files, no user `sitecustomize.py`/`.pth`, no `JUPYTER_PATH`/`JUPYTER_CONFIG_DIR`, no `/etc/jupyter` or `/usr/local/etc/jupyter` overrides.
- **Cloud metadata:** cloud-init uses `DataSourceNoCloud` from `/dev/vdb`; `169.254.169.254` returns 404 for IMDSv1/v2 paths, so the token is not exposed there. Vendor-data is 0600 root.
- **Token strength:** 32 hex = 128 bits, 14 distinct symbols, not derived from tunnel/instance/hostname (hashes tested); generation cannot be proven from one sample.
- **TLS:** 1.0/1.1 refused, 1.2/1.3 negotiated (tested from the instance; the macOS curl result was a local build artefact).
- **`X-Frame-Options`** absent but `CSP frame-ancestors 'self'` present — equivalent; not a finding.
- **Docker:** socket 660 `root:docker`; `ubuntu` groups are `users`, `admin`. **`nvidia-cap1`** 0400; only the main nodes are 0666 (JUP-16).
- **No password auth:** `ServerApp.password` empty; no `jupyter_server_config.json`; login page says "Token authentication is enabled".
- **RTC:** `LabApp.collaborative=False`, `YDocExtension.disable_rtc=True`; the collaboration extensions are installed but the real-time path is off.
- **`jupyter-troubleshoot`/`jupyter-migrate`** exist and print config/versions only; no secret output observed.

## References
- OSV.dev API, exact-version PyPI queries, 2026-10-30 (advisory IDs above).
- Jupyter Server docs: `allow_remote_access`, `local_hostnames`, `trust_xheaders`, `disable_check_xsrf`, cookie options.
- PyTorch 2.6 note: `torch.load` defaults to `weights_only=True`.
- Keras 3 `load_model(safe_mode=True)` docs and the bypass advisories above.
- Cloudflare Tunnel credentials and Access (Zero Trust) docs.
- `systemd.exec(5)` and `systemd-analyze security`.
