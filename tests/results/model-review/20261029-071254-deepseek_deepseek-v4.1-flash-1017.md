# deepseek/deepseek-v4.1-flash-1017

## Findings (most severe first)

### 1. Medium — `sgs-check` runs as root, daily, unsandboxed, with network and GPU access
`sgs-check.service:9-15` has no `User=`, no `ProtectSystem`/`ProtectHome`/`PrivateTmp`/`NoNewPrivileges`/`RestrictAddressFamilies`, and `ExecStart` runs `/usr/local/bin/sgs-check` as uid 0. The check is described as doing `pip-audit` (network) and GPU probing.
**Scenario:** a malicious package name/metadata on PyPI, a crafted container image config, or a crafted file path that `sgs-check` parses triggers a parsing bug → root code execution on a machine rented by an ML engineer. `Nice=10`/`IOSchedulingClass=idle` do not limit this. On a training machine, a GPU probe inside `sgs-check` can also allocate/reset the GPU mid-job.
**Fix:** run as a dedicated unprivileged user (with read access to what it needs), add `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp=yes`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, and drop GPU access unless a check truly needs it.

### 2. Medium — login message prints unsanitized WARN/FAIL text to every user (terminal escape injection)
`motd-60-sgs:17` pipes `grep -E '^ *\[(WARN|FAIL)\]'` through `cut -c1-110` and `sed 's/^ */   /'` — none of which strip control characters. WARN text can contain attacker-influenced strings (package names from `pip-audit`, file paths, container names, usernames).
**Scenario:** a user installs a package whose name contains `\x1b]52;c;...\x07` (OSC 52 clipboard) or `\x1b[2J\x1b[H` plus a fake "sudo password:" prompt. Every other user who logs in sees the injected sequence in their terminal; OSC 52 can plant clipboard contents, and cursor/title spoofing enables phishing.
**Fix:** sanitize before display, e.g. `sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g'` (or `tr -d '\000-\010\013\014\016-\037\177'`), and have `sgs-check` escape control characters in its own output.

### 3. Medium — `net.ipv4.conf.all.send_redirects=0` is a no-op for existing interfaces; eth0 still sends ICMP redirects
`sysctl-60-sgs.conf:47` sets `all.send_redirects=0`, but the kernel's `IN_DEV_SEND_REDIRECTS` reads only the per-device value; `all` is not a master switch for `send_redirects`. `default.send_redirects=0` (line 48) only applies to interfaces created *after* `systemd-sysctl` runs. On a normal cloud VM `eth0` exists at boot, so it keeps `send_redirects=1`.
**Scenario:** the comment at lines 40-42 claims "this one doesn't tell others to [reroute]"; in fact eth0 will still emit ICMP redirects to hosts on the same L2 segment, contrary to the stated posture. (The IPv4 `all.accept_redirects=0` at line 43 *is* ANDed and does work; the IPv6 `all.accept_redirects=0` at line 45 is likely also a no-op for existing interfaces — **unverified** on 6.8 — since `ndisc_redirect_rcv` consults only `idev->cnf.accept_redirects`.)
**Fix:** set per-interface values (loop over `/proc/sys/net/ipv4/conf/*/send_redirects` and `/proc/sys/net/ipv6/conf/*/accept_redirects` in a unit that runs after networking), or verify the effective per-interface values in `sgs-check`.

*No issue found* for Docker bridge, Tailscale, or Lambda cloud networking being broken by the redirect settings: `accept_redirects=0` on `all` is ANDed and does not affect container netns or the Tailscale TUN device.

### 4. Medium — no `TimeoutStartSec`; a slow `sgs-check` is killed at 90 s and leaves a stale `last-check` silently
`sgs-check.service:14` runs `sgs-check` (which does `pip-audit` network calls) with no `TimeoutStartSec=`. systemd's default `DefaultTimeoutStartSec=90s` applies to `Type=oneshot`, so a slow/hanging PyPI/OSV request kills the whole cgroup before the `mv` runs.
**Scenario:** on a machine with slow egress, `sgs-check` exceeds 90 s; systemd kills it, `/var/lib/sgs/last-check` is never updated, and the login message keeps showing the old result (eventually the ">3 days old" warning). The daily check silently stops reflecting reality.
**Fix:** set an explicit `TimeoutStartSec=` (e.g. `300`) and give `pip-audit` its own internal timeout; alternatively run the network part as a separate, bounded unit.

