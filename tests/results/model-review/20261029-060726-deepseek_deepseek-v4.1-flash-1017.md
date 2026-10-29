# deepseek/deepseek-v4.1-flash-1017

## Findings (ranked)

### 1. `sgs-check` reports "JupyterLab isn't running" for Jupyter it cannot recognise — false PASS, and every later check is skipped
**Severity: high.** `sgs-check-jupyter-block.sh:3-6` builds `jup_pids` from `ss -tlpnH | grep -i jupyter` plus `systemctl … 'sgs-jupyter@*'`. But `ss -p` prints the kernel `comm` (≤15 chars), so `python -m jupyterlab` / `python3 /opt/sgs/venv/bin/jupyter-lab` shows up as `python3` and never matches; and a Jupyter listening **only on a Unix socket** produces no `ss -tln` line at all. The header comment at `:1-2` claims exactly this case is covered, and it isn't.
*Scenario:* user runs `jupyter lab --ServerApp.sock=$HOME/j.sock --ServerApp.token= --ServerApp.allow_unauthenticated_access=True`. `jup_pids` is empty → line 9 skipped → line 15 prints `note "JupyterLab isn't running"` → lines 27-71 (token requirement, `NoNewPrivs`, token-file mode) never execute. Audit says clean; a token-less server is listening.
*Fix:* also collect PIDs from `ss -xlpnH` and from `/proc/*/cmdline` (`grep -l jupyter`); and make line 15 `bad` (not `note`) when a jupyter-ish process exists without a discovered socket.

### 2. The login token is written to the system journal, contradicting the design and the audit's own claim
**Severity: high (unverified whether jupyter_server logs a `JUPYTER_TOKEN`-supplied token; the code asserts it does).** `sgs-jupyter@.service:21-26` says in so many words that the token "shows up [in the journal] as token=…". The whole point of the token file was to avoid that; anyone in `adm`/`systemd-journal` (on Lambda, the default `ubuntu` user) then gets code execution as the Jupyter user via the tunnel. Meanwhile `sgs-check-jupyter-block.sh:62-66` greps the journal for exactly that and will either print `bad` on every correctly-installed machine (alert fatigue → the check gets ignored) or, if the comment is wrong, the `ok "token stays out of the system journal"` line is meaningless.
*Scenario:* second account in `adm` reads `journalctl -u sgs-jupyter@alice`, extracts `?token=…`, tunnels to `/run/sgs-jupyter/alice/jupyter.sock` — is it allowed to open a 0600 socket? No, but it can ask alice's own unprivileged process… i.e. the practical risk is the token leaking into ticket pastes/support bundles and any root/adm reader. Main defect: the audit's `ok` text is false by construction.
*Fix:* suppress the startup-URL log (`--ServerApp.log_level=WARN`), or accept rotation per start; and make the audit's message match the actual behaviour.

### 3. Both tests demand an unauthenticated HTTP 200 — i.e. they only pass on the *insecure* configuration
**Severity: medium.** `tests/user-checks.sh:54-55` and `tests/attack-demo.sh:43-45` curl `/api` with no token and `pass` on `200`. Your own verification on krabs says the socket returns **403 without a token**, so a correct stack fails both tests. The obvious way for a user to make them green is `--ServerApp.allow_unauthenticated_access=True` / dropping the token — precisely the regression the tests exist to catch.
*Scenario:* engineer runs `bash -l tests/user-checks.sh`, sees `[FAIL] JupyterLab not answering on …/jupyter.sock (HTTP 403)`, edits the unit to allow unauthenticated access.
*Fix:* assert `403` for the bare request, then re-request with `-H "Authorization: token $(cat ~/.local/share/jupyter/sgs-token)"` and assert `200`.

### 4. Nothing verifies that stream-local forwarding is enabled — the only access path can be dead while `sgs-check` passes
**Severity: medium.** The `sgs-check` block only inspects listening sockets; it never looks at `sshd -T`. Ubuntu images with `DisableForwarding yes` (or `AllowStreamLocalForwarding no`) in `sshd_config`/`sshd_config.d` reject `-L …:/run/sgs-jupyter/…` with "administratively prohibited". The only place this is exercised is the optional `tests/attack-demo.sh:40-45`, which prints a bare FAIL.
*Scenario:* hardened base image sets `DisableForwarding yes`; `sgs-check` reports PASS, Jupyter is unreachable for every user, and the user's workaround is to re-add a TCP port.
*Fix:* add `sshd -T | awk '$1=="allowstreamlocalforwarding"{print $2}'` (and `disableforwarding`) to the audit as a hard requirement, and set it explicitly in the installer's sshd drop-in.

