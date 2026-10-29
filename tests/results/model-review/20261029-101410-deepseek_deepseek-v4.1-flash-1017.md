# deepseek/deepseek-v4.1-flash-1017

# Findings — Rounds V & W

Ranked most severe first. All citations are to the files provided.

---

## 1. Host-networking root containers bypass the metadata guard (high)

**Defect:** `sgs-guard.nft:13` allows any packet whose socket UID is 0, but a container run with `--network host` as root creates sockets with host UID 0, so it is not filtered.

**Scenario:** An ML engineer runs `docker run --network host --rm -it someimage` (or a malicious image does so). Inside, `curl http://169.254.169.254/latest/meta-data/iam/security-credentials/` succeeds because the socket's `skuid` is 0. The `forward` chain (`sgs-guard.nft:18`) never sees this traffic — it is locally generated. The same applies to a user process that inherits a root-created socket via `SCM_RIGHTS` or systemd socket activation (unverified whether such a path exists in the default stack).

**Fix:** Do not key the exception on `skuid` alone. Either block all output to the metadata address and give cloud-init a dedicated mark/cgroup (e.g. `meta cgroup` matching the system slice, or a `socket cgroupv2` match), or additionally reject traffic from container cgroups (e.g. `meta cgroup` containing `docker`/`kubepods`/`libpod`). At minimum, document that host-networking containers are out of scope.

---

## 2. Replacing a watched startup file with a symlink evades detection (high)

**Defect:** `sgs-check-startup.sh:12` skips any path that is a symlink (`[ ! -L "$f" ]`), and `comm -13` only reports lines present in the new output, so a file that disappears from the output is silently ignored.

**Scenario:** `~/.bashrc` is recorded as a regular file. An attacker does `mv ~/.bashrc ~/.bashrc.bak && ln -s ~/.evil ~/.bashrc`. On the next `sgs-check`, the symlink is skipped, the old hash line is only in the record (suppressed by `comm -1`), and the check reports "No cron job, shell startup file… changed". The same works for `~/.ssh/authorized_keys` (sshd follows symlinks when `StrictModes` permits).

**Fix:** For each watched path, record both the symlink target (`readlink`) and, if the target is a regular file, the hash of its content. Do not drop the path from the output when it becomes a symlink; emit a distinct line (e.g. `LINK <target> <path>`) so `comm` sees a change.

---

## 3. Shell/SSH persistence vectors not watched (high)

**Defect:** `sgs-check-startup.sh:10-11` watches only `.bashrc`, `.profile`, `.bash_profile`, `.bash_login`, `.bash_logout`, `.zshrc`, `.zprofile`, and `authorized_keys`. It omits several files that execute code as the user.

**Scenario:** An attacker adds `~/.ssh/rc` (executed by sshd on login when `PermitUserRC` is on, the default), `~/.zshenv` (sourced by every zsh invocation, including non-interactive scripts), `~/.bash_aliases` (sourced by the default `.bashrc`), `~/.config/environment.d/*.conf` (systemd user environment), `~/.config/fish/config.fish`, or a `ProxyCommand` in `~/.ssh/config`. None are recorded, so `sgs-check` reports PASS.

**Fix:** Add `~/.ssh/rc`, `~/.ssh/config`, `~/.ssh/environment`, `~/.zshenv`, `~/.zlogin`, `~/.zlogout`, `~/.bash_aliases`, `~/.inputrc`, `~/.config/environment.d/*`, `~/.config/fish/config.fish`, `~/.gitconfig`, and `~/.pam_environment` to the list.

---

## 4. PATH and Python startup persistence not watched (high)

**Defect:** `sgs-check-startup.sh:10-11` does not watch `~/.local/bin` (typically earlier in `PATH` than `/usr/bin`) or Python's user site-packages (`~/.local/lib/python3.*/site-packages/`), where `.pth` files and `sitecustomize.py` execute on every interpreter start.

**Scenario:** An attacker drops `~/.local/bin/python` (a wrapper that runs the real Python plus a payload) or `~/.local/lib/python3.12/site-packages/evil.pth` containing `import os; os.system(...)`. Every `python`/`pip` invocation by the user runs the payload. `sgs-check` reports PASS.

**Fix:** Add `~/.local/bin/*` and `~/.local/lib/python*/site-packages/*.pth` / `sitecustomize.py` to the watch list (hash file contents, not just names).

---

## 5. `sgs-check-metadata.sh` gives a false PASS for IPv6 and containers (high)

**Defect:** `sgs-check-metadata.sh:5-6` tests only IPv4 `169.254.169.254` as `nobody`, and only checks that the table exists, not that the rules are correct.

**Scenario:** The IPv6 rule (`sgs-guard.nft:14`) is missing or broken, or a host-networking root container can reach metadata (finding 1). The check still runs `curl http://169.254.169.254/` as `nobody`, gets exit 7, sees the table exists, and prints "Ordinary users and containers can't reach the cloud metadata service". The word "containers" is false.

