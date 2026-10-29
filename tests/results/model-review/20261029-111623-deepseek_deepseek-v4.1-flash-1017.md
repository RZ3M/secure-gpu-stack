# deepseek/deepseek-v4.1-flash-1017

# Secure GPU Stack — Round Y findings

Ranked most severe first. Citations are to the excerpts provided.

---

**1. HIGH — On a Secure Boot machine whose driver fell back to DKMS, `setup_lockdown` prints nothing and the GPU is gone after reboot.**
`install.sh:50-65`: when `dkms_mods` is non-empty the `why` block runs, but if lockdown is already on from Secure Boot (no `60-sgs-lockdown.cfg`, no `lockdown=` in `/etc/default/grub`, no `lockdown=` in `/proc/cmdline`, `$lockdown == integrity`), all three `if/elif` arms are false and the function returns silently.
Scenario: Secure Boot on; `linux-modules-nvidia-*` doesn't match the running kernel so `install_driver` builds an unsigned DKMS module; `setup_lockdown` sees it, enters the block, says nothing; install reports success. Reboot → lockdown (and Secure Boot) refuse the unsigned module → no GPU, no warning at install time. The same silent path occurs when `lockdown=` is in `/etc/default/grub` — line 56 prints "it stays" but never mentions that the DKMS module will be refused.
Fix: in the `why` block, if `$lockdown` is `integrity`/`confidentiality` (i.e. from Secure Boot) and `dkms_mods` is non-empty, emit a loud warning that the DKMS module will be refused and the GPU will be gone, and tell the user to enroll the MOK key (`mokutil --import`) or use the signed prebuilt modules. Do not report a clean install in that state.

**2. MEDIUM — `sgs-check` silently re-baselines the startup record when the file is missing.**
`sgs-check:115-119`: if `/var/lib/sgs/startup-files` is absent, the check *creates* it from the current state and emits only a `note`, never `bad`.
Scenario: a malicious package postinst (or any root-level compromise) deletes `/var/lib/sgs/startup-files` after planting a `~/.bashrc` backdoor; the next `sgs-check` records the backdoored state as the baseline and reports "Recorded N startup files", not a failure. This directly contradicts the install.sh comment (`install.sh:107-113`) that a re-run must not accept an unseen change.
Fix: if the manifest shows SGS was installed but the record is missing, report `bad "startup-file record missing"` and do not auto-create; only create on an explicit `--accept-changes`.