### 5. Windows OpenSSH clients cannot do `-L port:/unix/socket`
**Severity: medium (unverified — depends on the Win32-OpenSSH build; AF_UNIX `-L` targets have historically been unsupported).** `bin/sgs-jupyter:33` prints the only supported command as `ssh -N -L 8888:/run/sgs-jupyter/…/jupyter.sock`. On a Windows laptop that fails; the user has no documented alternative and will ask for the port back.
*Fix:* document a fallback (WSL `ssh`, or `socat`/`npiperelay`, or VS Code's `LocalForward` in `~/.ssh/config` from WSL) and mention it in the `sgs-jupyter` banner.

### 6. The "VS Code and other Jupyter clients connect to the same URL through the tunnel" claim is wrong, and the Lambda dashboard link is dead
**Severity: medium.** `bin/sgs-jupyter:38` (and the unit header `sgs-jupyter@.service:1-8`). With Remote-SSH, VS Code's Jupyter extension runs *on the server* and resolves `localhost:8888` there — nothing listens. The Lambda Cloud dashboard's Jupyter button is hard-coded to `http://<public-ip>:8888/lab?token=…`, which is now refused (`tests/attack-demo.sh:37` asserts exactly that).
*Scenario:* user opens the instance from the Lambda console → connection refused; opens VS Code Remote-SSH → "cannot connect to Jupyter server"; concludes the stack is broken and re-adds `--ServerApp.port=8888`.
*Fix:* state explicitly that the tunnel must be established on the laptop *before* connecting, that the dashboard link no longer applies, and give the Remote-SSH recipe (`LocalForward 8888 …` via WSL/desktop ssh config) or a plain "open the tunnel, then use http://localhost:8888 in the local browser".

### 7. Only the alphabetically-first socket is auth-tested
**Severity: low-medium.** `sgs-check-jupyter-block.sh:31` uses `--unix-socket "$(echo "$jup_sock" | head -1)"`, while `:23` loops over all sockets for the permission check. A second, insecure Jupyter for the same user (e.g. `jupyter lab --ServerApp.sock=/tmp/j2.sock --ServerApp.token=''`, 0777) is never probed for the token requirement, and line 24 still prints the single `ok` line.
*Scenario:* a stale unprotected instance in `/tmp` stays reachable by any local account while the audit says "JupyterLab refuses requests without its token".
*Fix:* loop over `$jup_sock` and require 401/403 from every socket (or `bad` on the first one that answers).

### 8. `ss -xlpnH | awk '{print $5}'` breaks on socket paths containing spaces → false `ok` on an open socket
**Severity: low.** `sgs-check-jupyter-block.sh:8` takes the path from a whitespace-delimited field, so `/tmp/my sock/j.sock` becomes `/tmp/my`; `find "/tmp/my" -perm /077` (line 23) finds nothing, `open_sock` stays empty, and line 24 prints `ok "…a socket its user alone can open"` for a 0777 socket. (Line 31's curl then fails on the same truncated path and emits a misleading `bad`, so the block contradicts itself rather than failing cleanly.)
*Fix:* read paths from `/proc/net/unix` + the socket inode (or `lsof -U -F n`), and treat "path could not be stat'ed" as `bad`, not `ok`.

### 9. `sgs-jupyter` picks the wrong address and prints the token to stdout
**Severity: low.** `bin/sgs-jupyter:21` uses `hostname -I | awk '{print $1}'`; on a machine running Docker that is frequently `172.17.0.1` (docker0), so the printed `ssh` command targets an address that doesn't exist from the user's laptop. `:24` echoes the token into the terminal — scrollback, `tmux` capture, `script`/CI logs, and the user's shell session, which is the same exposure the token file was meant to avoid.
*Fix:* derive the address the way `tests/user-checks.sh:59` does (`ip -4 route get 1.1.1.1`), and print the URL without `?token=` plus a hint to paste it from the file.

### 10. `user-checks.sh` passes the network-exposure check vacuously when the address is unknown
**Severity: low.** `tests/user-checks.sh:59-61`: if `ip -4 route get 1.1.1.1` yields nothing (no default route, e.g. in some VPC setups), `addr` is empty, `curl "http://:8888/api"` returns `000`, and the script prints `[PASS] JupyterLab doesn't answer on the network address ()`. The machine's real external reachability is never tested.
*Fix:* if `addr` is empty, print `[FAIL]/[SKIP]` rather than PASS.
