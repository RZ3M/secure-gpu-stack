# Design decisions

Each decision names the Lambda Stack finding it answers (see
[lambda-stack-findings.md](lambda-stack-findings.md)) and the trade-off made.
"Strictness" is judged as we go; where a default could get in the way, that's
stated.

## 1. The NVIDIA driver comes from Ubuntu's archive, branch R580

- **Answers** findings 1 and 2: the driver security fixes Lambda's pin blocks,
  and Lambda's end-of-life R570 branch.
- **Choice:** Ubuntu's `-server` driver packages, R580, which NVIDIA supports
  until June 2028. Ubuntu signs them and ships fixes through `noble-security`.
  Where Ubuntu has prebuilt, signed kernel modules for the running kernel
  (`linux-modules-nvidia-580-server-open-<flavour>`), those are used, so no
  compiler runs at boot. Otherwise the installer falls back to DKMS.
- **Kernel flavour:** everything after `X.Y.Z-N-` in the kernel version, so
  `generic-64k` and `nvidia-64k` (arm64, as on GH200) resolve to their own
  prebuilt modules instead of falling back to an unsigned DKMS build.
- **Kernel line:** the module package must match the kernel line the machine
  follows, GA (`generic`) or HWE (`generic-hwe-24.04`, the default on recent
  desktop installs). Found on the krabs test bench: picking the GA package on
  an HWE machine pulled in an old 6.8 kernel just to have a driver, while the
  newest kernel, which boots by default, had none. The GPU would have been
  dead after the reboot. The installer now checks for the HWE kernel package.
- **Headers are required too.** Ubuntu's "prebuilt" modules are linked against
  their kernel during install, using `objtool` and `module.lds` from that
  kernel's headers package, but don't depend on it. On krabs the module
  package pulled in a newer kernel than the installed headers, and its setup
  failed. The installer now installs the headers meta package for the kernel
  line first, in its own step.
- **Leftovers from another driver branch are purged.** On krabs, libraries
  from the old R535 driver stayed installed. Their updates need the rest of
  R535, so apt held them back for good: unpatchable. The purge is simulated
  first and skipped if it would take anything else with it, such as a
  desktop's display driver. The installer also
  regenerates the GPU device spec for containers (CDI), which otherwise kept
  pointing at the removed files and broke every `docker run --gpus`.
- **Open vs closed modules:** Turing and newer GPUs get the open kernel modules,
  older ones the closed modules. This is the same rule Lambda's script uses.
- **GPUs older than Turing:** R580 still drives them, but CUDA 13 dropped
  Maxwell, Pascal and Volta, so the CUDA 13 framework builds have no code for
  them. The installer says so up front. Lambda handles its V100s the same way,
  with a separate "Legacy" image.
- **Trade-off: Ubuntu can lag NVIDIA.** On 2026-10-28, NVIDIA's CUDA
  repository had 580.196.07 while Ubuntu's `noble-security` had 580.178.04, the
  version NVIDIA's September 30 bulletin names as fixed. Without our pin, apt
  would take NVIDIA's build because its version number is higher. We prefer
  Ubuntu's: it's signed by Ubuntu, has prebuilt kernel modules that match
  Ubuntu's kernels, and is tracked by Ubuntu's security process. The cost is a
  delay of a few weeks before non-security driver releases arrive.
- **Trade-off:** driver security updates install automatically, like every other
  security update. Programs already running keep working, but new GPU programs
  fail with "driver/library version mismatch" until a reboot. `sgs-check` reports
  this. We chose patched-by-default over never-interrupted; a user who would
  rather schedule driver updates can hold the packages.

## 2. Package sources: HTTPS, one key per source, no override pins

- **Answers** findings 5, 6 and 7.
- **Keys:** each third-party key (NVIDIA CUDA, Docker) is downloaded over HTTPS,
  checked to be exactly one key with the expected full fingerprint, and stored
  in `/etc/apt/keyrings/`. Each source uses `Signed-By:`, so a key only vouches
  for its own repository.
- **NVIDIA's CUDA repository** supplies the toolkit, cuDNN, NCCL and the
  Container Toolkit. It also publishes driver packages under Ubuntu's names, so
  a pin at priority −1 stops apt from ever taking the driver from there (see
  `files/apt-pin-nvidia-cuda`).
- **NCCL:** published once per CUDA release. A pin at priority 600 prefers the
  CUDA 13.0 builds and still allows newer 13.0 builds to install. It's below
  1000, so it can never force a downgrade.
- **The installer refuses to run over Lambda Stack.** Lambda's pin would
  override our sources.
- **Existing entries for the same repositories are moved aside** (renamed to
  `.disabled`). Docker's install guide and NVIDIA's `cuda-keyring` package
  each add the repository with their own key file. A second entry with a
  different key makes apt refuse to run at all, which the krabs test bench
  hit with Docker's entry. Ours points at the same repository with a
  fingerprint-checked key.

## 3. The Python stack is isolated, read-only, hash-locked and wheels-only

- **Answers** finding 3 (stale packages with CVEs) and finding 7 (nothing
  verified).
