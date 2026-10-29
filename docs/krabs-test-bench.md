# krabs: the first real-GPU test bench

Until now, the stack had only been tested on GPU-less local VMs. krabs is a
lived-in Ubuntu 24.04 laptop with an NVIDIA GTX 1070 (Pascal, compute
capability 6.1), reached over Tailscale. Its earlier life (a media server,
Docker Desktop, Ubuntu's own CUDA 12.0 packages, a 198-day uptime) made it a
harder and more realistic target than a fresh cloud image. Every problem below
was found on it and fixed in this repository.

## What it found

### Installer bugs (the install would have failed or hurt the machine)

1. **Dead GPU after reboot on HWE kernels.** The installer picked driver
   modules for the GA kernel line (`generic`). On an HWE machine
   (`generic-hwe-24.04`, the default on recent desktop installs) that pulled in
   an old 6.8 kernel just for its modules, while the newest kernel, which boots
   by default, had none. Fixed: the kernel line is detected.
2. **"Prebuilt" modules need headers.** Ubuntu's prebuilt R580 modules are
   linked against their kernel during install, using `objtool` and
   `module.lds` from its headers package, but don't depend on it. The module
   package pulled in a newer kernel than the installed headers, and its setup
   failed partway, leaving apt broken. Fixed: the matching headers are
   installed first, in their own step.
3. **apt refused to run.** Docker's own install guide adds its repository
   with its own key file; ours added the same repository with a second key,
   and apt stops on conflicting `Signed-By` values. NVIDIA's `cuda-keyring`
   causes the same clash. Fixed: existing entries for the same repository are
   moved aside.
4. **A new password login.** krabs had no SSH server (only Tailscale SSH).
   The installer would have added one with Ubuntu's defaults, password logins
   included, and opened its port. Fixed: a newly installed SSH server starts
   keys-only. The firewall also allows the Tailscale interface.

### Stack bugs (installed fine, didn't work as claimed)

5. **TensorFlow never used the GPU.** It opens `libcusolver.so.11` by name from
   a library whose search path leaves out the cuSOLVER wheel. On krabs it
   "worked" only by borrowing Ubuntu's CUDA 12.0 copy, which then broke cuSPARSE.
   With that copy removed it found none, and quietly ran on the CPU.
6. **PyTorch's cuDNN and NCCL were silently replaced.** TensorFlow (CUDA 12)
   and PyTorch/JAX (CUDA 13) wheels write the same 70 files. pip let the last
   one win, so PyTorch got TensorFlow's CUDA 12 cuDNN and NCCL. Every download
   was hash-checked and `pip check` reported "No broken requirements found".
   TensorFlow's convolutions also mixed its cuDNN with the stack's system-wide
   CUDA 13 cuDNN and failed. Fixed: TensorFlow's CUDA 12 wheels live in their
   own hash-locked folder (`/opt/sgs/tf-cuda12`), and a hook loads them only
   when `tensorflow` is imported. See `docs/design.md` section 3.

### sgs-check blind spots (it said PASS when it shouldn't have)

7. **The GPU test.** It only checked that JAX and TensorFlow could *see* a GPU.
   JAX couldn't compute on it (`unsupported architecture compute_61`), and
   TensorFlow fell back to the CPU while reporting success. Now each framework
   runs a real matrix multiply in its own process, with silent CPU fallback
   turned off. Failures on GPUs a framework doesn't support are reported as
   SKIP, not PASS.
8. **The SSH checks never ran on Ubuntu 24.04.** `sshd -T` needs `/run/sshd`,
   which socket activation only creates on the first connection. Lambda's
   24.04 images behave the same way.
9. **"Automatic updates are on" while nothing was updated for 99 days.** A
   hung `apt-get update` in `apt-daily.service` held apt's lock from July 21.
   systemd never times out oneshot units, so every security update, and
   Tailscale's own auto-update, was blocked while the settings looked fine.
   Now: apt's jobs get time limits, and `sgs-check` checks that a run actually
   completed recently.
10. **No check that installed files are what was installed.** Hash-checked
    downloads don't prove what ends up on disk (finding 6). `sgs-check` now
    verifies every file against its wheel's recorded hash, like `debsums`.

### Found while verifying the fixes

11. **Old driver packages could never be patched.** Libraries left from the
    previous R535 driver (GL, firmware, module objects) stayed installed. Their
    security updates need the rest of R535, so apt kept them back for good,
    and sgs-check would have warned about them forever. The installer now
    purges packages from other driver branches (24 on krabs).
12. **GPU containers broke after the driver cleanup.** The CDI spec, which
    lists the host files Docker mounts into GPU containers, is generated at
    boot. It still named a Vulkan file from the purged R535 packages, so every
    `docker run --gpus` failed. The installer now regenerates it, and
    `sgs-check` flags a spec that names missing files.
13. **Smaller ones:**
    - The new audit check counted only 1 of 13 rules, because `auditctl -l`
      prints file watches as `-k`, not `key=`.
    - Every re-run asked for a reboot even when the right driver was loaded.
    - A re-run now takes 47 seconds, since unchanged environments are skipped.

### Found by an independent code review, confirmed on krabs

A fresh reviewer read the changed code with none of this context. Two of its
findings were serious, and both reproduced on krabs:

14. **docker compose ports went around the firewall.** `"ip": "127.0.0.1"`
    only covers Docker's default network. A container on its own network (one
    per compose project) published on `0.0.0.0` and `[::]`, while `sgs-check`
    said PASS. Fixed with `default-network-opts`. `sgs-check` names older
    networks that still publish everywhere (it found `firecrawl_backend` on
    krabs), and the attack demo has a compose-style case.
15. **The TensorFlow hook fired on a lookup, not just an import.** A bare
    `importlib.util.find_spec("tensorflow")` loaded 187 library mappings
    from TensorFlow's CUDA 12 set. That would have put its cuDNN and NCCL into
    any PyTorch process that imports Hugging Face `datasets`. It now fires only
    when tensorflow's code actually runs: 0 mappings after a lookup or
    `import torch`, 187 after `import tensorflow`.

Also fixed from the review:
- The kernel-settings step could abort the install, or lower stricter values.
- SSH lockouts: only port 22 was opened, and `MaxAuthTries 3`.
- A duplicate apt source added after install broke re-runs, and `sgs-check`
  reported "no pending updates" from stale lists.
- Docker and Container Toolkit fixes were never auto-installed.
- Re-runs overwrote `daemon.json`.
- An interrupted environment rebuild could delete the only good copy.
- 64k kernels resolved to the wrong flavour.
- The driver purge could take dependent packages with it.
- Watching all of `/opt/sgs` would flood the audit log on upgrades.

### Found by open-weight models, verified on krabs

`scripts/model-review.py` sends the stack's code to open-weight models
(DeepSeek V4.1 Flash and GLM 5.3 Flash, through OpenRouter) as read-only red
teamers. They get no tools and no shell. Their 23 findings were treated as
untrusted suggestions and each checked on krabs.

- **Rejected after testing:**
  - "Audit directory watches aren't recursive and miss in-place edits" (both
    models). On krabs, an in-place write to `/etc/docker/daemon.json` and a
    new file in `/etc/apt/sources.list.d/` were both recorded.
  - "Allow only SSH on Tailscale": a deliberate, documented trade-off.
- **Real, and fixed:**
  16. **Jupyter's login token was in the system journal**, 16 times, readable
      by the `adm` group. Jupyter logs a token it generated at a level that
      ignores `log_level`. The unit now generates the token once into an
      owner-only file and passes it in, and Jupyter logs a given token as
      `token=...`.
  17. **Notebook code was one `sudo` from root** on a machine like Lambda's,
      where the Jupyter user has passwordless sudo. The unit now sets
      `NoNewPrivileges` and `RestrictSUIDSGID`.
  18. **`sgs-check` could be fooled in nine ways**, all now caught. Each one was
      planted on krabs and produced a WARN, and krabs was restored after:
      - a `trusted=yes` source on a lookalike host (`notubuntu.com` counted as
        Ubuntu)
      - a fake `ubuntu-keyring-*.gpg` trusted for every repository
      - a pin at exactly 1000 (it already allows downgrades), and a low pin
        holding back `noble-security`
      - a duplicate key in `daemon.json` (Docker takes the last one, the grep
        saw the first)
      - `KbdInteractiveAuthentication yes` re-enabling passwords
      - a CDI spec owned by a normal user
      - pip pointed at another index
      - a planted `.pth` persistence file
      - a modified startup hook (the stack's non-pip files are now hashed at
        install)
  19. Smaller ones:
      - Locale-dependent parsing (now `LC_ALL=C.UTF-8`).
      - `SGS_PIP_AUDIT` ran any binary as root.
      - A merged `daemon.json` kept `default-runtime: nvidia`.
      - `sgs-venv` would build inside another user's folder.
