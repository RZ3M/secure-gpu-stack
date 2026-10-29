Round F — documentation claims vs. code

1. HIGH — README says Docker-published ports can't bypass the firewall, but a running container that publishes a port to 0.0.0.0 is only a NOTE, so sgs-check still exits 0.
   README.md:23 ("Docker-published ports don't bypass the firewall") and README.md:42 present this as proven; sgs-check:314-316 prints `note "Running containers that publish ports to every interface (the firewall doesn't apply)"`, and note() (sgs-check:39) never increments `warns`, so sgs-check:872 returns 0.
   Scenario: `docker run -p 0.0.0.0:8888:8888 …` — exactly the deliberate publish form design.md:183 recommends — while daemon.json is still correct. sgs-check reports 0 WARN and PASSes the Docker section; the port is world-reachable.
   Fix: make this a `bad` result (or fail unless the port is on an explicit allowlist), and run the same query over all networks, not only `docker ps` defaults.

2. MEDIUM — The "only SSH is reachable" check is TCP-only and ignores ufw allow-rules for ports that aren't currently listening; both produce notes, not warnings.
   README.md:23 claims "Nothing reachable from the network except SSH"; sgs-check:595-596 scans `ss -tlnpH` (TCP only), and sgs-check:618-623 emits `note "The firewall lets these through"` for ufw-ALLOWed ports, which doesn't affect the exit status; the firewall check at sgs-check:676-678 only tests the default policy.
   Scenario: an admin runs `ufw allow 6006` for TensorBoard, or `ufw allow 5353/udp`; at audit time nothing (or only a UDP socket) is listening, so sgs-check prints "Only SSH listens on the network" and exits 0, though a later start is reachable. A UDP daemon (avahi) never appears in the list at all.
   Fix: scan `ss -lunpH` too, and parse `ufw status` for non-SSH ALLOW rules and warn regardless of whether a listener exists.

3. MEDIUM — sgs-check never verifies the fingerprint or ownership of the key a third-party source points at, so the "Per-source keys with checked fingerprints" claim is only true at install time.
   README.md:22 and README.md:35 claim per-source keys with verified fingerprints; design.md:61-64 says each key is "checked to be exactly one key with the expected full fingerprint". install.sh:34-35 and install.sh:158-171 do that once. sgs-check:125-139 only checks that the URI is HTTPS and that `signed-by=` is non-empty, then prints PASS "HTTPS, key limited to this source".
   Scenario: any third-party `.sources`/`.list` entry pointing Signed-By at `/usr/share/keyrings/whatever.gpg`, or a replaced `/etc/apt/keyrings/sgs-nvidia-cuda.gpg`, yields PASS; apt would then accept a different signer than the pinned fingerprint. (Whether the keyring directory is otherwise protected isn't checked either.)
   Fix: for each third-party source, resolve Signed-By (reject inline keys), require a root-owned, non-group/world-writable regular file, and compare `gpg --show-keys` fingerprints against the same pins install.sh uses (NVIDIA/Docker).

4. MEDIUM — sgs-check does not verify that the installed driver came from Ubuntu's archive; a newer driver from NVIDIA's CUDA repo passes as "the newest build Ubuntu offers".
   README.md:21 and README.md:36 require R580 from Ubuntu's archive; design.md:8-16,45-51 explain the −1 pin. sgs-check:216-237 checks only branch EOL and version comparison against `apt-cache madison` entries on ubuntu.com: `version_lt "$ver" "$newest" || continue` means a higher NVIDIA-repo build (e.g. 580.196 vs Ubuntu's 580.178, the exact case in design.md:45-50) is skipped, leaving no pending/blocked entry, and sgs-check:237 prints "Driver is the newest build Ubuntu offers".
   Scenario: the pin file is missing or removed (files/apt-pin-nvidia-cuda isn't provided, so its presence isn't audited); apt upgrades to NVIDIA's build, which is not Ubuntu-signed and not covered by Ubuntu's security process; sgs-check still PASSes driver provenance and branch.
   Fix: check the installed version's origin/archive from `apt-cache policy`, require ubuntu.com, and warn if `files/apt-pin-nvidia-cuda`'s −1 pin for the driver isn't present.