**3. MEDIUM — Startup-file comparison is locale-sensitive; `comm` can miss a changed file.**
`startup_files` ends with `| sort` (`sgs-check:41`) and the comparison uses `comm` (`sgs-check:107,109`) without pinning `LC_ALL`. The record is written during the interactive install (user's locale); `sgs-check.service` runs under systemd with a different/unset locale.
Scenario: install under `en_US.UTF-8`, check under `C` (or vice versa) → different collation → `comm` mis-aligns and can drop a genuinely changed line, so a modified `~/.ssh/authorized_keys` is reported as "No … SSH key changed".
Fix: `export LC_ALL=C` in `startup_files` and before both `comm` invocations.

**4. MEDIUM — The watched set misses common persistence paths, so `sgs-check` reports a false "ok".**
`sgs-check:17-18` watches `/etc/crontab`, `/etc/cron.d/*`, spool crontabs/atjobs, linger and `/etc/sudoers.d/*`, but not `/etc/cron.{hourly,daily,weekly,monthly}`, `/etc/systemd/system/*.service|*.timer`, `/etc/rc.local`, `/etc/profile.d/*`, `/etc/bash.bashrc`, `/etc/environment`, or `/etc/ld.so.preload`.
Scenario: a malicious `.deb`/postinst drops `/etc/cron.daily/updater`; `sgs-check` prints "No cron job … changed since it was last accepted" (`sgs-check:111`) — a false PASS on a persisted backdoor.
Fix: add those paths (and systemd system units/timers) to `startup_files`.

**5. MEDIUM — `--no-lockdown` is silently ineffective on Secure Boot machines.**
`install.sh:48` sets `why="--no-lockdown"`, but on a Secure Boot machine the `why` block's arms (`install.sh:56,58,61`) are all false, so nothing is printed and lockdown stays on.
Scenario: user passes `--no-lockdown` specifically to allow an unsigned module; install says nothing; the module is still refused at boot. The user has no signal that the flag did not do what it claims.
Fix: detect Secure Boot lockdown and tell the user `--no-lockdown` cannot disable it (they must enroll the MOK key or disable Secure Boot).

**6. MEDIUM — `setup_lockdown` never verifies the generated `grub.cfg` actually contains `lockdown=`.**
`install.sh:79-88`: after `update-grub` succeeds it only checks `/proc/cmdline` (the *current* boot) and sets `NEED_REBOOT`. It never greps `/boot/grub/grub.cfg` for `lockdown=integrity`.
Scenario: `/etc/default/grub.d` is not sourced by this GRUB build, or a later-sourced `99-*.cfg` overwrites `GRUB_CMDLINE_LINUX_DEFAULT` without preserving it; `update-grub` exits 0, installer says "turns on at the next boot", but lockdown never turns on. `sgs-check` then reports `bad` only after the reboot.
Fix: after `update-grub`, `grep -q 'lockdown=integrity' /boot/grub/grub.cfg` and warn/fail if absent.

**7. LOW/MEDIUM — Record format is line-based; paths with spaces are truncated and newlines inject fake entries.**
`fingerprint` (`sgs-check:8-12`) emits `hash path`; `sgs-check:107,109` extract the path with `awk '{ print $2 }'`.
Scenario A: a file named `my app.desktop` under `~/.config/autostart` is reported as `…/my`, so the admin reviewing the alert looks at the wrong path.
Scenario B: a filename containing `\n` splits one fingerprint into two record lines, injecting an arbitrary `hash path` line into the record/now lists (causes spurious diffs and can confuse the reviewer; I could not construct a reliable false-negative, so treat exploitability as unverified).
Fix: NUL-delimit (`find -print0`, `sha256sum -z`) or at minimum parse the path from the right and reject/escape newlines.

**8. LOW — The startup record is only written when the file is absent, so a stale/partial record is never refreshed.**
`install.sh:111`: `if [ ! -f /var/lib/sgs/startup-files ]`. If a first run created an empty or partial record and then failed, every later run skips recording.
Scenario: first install dies after `--accept-changes` wrote a truncated record; re-runs never fix it; `sgs-check` then reports every startup file as "new or changed" forever, training the user to blindly run `--accept-changes` (which would then accept a real compromise).
Fix: record when the file is absent **or empty**, or store a schema/version marker and re-record on mismatch.

**9. LOW — `--no-hardening` leaves a previously installed lockdown cfg in place, unlike `--no-lockdown`.**
`install.sh:44`: `[ "$WITH_HARDENING" = 1 ] || return 0` returns before the removal logic at `install.sh:52-55`.
Scenario: a prior run enabled lockdown; the user later adds a DKMS module and re-runs with `--no-hardening` (to keep their SSH config); the cfg stays, the DKMS module is refused at boot, and the user believes they disabled the relevant hardening.
Fix: make `--no-hardening` also remove the lockdown cfg, or document that `--no-lockdown` is required and have `--no-hardening` warn when the cfg is present.

**10. LOW — The lockdown `ok` depends on a journal message; a refused module can go unnoticed.**
`sgs-check:60`: the "module refused" detection greps `journalctl -k -b 0` for `unsigned module loading is restricted`. If journald is volatile/rotated, kernel logging is suppressed, or the message format differs, the check prints `ok "Kernel lockdown is on"` while a device (e.g. the GPU) is silently dead.
Scenario: `Storage=volatile` and a long uptime; the refusal message is gone; `sgs-check` reports the stack healthy though `nvidia-smi` fails.
Fix: also check `dkms status` for modules not loaded (`lsmod`) and report a `bad` when a DKMS module exists but isn't loaded under lockdown, independent of the journal.