- **Round B** (the same models re-reviewing the fixes, told which claims had
  been rejected): 24 findings. Five were rejected against krabs's actual
  results. One was "sgs-check never finds the Jupyter process"; krabs's run
  shows those checks running and passing. The real ones:
  20. **`sgs-check` ran the code it audits, as root.** Reading package versions
      and running the GPU test started the stack's Python, so a planted `.pth`
      file ran as root during the audit itself. `pip-audit` from the tools
      environment did the same. Versions are now read from metadata by the
      OS's Python with site processing off. The GPU test and `pip-audit` run
      as the user who called sudo, or nobody. Planted on krabs: the `.pth`
      ran only as uid 1000, never as root.
  21. **More ways to fool `sgs-check`, now caught** (each planted on krabs):
      - `Trusted=1`, since apt accepts `1/true/on` and any capitalization
      - a second URI on a deb822 continuation line
      - a `.pth` in the tools environment
      - a deleted file manifest (it used to skip silently), and deleted RECORD
        files ("all 0 files match" used to pass)
      - a world-readable token file
  22. Smaller ones:
      - Port 22 is now exempt only while sshd owns it.
      - A broken `nvidia-ctk` no longer passes.
      - Docker ports published without `docker-proxy` are now listed.
      - Every Jupyter process is checked, and the current token is searched
        for anywhere in the journal.
      - A Jupyter that won't start no longer stops the install before the
        audit rules.
      - CDI specs are audited.
      - Two more pip config locations are checked.
      - `sgs-venv` checks ownership of everything inside the folder.