5. MEDIUM — Jupyter's token, sudo and journal checks are all keyed on the process name containing "jupyter"; under any other name they silently become "JupyterLab isn't running".
   README.md:38 says the token is required and notebook code can't sudo; design.md:158-173 and design.md:275-277 promise every skipped check says so. sgs-check:626 sets `jup=$(ss -tlpnH | grep -i 'jupyter' …)` and the entire block at sgs-check:634-675 (token probe at 637-641, NoNewPrivs at 646-657, token-in-journal and token-file perms at 661-674) is inside `if [ -n "$jup" ]`.
   Scenario: a server started as `python -m jupyterlab`, or any renamed launcher, is not matched by ss's comm name; sgs-check prints only `note "JupyterLab isn't running"` — no WARN — and returns 0 with none of the Jupyter claims tested. The actual unit's ExecStart (files/sgs-jupyter@.service) isn't in this code set, so whether this fires by default is unverified.
   Fix: derive the port from each `sgs-jupyter@*` unit's MainPID via `ss -tlpnH | grep "pid=$pid"`, and warn when a unit is active but no matching listener is found.

6. MEDIUM — The automatic-update "time limit" check covers only apt-daily, and a missing completion stamp is a note, not a warning.
   README.md:40 claims time limits and "sgs-check checks that a run actually completed"; design.md:230-233 says "The download job gets 1 hour and the upgrade job 4 hours". install.sh:294-298 writes drop-ins for both units, but sgs-check:792-794 tests only `TimeoutStartUSec` of `apt-daily.service`. sgs-check:779-780 emits `note "Automatic updates haven't completed a run yet"` when the stamp is absent, which is not counted.
   Scenario: the apt-daily-upgrade drop-in is removed or set to infinity — the hung-upgrade case design.md:227-230 describes — and sgs-check still prints "apt's daily jobs have a time limit". On a machine where unattended-upgrades has never completed a run, 0 WARN is recorded.
   Fix: check both `apt-daily.service` and `apt-daily-upgrade.service`, and make a missing stamp a WARN once the machine is older than a day.

