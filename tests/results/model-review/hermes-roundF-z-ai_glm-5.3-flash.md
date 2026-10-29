Round F — doc claims vs code. Ranked, most severe first. All severities are relative to "the audit/installer lies to the user about security posture."

1. MEDIUM — sgs-check's "only SSH listens" check exempts any process named `systemd` on any port.
   Claim: README.md:23 "Nothing reachable from the network except SSH", README.md:42 "Proof: `sgs-check`".
   Code: bin/sgs-check:596 — `grep -vE ":($ssh_ports) users:\(\(\"sshd|systemd\""`. The `|` falls outside the quoted names, so the second alternative is bare `systemd"` matched anywhere in the line; the port anchor binds only to `sshd`.
   Scenario: a local user copies any binary to `./systemd` and runs a listener on 0.0.0.0:4444; ss prints `users:(("systemd",...))`, the line is filtered out, sgs-check prints PASS "Only SSH listens on the network" and exits 0. This also breaks the project's own bar (design.md:277-278: "the check must turn it into a WARN").
   Fix: group the alternation inside the quotes and keep the port anchor for both names: `users:\(\(\"(sshd|systemd)\"` — or verify the owning pid's exe is /usr/sbin/sshd.

2. MEDIUM — the auditd rules claimed for "package sources, sudo, SSH, Docker, GPU hooks" mostly watch directory inodes, so the claimed events don't fire.
   Claim: README.md:41 "auditd rules for package sources, sudo, SSH, Docker, GPU hooks and the stack"; design.md:243-246 lists the same.
   Code: install.sh:566-571 — `-w /etc/apt/`, `-w /etc/docker/`, `-w /etc/ssh/sshd_config.d/`, `-w /etc/sysctl.d/`, etc. A `-w` on a directory records creation/deletion/rename of its direct entries only — not writes to files inside it, and nothing in its subdirectories.
   Scenario: `echo "deb [trusted=yes] http://evil/ ..." > /etc/apt/sources.list.d/evil.list` (or an in-place edit of daemon.json or 60-sgs.conf) leaves no audit record. /etc/apt/preferences.d isn't watched at all, and /opt/sgs/files.sha256 (install.sh:598-602) covers the preload hook, commands and service unit — not the pins, daemon.json or the sysctl file.
   Fix: add explicit per-file watches for every file the stack installs (all exist when rules are written at install.sh:618), keeping the directory watches for creation/deletion.