- **Where:** `/opt/sgs/venv`, built from Ubuntu's own Python 3.12, owned by root.
  `/etc/profile.d/sgs.sh` puts it first on `PATH`, so `python3 -c "import torch"`
  works as on Lambda Stack. **Trade-off:** `/etc/profile.d` covers login shells only. Cron jobs,
  systemd units and `ssh host python3 ...` run the OS's Python unless they
  call `/opt/sgs/venv/bin/python` (the Jupyter service does). Lambda Stack,
  being the system Python, works everywhere; the isolation is the price.
- **How:** `pip install --require-hashes --only-binary :all: --no-deps` from a
  lockfile with a SHA-256 for every file. Only wheels are accepted, so no
  package build script runs during the install. There's a single index (PyPI),
  so there's no dependency confusion between indexes.
- **Versions:** current upstream (PyTorch 2.15.0, TensorFlow 2.21.0, Keras
  3.15.1, JAX 0.12.0.1). All 161 pinned packages had zero known vulnerabilities
  in OSV at lock time. pip itself is upgraded, because Ubuntu's venv ships pip
  24.0.
- **Two CUDA lines, kept apart:** TensorFlow 2.21 is built for CUDA 12;
  PyTorch 2.15 and JAX 0.12 for CUDA 13 (PyTorch 2.15 has no CUDA 12 build,
  and its last one lacks Blackwell support, so one shared line isn't an
  option). v0.1 said they "install side by side without conflicts". The krabs
  test bench proved that wrong: `nvidia-cudnn-cu12` and `nvidia-nccl-cu12`
  write the same 70 files as the CUDA 13 wheels, so pip silently replaced
  PyTorch's cuDNN and NCCL with TensorFlow's, and `pip check` reported nothing.
  TensorFlow's 12 CUDA wheels now have their own hash-locked folder,
  `/opt/sgs/tf-cuda12` (`python/tf-cuda12.in`).
- **TensorFlow's library loading:** TensorFlow opens CUDA libraries by name, and
  its search path doesn't reach that folder. It doesn't even reach its own
  cuSOLVER wheel in a stock install, so on any machine it either quietly fell
  back to the CPU or loaded a stray system copy. On krabs that was Ubuntu's
  CUDA 12.0 cuSOLVER, then the stack's own system-wide CUDA 13 cuDNN, and
  every GPU convolution failed. `files/sgs_cuda_preload.py`, run through a
  `.pth` hook just before tensorflow's own code runs, loads the folder's
  libraries by full path first. Nothing is added to the system library path.
  It fires on a real `import tensorflow` only. A first version also fired when
  code merely *asked* whether tensorflow was installed (`find_spec`, which
  Hugging Face `datasets` does), and then loaded TensorFlow's cuDNN and NCCL
  into PyTorch-only processes. An independent review caught that, and krabs
  confirmed it.
  **Trade-off:** cuDNN and NCCL keep the same library names across CUDA
  versions, so a single process that imports both PyTorch and TensorFlow gets
  whichever loaded first. Keep GPU work for the two in separate processes.
- **What's on disk is verified, not just what was downloaded:** `sgs-check`
  checks every installed file against the hash its wheel recorded, like
  `debsums` for Python. That's how the overwritten cuDNN and NCCL showed up,
  and it also catches files changed after the install.
- **Upgrades rebuild:** when a lockfile changes, the installer builds that
  environment fresh, because pip never removes packages a lockfile dropped. The
  old one is put back if the new one fails to build. If a run is interrupted
  mid-build, for example by a dropped SSH session, the next run restores the old
  one first, instead of deleting the only good copy.
- **Your own packages:** `sgs-venv ~/env` makes an environment that sees the
  whole stack and reuses its hash-verified pip. That's the equivalent of
  Lambda's `--system-site-packages` advice. The stack itself can't be changed
  by accident.
- **Security tools** (pip-audit, modelscan) live in a separate `/opt/sgs/tools`
  environment, so their dependencies can't shift the ML stack's versions.
- **Gap found while testing modelscan:** it catches booby-trapped `torch.save`
  files and plain pickles. But a plain pickle **renamed to `.pt`** is skipped
  with "No issues found!", because modelscan expects PyTorch's zip format.
  `torch.load` can still read that legacy format. The guard that actually holds
  is PyTorch's default `weights_only=True` loading (PyTorch 2.6 and later),
  which refused the payload in testing. Treat modelscan as a second opinion,
  not the gate.

## 4. flash-attn is left out

- **Answers** finding 8.
- Lambda ships flash-attn 2.7.4.post1. CVE-2026-31253 (High, insecure checkpoint
  deserialization) has no fixed release. It also has no prebuilt wheels on PyPI,
  so including it would mean running its build script during the install.
  Users who need it can install it in their own `sgs-venv` environment.

## 5. Jupyter listens on a private socket

- **Choice:** JupyterLab runs as a service for the main user, on a Unix
  socket only that user can open (`/run/sgs-jupyter/USER/jupyter.sock`: the
  folder is 0700, the socket 0600), with token authentication. You reach it
  with an SSH tunnel to the socket, `ssh -N -L 8888:/run/sgs-jupyter/USER/jupyter.sock
  USER@HOST`; `sgs-jupyter` prints the command and the URL. The assigner
  confirmed an SSH tunnel is acceptable.