7. MEDIUM — pip-audit never scans `/opt/sgs/tools`, so "zero known vulnerabilities in the stack's Python packages" excludes the security tools' own dependencies.
   README.md:20 (criterion 3), README.md:24 and README.md:42 claim the stack is vulnerability-free and that sgs-check proves it; design.md:134-135 says the tools live in their own environment. sgs-check:463-464 builds `audit_paths=(--path "$SITE")` plus `tf-cuda12` only.
   Scenario: a CVE in pip-audit/modelscan or a transitive dependency in `/opt/sgs/tools/lib/python3*/site-packages` is installed by install.sh:525-526; the audit prints PASS "No known vulnerabilities in N Python packages", and the tools are run as root elsewhere. This also explains part of the README.md:51 "149 packages" vs design.md:93 "161 pinned packages" gap (unverified that they're the same set).
   Fix: add `--path /opt/sgs/tools/lib/python3*/site-packages` to audit_paths.

8. MEDIUM — design.md says pip is upgraded, but nothing in the installer upgrades pip; the stack keeps Ubuntu's pip 24.0.
   design.md:95: "pip itself is upgraded, because Ubuntu's venv ships pip 24.0." install.sh:493 creates the venv with `python3 -m venv` and immediately installs the lockfile; make_venv's options (install.sh:480) are `--require-hashes --only-binary --no-deps -r "$lock"` with no `--upgrade pip`, and install.sh:506-529 has no pip step. sgs-check doesn't report pip's version either.
   Scenario: the environment on disk is the one the doc says was replaced; any pip fix after 24.0 is absent from the stack's install path while README.md:37 advertises "current versions".
   Fix: upgrade pip from a hash-pinned entry (or add pip to the lockfile) inside make_venv, or delete the claim.

9. MEDIUM — The unattended-upgrades coverage check only asks about Docker and container-toolkit packages, not the CUDA/cuDNN/NCCL packages the README says are covered.
   README.md:20 says CUDA gets NVIDIA's security updates automatically; README.md:40 says "Docker and NVIDIA packages included"; design.md:234-242 says the Origins-Pattern covers `NVIDIA CUDA` and sgs-check asks unattended-upgrades whether "those packages" are covered. sgs-check:762 iterates only `docker-ce`, `containerd.io`, `nvidia-container-toolkit`, `libnvidia-container1`.
   Scenario: the label is wrong or a repo entry changes so `cuda-toolkit-13-0`, `libcudnn9-cuda-13` or `libnccl2` (installed from NVIDIA's repo by install.sh:416) never auto-update; sgs-check prints PASS "Automatic updates cover Docker and the NVIDIA Container Toolkit".
   Fix: include the CUDA toolkit, cuDNN and NCCL package names in the coverage loop, and word the PASS to match.

10. MEDIUM — If the NVIDIA module isn't loaded, the perf-counter, module-signature and Secure Boot checks disappear with no SKIP or WARN, contradicting design.md section 8.
   design.md:275-277: "Every check that could be skipped silently says so"; design.md:263-264: sgs-check "also reports whether the NVIDIA module is signed and whether Secure Boot is on". sgs-check:243 guards the whole block with `if [ -r /proc/driver/nvidia/params ]` and has no else branch; the driver section at sgs-check:206-241 only checks packages and an nvidia-smi "version mismatch" string.
   Scenario: driver packages installed but the machine not rebooted, or a DKMS build that failed to load — packages look current, nvidia-smi fails silently (no mismatch string), so no WARN; the unsigned-module check at sgs-check:252-259 never runs.
   Fix: with GPUs present and the driver installed, emit a WARN/SKIP when `/proc/driver/nvidia/params` is unreadable, saying the module isn't loaded and a reboot may be needed.

11. LOW — "The installer refuses to run over Lambda Stack" is implemented as two exact filename checks only.
   design.md:72-73. install.sh:83 tests `/etc/apt/preferences.d/lambda-repository` and `/etc/apt/sources.list.d/lambda-repository.list`; sgs-check:61 likewise recognizes Lambda only via the `lambda-repository` package.
   Scenario: a Lambda repo file under any other name (deb822 `.sources`, a differently named preferences file) isn't detected; the installer proceeds, and Lambda's 1001 pin overrides the stack's −1 NVIDIA and 600 NCCL pins, defeating criterion 4. (Which filenames Lambda's current image actually writes is unverified.)
   Fix: detect by content — any pin at ≥1000 with `Package: *`, and any apt source matching Lambda's repository host — rather than by filename.

12. LOW — README presents the checksum/signature step as the security improvement over `wget | sh`, but the design admits it is corruption-only until an undecided release key exists.
   README.md:34: "Same one command, with a SHA-256 to check first, and an optional signature … that the Lambda cloud-init wrapper verifies"; README.md:79 tells users to fetch the tarball and `SHA256SUMS` from the same place. design.md:290-291: "A checksum fetched from the download host only catches corruption"; design.md:311-313 lists the release key under "Not done yet (v0.2 candidates)".
   Scenario: the download host is compromised and serves a matching tarball+SHA256SUMS; `sha256sum -c SHA256SUMS && sudo install.sh` installs the attacker's installer as root, with the same trust as `wget | sh`.
   Fix: state in README.md:34/79 that the checksum alone has no trust anchor, and make the signed `allowed_signers` path (or a hash published out-of-band) the documented default for installs — or make the release key a release blocker.

Not verifiable from the provided files: the contents of `files/apt-pin-*`, `files/docker-daemon.json`, `files/sshd-10-sgs.conf`, `files/sysctl-60-sgs.conf`, `files/sgs-jupyter@.service`, the lockfiles, `bin/sgs-sbom`, `cloud-init/` and `scripts/release.sh`. Claims that depend only on those (perf-counter pin value, SSH defaults, the SBOM's symlink/size handling, signature verification, Jupyter's `allow_unauthenticated_access`) are unverified here and are cited above only where the surrounding code shows the claim isn't reachable.