### 5. Medium — `60-sgs.conf` can be overridden by any later-sorting sysctl file; the "can't quietly loosen" claim is false
`sysctl-60-sgs.conf:1-3` claims pinning prevents a package or tuning guide from loosening the settings. But `systemd-sysctl` applies `/etc/sysctl.d/*.conf` in lexical order, so a package shipping `99-*.conf` (or an admin's `90-*.conf`) that sets `kernel.kptr_restrict=0`, `kernel.io_uring_disabled=0`, etc. wins at every boot. The installer's raise-only loop only runs at install time and is undone by `systemd-sysctl` at boot.
**Scenario:** installing a package that drops `99-perf.conf` with `kernel.kptr_restrict=0` and `kernel.io_uring_disabled=0` silently loosens the stack; `sgs-check` only notices on its next daily run.
**Fix:** install as `99-sgs.conf` (or higher), or add a `systemd-sysctl` drop-in/unit ordered after other sysctl files that re-applies the strict values, and have `sgs-check` verify the *effective* runtime values.

### 6. Medium — GPU memory test cannot prove the driver zeroes memory; a real cross-tenant leak would be invisible
`tests/gpu-memory-test.py:22,28-34`: the `write` process allocates, fills, and exits; the `read` process then calls `cuMemAlloc` and copies back. `cuMemAlloc` gives no guarantee of returning the same physical pages, and the driver may zero on free, on alloc, or not at all. A "marker found 0 times" result therefore cannot distinguish "driver zeroed" from "different pages were handed out".
**Scenario:** on a driver that does *not* zero but also does not immediately reuse the freed block, the test reports clean; two Lambda tenants sharing the GPU could then read each other's model/data, and the stack's assurance is false.
**Fix:** force reuse in one process (alloc → write marker → free → alloc again, or loop until the same device pointer is returned) and/or use `cudaMallocAsync` with a pool; document that the test only detects leaks when pages are reused. Mark the current "driver cleared it" conclusion as unverified.

### 7. Low — `last-check` is world-readable, exposing the full posture report to every local user
`sgs-check.service:14` does `chmod 0644 /var/lib/sgs/last-check.new`. The motd only shows five lines, but the whole report (paths, usernames, package versions, container/image names, possibly host details) is readable by any local user.
**Scenario:** a low-privileged user on a shared ML workstation reads `/var/lib/sgs/last-check` to enumerate weaknesses (e.g. world-writable paths, sudo group members) to target.
**Fix:** make it `0600` and have the motd (which runs as root under `update-motd`) read it; if `update-motd` runs as the user, keep `0644` but have `sgs-check` redact sensitive details from the persisted summary.

### 8. Low — motd result line can be spoofed by a multi-line WARN message
`motd-60-sgs:14` takes `tail -1` of lines matching `^== Result: `. If `sgs-check` ever emits a WARN/FAIL message containing a newline followed by `== Result: PASS` (e.g. from an attacker-influenced package name or path), the motd shows PASS while the real result is FAIL.
**Scenario:** a crafted package name containing `\n== Result: PASS` makes the login banner report PASS. **Unverified** — depends on whether `sgs-check` emits multi-line WARN text.
**Fix:** have `sgs-check` write a single machine-readable result line (e.g. `RESULT=PASS|WARN|FAIL`) and have the motd read only that, or strip newlines from WARN text.

### 9. Low — motd re-scans the whole `last-check` at every login
`motd-60-sgs:17-18` runs `grep -E`, `grep -cE`, `sed`, `cut`, `head`, `tail`, and `find` over `last-check` on every login. `grep -cE` and the `head -5` pipeline read the entire file.
**Scenario:** if `sgs-check` output grows large (e.g. `pip-audit` listing hundreds of packages), every SSH login pays the scan cost; on a busy multi-user box this is a login-latency DoS.
**Fix:** have `sgs-check` write a small fixed-size summary (result + ≤5 WARN lines) to a separate file that the motd reads, and cap the full report's size.

### 10. Low — `SuccessExitStatus=1` masks `sgs-check` internal errors
`sgs-check.service:12` treats exit 1 as success (intended for WARN). If `sgs-check` also exits 1 on an internal error (crash, unreadable file), the unit reports success and the failure is only visible as a missing/partial `last-check`.
**Scenario:** `sgs-check` crashes early, exits 1, unit is "success", motd shows "no result" but nothing flags the broken check. **Unverified** — depends on `sgs-check`'s exit-code contract.
**Fix:** reserve exit 1 strictly for WARN and use a distinct code (e.g. 2) for errors, or have the unit check that `last-check` was actually updated.