- **Why not a localhost port:** `127.0.0.1:8888` (the first version) is
  reachable by every account on the machine: a compromised service, a web
  app tricked into making requests (SSRF), a container on the host network.
  On krabs, `nobody` got HTTP 200 from it; now it can't connect at all.
  Kernels moved off localhost too (`KernelManager.transport=ipc`, sockets in
  the same private folder): each kernel had 6 localhost ports, now 1.
  - **The port left** is ipykernel's pipe for output from forked
    subprocesses. It's hard-coded to TCP (`iostream.py`), and it drops any
    message without its random 16-byte key.
  - **Clients:** OpenSSH can forward to a Unix socket (tested from macOS).
    Windows' built-in `ssh` is OpenSSH too, untested here. PuTTY forwards
    only TCP ports; use Windows' `ssh` or WSL.
  - **VS Code Remote-SSH** doesn't need the server: it runs kernels from the
    stack's Python directly.
- **The token is required everywhere:** `allow_unauthenticated_access=False`,
  so an extension that forgets to protect its endpoints gets refused too
  (Jupyter Server defaults this to True). The socket keeps other accounts
  out, but not the user's own other processes or root, so the token still
  matters. `sgs-check` sends a request without the token and expects a
  refusal. It also warns if any Jupyter listens on a localhost port (one a
  user started by hand, say), or if its socket opens to other accounts.
- **The token stays out of the logs:** the service generates it once into
  `~/.local/share/jupyter/sgs-token` (mode 600) and passes it in. Jupyter writes
  a token it generated itself into the system journal as part of its startup
  URL, at a level `log_level` doesn't silence, where the `adm` group can read
  it. Delete the file and restart the service to rotate it.
- **A sandbox notebooks don't notice:**
  - **What it takes away:** capabilities, writes to `/usr`, `/boot` and
    `/etc`, kernel settings, modules and logs, new namespaces, other users'
    processes, clock, mount and raw-I/O syscalls, the Docker socket (root
    for anyone in the `docker` group), and every device but the GPU, DRM,
    InfiniBand verbs and terminals.
  - **On purpose, from a notebook:** no FUSE mounts, rootless podman or
    Docker CLI. Use an SSH session for those.
  - **The score:** systemd-analyze security went from 8.5 EXPOSED to 2.2 OK.
  - **What still works:** TensorFlow on the GPU, DataLoader workers, pip, DNS,
    the terminal. Tested through the tunnel on krabs and on the VM.
  - **Left out:** `MemoryDenyWriteExecute`, which breaks the JIT compilers
    (Triton, `torch.compile`, numba, JAX); `RemoveIPC`, which would delete
    the user's shared memory, a training run's included, whenever Jupyter
    restarts; and `ProtectHome`.
  - **`sgs-check`** reads the score of every Jupyter unit, running or not,
    and warns above 3.0, so a drop-in that weakens it shows up.
- **Notebook code can't become root:** `NoNewPrivileges` and `RestrictSUIDSGID`
  on the service. On Lambda the Jupyter user has passwordless sudo, so a
  malicious package or model loaded in a notebook would otherwise be one
  `sudo` away from root, and from rewriting `sgs-check` to lie.
  **Trade-off:** `!sudo ...` in a notebook fails; use an SSH session.
- **Trade-off:** Lambda Cloud's "Launch Jupyter" button won't work, because
  nothing is exposed for it to reach.

## 6. Docker can't open ports around the firewall

- **Choice:** `"ip": "127.0.0.1"` in `/etc/docker/daemon.json`, so
  `docker run -p 8888:8888` binds to localhost. Docker writes its own firewall
  rules, so without this a published port is open to the internet even with ufw
  on. To publish deliberately, use `-p 0.0.0.0:8080:8080`.
- **Every network, not just the default one:** `"ip"` only covers Docker's
  default bridge. `docker compose` creates a network per project, and ports
  published there went to `0.0.0.0` and `[::]`, around the firewall, while
  `sgs-check` said PASS. The review found it and krabs confirmed it.
  `default-network-opts` now makes localhost the binding for new networks too.
  Networks created before that keep the old behavior, so `sgs-check` names
  them (on krabs, a months-old `firecrawl_backend`). The attack demo now
  tests a compose-style network.
- **The owner's settings survive:** the stack's keys are merged into an
  existing `daemon.json`. Overwriting it on a re-run would have dropped
  settings such as a `data-root` on another disk.
- **docker group:** nobody is added; use `sudo docker`. Honest caveat: on a
  single-user Lambda instance where `ubuntu` already has passwordless sudo, this
  changes little. It matters on shared machines.
- **No privilege escalation inside containers:** `"no-new-privileges": true`,
  so setuid programs in an image can't raise privileges. **Trade-off:** `sudo`
  inside a container stops working, for example in devcontainers. Opt out per
  container with `--security-opt no-new-privileges=false`. Also
  `"icc": false`: containers on the default bridge can't talk to each other
  unless linked.