3. MEDIUM — every Jupyter security check silently disappears if `ss` doesn't label the process "jupyter".
   Claim: design.md:275-276 "Every check that could be skipped silently says so"; README.md:38 (token everywhere, no sudo, token out of logs — all presented as verified).
   Code: bin/sgs-check:626 gates the whole Jupyter block on `ss -tlpnH | grep -i jupyter`; the MainPID fallback (646-649) — added because, per its own comment, Jupyter may run "under another name (python -m jupyterlab, say)" — feeds only the NoNewPrivileges check and runs only inside `if [ -n "$jup" ]` (634).
   Scenario: unit runs `python -m jupyterlab` (or ss reports the interpreter's comm): jup is empty, output is the note "JupyterLab isn't running" while Jupyter is up — no localhost check, no token-refusal curl, no NNP check, no token-in-journal check, exit 0. Unverified: which name ss prints for the service's ExecStart (unit file not provided); the silent-skip structure is in the code either way.
   Fix: enumerate `sgs-jupyter@*` units first and drive all Jupyter checks from MainPID plus the unit's configured port; WARN when a unit exists but no socket is found.

4. MEDIUM — pip-audit covers two of the three Python environments the stack installs, so "zero known vulnerabilities" is overstated.
   Claim: README.md:20 criterion 3 ("Zero known vulnerabilities in the stack's Python packages ... `sgs-check` runs pip-audit"); design.md:299 calls tools one of "the stack's three environments"; sgs-check's own PASS line says "No known vulnerabilities in N Python packages".
   Code: bin/sgs-check:463-464 — `audit_paths` is the venv site-packages plus tf-cuda12 only; /opt/sgs/tools (pip-audit, modelscan and their dependency trees, install.sh:524-526) is never audited, although sgs-check:425's comment says "The tools environment counts too". This also explains the 161-pinned (design.md:93) vs 149-audited (README.md:51) discrepancy.
   Scenario: a vulnerable modelscan/pip-audit dependency ships in /opt/sgs/tools; sgs-check exits 0.
   Fix: append the tools site-packages to audit_paths.

5. MEDIUM — "The installer refuses to run over Lambda Stack" tests two hardcoded filenames only.
   Claim: design.md:72-73. Code: install.sh:83-85 checks only `/etc/apt/preferences.d/lambda-repository` and `/etc/apt/sources.list.d/lambda-repository.list`.
   Scenario: Lambda's pin under a different name (or merged into /etc/apt/preferences) → installer proceeds; Lambda's 1001 pin then outranks the stack's sources — the exact mixing the design forbids. sgs-check detects Lambda by package (sgs-check:61) and flags ≥1000 pins (175-176) only after the fact.
   Fix: also fail on `dpkg-query -W lambda-repository` and on any preferences stanza with priority ≥1000.

6. LOW — a running container published to 0.0.0.0 is a `note`, so criterion 6 "passes".
   Claim: README.md:23 ("Nothing reachable from the network except SSH ... Docker-published ports don't bypass the firewall — `sgs-check` plus an attack demo").
   Code: bin/sgs-check:314-316 emits `note` (not WARN) for running containers publishing to 0.0.0.0/[::]; exit status (871-872) counts warns only.
   Scenario: `docker run -p 0.0.0.0:80:80` — the escape hatch design.md:182 itself documents — leaves the port internet-reachable while sgs-check exits 0.
   Fix: WARN on public publishes of running containers, or state in README.md:23 that deliberate publishes only produce a note.

7. LOW — "Pending security updates applied" prints even when the run failed, and a never-completed run is only a note.
   Claim: README.md:20 "checks that updates install"; README.md:40 / design.md:231-232 "checks that a run actually completed".
   Code: install.sh:325 `unattended-upgrade ... || info "Couldn't apply..."` followed by unconditional `info "Pending security updates applied"` (327); bin/sgs-check:779-780 emits `note` when the upgrade-stamp doesn't exist.
   Scenario: unattended-upgrade fails during install → installer claims success; if the daily job then never succeeds, sgs-check exits 0 with a footnote.
   Fix: make line 327 conditional on the exit status; WARN when the stamp is missing on a machine whose manifest install date (install.sh:587) is more than 3 days old.

8. LOW — criterion 1 ("Same tools ... How it's checked: Installer output, `sgs-check`") isn't actually checked by sgs-check.
   Claim: README.md:18. Code: bin/sgs-check:374-377 prints framework versions as a `note`; a missing torch/tensorflow/keras/jax/jupyterlab produces no WARN, and torchvision, Triton, cuDNN and NCCL are never verified anywhere.
   Scenario: a broken/partial venv (empty site-packages) → 0 WARN, exit 0.
   Fix: WARN when any criterion-1 package is absent from the metadata read at 371-376, and check dpkg for libcudnn9/libnccl2.

9. LOW, unverified — "pip itself is upgraded, because Ubuntu's venv ships pip 24.0" (design.md:93-94) has no backing code.
   install.sh:478-504 creates the venv and installs only `-r lock-${PY_ARCH}` with `--require-hashes --no-deps`; there is no pip-upgrade step. Unless pip is pinned inside the lockfile (not provided), Ubuntu's pip 24.0 stays and the stated reason doesn't happen. Fix: pin pip in the lockfile (hash-verified like everything else) or drop the claim.

10. LOW — `--no-hardening` silently skips more than documented, while README presents those features as unconditional.
    install.sh:12 says "don't change SSH, firewall or automatic-update settings", but harden() also writes the sysctl pin (install.sh:307-321) and install_audit_rules returns early with no message (556). README.md:41-42 / design.md:243,252 list audit rules and pinned kernel settings as stack deliverables. Fix: enumerate what the flag skips in --help and print a note when skipping.

11. LOW — "so `python3 -c "import torch"` works as on Lambda Stack" (design.md:86-87) holds only for login shells.
    /etc/profile.d is sourced by login shells only; install.sh touches no other PATH mechanism (528). Scenario: `ssh host python3 -c "import torch"`, cron, or a systemd unit → ImportError, unlike Lambda's system-wide install. design.md:6 promises trade-offs will be stated; this one isn't. Fix: document it, or also write a drop-in to /etc/environment.d.

Not checkable from the files provided: contents of files/docker-daemon.json, files/sgs-jupyter@.service, the sshd/sysctl/modprobe/pin files, bin/sgs-venv, bin/sgs-jupyter, bin/sgs-sbom, scripts/release.sh, cloud-init and tests/. Several design claims resting solely on those (design.md:158-159 allow_unauthenticated_access, design.md:201-209 icc:false and log-size limits, design.md:282-309 release signing and SBOM behaviour) are therefore unverified here, not confirmed — notably, icc and log limits have no sgs-check verification either, unlike ip/no-new-privileges/default-runtime.
