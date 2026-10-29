# deepseek/deepseek-v4.1-flash-1017

## Findings (most severe first)

**1. High — aa-exec bypass check can test the wrong AppArmor profile and report PASS**  
`sgs-check-kernel-block.sh:19-24`  
Defect: the check picks the first file containing `userns,`, then the first `profile` line in that file, not the profile that actually contains `userns,`.  
Scenario: `/etc/apparmor.d/foo` contains `profile A { ... }` followed by `profile B { userns, }`. `grep` returns `foo`, `awk` prints `A`, `aa-exec -p A -- unshare -Ur true` fails, `userns_open` stays empty, and line 23 reports OK even though `aa-exec -p B` would give uid 0. Profiles in `/etc/apparmor.d/*/` are also missed.  
Fix: parse the profile block containing the `userns,` rule, or iterate all loaded profiles (`aa-status --profiled` / `apparmor_parser -N`) and fail if any allows `unshare -Ur`.

**2. High — unprivileged `sgs-check` run is treated as “userns blocked”**  
`sgs-check-kernel-block.sh:18-24`  
Defect: any failure of `runuser -u nobody -- unshare -Ur true` is interpreted as “ordinary users cannot create user namespaces”.  
Scenario: an ML engineer runs `sgs-check` without sudo; `runuser` exits with “may not be used by non-root users”; `userns_open` remains empty; line 23 reports OK on a machine where unprivileged user namespaces are actually allowed. The shown code does not enforce root.  
Fix: require root for this check, or distinguish “test could not run” from “test succeeded” and emit WARN/FAIL on setup failure.

**3. High — `dpkg --verify` errors are reported as OK**  
`sgs-check-native-block.sh:15-17`  
Defect: the exit status of `dpkg --verify` is ignored; any error produces empty stdout and is treated as “no changed files”.  
Scenario: `dpkg --verify` fails because the dpkg database is locked/corrupt or the command is interrupted (unverified whether `--verify` itself takes the dpkg lock); `changed` is empty; line 17 says the driver/CUDA/container files match their packages.  
Fix: capture `rc=$?`; only report OK when `rc=0` and `changed` is empty; otherwise report bad/WARN.

**4. Medium — native package verification is silently skipped if `dpkg-query` fails or matches nothing**  
`sgs-check-native-block.sh:7-12`  
Defect: if `dpkg-query` fails or no packages match, `native` is empty and the whole native block is skipped with no OK and no bad.  
Scenario: dpkg database is locked/corrupt, or NVIDIA/Docker packages were removed; `dpkg-query` writes an error to stderr (suppressed) and no stdout; `if [ -n "$native" ]` is false; `sgs-check` never reports missing driver/CUDA/container packages.  
Fix: check `dpkg-query` status and require a non-empty expected package set; report bad if the query fails or expected packages are absent.

**5. Medium — held packages are excluded from `dpkg --verify`**  
`sgs-check-native-block.sh:11`  
Defect: `awk '$1 ~ /^ii/ { print $2 }'` only includes packages whose desired state is `install`; held packages (`hi`) are skipped.  
Scenario: `apt-mark hold libnvidia-compute-550 docker-ce`; `dpkg-query` prints `hi ...`; `awk` drops them; a modified file in a held NVIDIA/Docker package is never verified, and `sgs-check` reports OK.  
Fix: use `${db:Status-Status}` == `installed`, or match `^.i`, instead of `^ii`.

**6. Medium — audit check passes on one dummy `sgs-` rule**  
`sgs-check-kernel-block.sh:26-29`  
Defect: the check only counts lines containing any `sgs-` key; it does not verify the specific rules.  
Scenario: real audit rules for sudo/SSH/Docker/package sources are removed, and `-w /tmp/x -k sgs-dummy` is added; `auditctl -l | grep -c` returns 1; line 28 reports OK.  
Fix: check for each expected key/path (or a required minimum set), not just any `sgs-` key.

**7. Medium — `wait_for_apt` misses `/var/cache/apt/archives/lock`**  
`install-apt.sh:8`  
Defect: the `fuser` loop watches only `lock-frontend`, `lock`, and `lists/lock`; another apt downloading packages can hold the archives lock.  
Scenario: unattended-upgrades starts an apt download and holds `/var/cache/apt/archives/lock`; `wait_for_apt` sees no lock on the three listed files and returns; `apt_get install` fails with “Could not get lock /var/cache/apt/archives/lock”.  
Fix: add `/var/cache/apt/archives/lock` to the `fuser` list.

**8. Medium — `DPkg::Lock::Timeout=600` does not cover APT’s own locks**  
`install-apt.sh:17`  
Defect: the timeout covers the dpkg lock, not the APT lists/archives locks, so the race after `wait_for_apt` remains for `apt-get update`/download.  
Scenario: `wait_for_apt` sees no lock; cloud-init starts `apt-get update` holding `/var/lib/apt/lists/lock`; the installer’s `apt-get install` fails immediately with exit 100.  
Fix: add the appropriate APT lock timeout option (e.g. `APT::Lock::Timeout=600` if supported on this apt version — unverified) and/or retry `apt-get` on lock errors; make the timeout at least as long as `wait_for_apt`’s 20 minutes.

**9. Medium — container runtime `runc` is not verified**  
`sgs-check-native-block.sh:7-10`  
Defect: the package globs include `docker-ce*`, `containerd.io`, and plugins, but not `runc` (or Ubuntu’s `containerd`/`docker.io` if used).  
Scenario: Docker CE installs `runc` as a separate package (unverified for this exact image); an attacker replaces `/usr/sbin/runc`; `dpkg --verify` is never run on `runc`; `sgs-check` says container files match their packages.  
Fix: add `runc`, `containerd`, and `docker.io` to the package set, or derive the full dependency set from `docker-ce`/`containerd.io`.

**10. Low — `fs.protected_fifos` and `fs.protected_regular` are not checked**  
`sgs-check-kernel-block.sh:3-5` vs `sysctl-60-sgs.conf:40-41`  
Defect: the sysctl file pins `fs.protected_fifos=1` and `fs.protected_regular=2`, but the check’s `want` list omits both.  
Scenario: a package or tuning script sets `fs.protected_regular=0`; `sgs-check` still reports “Kernel hardening settings are on”.  
Fix: add both keys with their expected values to the `want` list.

No issue found with the `-` prefix itself: procps `sysctl` and `systemd-sysctl` support it (unverified for the exact systemd version on the image). No `set -e` issue found in `wait_for_apt`; `fuser` in the `while` condition is exempt.