- **GPU only on request:** `nvidia` is never the default runtime. Otherwise
  any image that sets `NVIDIA_VISIBLE_DEVICES` gets the GPU and the toolkit's
  host-side hooks without `--gpus`, the path NVIDIAScape (CVE-2025-23266)
  abused. `sgs-check` also flags GPU device specs (CDI) that non-root users
  could edit.
- **Also:** log size limits (a noisy container can't fill the disk), and the
  NVIDIA runtime configured with `nvidia-ctk`.
- **Containers that are root on the machine are reported:** `sgs-check`
  names any running container started with `--privileged`, the Docker socket
  mounted, the host's PID namespace or `CAP_SYS_ADMIN`, the options that
  turn up in copy-pasted GPU recipes. Host networking isn't flagged: the
  firewall still filters it, and multi-node NCCL often needs it.

## 7. Host hardening, with lockout protection

- SSH: keys only, no root login, no X11 forwarding (Ubuntu turns it on;
  whoever takes over the server could reach the screen and keystrokes of
  anyone connected with `ssh -X`). This is applied **only if
  the main user has an authorized SSH key**, so the installer can't lock the
  owner out. The exception is a machine that had no SSH server before:
  nobody can be relying on its password logins, so it starts keys-only.
  Otherwise the installer would have added a password login to krabs, which
  until then was reachable only through Tailscale SSH. `MaxAuthTries` stays at
  OpenSSH's default of 6: v0.1's 3 locked out people whose ssh-agent offers
  several keys before the right one.
- Firewall: incoming traffic denied except SSH, on every port sshd listens on
  (opening only 22 would lock out a machine whose SSH is on another port).
  Lambda's cloud firewall stays
  as an outer layer. If Tailscale is running, its interface is allowed too:
  those peers are already authenticated and filtered by the tailnet's policy,
  and blocking them would break Tailscale SSH without adding protection.
- Daily automatic security updates, **with time limits.** apt's daily jobs are
  oneshot units, which systemd never times out. On krabs one hung download
  held apt's lock for 99 days, and nothing was patched while the settings
  still said "on". The download job gets 1 hour and the upgrade job 4 hours.
  `sgs-check` now checks that a run actually completed in the last 3 days,
  instead of only reading the settings. It also warns when apt can't refresh
  its lists at all, rather than reporting "no pending updates" from stale ones.
- **Docker and NVIDIA updates install themselves too.** Unattended upgrades
  only take Ubuntu's packages by default, so a Container Toolkit
  container-escape fix would have waited for a person.
  `/etc/apt/apt.conf.d/52sgs-unattended-upgrades` adds Docker's and NVIDIA's
  repositories by their exact Release labels, `Docker CE` and `NVIDIA CUDA`. A
  first version said "Docker" and "NVIDIA" and matched nothing. Because a
  pattern that matches nothing looks fine in the config, `sgs-check` asks
  unattended-upgrades itself whether those packages are covered. NVIDIA's
  driver packages stay blocked by the pin.
- **Audit rules for the machine's trust roots** (`/etc/audit/rules.d/60-sgs.rules`):
  package sources, sudo, SSH, Docker, the GPU container hooks, kernel module
  and sysctl settings, the stack's startup hook, `sgs-check` and the Jupyter
  service, and kernel module loading. Before this, auditd ran with no rules at
  all. `/dev/nvidia*` and `/var/lib/docker` are left out, since every CUDA
  program and image pull would flood the log. So is the rest of `/opt/sgs`:
  its ~60,000 package files would rotate the audit history out of the log on
  every upgrade, and `sgs-check`'s integrity check already covers them. Read
  the log with `sudo ausearch -k sgs-`.
- **Kernel settings pinned** (`/etc/sysctl.d/60-sgs.conf`): pointer and dmesg
  restrictions, no unprivileged BPF, ptrace scope, and protections for
  `/tmp`. Ubuntu already defaults to these. Pinning them means a tuning guide
  can't quietly loosen them, and `sgs-check` verifies them. The installer only
  ever raises a value: a stricter one already in place (`ptrace_scope=2`, or
  the one-way `unprivileged_bpf_disabled=1`, which the kernel won't change to 2)
  is kept, instead of being lowered or failing the install. **Trade-off:** GPU
  Xid errors in `dmesg` need `sudo`.
- **io_uring for root only** (`kernel.io_uring_disabled = 1`; Ubuntu lets
  everyone use it). io_uring is a fast I/O interface, and it was behind most
  kernel exploits in Google's kCTF program; Google turned it off on its
  servers. Setting 1 rather than 2 keeps it for root. Tested on krabs with it
  on:
  - a normal user gets "Operation not permitted";
  - a PyTorch `DataLoader` with worker processes, `tf.data` parallel reads
    with GPU math, JAX, a Jupyter kernel, pip, GPU containers and the
    machine's services all ran as before.

  Scanning every library in the stack found no use, apart from an opt-in
  cuFile mode (`CUFILE_PARAM_PREFER_IO_URING`); QEMU's tools are the only
  system users. To let a group use it, set `kernel.io_uring_group` in a later
  sysctl file. Docker's default seccomp profile already blocks it inside
  containers (tested); with this setting, so is a container started with
  `--security-opt seccomp=unconfined`, unless it's also privileged.
- **Cloud metadata for root only** (`/etc/sgs/guard.nft`, loaded by
  `sgs-guard.service` before networking starts). On many clouds
  169.254.169.254 hands out credentials or the user data given at launch. A
  malicious package, or a container a web request tricks into asking (SSRF),
  could read them. Ordinary users and containers are refused at once; root
  isn't, because cloud-init reads the machine's configuration there. A
  container on the host's network sends as the host would, often as root,
  so Docker puts every container under `docker.slice` and the rules match
  that cgroup too. Tested
  on a VM: refused in 4 ms for a user and a container, loaded before the
  network came up. `sgs-check` tries it as `nobody`. Whether Lambda runs such
  a service is in the Lambda test plan.
- **User namespaces closed to ordinary users, bypass included**
  (`kernel.apparmor_restrict_unprivileged_userns = 1`, Ubuntu's default, and
  `kernel.apparmor_restrict_unprivileged_unconfined = 1`, which Ubuntu leaves
  off).
  - **Why the second setting:** without it, any user can get a namespace with
    `aa-exec -p <a profile that allows them>`, the bypass Qualys published in
    2025. That gave a normal user uid 0 in a new namespace on krabs and on
    the Lambda baseline VM; with it, the attempt fails.
  - **What still works:** the stack, Docker, GPU containers and Jupyter, and
    there were no AppArmor denials.
  - **How `sgs-check` tests it:** as the attacker would, by trying both ways
    as `nobody`. It also warns if AppArmor itself is off, which would make
    the setting meaningless.
  - **On other kernels:** the keys are Ubuntu's, so they're written with
    systemd's `-` prefix and skipped quietly on a kernel without them.
- **Only root loads terminal line-discipline modules**
  (`dev.tty.ldisc_autoload = 0`). On Ubuntu's 6.8 kernel, which the cloud
  image runs, any user can make the kernel load one by attaching it to a
  terminal. On the test VM an ordinary user loaded `ppp_async` and `slip`
  this way; with the setting, the attempt is refused and nothing loads. Bugs
  in these modules (`n_hdlc`, `n_gsm`) have given local root before, and
  nothing in an ML stack uses them. krabs's newer kernel already defaults to 0.
- **No ICMP redirects**, accepted or sent (IPv4 and IPv6), on every
  interface. The Ubuntu cloud image accepts them, which lets another machine
  on the network reroute this one's traffic. Setting only `all` isn't enough:
  IPv4 sends a redirect if `all` or the interface allows it, and IPv6 reads
  only the interface. So the settings are glob keys, which systemd applies at
  boot and, through its udev rule, to each new interface (Docker's,
  Tailscale's). `sgs-check` reads every interface.
- **Why the installer treats these differently:** it only ever raises a
  kernel setting, so a stricter value already in place is kept. For these
  settings 0 is the strict value, so they're always set as written. The
  first version would have kept the cloud image's 1.
- **Kernel lockdown, integrity mode** (`/etc/default/grub.d/60-sgs-lockdown.cfg`).
  In lockdown, even root can't load a kernel module without a trusted
  signature, write kernel memory through `/dev/mem`, or start an unsigned
  kernel with kexec. Those are the ways a rootkit gets into the kernel, and
  around Secure Boot. Ubuntu turns lockdown on only with Secure Boot, which
  cloud VMs usually don't have. The stack sets it on the kernel command line
  otherwise.
  - **Tested on the VM:** after the reboot, root's `dd if=/dev/mem` and
    loading an unsigned module were both refused, with no failed services.
  - **What it costs:** hibernation, writing CPU registers (MSRs) and PCI
    configuration space from user space, and unsigned kernel modules.
    Nothing in the stack uses them. krabs runs in this mode under Secure
    Boot, with the whole stack and the GPU. `--no-lockdown` leaves it off.
  - **DKMS modules:** DKMS signs what it builds with the machine's own key,
    which the kernel trusts only once it's enrolled through Secure Boot. On
    the VM, lockdown refused a DKMS-built module. So the installer leaves
    lockdown off while DKMS modules are installed, and takes it back out on
    a re-run if one has arrived since.
  - **When the installer decides:** after installing the driver, which falls
    back to DKMS on a kernel without Ubuntu's prebuilt modules. The first
    version decided before that. On such a kernel the GPU would have been
    gone after the reboot.
  - **Only a boot menu that has it counts:** the installer checks that
    `grub.cfg` gained the setting, and takes its file back out otherwise.
  - **What `sgs-check` reports:** the mode; DKMS modules lockdown refuses,
    known without Secure Boot and, with it, from the kernel's message this
    boot; and why it's off.
  - **Limits:** recovery-mode boot entries are left without it, as a way back
    in from the console if a module is refused. Root can still remove the
    setting and reboot: lockdown keeps root out of the running kernel, not
    out of the next boot.
- **GPU performance counters are admin-only** (`NVreg_RestrictProfilingToAdminUsers=1`,
  CVE-2018-6260 side channel). The driver defaults to this. The pin stops a
  profiling guide's `=0` from undoing it unnoticed. Nsight Compute metrics
  need `sudo`. `sgs-check` also reports whether the NVIDIA module is signed and
  whether Secure Boot is on.
- **Setuid programs don't dump core** (`fs.suid_dumpable = 0`). A core dump is
  a copy of a process's memory, so on a shared GPU box the worry is a crash
  spilling one user's model weights or tokens into a file another user reads.
  Tested: it doesn't happen for ordinary processes — the kernel already writes
  cores mode `0600` to the crashing user (a second user read a planted token
  out of a core 0 times). The one gap left is a setuid program (sudo, mount,
  pkexec) whose core could hold privileged memory; `0` (Ubuntu defaults to `2`)
  stops those from dumping at all. No effect on ML work. What a job leaves on
  disk afterward — cores, `/dev/shm`, caches — is still an accepted gap (see
  the threat model).

## 8. sgs-check doesn't run what it audits as root

- `sgs-check` runs as root, and the stack's Python environments are exactly what
  it audits. Starting the stack's Python would run any `.pth` file planted in
  its site-packages, as root, before the check that looks for planted files.
- So package versions are read from metadata by the OS's own Python with site
  processing off. The GPU test and `pip-audit` run as the user who called sudo
  (or nobody), with a throwaway home directory. On krabs a planted `.pth`
  that records its user ran only as uid 1000.
- **Startup files are watched:** where code makes itself permanent. A change
  since the record was last accepted is a WARN, and so shows at login, until
  you check it and run `sudo sgs-check --accept-changes`. Only fingerprints
  are kept, root-only, in `/var/lib/sgs/startup-files`.
  - **In every account (root's too):** shell startup files, SSH authorized
    keys and `~/.ssh/rc`, user services, desktop autostart, `~/.local/bin`
    (first on PATH), Python `.pth` and customize hooks, and two that matter
    on an ML machine: IPython's startup scripts, which run in every notebook
    kernel, and Jupyter's `.py` configuration and kernel specs.
  - **System-wide:** cron, systemd units and generators, init scripts, sudo,
    `/etc/ld.so.preload` (a library loaded into every program), the login
    message scripts (run as root at every SSH login), PAM, SSH's
    configuration, apt hooks, udev rules, module options, and system Python
    hooks. Only root writes these, but so can a container with the host's
    files mounted, or a package installed with `sudo`.
  - **Left out:** snapd's mount units, rewritten at every snap refresh, but
    only when they mount a snap under `/snap` and nothing else. On krabs that
    kept 78 changing files out of the record; a look-alike that mounts
    something else is still reported.
  - **The stack's own changes:** the installer and `sgs-egress` change watched
    files themselves (units, the login message). They list the files before
    and accept only what changed meanwhile, plus places a new version
    watches for the first time. A change made before the run stays reported.
    (The first version re-recorded everything at every install, so a planted
    change was accepted by the next re-run.)
- Every check that could be skipped silently says so. A deleted file manifest
  is a WARN, not a missing line, and so are deleted package records.
- **The native GPU stack is checked too:**
  - **What:** the files of the driver's libraries, CUDA, cuDNN, NCCL, the
    container toolkit and Docker (90 packages on krabs), compared with the
    hashes dpkg recorded at install (`dpkg --verify`, about 15 seconds).
  - **Not the kernel module:** Ubuntu assembles `nvidia.ko` at install, so
    it isn't in dpkg's records (checked on krabs). Its signature and the
    kernel's unsigned-module flag cover it instead.
  - **Why:** without it, a replaced `libcuda.so` or `nvidia-container-cli`
    would pass, though the Python files above it are all checked.
  - **Left out:** configuration files, since editing those is normal.
  - **The limit:** a root attacker who also rewrites dpkg's records gets
    past it, as with pip's RECORD files.
- Each "fooling" technique the reviewers found is planted on the test bench
  before a fix counts as done: the check must turn it into a WARN.

- **It re-runs daily on its own** (`sgs-check.timer`):
  - **Where the result goes:** `/var/lib/sgs/last-check`, summarized in the
    login message (the counts and up to five WARN lines), with a note if
    it's more than three days old.
  - **Why:** a loosened setting, a stale driver or a new open port shows up
    the next time anyone logs in, not only when someone thinks to look.
  - **Exit 1 is a result, not a failure** (`SuccessExitStatus=1`), so a
    machine with WARNs doesn't show a failed unit every day.
  - **The first run** happens at install, after the file records it checks
    against are written.
  - **`sgs-check` warns** if the timer is off.
  - **What every user sees at login:** the counts and up to five WARN lines,
    as printable ASCII only, so a WARN that quotes a file name a user chose
    can't send escape codes to the next person's terminal. The full report
    is root-only; the login message is built as root (`pam_motd`).
  - **Runs take turns:** a manual `sgs-check` waits for the daily one, and
    the apt refresh waits for Ubuntu's own apt jobs, instead of reporting
    each other as failures. A run that doesn't finish keeps the previous
    result.

## 9. A verifiable install, and a record of what's installed

- `scripts/release.sh` builds a tarball, with root-owned files, and
  `SHA256SUMS`. The cloud-init wrapper for Lambda checks the hash before
  running anything, and refuses HTTPS-to-HTTP redirects.
- **Signed releases**, with plain `ssh-keygen` (already on every Ubuntu and
  macOS machine, so there's no extra tool to trust). With `SGS_SIGNING_KEY`
  set, `release.sh` signs `SHA256SUMS`. Given the release's public key (an
  `allowed_signers` line from the git repository, not the download host), the
  cloud-init wrapper verifies the signature and takes the hash from the signed
  file. A checksum fetched from the download host only catches corruption;
  the signature catches tampering. Tested on krabs with a throwaway key: the
  genuine release was accepted, and a tampered `SHA256SUMS`, a wrong key and
  a tampered tarball were all refused. A hash pinned in the user data must
  also match the signed one, so the host can't roll back to an older signed
  release, and the signer has to be one line for exactly
  `release@secure-gpu-stack`. **Still to decide:** who holds the real release
  key.
- **An SBOM of the installed machine.** `sgs-sbom` writes CycloneDX JSON
  covering every apt package and every Python package in the stack's three
  environments, each wheel with a hash of its RECORD. It describes what's
  actually installed, not what a lockfile asked for, and it reads metadata
  only, never running the packages. Since it runs as root over files packages
  put there, it reads only regular files, without following symlinks and with
  a size cap. It writes its output through a rename, and percent-encodes
  package names into the purls. The hash per wheel is of its RECORD file,
  which identifies the build. Edits to installed files are `sgs-check`'s job,
  not the SBOM's. The installer saves one to
  `/opt/sgs/sbom.cdx.json`. It works on Lambda Stack too: 1,024 components
  on the baseline VM, against 1,780 on krabs (a desktop install).

## 10. GPU device files for the video group only

- **The problem:** Ubuntu creates `/dev/nvidia*` mode 0666, so every local
  user and every service account (a web app's, a model server's, `nobody`)
  can talk to the NVIDIA kernel driver. NVIDIA's security bulletins regularly
  fix bugs reachable that way. Lambda's docs don't mention it; the baseline
  VM has no GPU, so whether Lambda Stack keeps 0666 is checked on a Lambda
  instance (`docs/lambda-test-plan.md`).
- **The fix:** the files CUDA uses (`nvidiactl`, `nvidia0`…, `nvidia-modeset`,
  `nvidia-uvm`, `nvidia-uvm-tools`) are `root:video` 0660, and each is
  **locked with a read-only bind mount onto itself**. On a read-only mount
  `chmod` and `chown` fail, but opening a device for reading and writing
  still works (the kernel's read-only rule covers files, folders and
  symlinks, not devices). The installer adds the Jupyter user to `video`; GPU
  containers keep working as root and as other users, through `--gpus` and
  CDI alike, because the NVIDIA Container Toolkit gives the container the
  device's group.
- **Why the lock:** four things create or reset the files, all found on
  krabs:
  1. Ubuntu's `ub-device-create`, which udev runs when the driver loads. It
     creates them 0666 and reads no driver options.
  2. `nvidia-cdi-refresh.service` (`nvidia-ctk system create-device-nodes`),
     at boot.
  3. Any root process using the GPU (`sudo nvidia-smi`, `sgs-check` itself):
     NVIDIA's library resets the files to the driver's `DeviceFile*` options,
     default 0666. `/etc/modprobe.d/sgs-nvidia.conf` sets those to `video`
     and 0660, from the next boot on.
  4. The same library always resets the UVM files to 0666: it reads no
     options for them (`nvidia-modprobe-utils.c`).

  The first version set the mode again after each of these (a udev rule, a
  CDI drop-in and a systemd path unit). Measured on krabs with a `nobody`
  process retrying `open()`:

  | Moment | Re-applying the mode | Final design |
  |---|---|---|
  | Root uses the GPU | got in during 20 of 20 runs | 0 in 2.9 million tries |
  | Files first created (as at boot) | got in 10 of 10 times | 0 in 14 million tries |

- **When it's applied:**
  - **Creation:** `ub-device-create` is diverted (`dpkg-divert`, so package
    updates land beside it) to `sgs-gpu-devices --no-lock`. That creates each
    missing file with `mknod -m 0660` and then gives it to `video`, so it's
    never open to others.
  - **Locking** needs the host's mount namespace: mounts made inside
    `systemd-udevd` stay in its private one. So udev starts
    `sgs-gpu-devices.service` when the driver or `nvidia_uvm` loads, ordered
    before `nvidia-cdi-refresh` and `nvidia-persistenced`.
  - **Afterwards:** a drop-in runs it after every `nvidia-cdi-refresh` run,
    failed or not, and the installer runs it once.
  - **Stale files:** if a file has the wrong device numbers (`nvidia_uvm`
    reloaded with a new major), it's replaced.
  - **Busy files:** unlocking is lazy (`umount -l`), since an open file makes
    a plain unmount fail.
  - **Checking the lock** is functional, not read from mountinfo: `/dev`'s
    shared propagation can stack copies of a mount, and the last one listed
    isn't always the one a path reaches. On a file that's already 0660,
    `chmod 0660` changes nothing and fails exactly when the lock holds.
- **What the lock is not:** a barrier against root. Root can unmount it. It
  stops NVIDIA's library, which runs as root whenever root uses the GPU.
  Containers get their own device files (separate inodes on the container's
  `/dev`), so a root `chmod` inside a GPU container changes nothing on the
  host. Tested with `--gpus` and CDI.
- **What it costs:** `nvidia-persistenced` drops root without its account's
  groups (`setgid` and `setuid`, no `initgroups`), so it failed until a
  drop-in gave it `SupplementaryGroups=video`. Users other than the install
  user (more people, or Slurm job users) need `sudo usermod -aG video NAME`.
  To change a file's mode by hand, unmount it first (`sudo umount
  /dev/nvidia0`); `sgs-gpu-devices` puts both back.
- **What it doesn't cover:** other `/dev/nvidia*` files (NVSwitch, NVLink,
  vGPU) are left as they are, since who needs them is untested here (krabs
  has none); `sgs-check` warns if any is open to everyone. MIG capability
  files under `/dev/nvidia-caps` are readable by everyone by NVIDIA's design
  (MIG monitoring); `sgs-check` warns only if one is writable.
- **Checked by:** `sgs-check`:
  - no world-open device file
  - the CUDA files exactly `root:video` 0660, and locked
  - the driver options loaded
  - `ub-device-create` diverted
  - no service account in `video`
  - `nvidia-persistenced` not failing

  Also `tests/user-checks.sh`, and the attack demo, whose `nobody` process
  keeps trying to open every device file while an admin runs `sudo
  nvidia-smi`.

## 11. An optional strict mode for outbound traffic (experimental)

- **What it's for:** sensitive work, where data and credentials mustn't leave
  the machine. Off by default; `sudo sgs-egress strict` turns it on,
  `sudo sgs-egress open` turns it off, and it survives reboots.
- **How it works:** a local resolver (dnsmasq) answers only for the domains in
  `/etc/sgs/egress-allow` (PyPI, PyTorch, Hugging Face, GitHub, Ubuntu, NVIDIA,
  Docker, Canonical and Tailscale by default), and adds their addresses to an
  nftables set as it looks them up. Ordinary users' programs may then open
  HTTP and HTTPS connections only to addresses in that set. Domain names, not
  addresses, because CDN addresses change all the time.
- **What it refuses**, tested on a VM as an ordinary user: any other domain,
  raw IP addresses, DNS queries to other servers, and lookups of names not on
  the list, so DNS can't carry data out either. Containers get no new
  outbound connections, those on the host's network included (matched by
  their `docker.slice` cgroup). Allowed sites, `pip download` and Hugging Face's API
  kept working. DHCP, NTP and IPv6 neighbor discovery are allowed, so the
  machine stays on the network.
- **Root:** its traffic isn't filtered (root is out of scope), but its lookups
  go through the same resolver. That's why the list includes what the system
  itself needs.
- **Limits:**
  - A domain on a shared CDN shares its addresses with other sites there.
  - A program can still leak a little through which allowed names it looks
    up.
  - Upstream DNS servers are read when strict mode starts, so a network
    change needs `sudo sgs-egress strict` again.
- **Why "experimental":** one long-lived test VM stopped accepting multipass's
  login after a reboot in strict mode (sshd answered, but multipass's session
  never came up), twice. A fresh VM with the same code came back normally
  through both kinds of reboot, and I couldn't look inside the first one.
  Until that's understood, try strict mode on a disposable machine first,
  and keep a second way in (the provider's console) before rebooting with it
  on.
- **Checked by `sgs-check`:** with strict mode on, an ordinary account trying
  a raw address must be refused, and a missing firewall table or resolver is
  a WARN. With it off, a note says how to turn it on.

## Not done yet (v0.2 candidates)

- **A release key and where it lives** (the signing mechanism is in
  `release.sh`; see section 9).
- **Our own signed apt repository**, so `apt upgrade` updates the Python stack
  the way it does on Lambda Stack. Today, updating means running a newer
  `install.sh`.
- **GPU validation on a current GPU.** krabs (GTX 1070, Pascal) proved the
  driver install path, Secure Boot signing, the container toolkit and
  TensorFlow on the GPU. PyTorch and JAX need Turing or newer, cuDNN 9.27 has
  no Pascal kernels, and the cuDNN/NCCL separation matters most for PyTorch
  on those GPUs. Still to do on a Lambda instance: a PyTorch convolution and
  NCCL test with the separated libraries, Fabric Manager on NVSwitch systems,
  and the performance comparison with Lambda Stack.
- **uv in the tools environment**, whose default index strategy blocks
  dependency confusion when users add a second index (for example PyTorch's).