- **Round C** (the delivery path, login profile, apt pins, Python policy and
  test scripts, which no model had reviewed): 24 findings.
  23. **Docker and NVIDIA updates never installed themselves.** The
      unattended-upgrades patterns said `label=Docker` and `label=NVIDIA`, but
      the real labels are `Docker CE` and `NVIDIA CUDA`. Running
      unattended-upgrades' own matcher on krabs confirmed they matched
      nothing. GLM had flagged this in rounds A and B, and I'd dismissed it:
      my check had cut "NVIDIA CUDA" to "NVIDIA". Fixed. `sgs-check` now asks
      unattended-upgrades itself whether `docker-ce` and the Container Toolkit
      are covered. Its first version also passed on the broken patterns
      (dpkg's local "now" origin always counts as allowed); now it warns on
      the old patterns and passes on the fixed ones.
  24. **Tests that couldn't fail:**
      - The attack demo's password test used `NumberOfPasswordPrompts=0`, so
        it could never succeed. It now asks the server which login methods
        it offers.
      - Its root test now reads sshd's own setting.
      - Its Docker results count only if a deliberately public port *is*
        reachable.
      - It now proves the machine is reachable first, and always removes its
        public container.
      - The user checks' "read-only stack" passed on any pip failure, such as
        no network. It now tests the permission itself.
      - The `torch.load` test now requires PyTorch's own refusal.
  25. **Secrets:** `sgs-check` now checks that home folders are closed and that
      Hugging Face, W&B (`.netrc`), AWS, GCP, Kaggle and SSH keys are private
      to their owner.
  26. Smaller ones:
      - The login profile only puts root-only folders first on `PATH`, and
        `sgs-check` verifies that.
      - The release tarball's files are owned by root.
      - The cloud-init wrapper refuses HTTPS-to-HTTP redirects and doesn't
        keep the archive's file ownership.
      - `sgs-venv` sets its permissions after creating every file.
      - Each new check was planted on krabs (a readable token, an open home
        folder, a writable `bin`) and warned.
  - **Rejected after testing:** "the NVIDIA driver pin does nothing". The full
    `apt-cache policy` shows NVIDIA's driver versions at priority −1. apt's
    `Pin: origin` *is* the hostname, and apt picks Ubuntu's 580.178.04 over
    NVIDIA's newer 580.196.07. A partial reading first suggested the
    opposite.
  - **Claims corrected in the README:**
    - A checksum fetched from the download host only catches corruption.
    - Jupyter's version and login pages are public.
    - "Zero known vulnerabilities" covers the Python packages.
    - User environments aren't hash-locked.
- **Round D** (the new `sgs-sbom` and release signing): 20 findings, one
  rejected (krabs's SBOM does list TensorFlow's CUDA libraries). The real ones:
  27. **A rollback past the signature.** In signed mode, a hash pinned in the
      user data was silently replaced by the one from the signed file, so a
      compromised host could serve an *older*, validly signed release. A
      pinned hash now has to match.
  28. **Signer-line weaknesses:** a wildcard principal or an extra pasted line
      could let another key's signature count. Now exactly one line, for
      exactly `release@secure-gpu-stack`, is accepted.
  29. **`sgs-sbom` trusted the packages it describes.** It runs as root at
      install:
      - A FIFO as a package's metadata would have hung it.
      - A symlink at its output path would have been followed.
      - A crafted package name could forge another package's purl.
      - Held packages were left out.

      It now reads regular files only, without following links and with a
      size cap. It writes through a temporary file and a rename, and
      percent-encodes names. On krabs a planted FIFO and a `/dev/zero`
      symlink were skipped in 0.14 s, and a protected file behind a symlinked
      output path was untouched.
  30. **My own SBOM comment was false:** a hash of a wheel's RECORD doesn't
      change when an installed file is edited. It identifies the build;
      `sgs-check`'s integrity check covers the files. The SBOM now says so.
  31. Smaller ones:
      - `release.sh` only worked on macOS (bsdtar flags, `shasum`). It now
        builds root-owned tarballs with GNU tar too, tested on krabs.
      - `awk -v` mangled backslashes.
      - Download URLs with a query string didn't match.
      - A reboot could follow a stale manifest; it now needs this run's
        success marker in `/run`.

  Nine signature cases on krabs: three genuine ones accepted, and six attacks
  refused for the right reason (rollback, wildcard signer, two signers,
  tampered checksums, wrong key, tampered tarball). Getting that test right
  took four attempts. In one, bash ignored `set -e` in a tested subshell; in
  another, the "tampering" changed nothing because the real hash already
  began with `0`. The wrapper now exits explicitly instead of relying on
  `set -e`.
- **Round E, through Hermes** (the agent harness already on krabs): a fresh
  regression review of `install.sh` and `sgs-check` after ten rounds of edits.
  - **How it was contained:** in one-shot mode Hermes loads its tools and
    auto-approves them. So it ran in a systemd sandbox:
    - `DynamicUser` and `NoNewPrivileges`
    - `ProtectSystem=strict`, home folders hidden
    - Hermes's own directory read-only
    - the `safe` toolset (no terminal or file tools)

    Before any model ran, a shell in the same sandbox was refused `sudo`,
    couldn't write `/etc` or `/opt/sgs`, and couldn't see the home folders.
    The OpenRouter key sat in a root-only file in `/run` for the run and was
    deleted after.
  - **Findings:** 20. Rejected: "Jupyter can't be found by process name"
    (krabs shows `jupyter-lab`, and the checks run), though the check now also
    uses the service's main PID. The real ones:
  32. **Two of my own earlier fixes were incomplete:**
      - The file integrity check still called a bare `python3`. Root's login
        PATH puts the stack's Python first, so it would have run the stack as
        root, the exact thing round B removed everywhere else.
      - The kernel-settings loop's error message went *into*
        `/etc/sysctl.d/60-sgs.conf`, since the loop's output is that file.

      Both fixed and tested.
  33. **Checks that went quiet or passed on nothing:**
      - A truncated `files.sha256` passed.
      - A crashed pin parser counted as "no pins".
      - A failed update-coverage test vanished.
      - Only the first installed driver branch got its end-of-life check.

      Now each one warns.
  34. **New checks:**
      - The Docker API listening on TCP (unauthenticated root).
      - A third-party source pinned above Ubuntu for every package.
      - A `sitecustomize` package, not just the `.py` file.
      - The tools environment and TensorFlow's CUDA folder must be root's.

      All five new states were planted on krabs and warned. The healthy run
      first also caught false positives in my pin check (Ubuntu Pro's ESM
      pins, a NodeSource pin for `nodejs`), so it now flags only all-package
      pins on third-party sources.
  35. **The two scripts contradicted each other:**
      - Extra SSH ports the installer opens were flagged by `sgs-check`.
      - `--no-driver` gave a permanent WARN (now a SKIP, via the manifest).
      - Application-profile firewall rules were misread.
  36. Installer:
      - The upfront file check missed five files.
      - `--user root` was accepted.
      - `systemctl enable` could abort the install before the audit rules.
      - A DKMS fallback under Secure Boot now warns up front.
      - Already-clashing apt sources are repaired before the first update.
- **Round F, through Hermes:** the README's and `design.md`'s claims checked
  against the code. 23 findings.
  - **Rejected after testing:**
    - "Any process named `systemd` is exempt on any port". The regex groups
      correctly; a test showed a `systemd` listener on 4444 still flagged.
    - "pip is never upgraded". The stack has pip 26.2.2, pinned in the
      lockfile with a hash.
    - The recurring "audit watches aren't recursive", already disproven in
      round A.
  37. **The docs promised more than `sgs-check` enforced,** now closed, each
      planted on krabs and caught:
      - A running container deliberately published on `0.0.0.0` was only a
        note, though the README says nothing but SSH is reachable. Now a WARN.
      - Firewall allow-rules beyond SSH weren't flagged.
      - The two apt keys pinned at install were never re-verified; a swapped
        Docker key now shows by its fingerprint.
      - Group-writable repository keys weren't flagged.
  38. Also:
      - The installed driver must be a build Ubuntu offers.
      - An installed-but-unloaded driver warns instead of silencing three
        checks.
      - Both apt jobs' time limits are checked, not one.
      - A never-completed update run warns three days after install.
      - `pip-audit` now covers the tools environment.
      - The update-coverage check covers CUDA, cuDNN and NCCL.
      - Missing core frameworks warn.
      - Jupyter is found through its unit even under another process name,
        and a running unit with no socket warns.
      - Lambda Stack is detected by its package and repository, not two
        filenames.
      - The installer no longer prints "updates applied" when they failed.
      - `--no-hardening` lists what it skips.
      - The README's install step says where the hash has to come from.
      - `design.md` states the login-shell-only `PATH` trade-off.
  39. **A regression I introduced, caught by the next reinstall:** moving the
      "updates applied" message left `[ -f /var/run/reboot-required ] &&
      NEED_REBOOT=1` as the hardening function's last line. With no reboot
      pending, that returned failure, and `set -e` stopped the installer.
      `sgs-check` still showed a good score, because the previous install's
      state was in place. Only the installer's exit code (1) gave it away,
      on krabs and on the VM. Fixed (an `if`), every function scanned for the
      same pattern, and the installer's exit code now checked on every run.
- **Found by running the fixes:** `sgs-jupyter`, the helper that prints the
  tunnel command, failed with "bad substitution" on every machine since v0.1.

### Round G: GPU device files for the video group only

The goal: `/dev/nvidia*` no longer open to every local user (`docs/design.md`
section 10). Each step was tested on krabs, across three reboots.

40. **Four things reopen the files,** found one at a time, each after the
    previous fix seemed to hold:
    - Ubuntu's udev rule, when the driver loads.
    - `nvidia-cdi-refresh.service`, at boot. Its capability set has no
      `CAP_CHOWN`, so a hook there needs systemd's `+`.
    - Any root process using the GPU, `sgs-check`'s own `nvidia-smi`
      included. NVIDIA's library resets the files from the driver's
      `DeviceFile*` options (default 0666). Fixed with module options.
    - The UVM files, which that library always resets to 0666. NVIDIA's
      source (`nvidia-modprobe-utils.c`) reads no options for them.
41. **Re-applying the mode afterwards wasn't enough.** A systemd path unit
    re-applied it after every change; a `nobody` process retrying `open()`
    still got in during 20 of 20 root `nvidia-smi` runs. Two more problems
    with it:
    - Every CUDA program, root or not, woke it.
    - Its service hit systemd's start limit within seconds.

    Replaced with a lock: a read-only bind mount of each file onto itself
    (findings 45–47 finish it).
    `chmod` and `chown` then fail, while the device opens normally. Results:
    - The attacker got in 0 times in 2.9 million tries, across 20 root
      `nvidia-smi` runs and 20 root CUDA starts.
    - Root's CUDA, including managed memory, still works.
    - udev starts the lock as a service: udevd's mounts are private
      (`PrivateMounts=yes`).
42. **A regression the restriction caused:** `nvidia-persistenced` failed at
    boot. It drops root with `setgid` and `setuid` and no `initgroups`, so
    adding its account to `video` did nothing. A
    `SupplementaryGroups=video` drop-in fixed it, and `sgs-check` now warns
    if it fails.
43. **The attack demo under-tested:** its `nobody` ran `nvidia-smi`, which
    fails as soon as `nvidiactl` is closed. It couldn't see an open
    `/dev/nvidia-uvm`. It now runs a looping attacker that tries every device
    file, for reading and for writing separately, while the admin uses the
    GPU. Negative control: with the protection removed, it FAILs.
44. **Edge cases tested:**
    - a stale UVM file with the wrong device numbers (replaced and locked)
    - a real `nvidia_uvm` reload (locked again, CUDA works)
    - a planted world-open unknown `/dev/nvidia*` node (reported, not
      touched)
    - containers as root and as uid 1000, through `--gpus` and CDI
    - Jupyter, which gets `video`
- **Open-model review of the code (round G):** 24 findings from GLM and
  DeepSeek.
  - **Taken:**
    - Check the exact owner and group, not just "not world-open". A
      `root:users` 0660 file would have passed.
    - Enforce the exact state on the CUDA files. The first version skipped
      any file without world access, and left a planted 0640 that locked
      the GPU's own users out.
    - Never change NVSwitch or NVLink files; only report them.
    - Run after a failed CDI refresh too (`ExecStopPost`).
    - Test reads and writes separately in the demo.
    - Fail, not pass, when sudo or SSH breaks mid-demo.
    - Document that other GPU users must join `video`.
    - Log when the video group is missing.
    - The trigger-limit problem in the path unit, moot once it was removed.
  - **Rejected after checking:**
    - "The driver-path udev match never fires." Ubuntu's own
      `ub-device-create` uses the same match, and replaying the event
      restored planted 0666 files.
    - "MIG capability files are created 0666." The driver reports 0400 and
      0444 (`/proc/driver/nvidia/capabilities`); 0444 is for monitoring, by
      design. `sgs-check` now flags only writable ones.
    - "`<(…)` breaks under sh": the installer is bash.
    - "The CDI spec can record the wrong group": Ubuntu fixes `video` at gid
      44, and the spec is regenerated at each boot.
    - Guarding the leftover-driver purge: it aborts like every other failed
      apt step.

45. **The boot window, found while reviewing the lock:** when the driver
    loads, Ubuntu's `ub-device-create` creates the files 0666, and the lock
    came about 45 ms later. On krabs the driver loads 3 seconds after
    services start. A `nobody` process waiting for the files got one open on
    10 of 10 fresh creations. `ub-device-create` is now diverted
    (`dpkg-divert`) to a version that creates them 0660 from the start: 0 in
    14 million tries, on a reload and after a real reboot.
46. **Mountinfo misled both the script and `sgs-check`.** A planted
    read-write remount let root's `chmod` through, while both still read
    "locked". The cause: `/dev`'s shared propagation had stacked three copies
    of the mount, and the last one listed wasn't the one in effect. Both now
    test the lock directly: on a 0660 file, `chmod 0660` changes nothing and
    fails exactly when the lock holds. A reinstall turned the three mounts
    back into one working lock.
47. **Unlocking a busy file would have hung.** A plain `umount` of a file
    someone has open fails ("target is busy"), and the unlock loop retried
    forever. It's lazy now (`umount -l`) and bounded. Tested with a process
    holding `/dev/nvidiactl` open: the file was repaired, and the process
    kept its handle.
- **Second open-model review (round G2), of the lock design:** 21 findings.
  - **Taken:**
    - The hang (finding 47).
    - Judge the mount in effect, not just any line; done by testing it
      (finding 46).
    - Exit non-zero when a file isn't right afterwards, so the installer's
      `die` can fire.
    - Warn on service accounts in `video`.
    - Try `O_RDWR` too in the demo.
    - Report a failed Fabric Manager enable instead of hiding it.
    - Verify the video-gid rewrite.
  - **Rejected after testing:**
    - "Root in a GPU container can `chmod` the host's file through its own
      mount." Containers get separate inodes on their own `/dev`; a root
      `chmod` inside both container types left the host file `660 video`.
    - "The driver-path udev match never fires," again. The boot journal
      shows the lock service starting with `nvidia-persistenced`, which the
      same event starts.
    - "Unlock before `nvidia-cdi-refresh` runs." That would reopen the
      window; the refresh succeeds with the files locked.
    - "`sgs-check` doesn't notice a deleted udev rule or drop-in." The
      installed-files check does, as planted earlier.
    - "Stale major numbers for `nvidiactl`": NVIDIA's major is fixed at 195.
      The script now compares every file's numbers anyway.
    - "The demo's `nvidia-smi -L` may not trigger the reset." It did, 20 of
      20 times.

### Round H: io_uring for root only

48. **io_uring was open to every user,** Ubuntu's default (`kernel.io_uring_disabled
    = 0`). It's now limited to root (setting 1). Checked before setting it:
    - A scan of every library in the stack found no use. PyTorch's one
      match was a false positive (the search for "uring" matched words like
      "during"); cuFile uses it only in an opt-in mode.
    - Ran with it on, as a normal user: a PyTorch `DataLoader` with 4
      worker processes, `tf.data` parallel file reads plus GPU math, JAX on
      CPU (identical with it off), a Jupyter kernel, a pip install, a uid-1000
      GPU container, and `sgs-check --gpu-test` (47 PASS, the same 3 WARNs).
    - A normal user's `io_uring_setup` now fails with "Operation not
      permitted"; root's still works.
    - A planted `0` is caught by `sgs-check`.

### Round I: JupyterLab on a private socket

49. **Every account on the machine could reach JupyterLab.** It listened on
    `127.0.0.1:8888`: `nobody` got HTTP 200 from it, and each kernel opened 6
    more localhost ports. The token stopped strangers, but a compromised
    service or an SSRF bug in another app could still talk to it. Now:
    - **The server** listens on `/run/sgs-jupyter/USER/jupyter.sock` (folder
      0700, socket 0600). `nobody` can't connect.
    - **Kernels** use the ipc transport, so 1 localhost port each instead of
      6. That one is ipykernel's subprocess-output pipe, hard-coded to TCP
      and gated by a random key.
    - **Tested end to end through OpenSSH from a Mac:**
      `ssh -L 8888:/run/sgs-jupyter/jm/jupyter.sock`, the lab page, a kernel,
      the websocket, and a TensorFlow cell on the GPU.
50. **`sgs-check` couldn't see every Jupyter.** It found servers by the name
    `ss` shows, which for `python -m jupyterlab` is just "python", and a
    socket-only server has no TCP line at all. Now:
    - Servers are found by command line.
    - Every listener is tested for the token.
    - Whether another account can connect is tested by connecting as
      `nobody`: with the socket planted at 0666 inside the 0700 folder,
      `nobody` still couldn't connect, so a permission-based check would have
      overstated it.
    - It warns if sshd forbids tunnels to sockets.

    Planted and caught: an opened folder and socket, `python -m jupyterlab`
    on a localhost port, and `AllowStreamLocalForwarding no`. A weak token
    file is now replaced.
51. **The installer failed when apt was busy.** A reinstall stopped with
    apt's exit code 100: another `apt-get` held the dpkg lock. On a fresh
    Lambda instance that's the normal first-boot situation, because Ubuntu's
    daily apt jobs and unattended-upgrades run just as cloud-init starts the
    installer. It now waits for apt's locks (up to 20 minutes) and passes
    `DPkg::Lock::Timeout`. Tested by holding the lock for 60 seconds: the
    installer waited, then finished (exit 0).
- **Open-model review (round I):** 20 findings.
  - **Taken:**
    - The detection gaps (finding 50).
    - Test every listener for the token.
    - Check the sshd forwarding settings.
    - The user checks expect 403 without the token and 200 with it, and skip
      when there's no network address.
    - `sgs-jupyter` takes the address from the default route, not
      `hostname -I`, which can list Docker's bridge first.
    - Clearer VS Code and PuTTY guidance.
    - Replace weak token files.
  - **Rejected after checking:**
    - "The token is in the journal" (both models). They misread the unit's
      comment: Jupyter logs a token it was given only as the literal
      `token=...`, and `sgs-check`'s journal check passes. The comment is
      reworded.
    - "Don't print the token in `sgs-jupyter`." Running it is asking for the
      login URL, the same one Jupyter prints.

### Round J: user namespaces, bypass included

52. **Ubuntu's user-namespace restriction had a way around it.** Ordinary
    users can't create user namespaces (`unshare -Ur` fails), but
    `aa-exec -p chrome -- unshare -Ur id -u` printed `0` for jm: Qualys's
    2025 bypass, through one of the 91 profiles that allow namespaces. The
    Lambda baseline VM is the same (`aa-exec -p 1password`). Ubuntu's `busybox`
    bypass was already closed.
    - **The fix:** `kernel.apparmor_restrict_unprivileged_unconfined = 1`.
      The `aa-exec` attempt now fails, while TensorFlow on the GPU, a PyTorch
      DataLoader, a uid-1000 GPU container and Jupyter all ran, with no
      AppArmor denials.
    - **`sgs-check`** tries both ways as `nobody`. Each setting planted at
      Ubuntu's weaker value turned into a WARN that names the way in.

### Round K: the native GPU stack's files

53. **Nothing checked the layer under the Python packages.** `sgs-check`
    verified every Python package file and the stack's own files, but not
    the driver's libraries, CUDA, cuDNN, NCCL, the container toolkit or
    Docker. A replaced `libcuda.so` would have passed.
    - **Now:** `dpkg --verify` over those 90 packages (5,832 files, 4.9 GB of
      CUDA) takes 15 seconds and found nothing on krabs. dpkg follows the
      diverted `ub-device-create` correctly.
    - **Planted:** a modified file and a missing file from a CUDA package,
      both caught by name; restored, `dpkg --verify` was clean again.
    - **Configuration files are left out** (editing them is normal).
    - **A pattern caught before it shipped:** `libcu*` also matched `libcurl`
      and `libcups`, so the CUDA libraries are named one by one.
    - **Corrected after review (GLM):** the first version claimed to cover
      the kernel module. It doesn't: Ubuntu assembles `nvidia.ko` at install,
      and no package owns it. Its signature check covers it. Also from that
      review: held packages now count, a dpkg error is reported instead of
      passing, and the `aa-exec` test tries up to three loaded profiles.

### Round L: line disciplines and ICMP redirects

54. **Any user could make the kernel load line-discipline modules,** on
    Ubuntu's 6.8 kernel (the cloud image's; krabs's HWE kernel already
    defaults to 0). On the stack VM an ordinary user attached PPP to a
    terminal, and the kernel loaded `ppp_async` and `slip` for them. With
    `dev.tty.ldisc_autoload = 0` both attempts are refused and nothing loads.
    The same VM also accepted ICMP redirects. Both are now pinned to 0.
    - **An installer bug avoided:** its loop only ever raised kernel
      settings, so it would have kept the cloud image's 1s. Settings whose
      strict value is 0 are now set as written. Verified on the VM: all 0
      after install, `sgs-check` 42 PASS / 0 WARN.
    - **Planted** `ldisc_autoload = 1` on krabs: caught by name.

### Round M: GPU memory between processes, and the J–K review

55. **GPU memory doesn't carry over between processes** on driver 580. A
    process filled 7,168 MB of the 8,107 MB GPU with a marker and exited.
    The next process, another user's, took the same 7,168 MB, so it had to
    get the first one's old pages, and read it back before writing to it.
    All zeros, no marker, twice. (A first version read only 256 MB, which
    could have landed on pages nobody had used; zeros there prove little.)
    A property verified, not a fix; `tests/gpu-memory-test.py` repeats it on
    Lambda's data-center GPUs, where MIG or other drivers could behave
    differently.
56. **Open-model review of rounds J and K:** 18 findings.
    - **Taken:**
      - The integrity record didn't cover the stack's own audit rules and
        kernel settings; it does now.
      - The audit check passed on any one `sgs-` rule; it now compares the
        loaded rules with the file. Its first version counted a comment
        line too and warned on the healthy machine, which the first healthy
        run caught.
      - `fs.protected_fifos` and `fs.protected_regular` were pinned but not
        checked.
      - The `aa-exec` test now picks the profile that holds the rule.
      - The installer also waits on apt's download lock.
    - **Rejected after checking:**
      - "`runc` isn't verified": it's in `containerd.io`, which is.
      - "An unprivileged `sgs-check` reports user namespaces as blocked":
        `sgs-check` refuses to run without root.
      - "`ptrace_scope = 1` breaks attaching to sibling ranks": it's Ubuntu's
        own default, and the trade-off is documented.
      - "`perf_event_paranoid` is checked but not pinned": a lowered value
        is a loosened state, and saying so is the point.
    - Planted on krabs: one audit rule removed at runtime, an edited kernel
      settings file, and `fs.protected_regular = 0`. All three were caught.

### Round N: the check re-runs daily

57. **The posture was only visible when someone ran `sgs-check`.** A daily
    timer now runs it, and the login message shows the latest result: the
    counts, the WARN lines, and a note if it's more than three days old.
    Tested on krabs:
    - the first run during the install
    - exit 1 (WARNs present) recorded as success, not as a failed unit
    - the login message showing krabs's three WARNs
    - the stale notice on a result aged five days, cleared by a fresh run
    - a disabled timer caught by `sgs-check`

58. **Two `sgs-check` runs at once reported each other as failures.** The VM
    test caught it: the installer's first daily run held apt's lock, and the
    next run said "automatic updates are failing". Runs now take turns (a
    lock; the second waits and says so), and the apt refresh waits up to 10
    minutes for Ubuntu's own apt jobs. Tested on krabs with both cases: the
    timer's run against a manual one, and apt's lock held for 40 seconds.
    Both results came out clean.
59. **Open-model review of rounds L to N:** 18 findings.
    - **Taken:**
      - **ICMP redirects** (both models): setting only `all` and `default`
        missed interfaces that already existed. On the VM, `enp0s1` still
        sent redirects and accepted IPv6 ones, and `sgs-check` passed. Now
        glob keys cover every interface, systemd's udev rule covers new ones
        (a container's `veth` came up at 0), and `sgs-check` reads each
        interface. A planted `wlp3s0` value was caught.
      - **The login message** strips anything but printable ASCII, so a WARN
        quoting a user-chosen file name can't send escape codes to the next
        person who logs in. A planted ESC sequence reached the terminal as 0
        bytes.
      - **A daily run that doesn't finish** keeps the previous result and
        fails visibly. Killed mid-run: the old result stayed.
      - **Bounded runtime:** `TimeoutStartSec=30min`.
      - **The full report is root-only;** the login summary still works
        through `pam_motd`, checked over a real OpenSSH login.
      - **The tests:** the GPU memory test fills 90% of the GPU (finding 55),
        and the sysctl comment no longer claims later files can't override
        it.
    - **Rejected after checking:**
      - "Oneshot units are killed at 90 s": oneshot start timeouts are off by
        default, and the first daily run took 103 s.
      - "Run the daily check unprivileged and under `NoNewPrivileges`": what
        it audits needs root, the parts that run untrusted code already drop
        to `nobody`, and `NoNewPrivileges` would make the `aa-exec` test pass
        falsely.
      - "A multi-line WARN could fake the result line": the summary takes the
        last result line, which `sgs-check` prints last.

### Round O: X11 forwarding, checked

60. **The stack turned X11 forwarding off, but nothing verified it.** Ubuntu's
    `sshd_config` turns it on, and the Lambda baseline VM has it on. Whoever
    takes over a machine with it on can reach the screen and keystrokes of
    anyone connected with `ssh -X`. `sgs-check` now checks it: PASS on krabs
    and the stack VM, WARN on the baseline.

### Round P: containers that are root on the machine

61. **`sgs-check` looked at what running containers publish, not what they
    can do.** Several common `docker run` options hand a container root over
    the host: `--privileged`, a mounted Docker socket (whoever reaches it
    starts any container), the host's PID namespace, and `CAP_SYS_ADMIN`.
    They turn up in copy-pasted GPU recipes. `sgs-check` now names each
    running container that has one, and why. Planted on krabs: three such
    containers, each named with its reason; an ordinary container next to
    them wasn't flagged. Host networking isn't flagged: the firewall still
    filters it, and multi-node NCCL often needs it.

### Round Q: a sandbox for the Jupyter service

62. **Notebook code ran with nearly everything a user process can do.** It
    couldn't `sudo`, but by systemd's own score the service was 8.5 EXPOSED,
    and a notebook could see 280 of other users' processes, the secrets in
    their command lines included.
    - **The sandbox:**
      - no capabilities
      - `/usr`, `/boot` and `/etc` read-only
      - kernel settings, modules, logs and cgroups untouchable
      - other users' processes hidden
      - no new namespaces
      - a syscall filter for clock, module, mount, reboot and raw-I/O calls
      - only Unix, IP and netlink sockets
      - devices limited to the GPU, DRM and terminals
    - **The score:** 2.2 OK.
    - **Through the tunnel on krabs, everything a notebook did before still
      worked:** TensorFlow on the GPU, a PyTorch DataLoader with worker
      processes, multiprocessing, `nvidia-smi`, writes to home and `/tmp`,
      DNS, `pip download` and a Jupyter terminal. Other users' processes
      visible: 0.
    - **Left out on purpose:** `MemoryDenyWriteExecute` (breaks JIT
      compilers), `RemoveIPC` (would delete the user's `/dev/shm` when
      Jupyter restarts) and `ProtectHome`.
    - **`sgs-check` reads the score,** so a drop-in can't weaken it unnoticed:
      a planted override scored 7.6 EXPOSED and was caught.
63. **Found while testing the sandbox: JAX crashed on a machine without the
    NVIDIA driver.** In a sandboxed kernel on the VM, `import jax.numpy`
    killed the kernel. The cause wasn't the sandbox: JAX segfaulted in a
    plain shell too. Its CUDA plugin crashes instead of falling back when no
    driver is loaded, as on a CPU-only machine or between the install and
    its first reboot.
    - **The fix:** the stack's startup hook sets `JAX_PLATFORMS=cpu` only
      when no NVIDIA driver is loaded, and never over the user's own value.
      On krabs, which has a driver, nothing changes.
    - **On the VM:** the kernel ran PyTorch, a DataLoader with workers and
      JAX in one cell, inside the sandbox.

64. **Open-model review of rounds O to Q:** 24 findings.
    - **Taken:**
      - **The sandbox check matched "SAFE" inside "UNSAFE"** (DeepSeek), so a
        gutted sandbox would have passed. It now compares the number (at most
        3.0; 2.2 as shipped), parsed by pattern rather than field position,
        and scores every Jupyter unit, running or not. A stopped one was
        still scored.
      - **The JAX default could misfire** (GLM). Decided once at startup, a
        Jupyter server started at boot before the driver loaded would have
        passed `JAX_PLATFORMS=cpu` to every later kernel, and JAX would have
        trained on the CPU without a word. It's now decided when `jax` is
        imported, in that process, and only if there's neither a driver nor
        `/dev/nvidiactl`. On the VM the server's environment stays clean, and
        JAX picks the CPU at import.
      - **The Docker socket from notebooks:** a user in the `docker` group
        (jm is) could have had notebook code take over the machine through
        it. The Jupyter service now can't reach it ("Permission denied"
        from a notebook; jm's own shell still can, which is krabs's existing
        WARN).
      - **SSH `Match` blocks** are now evaluated for the people who log in.
        A planted `Match User jm` turning X11 back on was caught.
      - **The container check** also covers host `/usr`, `/var`, `/run`,
        `/home`, `/proc` and `/sys` mounts, and the capabilities `SYS_MODULE`,
        `SYS_RAWIO` and `DAC_READ_SEARCH`. A planted `/proc` mount was caught.
      - **InfiniBand verbs** are allowed for multi-node NCCL (untested here;
        in the Lambda test plan), and the unit documents the workflows it
        blocks on purpose: FUSE mounts, rootless podman, the Docker CLI.
    - **Rejected after checking:**
      - "`--ipc=host` is root-equivalent": PyTorch's docs recommend it for
        DataLoaders, and it isn't root.
      - "`seccomp=unconfined` should be flagged as root": it widens the
        kernel's attack surface, but it isn't root on its own, and the
        message has to stay true.
      - "MIG capability files need write access": NVIDIA creates them
        0444/0400 itself.
      - "A drop-in adding `MemoryDenyWriteExecute` should be caught": that
        breaks JIT compilers, not security.

### Round R: a brand-new machine

65. **Every VM run so far reused one VM, with hours of state.** A brand-new
    Ubuntu 24.04 VM (`tests/test-local.sh sgs-fresh`) went through what a
    fresh Lambda instance would, and was then rebooted:
    - The install finished (exit 0).
    - The first daily check ran at install: 44 PASS / 0 WARN, shown in the
      login message.
    - The user checks passed (11; the two GPU checks don't apply without a
      GPU).
    - After the reboot: no failed units, Jupyter up on its 0600 socket in its
      sandbox, the timer active, every kernel setting applied, and ICMP
      redirects off on each interface, including the one that existed before
      the settings loaded. `sgs-check`: 44 PASS / 0 WARN.
    - One check behaves differently on a new machine, as designed: "Automatic
      updates haven't completed a run yet" is a note, not a WARN, for the
      first three days.

### Round S: the hardening's cost in speed

66. **The sandbox doesn't slow ML work down measurably.** The same script,
    three runs each, in a plain shell and in the sandboxed Jupyter kernel
    (through the tunnel):

    | Workload | Plain shell | Sandboxed kernel | Difference |
    |---|---|---|---|
    | TensorFlow fp32 matmul, 4096², on the GPU | 3.97, 3.97, 3.95 TFLOP/s | 3.94, 3.94, 3.94 | −0.5% |
    | PyTorch DataLoader, 4 workers | 67.7k, 69.4k, 68.7k samples/s | 66.3k, 65.8k, 69.2k | −2%, ranges overlap |

    The DataLoader is the syscall-heavy case, where a syscall filter would
    show up first. Both differences are within run-to-run spread. The
    comparison with Lambda Stack itself still needs a Lambda GPU
    (`docs/lambda-test-plan.md`).

### Round T: a threat model

67. **Deliverable 5 had no threat model.** `docs/threat-model.md` now says what
    the stack protects, from whom, and what it doesn't. Its claims point to
    the findings here. The open-model review found real overstatements, which
    are corrected: Jupyter's kernels keep one port; the GPU lock stops
    NVIDIA's library, not root; `torch.load` refuses code only by default;
    wheels-only stops install-time code, not malicious imports; a login
    banner proves nothing after a root compromise. It also found missing
    threats, now listed: cloud metadata, unencrypted multi-node NCCL,
    persistence through cron or user services, and leftovers in `/dev/shm`,
    swap and core dumps.

### Round U: strict outbound mode (experimental)

68. **Outbound traffic was unrestricted, the last design rule not built.**
    `sgs-egress strict` limits ordinary users and containers to allowed
    domains (`docs/design.md` section 11). On a VM, as an ordinary user:
    - **Still worked:** PyPI, `pip download`, Hugging Face's API, GitHub.
    - **Refused:** `example.com`, a raw address, a direct query to 8.8.8.8,
      a lookup of an unlisted name, and a container's request.
    - **After a reboot:** strict mode was back.
    - **`sgs-egress open`:** restored everything.
    - **Planted:** a missing firewall table was caught.
    - **First design flaw caught:** root's lookups go through the same
      resolver, so system services (Tailscale, Livepatch, snaps) need their
      domains listed; the default list now has them.
    - **Unresolved:** the long-lived `sgs-test` VM stopped accepting
      multipass's login after a reboot in strict mode, twice. sshd answered;
      a fresh VM with the same code came back normally through both kinds of
      reboot, and so did `sgs-test`'s exact sequence replayed on it: the old
      list first, the test suite and a container under strict mode, root's
      `apt-get update`, then `multipass restart`. So it's tied to that VM's
      accumulated state, which I can't inspect: its only other authorized key
      is gone. `sgs-test` is stopped, not deleted. Strict mode stays
      experimental until the cause is known.

### Round V: cloud metadata for root only

69. **Any process could reach a cloud metadata service.** On many clouds
    169.254.169.254 hands out credentials or the user data given at launch.
    The threat-model review raised it. Now a small nftables table, loaded
    before networking starts, refuses ordinary users and containers. Root
    keeps access, since cloud-init reads its configuration there. On a VM:
    - **Refused:** an ordinary user in 4 ms, and a container.
    - **Root:** passed the guard (it timed out only because the VM has no
      metadata service).
    - **At boot:** the guard loaded half a second before the network was
      prepared.
    - **Planted:** a stopped guard was caught.
    - **Scores:** the Lambda baseline gets a WARN; krabs 53 PASS / 3 WARN.

### Round W: where code makes itself permanent

70. **Nothing watched the places malicious code uses to come back.** A
    package or notebook running as you can add a cron job, a line in
    `~/.bashrc`, a user systemd unit or an SSH key, and return after
    everything is restarted. `sgs-check` now fingerprints these for root
    and every regular account, and reports what's new or changed since the
    record was last accepted. You check the change, then run
    `sudo sgs-check --accept-changes`. The installer records them as they are
    at install, and the daily check puts any change in the login message.
    - **On the VM:** a planted crontab entry, a `.bashrc` alias, an
      `authorized_keys` line and a user unit were each named, also in the
      login message. Restored exactly, the result was PASS again. A reviewed
      change was cleared by accepting it.
    - **On krabs** (22 files recorded): a planted user unit was named, and
      PASS came back when it was removed.
    - **A bug the healthy run exposed:** the first version reported unchanged
      files too. Only half the list was sorted before comparing, which
      `comm` complained about. Fixed by sorting the whole list.

### Round X: the V–W review, and containers on the host's network

71. **Open-model review of rounds V and W (24 findings), and the hole both
    models found first:** a container started with `--network host` sends
    from the host's own network, as root if it runs as root, so it passed
    both the metadata guard and strict mode.
    - **The fix:** Docker now puts every container under one systemd slice
      (`"cgroup-parent": "docker.slice"`), and nftables matches sockets by
      that cgroup. The slice has to exist when the rules load, so the guard
      waits for it; it kept the same identity through containers coming and
      going and a Docker restart.
    - **Tested on the VM:** a host-network container was refused metadata
      (as was a bridge one), and in strict mode both kinds were refused
      outbound connections, even to allowed sites.
    - **Tested on krabs:** GPU containers still work in every mode (`--gpus`,
      CDI, uid 1000, host network). A host-network container was refused
      metadata, against a 5-second timeout for root on the host, which the
      guard doesn't touch.
    - **Also taken:**
      - Symlink swaps and deleted startup files were invisible; now reported
        ("new or changed", "gone"), both planted and caught.
      - More persistence spots: `~/.local/share/systemd/user`, `~/.zshenv`,
        `~/.bash_aliases`, `~/.ssh/config`, `~/.gitconfig`, `/etc/sudoers.d`,
        plus `~/.local/bin`, Python `.pth` and customize hooks, `~/.ssh/rc`
        and `at` jobs from my own pass. Three of those were planted and
        caught.
      - Strict mode had let any user send UDP to any host on ports 67, 123
        and 547; now only the DHCP and time-sync accounts.
      - Its container rule had depended on bridge names; now it refuses new
        forwarded connections that leave by an uplink.
      - It recorded "on" before applying; now after.
      - `status` and `sgs-check` verify the resolver too.
      - The guard covers ECS's and GCP's IPv6 metadata addresses, and
        `sgs-check` verifies its rules, not just the table.
    - **My own mistakes caught by testing:**
      - A `${var:+…}` that ended at the first `}` and mangled a rule.
      - An nftables comparison of two interfaces that doesn't exist.
      - Two `set -e` traps that made `sgs-egress` exit silently.
    - **Rejected:**
      - Azure's 168.63.129.16, which Azure machines also use for DNS.
      - Root-only and `ACCEPT` concerns that `sgs-check` already handles.
      - Self-test fragility.

### Round Y: kernel lockdown

72. **Without Secure Boot, root could write kernel memory and load any
    module.** Ubuntu turns kernel lockdown on only under Secure Boot, which
    krabs has and cloud VMs usually don't. The Lambda baseline and stack VMs
    both ran with lockdown off. The installer now sets `lockdown=integrity`
    on the kernel command line when Secure Boot doesn't.
    - **On the VM:** after the reboot, root's `dd if=/dev/mem` and loading
      an unsigned module were refused. 0 failed units, 47 PASS / 0 WARN.
    - **On krabs:** already on from Secure Boot; the installer changes
      nothing there.
    - **A bug caught before it shipped:** the first version decided in the
      hardening step, which runs before the driver is installed. The driver
      falls back to a DKMS build on a kernel without Ubuntu's prebuilt
      modules, and lockdown refuses DKMS modules. Tested with a real one:
      DKMS signed it with the machine's own key, and lockdown still refused
      it, since that key isn't trusted without Secure Boot. On such a kernel
      the GPU would have been gone after the reboot. Now the decision comes
      after the driver, and a DKMS module keeps lockdown off.
    - **Tested end to end with that DKMS module:** refused under lockdown;
      the installer took lockdown back out; after the reboot the module
      loaded; module removed, installer re-run, reboot: lockdown on again,
      47 PASS / 0 WARN.
    - **`sgs-check`:** reports a module lockdown refused (an unsigned one,
      planted, was caught), with the right next step for its cause. A first
      version blamed Secure Boot for a VM's command-line lockdown; caught
      and fixed in the same test.
73. **A re-run of the installer accepted startup-file changes unseen.** It
    re-recorded the watched files on every run, so a cron job or `.bashrc`
    line planted between runs became part of the accepted record. Now it
    records them at the first install only (Round Z refines this). Tested: a
    `.bashrc` line planted before a re-run stayed reported.

### Round Z: the Y review, and more places where code persists

74. **Open-model review of Round Y (22 findings).** Both models named
    persistence spots `sgs-check` didn't watch, such as `/etc/ld.so.preload`,
    `/etc/cron.daily` and system-wide systemd units. Only root writes those,
    but so can a container with the host's files mounted, without being the
    careful attacker that could also fool `sgs-check`.
    - **Now watched:** 71 places, system-wide and in every account,
      including two of my own that matter on an ML machine: IPython startup
      scripts, which run in every notebook kernel, and Jupyter's `.py`
      configuration and kernel specs (`docs/design.md` section 8).
    - **The catch:** the installer and `sgs-egress` change watched files
      themselves. Re-recording everything at each install is finding 73's
      hole again. So each record line now says which watched place it's
      under. The installer and `sgs-egress` list the files before they run,
      and accept only what changed meanwhile, plus places a new version
      watches for the first time.
    - **Planted on the VM:** eight kinds of persistence (a `cron.daily`
      script, `/etc/ld.so.preload`, a system unit, a fake snap mount unit, an
      IPython startup script, Jupyter configuration, and autostart and
      `~/.local/bin` entries with a space and a newline in their names). All
      eight were named, and stayed named through an installer re-run, strict
      mode on and off, and an install of a release that changed a watched
      file. That file's change was accepted; nothing else was. Removed, the
      result was 47 PASS / 0 WARN.
    - **snapd:** it rewrites its mount units at every snap refresh. Those are
      left out only when they mount a snap under `/snap` and nothing else (a
      look-alike was reported). On krabs that keeps 78 files, and the churn
      they cause, out of the record.
    - **Also taken:**
      - The installer checks that GRUB's boot menu actually gained
        `lockdown=` and takes its file back out if not (a failing
        `update-grub` was simulated).
      - Whether lockdown is on is read from the kernel, not the command line.
      - A DKMS module under command-line lockdown is reported without waiting
        for the kernel's message.
      - Lockdown missing from the kernel is a WARN, not a SKIP.
      - Secure Boot machines are told what applies to DKMS modules and to
        `--no-lockdown`.
    - **Rejected:**
      - Locale-dependent sorting: `sgs-check` sets `LC_ALL` itself.
      - Unprivileged runs: `sgs-check` refuses to run without root.
      - Lockdown in recovery-mode boot entries: they're kept without it as a
        way back in from the console.
      - Setting lockdown under Secure Boot too, in case Secure Boot is later
        turned off: that needs the console.
      - A broader match for the kernel's refusal message: the exact one was
        verified on Ubuntu's 6.8 kernel, and a broader one would count
        `/dev/mem` refusals as broken devices.
      - `sgs-check` making a record when none exists: only root can delete it.

75. **A root container with `--ipc=host` reads every user's shared memory.**
    An earlier review called `--ipc=host` root-equivalent, and I rejected
    that (round Q): it isn't root. Measured this time, it still matters. On the
    VM, a root container started with `--ipc=host` read another user's
    private file in `/dev/shm`, where DataLoader workers and NCCL keep
    tensors; without the flag, or as a non-root user, it couldn't. PyTorch's
    docs suggest the flag for DataLoaders; `--shm-size` gives them the room
    without it. `sgs-check` now names such containers, and ones with the
    seccomp filter or AppArmor turned off, as "weakened isolation". That's a
    separate WARN, so "root over this machine" stays true. Five containers were
    planted, and exactly the two that should have been named were (plus the
    privileged one, under root).

### Round AA: core dumps (a tested non-finding, plus one pin)

76. **Can a crashing job leak its memory to another user through a core
    dump?** An ML process holds model weights and tokens in memory; a core
    dump is a copy of that memory. The worry: a crash writes a core file a
    second user on the shared machine can read. **Tested on the VM, and it
    doesn't happen:** with `core_pattern` set to a plain file and a user
    crashing a Python process holding a known token, the kernel wrote the
    core mode `0600` owned by the crashing user. A second user (`mallory`)
    found the token in it 0 times. Ubuntu's apport handler intercepts the
    dump entirely. So there's no cross-user leak to fix.
    - **The one thing worth pinning:** `fs.suid_dumpable = 0`. Ubuntu
      defaults to `2` (setuid programs may dump, to a root-only core); `0`
      means they don't dump at all, so a bug in a setuid program (sudo,
      mount, pkexec) can't spill privileged memory to a core. Standard
      server hardening (CIS), no effect on any ML workflow. `sgs-check`
      reads it with the other kernel settings; on the VM it shows `0` and
      "no setuid core dumps".
    - **Left as-is:** core dumps still happen for ordinary processes (they're
      useful for debugging a crash, and they're already `0600`). What a job
      leaves behind on disk — cores, `/dev/shm`, caches — is still the
      threat model's "data left behind" gap, not something the stack cleans.
    - **Why it's written down even though it's a non-finding:** testing a
      plausible-sounding worry and showing it's already handled is as much a
      result as a fix, and it keeps the next person from re-chasing it.

### Hardening added in the same round

Based on a research pass over NVIDIA, Docker and kernel guidance, each one
verified on krabs:

- Audit rules for package sources, sudo, SSH, Docker, the GPU container
  hooks, kernel settings, the stack and module loading. Before, auditd had no
  rules at all.
- Docker `no-new-privileges` and `icc: false`. Plus a check that the NVIDIA
  runtime isn't the default, so a container gets the GPU only when it asks.
- Jupyter refuses unauthenticated access on every endpoint
  (`allow_unauthenticated_access=False`), and `sgs-check` tests it.
- Pinned kernel settings (`/etc/sysctl.d/60-sgs.conf`), and GPU performance
  counters pinned to admin-only (CVE-2018-6260).
- `sgs-check` reports the NVIDIA module's signature and Secure Boot state, any
  pip config that adds a second index, and system CUDA libraries that could
  override the stack's.

## Scores on krabs

`sgs-check --gpu-test`. The PASS count goes up as checks are added, so
compare the WARNs:

| Run | PASS | WARN | SKIP | Notes |
|---|---|---|---|---|
| First install, original sgs-check | 19 | 4 | 1 | Hid findings 5–7 and 9 |
| First install, expanded sgs-check (round 0) | 27 | 8 | 2 | The honest baseline |
| Round 1: separate CUDA libraries, hardening | 32 | 3 | 2 | |
| Round 3: leftover cleanup, CDI refresh, check fixes | 34 | 2 | 2 | |
| Round 4: review fixes (more checks) | 35 | 3 | 2 | New WARN is krabs's `firecrawl_backend` network |
| Round 5: open-model review fixes (more checks) | 37 | 3 | 2 | Nine planted attacks: 12 WARNs, then back to 3 |
| Round 6: Jupyter token and sudo fixes, reinstalled | 39 | 3 | 2 | Clean arm64 VM, same code: 32 PASS, 0 WARN, 1 SKIP |
| Round 7: open-model round B fixes | 39 | 3 | 2 | GPU test and pip-audit now run unprivileged |
| Round 8: open-model round C fixes | 43 | 3 | 2 | Attack demo 7/7, with positive controls |
| Round 10: SBOM, release signing, round D fixes | 43 | 3 | 2 | Nine signature cases on krabs, all correct |
| Round 11: Hermes round E fixes (more checks) | 43 | 3 | 2 | Five planted states caught; false-positive pins fixed |
| Round 12: Hermes round F fixes (docs vs code) | 46 | 3 | 2 | Four planted states caught; a set -e regression caught and fixed |
| Round 13: GPU device files locked to video (round G, G2) | 47 | 3 | 2 | Four reboots; race 20/20 → 0, boot window 10/10 → 0; nine planted states caught |
| Round 14: io_uring for root only (round H) | 47 | 3 | 2 | ML workloads unchanged; planted 0 caught |
| Round 15: JupyterLab on a private socket (round I) | 47 | 3 | 2 | Attack demo 9/9, user checks 13/13; four planted states caught; apt-lock install failure fixed |
| Round 16: user namespaces, bypass closed (round J) | 48 | 3 | 2 | aa-exec bypass: uid 0 before, refused after; two planted states caught |
| Round 17: native GPU stack files checked (round K) | 49 | 3 | 2 | 90 packages, 15 s; modified and missing files caught |
| Round 18: line disciplines, ICMP redirects (round L) | 49 | 3 | 2 | VM: user loaded 2 modules before, refused after |
| Round 19: GPU memory test, J–K review fixes (round M) | 49 | 3 | 2 | No GPU memory carried over; three planted states caught |
| Round 20: daily check, result at login (round N) | 50 | 3 | 2 | Stale and disabled-timer cases caught |
| Round 21: L–N review fixes | 50 | 3 | 2 | Redirects on every interface; VM 43 PASS / 0 WARN |
| Round 22: fresh-boot regression, X11 check (round O) | 51 | 3 | 2 | Reboot: all settings and locks in place; attack demo 9/9 |
| Round 23: root-equivalent containers (round P) | 51 | 3 | 2 | Three planted containers named, an ordinary one not |
| Round 24: Jupyter sandbox, JAX on GPU-less machines (round Q) | 52 | 3 | 2 | Exposure 8.5 → 2.2; notebooks unchanged; VM 45 PASS / 0 WARN |
| Round 25: O–Q review fixes | 52 | 3 | 2 | Docker socket blocked from notebooks; three planted states caught |
| Round 26: install on a brand-new VM, then reboot (round R) | 52 | 3 | 2 | Fresh VM: 44 PASS / 0 WARN before and after the reboot |
| Round 27: sandbox overhead measured (round S) | 52 | 3 | 2 | GPU matmul −0.5%, DataLoader within noise |
| Rounds T–U: threat model, strict outbound mode (VM only) | 52 | 3 | 2 | Strict mode not enabled on krabs; VM: refusals and allowed sites as intended |
| Round V: cloud metadata for root only | 53 | 3 | 2 | User and container refused in milliseconds; baseline WARN |
| Round W: startup files watched for changes | 54 | 3 | 2 | Four kinds of planted persistence named, restored to PASS |
| Round X: V–W review, host-network containers | 54 | 3 | 2 | Host-network container refused metadata; GPU containers fine in docker.slice |
| Round Y: kernel lockdown (integrity) | 55 | 3 | 2 | Already on from Secure Boot on krabs; on the VM, a DKMS module was refused and the GPU was kept by backing lockdown out |
| Round Z: Y review, wider persistence watch | 55 | 3 | 2 | 71 places watched; eight planted persistences named; snapd churn excluded; `--ipc=host`-as-root containers flagged |
| Round AA: no setuid core dumps | 55 | 3 | 2 | The core-leak hypothesis was tested and disproved (cores are 0600); `fs.suid_dumpable=0` pinned as defence in depth |

The WARNs left are krabs's own, not the stack's:
- `jm` was in the docker group before the stack. The installer reports it but
  doesn't remove it; `sudo gpasswd -d jm docker` would.
- Two of the owner's services listen on all interfaces. The firewall blocks
  both from the network.
- An old Firecrawl project's Docker network, created before the fix, would
  publish on every interface if that project were started again
  (`docker network rm firecrawl_backend` once nothing uses it).

The two SKIPs are the GPU's age (see below).

Other tests, all on krabs:

- **User checks:** 13/13.
- **Attack demo** from another machine on the same network: 9/9, with positive
  controls (the machine is reachable, a deliberately public port is
  reachable). Jupyter
  isn't reachable directly, works through a tunnel to its socket, and another
  account on the machine can't reach it at all. Root and password
  logins are refused. `docker run -p` stays on localhost, and so does a port
  published on its own Docker network, as `docker compose` does. A `nobody`
  process retrying every GPU device file while the admin runs `sudo
  nvidia-smi` never gets in.
- **GPU containers:** both `--gpus all` and CDI `--device nvidia.com/gpu=all`
  run `nvidia-smi`, with `no-new-privileges` active inside. A container that
  sets `NVIDIA_VISIBLE_DEVICES=all` without asking gets no GPU.
- **TensorFlow:** 3.5–3.7 TFLOP/s fp32 matmul on the GPU, plus cuSOLVER (QR)
  on the GPU.
- **Each framework loads its own CUDA libraries.** PyTorch reports cuDNN 9.26,
  its CUDA 13 wheel; before the fix it would have loaded TensorFlow's 9.27.
  A TensorFlow process maps cuDNN, cuSOLVER and NCCL only from
  `/opt/sgs/tf-cuda12`. The same holds in a user's own `sgs-venv`
  environment. The hook adds no measurable Python startup time (10–20 ms
  either way).
- **A clean arm64 VM upgraded from v0.1:** 27 PASS, 0 WARN, 1 SKIP (no GPU).
  The environment rebuild works, and all 54,215 installed files match.

## What krabs can't prove

- **PyTorch and JAX on the GPU.** Their CUDA 13 builds need Turing (2018) or
  newer. cuDNN 9.27 has no Pascal kernels, so TensorFlow convolutions don't run
  on krabs either; its matrix and solver work does.
- **Whether separating the cuDNN and NCCL libraries is enough for PyTorch on a
  current GPU.** That, Fabric Manager and the performance comparison need a
  Lambda instance (`docs/lambda-test-plan.md`).