**Fix:** Also test `curl -6 http://[fd00:ec2::254]/` and a container on host networking (e.g. `docker run --rm --network host curlimages/curl …`). Verify the actual rule content (e.g. `nft list chain inet sgs_guard output`) rather than just table existence.

---

## 6. Guard covers only two metadata addresses (medium)

**Defect:** `sgs-guard.nft:13-14` blocks only `169.254.169.254` and `fd00:ec2::254`.

**Scenario:** On Alibaba Cloud (`100.100.100.200`), Oracle (`192.0.0.192`), AWS ECS (`169.254.170.2`), or GCP over IPv6 (`fd20:ce::254`), a user or container reads credentials despite the guard. The stack targets Lambda Cloud, but the check message and docs claim "the cloud metadata service" generally.

**Fix:** Add the other well-known metadata addresses (or a configurable list) to both chains, or narrow the claim to "AWS/Lambda metadata".

---

## 7. `sgs-egress` allows UDP to any host on ports 67/123/547 (medium)

**Defect:** `sgs-egress:75` accepts `udp dport { 67, 123, 547 }` to any destination, for any user.

**Scenario:** In strict mode, a user's notebook sends UDP/123 packets with encoded data to an attacker-controlled NTP server. The firewall accepts them, so strict mode does not prevent exfiltration. The system's own NTP/DHCP clients run as root and are already covered by `meta skuid 0 accept` (`sgs-egress:73`), so the blanket rule is unnecessary.

**Fix:** Remove the blanket UDP rules, or restrict them to the specific DHCP/NTP server addresses (or to the daemon's UID).

---

## 8. `sgs-egress` forward chain misses non-Docker bridges and host networking (medium)

**Defect:** `sgs-egress:85-86` only matches `iifname "docker0"` and `iifname "br-*"`.

**Scenario:** A container on a Podman bridge (`podman0`, `cni-podman0`), a Kubernetes CNI bridge (`cni0`, `flannel.1`, `cali*`), or a libvirt bridge (`virbr0`) is not matched, so it can open new outbound connections in strict mode. A host-networking container is output traffic with `skuid 0` and is accepted at `sgs-egress:73`.

**Fix:** Match on the container's cgroup (e.g. `meta cgroup` containing `docker`/`libpod`/`kubepods`) rather than interface names, or add the other common bridge prefixes.

---

## 9. `sgs-egress` records "strict" before applying the rules (medium)

**Defect:** `sgs-egress:105` writes `strict` to `$STATE` before `apply()` runs. If `apply()` fails (dnsmasq missing, `nft` error, resolved restart failure), the state file claims strict while no rules are loaded.

**Scenario:** `sudo sgs-egress strict` fails at `nft -f` (e.g. a syntax error from a bad allow-list entry). The script exits non-zero, but `$STATE` says `strict`. `sgs-egress status` prints "Strict mode: on" (with a warning), and on reboot `boot` retries. During the window, traffic is unfiltered while the state claims otherwise.

**Fix:** Write `$STATE` only after `apply()` succeeds, or use a separate `pending` state and have `status`/`boot` treat it as not-strict.

---

## 10. `at` jobs are not watched (medium)

**Defect:** `sgs-check-startup.sh:5` watches `/etc/crontab`, `/etc/cron.d/*`, `/var/spool/cron/crontabs/*`, and linger, but not `/var/spool/cron/atjobs/*`.

**Scenario:** A user schedules `echo 'curl … | sh' | at now + 1 minute`. The job runs as the user, but `sgs-check` reports no change.

**Fix:** Add `/var/spool/cron/atjobs/*` (and `/var/spool/cron/atspool/*`) to the watch list.

---

## 11. `$ACCEPT` is unbound under `set -u` (medium, unverified)

**Defect:** `sgs-check-startup.sh:20` uses `[ "$ACCEPT" = 1 ]` without a default. If the parent `sgs-check` runs with `set -u` and `ACCEPT` is not initialized, the script aborts.

**Scenario:** `sgs-check` is invoked normally (no `--accept-changes`); `ACCEPT` is unset; `set -u` is active; the startup check exits with "ACCEPT: unbound variable" instead of reporting PASS/FAIL. Whether the parent uses `set -u` is unverified.

**Fix:** Use `[ "${ACCEPT:-}" = 1 ]`.

---

## 12. Symlink hash covers only the target path, not its content (low)

**Defect:** `sgs-check-startup.sh:15` hashes `readlink "$f"` for symlinks in `~/.config/systemd/user` and `~/.config/autostart`. If the target file's content changes, the hash does not change.

**Scenario:** A user creates `~/.config/systemd/user/evil.service` as a symlink to `~/.evil.service`. The symlink is recorded (hash of the target path). The attacker later edits `~/.evil.service` to add a malicious `ExecStart=`. `sgs-check` sees no change.

**Fix:** If the symlink target is a regular file, hash its content as well (or instead), and record both the target path and the content hash.
