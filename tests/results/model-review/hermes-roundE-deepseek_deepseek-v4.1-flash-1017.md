Findings, most severe first. File:line refers to the listing above.

1. bin/sgs-check:588, 596-613 — medium
Defect: Jupyter is located by grepping ss's process field for "jupyter" (the kernel comm name), but the normal launch (`/opt/sgs/venv/bin/jupyter-lab` or `python -m jupyterlab`) is a shebang script, so comm is "python3" and the grep matches nothing.
Scenario: sgs-jupyter starts jupyterlab with its token disabled (or the unit loses NoNewPrivileges in a later edit) -> `jup` is empty -> line 590 prints the harmless note "JupyterLab isn't running"; the localhost-only check (591), the no-token probe (599-603) and the sudo/NoNewPrivs check (606-613) never run, and the audit can end with 0 WARN while any local user or host-network container can drive an unauthenticated Jupyter on 127.0.0.1. (Unverified only in that the unit file isn't shown; any launch through a Python console script has this comm.)
Fix: derive the pid/port from `systemctl show -p MainPID sgs-jupyter@*` (then read /proc/$pid/cmdline and /proc/$pid/net or the listening socket), not from the ss comm field.

2. bin/sgs-check:268-277, 562 — medium
Defect: the daemon.json audit reads only ip, default-network-opts, no-new-privileges and default-runtime; Docker's `hosts` key and docker.service drop-ins are never inspected, and the listening check filters every 127.* socket (562).
Scenario: an existing /etc/docker/daemon.json (preserved by install.sh:425) contains `"hosts": ["unix:///var/run/docker.sock","tcp://127.0.0.1:2375"]` — the unauthenticated Docker API is now reachable by every local user and every `--network host` container, which is root; sgs-check still prints "Only SSH listens on the network" and "Published container ports stay on localhost" as PASS.
Fix: parse `hosts` from daemon.json and `ExecStart` from /etc/systemd/system/docker.service.d/*.conf, and WARN on any `tcp://` listener that isn't TLS-authenticated.

3. install.sh:94-99 vs install.sh:231, 420, 508, 515, 521-522 — medium
Defect: preflight's file list omits files the installer later requires (files/docker-daemon.json, files/sshd-10-sgs.conf, files/profile-sgs.sh, files/sgs-jupyter@.service, files/motd-60-sgs), so a broken release passes the preflight.
Scenario: release unpacked without files/docker-daemon.json -> apt sources are rewritten, SSH/ufw/auditd configured, driver and CUDA installed, docker-ce's postinst starts dockerd with the default daemon.json (ports on 0.0.0.0, ufw doesn't cover it), then line 420/421 dies with the misleading "daemon.json isn't valid JSON"; install_commands never runs, so the machine has no sgs-check to notice any of it.
Fix: add every file read by a later step to the preflight loop, or copy them to $SGS_PREFIX in preflight and read from there.

4. install.sh:303-313 — medium
Defect: the whole while loop's stdout is redirected to /etc/sysctl.d/60-sgs.conf, so the failure branch at 312 (`... || info "Couldn't set ..."`) writes the human message into the config file instead of the terminal.
Scenario: kernel without YAMA or a read-only /proc/sys -> the file gets a line "    Couldn't set kernel.yama.ptrace_scope to 1" (no "="), the setting is silently not applied, and systemd-sysctl logs a parse error on every boot.
Fix: emit that message to stderr/tty (`info ... >&2`) so it cannot land in the redirected file.

5. bin/sgs-check:172-181 — medium
Defect: the pin check only flags Pin-Priority >= 1000 (downgrades) or < 500 when the target names Ubuntu; a 500-999 pin on any other origin outranks noble-security's default 500 and silently wins the candidate selection.
Scenario: /etc/apt/preferences.d/foo with `Pin: origin "mirror.example"` / `Pin-Priority: 600` (a slow mirrors or an older CUDA/NVIDIA pin) -> the mirror's older package beats the security update from noble-security, and sgs-check prints PASS "No apt pin can override Ubuntu's updates or force downgrades".
Fix: WARN on any pin above 500 whose target isn't an Ubuntu suite (o=Ubuntu, noble*), not just above 1000.

6. bin/sgs-check:194-207 (with install.sh:382-388) — medium
Defect: the branch is taken from `head -1` of all matching nvidia packages, so only one installed branch is ever EOL-checked.
Scenario: install_driver refuses to purge an old branch because it would remove dependents (install.sh:385-388, e.g. R535 libraries left behind); dpkg-query's ordering puts nvidia-driver-580 first -> branch=580 -> PASS "Driver branch R580 is supported by NVIDIA until 2028-06" while the EOL R535 userspace keeps its unpatched CVEs (the loop at 210-215 only asks whether Ubuntu has a newer build of each package, not whether the branch is dead).
Fix: extract every distinct branch from $drv_pkgs and warn if any is EOL or unlisted.

7. install.sh:328-342 — medium (environment-dependent, unverified)
Defect: the DKMS fallback installs `nvidia-headless-580-...`, which builds modules locally, and nothing in the script checks Secure Boot or enrolls a MOK.
Scenario: a kernel flavour with no prebuilt module package on a machine with Secure Boot enabled (mokutil --sb-state) -> install finishes and prints "Reboot", but shim rejects the unsigned modules at load; only after reboot does sgs-check:197 ("GPUs present but no NVIDIA driver") or 234-240 ("isn't signed") show it.
Fix: in the DKMS branch, refuse (or die with instructions) when `mokutil --sb-state` reports Secure Boot enabled and no MOK is enrolled.

8. bin/sgs-check:497-498, 551-556 — low (two manifestations of one defect)
Defect: the root-run integrity check invokes bare `python3` instead of the `/usr/bin/python3 -I` used at 68, 268, 353, 407 and 444, and `sha256sum -c` is piped through `cut ... || true`, so its exit status is discarded.
Scenario A: root logs in via `su -` (profile.d from install.sh:515 puts /opt/sgs/venv/bin first) and runs sgs-check -> the stack's interpreter and its .pth hook execute as root, the exact thing the comment at 350-352 says to avoid. Scenario B: /opt/sgs/files.sha256 is empty or truncated (interrupted write_manifest, disk full) -> sha256sum fails "no properly formatted checksum lines", stderr is discarded, changed_files is empty -> PASS "The stack's own files ... are as installed" with nothing verified.
Fix: use /usr/bin/python3 -I at 498, and require a minimum line count in files.sha256 (or check sha256sum's status) before PASSing.

9. bin/sgs-check:704-732 — low
Defect: the update-coverage result is only reported `[ -n "$uu_out" ] && report ...`, with no else, so a failure of the embedded python removes the check without a WARN or SKIP.
Scenario: /usr/bin/unattended-upgrade moves or python-apt is missing -> the Docker/NVIDIA auto-update coverage is never verified, no counter changes, and the summary looks clean.
Fix: `[ -n "$uu_out" ] && report ... || bad "Update coverage check didn't run (internal error)"`.

10. bin/sgs-check:159-182 — low
Defect: an empty pin_report is treated as PASS, including when the embedded python dies, unlike every other helper which goes through report() (44-51) and says "didn't run".
Scenario: the python errors out (IO error on /etc/apt/preferences.d, future syntax edit) -> output empty -> `ok "No apt pin can override Ubuntu's updates or force downgrades"` on a machine whose pins were never read.
Fix: run the pin output through report(), as line 181 already does for the non-empty case.

11. install.sh:55, 92, 524-529 — low
Defect: `--user root` is accepted (only auto-detection excludes root at line 88); nothing validates uid 0.
Scenario: `sudo ./install.sh --user root` enables sgs-jupyter@root, which writes its token under /root and hands notebook code every private key and cloud credential on the box; no check in either script objects.
Fix: reject TARGET_USER when `id -u "$TARGET_USER"` is 0.

12. bin/sgs-check:420-424 — low
Defect: the unrecorded-startup-code scan only matches the names "sitecustomize.py"/"usercustomize.py", but Python's site module imports `sitecustomize`/`usercustomize` as modules, so a package-shaped directory of that name is equally executed and is not reported.
Scenario: site-packages/sitecustomize/__init__.py (as some tools ship, or as malware drops when it can write there) runs in every interpreter start of the stack and the check prints PASS "No startup code in the stack beyond what its packages installed".
Fix: match `sitecustomize`/`usercustomize` both as `.py` and as directories (and check `*.pth` in the same pass as now).
