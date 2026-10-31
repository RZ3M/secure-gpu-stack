# Secure GPU stack: a security-first alternative to Lambda Stack

Project context for Claude sessions in this folder. Keep it current as decisions
are made.

## The task

- **The challenge:** an employer challenge. Build a software stack for GPU
  machines that is **similar to Lambda Stack, an alternative to it**, but with
  security built in.
- **What Lambda Stack is:** NVIDIA driver, CUDA, cuDNN, NCCL, PyTorch,
  TensorFlow, JAX, JupyterLab and Docker. ML engineers get one install and
  everything works.
- **Our version:** the same experience and the same tools. The difference is
  that the defaults are safe, and we can prove it.
- **Feedback (2026-10-28):** the assigner wants it similar to Lambda Stack, an
  alternative to it. This replaced an earlier plan for a locked-down
  inference-only appliance.
- **Who uses it:** people who already rent GPUs on Lambda. They'd install this
  instead of Lambda Stack (confirmed 2026-10-28). So it has to work on Lambda's
  instances and feel familiar to Lambda Stack users.
- **The company:** called "blackbox" by the user. It sells inference.
- **In scope:** the machine and its software stack: OS, NVIDIA driver and CUDA,
  ML frameworks, Jupyter, Docker, Python packaging, and the network.
- **Out of scope:** model and agent behavior (guardrails, jailbreaks,
  red-teaming). NVIDIA NeMo Helix was considered and set aside for that reason.
- **GPUs:** rented on Lambda (lambda.ai) with a corporate card. The user handles
  account signup and payment; Claude never enters card details. A Lambda API key,
  when there is one, lives in an environment variable such as `LAMBDA_API_KEY`,
  never in a file.

## Lambda Stack, the thing we're matching (checked 2026-10-27)

- **Versions at last check:** PyTorch 2.7.0, TensorFlow 2.19.0, Keras 3.10.0,
  JAX 0.6.0, Triton 3.3.0, CUDA 12.8, NCCL 2.26.2, NVIDIA Container Toolkit
  1.18.1.
- **How it's installed:** a one-line install script on Ubuntu. The script
  detects the hardware, installs matching drivers and firmware (Fabric Manager on
  NVSwitch systems), and pulls the frameworks in as apt packages such as
  `python3-torch-cuda`. Updates come through `apt`.
- **On Lambda Cloud:** it's preinstalled, along with JupyterLab, Git, Vim, tmux
  and build-essential.
- **Security:** the docs don't say anything about it.

## Lambda Cloud facts (from docs.lambda.ai, checked 2026-10-27)

- **Base images:** there's no documented way to upload a custom image. The API
  offers four:
  - **Lambda Stack:** the default.
  - **Lambda Stack Legacy:** for V100s.
  - **GPU Base:** driver, CUDA, cuDNN, NCCL, Docker.
  - **Ubuntu Server:** plain Ubuntu.

  Each comes in 22.04 and 24.04. Only Lambda Stack also has an arm64 build.
- **cloud-init:** user data can be passed at launch, through the API only.
- **Network:** by default only port 22 is open. Firewall rules (global and
  per-instance) are managed in the console or the API.
- **Patching:** Lambda's own docs say `apt full-upgrade` and `dist-upgrade`
  currently fail on Lambda Stack 24.04 and GPU Base 24.04. That's a finding
  worth highlighting.

## Approach

Confirmed 2026-10-28: ship it the same way Lambda Stack ships, with everything
Lambda Stack includes.

1. **Install script:** one command that turns any Ubuntu 24.04 GPU machine into
   the full stack. Lambda's is a `curl | sh` one-liner. Ours should be just as
   easy, but verifiable: the script has a published checksum and signature, so
   users can check it before running it.
2. **Updates through apt:** matching Lambda Stack means users update with
   `apt upgrade`. A signed apt repo with a meta-package is the long-term way to
   get there. Version 1 can be the install script plus pinned upstream repos.
3. **cloud-init wrapper:** runs the install script at launch on Lambda's plain
   Ubuntu Server image. Lambda doesn't allow uploading custom images, so this is
   the closest to "preinstalled".
4. **Release manifest:** every pinned version, plus an SBOM and a vulnerability
   report for each release.

**Open decision: where the Python frameworks live.** Lambda puts PyTorch,
TensorFlow and JAX in the system Python. Options:
- **Match Lambda:** easiest compatibility.
- **A dedicated environment that's on by default:** for example
  `/opt/<stack>/venv` on everyone's PATH. `import torch` still just works, but
  the frameworks stay separate from the OS's Python.

## Design rules: the same tools, safe defaults

1. **Same experience:** the same tools and roughly the same versions as Lambda
   Stack. If a researcher's code runs there, it runs here.
2. **Trustworthy sources:** everything comes from signed repos (NVIDIA, Ubuntu,
   PyPI) at pinned versions listed in the published manifest.
3. **Patching that works:** security updates are on automatically. The GPU
   driver and CUDA are pinned so updates can't break them.
4. **Nothing exposed by default:**
   - Jupyter listens only on a Unix socket its user can open (Round I; it was
     localhost); users reach it through an SSH tunnel to the socket.
     The tunnel is confirmed acceptable. How strict the other defaults should
     be gets decided as we go.
   - The firewall denies incoming traffic except SSH.
   - SSH is key-only, and root can't log in.
5. **Least privilege:** no `docker` group (it's root-equivalent), so Docker runs
   rootless or through sudo. Keep the NVIDIA Container Toolkit current; it has
   had container-escape CVEs.
6. **Safer Python and models:**
   - Frameworks live in a virtual environment, not the system Python.
   - Installs are hash-checked, pip only talks to known indexes, and `pip-audit`
     is available.
   - Model loading defaults to safetensors and `torch.load(weights_only=True)`,
     and `modelscan` is installed.
7. **Secrets hygiene:** a secret scanner (gitleaks) is installed, token files
   get restrictive permissions, and the docs cover handling HF, W&B and cloud
   keys. (Found on Lambda, 2026-10-30: gitleaks was never actually shipped;
   it's a v0.2 candidate in `docs/design.md`.)
8. **Visibility:** `auditd` logging, plus a check command that shows the
   machine's security posture. An optional strict mode restricts outbound
   traffic for sensitive work.

## Deliverables

1. The install script and the cloud-init wrapper.
2. A release manifest (pinned versions), an SBOM and a vulnerability scan.
3. The security check command, grown out of `exercise-01/look-around.sh`.
4. A comparison report, Lambda Stack vs. ours:
   - the security checks and simple attack demos
   - proof the same ML code runs (PyTorch and JAX on the GPU, Jupyter)
   - performance parity on a benchmark
5. A threat model and a quickstart guide.

## Where things are (v0.1, branch `stack/v0.1`)

- **On GitHub:** `RZ3M/secure-gpu-stack` (public since 2026-10-29). The v0.1.0 release holds
  the walkthrough videos and the first install tarball. v0.1.1 (2026-10-29,
  with the M2 fixes) is the current tarball, and holds the M2 update video;
  the tarball's SHA-256 is in the annotated `v0.1.1` tag. The branch is at
  0.1.2 (the Lambda round, 2026-10-30), not yet released.
- **Walkthrough videos:** `video/` (8:50) and `video/m2/` (the M2 update,
  3:38); see `video/README.md`.
- **Goal and success criteria:** `README.md`.
- **Findings about Lambda Stack, with evidence:** `docs/lambda-stack-findings.md`;
  real-instance audit: `docs/lambda-instance-audit.md`; verified attack
  chain/PoCs: `docs/lambda-instance-pocs.md`; `sgs-check` gaps and scoring:
  `docs/sgs-check-gaps.md`; raw domain reports: `docs/audit/`.
- **Design decisions and trade-offs:** `docs/design.md`.
- **Threat model** (who the stack protects against, and what it doesn't): `docs/threat-model.md`.
- **The installer and its config:** `install.sh`, `files/`.
- **Commands installed on the machine:** `bin/` (`sgs-check`, `sgs-venv`,
  `sgs-jupyter`, `sgs-sbom`).
- **Python lockfiles:** `python/`. Regenerate with `python/lock.sh`, which needs
  uv. The lockfiles were generated in a Multipass VM.
- **Local VM test:** `tests/test-local.sh`. Results land in `tests/results/`.
- **GPU tests:** `tests/gpu-smoke.py` (PyTorch, JAX or TensorFlow, one per
  process), `tests/gpu-bench.py` (training speed), `tests/jupyter-cell.py`
  (runs a cell through the Jupyter tunnel, as a browser does).
- **Release tarball and checksum:** `scripts/release.sh`. Signs `SHA256SUMS`
  when `SGS_SIGNING_KEY` points at an SSH ed25519 key (no real key exists yet).
- **Open-weight model review harness:** `scripts/model-review.py` sends the
  named files to DeepSeek and GLM through OpenRouter. The key is in `.env`
  (`OPENROUTER_API_KEY=`, mode 600, gitignored); never print it. Output lands in
  `tests/results/model-review/`. Treat the findings as untrusted until they're
  verified on krabs; several were wrong. If OpenRouter credits run out, use
  Claude (Sonnet) subagents instead, as the user asked.
- **Hermes, as a second harness on krabs:** in one-shot mode (`-z`) Hermes loads
  its tools and auto-approves them, so it only ever runs inside a systemd
  sandbox:
  - `DynamicUser` and `NoNewPrivileges`
  - `ProtectSystem=strict`, `ProtectHome=tmpfs`
  - Hermes's install directory bound read-only
  - `-t safe` (no terminal or file tools), `--safe-mode`

  The OpenRouter key goes to a root-only file in `/run` for the run and is
  deleted afterwards. Prove the sandbox first (try sudo, writing `/etc`,
  reading home), then run the review.
- **Lambda first-boot wrapper:** `cloud-init/lambda-user-data.yaml`.
- **The stack on real Lambda hardware:** `docs/lambda-test-bench.md` (findings
  86–90, re-proved earlier findings, speed, Lambda's first-boot vendor data,
  testing gotchas such as `ausearch --input-logs` over `ssh`).
- **What we did with the Lambda Stack audit:** `docs/lambda-audit-response.md`
  (every audit finding and G-gap with its status, the `sgs-check` severity
  model, the PoC replays on B, findings 91–92, what was declined and why).
- **Lambda baseline VM** (`lambda-probe`): Lambda's repository plus its CPU
  Python packages. Not the full CUDA stack, since that needs accepting the cuDNN
  license. `sgs-check` runs there with `SGS_PIP_AUDIT=/tmp/audit/bin/pip-audit`,
  which must be root-owned (create `/tmp/audit` with sudo; `/tmp` clears on reboot).
- **Real-GPU test bench: krabs.** The user's laptop (x86-64, GTX 1070 Max-Q,
  Pascal, compute capability 6.1), reached over Tailscale as
  `jm@krabs.tail50f3a6.ts.net` (Tailscale SSH; the user's Mac key also works
  on its LAN address, 10.0.0.237). It runs the full stack. Results and
  install logs are in `~/sgs-testbench/results/` on krabs, and findings are
  in `docs/krabs-test-bench.md`. Run commands there with
  `ssh -o BatchMode=yes jm@krabs.tail50f3a6.ts.net '...'`, with the Bash
  sandbox disabled. Notes:
  - Lid-close suspend and all sleep targets are disabled (it's a server).
  - Passwordless sudo is temporary (`/etc/sudoers.d/90-setup-temp`, removed
    by a timer). Never type the user's password.
  - PyTorch and JAX can't use Pascal; TensorFlow can, except convolutions.
  - After a reboot (four for the Round G boot-path tests, 2026-10-29) it's back
    on Tailscale in about a minute, and the owner's services (ports 8765,
    9377) start on boot.
- **Second GPU bench: M2** (added 2026-10-29). A desktop (Ryzen 9 5900X,
  32 GB, RTX 3080 10 GB, Ampere, compute capability 8.6, driver 615.78)
  running CachyOS (Arch), not Ubuntu, so `install.sh` can't run on it. It's for
  GPU work that Pascal can't do. Reach it over Tailscale with
  `ssh -i ~/.ssh/gpubox -o BatchMode=yes remote@M2 '...'`, Bash sandbox
  disabled. Notes:
  - It's someone's desktop: KDE runs on the GPU (about 1 GB of VRAM). Never
    reboot it, stop display services, or change SSH, firewall, Tailscale or
    sudo config without asking. Passwordless sudo; packages via
    `sudo pacman -S --needed`. Long jobs go in `nohup` (no tmux installed).
  - `~/sgs-smoke` holds the stack's pinned Python set (`lock-x86_64.txt`
    plus `tf-cuda12`, hash-checked, Python 3.12 from uv), about 26 GB.
  - **The full stack runs in Ubuntu 24.04 VMs with the RTX 3080 passed
    through** (`~/sgs-vm`, scripts from `tests/gpu-vm/`; QEMU and edk2-ovmf
    installed with pacman). VM `b` is Secure GPU Stack, `a` the Lambda Stack
    baseline; both are stopped, disks kept. `sudo ./gpu-handoff.sh to-vm`
    ends jm's desktop session (ask the user first, every time), `to-host`
    brings it back. Write-up: `docs/m2-test-bench.md`.

## Status

- [x] **Exercise 1** (`exercise-01/`): local Multipass VMs, plain vs. hardened.
  Tested 2026-10-28: plain scored 4 PASS / 3 WARN, hardened 8 PASS / 1 WARN.
  Still fully relevant: the hardening basics, cloud-init and the audit script
  carry over.
- [ ] The user runs exercise 1 themselves.
- [x] Follow-ups 1–3 and 5 answered (2026-10-28): it's for Lambda customers,
  includes everything Lambda Stack has, ships the same way, and an SSH tunnel is
  OK.
- [ ] The rest of `questions-for-assigner.md`, especially 6 (what to hand in)
  and 11 (biggest concern).
- [x] Hand-in clarified (2026-10-28): an image or stack like Lambda's. There
  are no formal criteria; the assigner wants to see how we think and work. They
  shared no security concerns, so we found Lambda's flaws ourselves.
- [x] v0.1 built and tested on local VMs (2026-10-28):
  - `sgs-check`: Lambda baseline 5 PASS / 8 WARN; Secure GPU Stack 18 PASS /
    0 WARN / 1 SKIP (no GPU)
  - user checks: 10 of 10 pass
  - attack demo: 5 of 5 pass
- [x] Stack installed on the krabs test bench with a real GPU (2026-10-29). It
  found 15 installer bugs, stack bugs and `sgs-check` blind spots (two of
  them from an independent code review), all fixed; details in
  `docs/krabs-test-bench.md`. Final `sgs-check --gpu-test` on krabs: 55 PASS /
  3 WARN (krabs's own) / 2 SKIP (Pascal). Attack demo 9/9, user checks 13/13.
  Same `sgs-check` on VMs: Lambda baseline 16 PASS / 15 WARN;
  Secure GPU Stack 47 PASS / 0 WARN.
- [x] Round G (2026-10-29): `/dev/nvidia*` limited to the video group,
  `docs/design.md` section 10. The files are created 0660 (`ub-device-create`
  diverted to `sgs-gpu-devices --no-lock`) and locked with read-only bind
  mounts, checked functionally (`chmod` fails). Re-applying the mode lost
  the race 20/20 and 10/10; the final design 0 in 17M tries. Verified across
  four reboots of krabs and a `nvidia_uvm` reload. udevd has
  `PrivateMounts=yes`, so udev starts a service for the lock;
  nvidia-persistenced needs `SupplementaryGroups=video`.
- [x] Round H (2026-10-29): io_uring limited to root
  (`kernel.io_uring_disabled = 1`), tested with ML workloads on krabs.
- [x] Round I (2026-10-29): JupyterLab on a private Unix socket, kernels over
  ipc. Tunnel: `ssh -N -L 8888:/run/sgs-jupyter/USER/jupyter.sock`. Tested
  end to end through OpenSSH, including a TensorFlow GPU cell.
- [x] Round J (2026-10-29): `kernel.apparmor_restrict_unprivileged_unconfined
  = 1` closes the aa-exec bypass of Ubuntu's user-namespace restriction
  (uid 0 before, on krabs and the Lambda baseline VM).
- [x] Round K (2026-10-29): `sgs-check` runs `dpkg --verify` over the driver,
  CUDA, cuDNN, NCCL, container toolkit and Docker packages (90 on krabs,
  15 s). Krabs now 49 PASS / 3 WARN.
- [x] Round L (2026-10-29): `dev.tty.ldisc_autoload = 0` and no ICMP
  redirects. The sysctl loop sets wanted-0 settings as written (it used to
  only raise).
- [x] Round M (2026-10-29): GPU memory is zeroed between processes on
  driver 580 (`tests/gpu-memory-test.py`). J–K review fixes: the audit rules
  and kernel settings file are in the integrity record, and the loaded audit
  rules are compared with the file.
- [x] Round N (2026-10-29): `sgs-check.timer` re-runs the check daily; the
  login message shows the latest result. Krabs 50 PASS / 3 WARN. Review fixes: redirects
  on every interface (glob keys), runs take turns, the login text is
  sanitized, the report is root-only.
- [x] Round O (2026-10-29): fresh-boot regression passed (every setting and
  lock in place after a reboot); `sgs-check` verifies X11 forwarding is off.
  Krabs 51 PASS / 3 WARN; Lambda baseline VM 15 PASS / 13 WARN.
- [x] Round P (2026-10-29): `sgs-check` names running containers that are
  root on the machine (`--privileged`, Docker socket, host PIDs,
  CAP_SYS_ADMIN).
- [x] Round Q (2026-10-29): the Jupyter service is sandboxed (systemd-analyze
  security 8.5 → 2.2; notebooks unaffected, checked through the tunnel).
  Found while testing: JAX segfaults without an NVIDIA driver; the startup
  hook sets JAX_PLATFORMS=cpu at `import jax`, only when there's no driver.
  Review fixes: numeric sandbox threshold (the old check matched "SAFE" in
  "UNSAFE"), Docker socket hidden from notebooks, SSH Match blocks evaluated.
  Krabs 52 PASS / 3 WARN, VM 45 / 0.
- [x] Round R (2026-10-29): install on a brand-new VM (`sgs-fresh`, stopped,
  not deleted) and a reboot: 44 PASS / 0 WARN both times.
- [x] Round S (2026-10-29): the sandboxed Jupyter kernel runs as fast as a
  plain shell (TF matmul 3.94 vs 3.96 TFLOP/s; DataLoader within noise).
- [x] Round T (2026-10-29): `docs/threat-model.md`, deliverable 5's first half
  (the quickstart is in `README.md`).
- [x] Round U (2026-10-29): `sgs-egress strict`, an opt-in, experimental
  strict outbound mode (dnsmasq + an nftables set; `docs/design.md` section
  11). Tested on VMs only, never enabled on krabs. Unresolved: the old
  `sgs-test` VM stopped accepting multipass's login after a reboot in strict
  mode; `sgs-fresh` (this Mac's key is authorized there for direct SSH at
  its IP) came back fine. Replaying sgs-test's exact sequence on sgs-fresh didn't
  reproduce it either.
- [x] Round V (2026-10-29): cloud metadata (169.254.169.254) for root only,
  always on (`sgs-guard.service`). Krabs 53 PASS / 3 WARN; VM 46 / 0;
  Lambda baseline 15 PASS / 14 WARN.
- [x] Round W (2026-10-29): `sgs-check` watches cron, shell startup files,
  user services and SSH keys for changes (`--accept-changes` after review).
  Krabs 54 PASS / 3 WARN.
- [x] Round X (2026-10-29): V–W review fixes. Docker's `cgroup-parent` is
  `docker.slice`, so the metadata guard and strict mode also cover
  host-network containers (matched by cgroup); symlink swaps and deletions
  of startup files are reported; more persistence spots are watched.
- [x] Round Y (2026-10-29): kernel lockdown (integrity) on the kernel
  command line when Secure Boot doesn't set it; left off, or taken back out,
  while DKMS modules exist (a real DKMS module was refused under lockdown on
  the VM). `--no-lockdown` opts out. The installer no longer re-accepts the
  startup record on every run.
- [x] Round Z (2026-10-29): Y review fixes. `sgs-check` watches 71 places
  (system-wide too: `/etc/ld.so.preload`, cron.daily, systemd units, PAM,
  apt hooks; IPython startup and Jupyter config per account). The installer
  and `sgs-egress` accept only what they changed (`--list-startup-files`,
  `--accept-changes-since`). snapd's mount units are skipped by shape. Root
  containers with `--ipc=host`, and containers with seccomp or AppArmor off,
  are a "weakened isolation" WARN. Krabs 55 PASS / 3 WARN; VM 47 / 0;
  Lambda baseline 16 PASS / 15 WARN.
- [x] Round AA (2026-10-29): core dumps. Tested the worry that a crash leaks
  a job's memory (model weights, tokens) to another user via a core file —
  it doesn't: the kernel writes cores 0600 to the crashing user (a second
  user read a planted token 0 times). Added one pin, `fs.suid_dumpable = 0`
  (setuid programs don't dump), which `sgs-check` verifies. VM 47 / 0.
- [x] **Hill-climbing ended here (2026-10-29), at the user's call.** 76
  findings over rounds 1–AA; the big wins were early (GPU device files,
  cloud metadata, user namespaces, lockdown). Remaining work is not more
  rounds but real-Lambda validation (below). Committed on `stack/v0.1`;
  commit further changes only on the user's OK.
- [x] Walkthrough video (2026-10-29): `video/`, 8:50, narrated with
  OpenRouter's HeyGen voice "noelle" (never macOS `say`). The MP4s are
  assets of the v0.1.0 GitHub release, not tracked in git.
- [x] Pushed to GitHub (2026-10-29): public repository
  `RZ3M/secure-gpu-stack`, both branches, default branch `stack/v0.1`.
- [x] M2 test bench (2026-10-29): the Lambda test plan on an RTX 3080 in
  Ubuntu 24.04 VMs. Published v0.1.0 via cloud-init: open driver, lockdown,
  all three frameworks on the GPU. Findings 77–81, all fixed, released as v0.1.1:
  TensorFlow convolutions broken by mixed cuDNN builds, apport undoing
  `suid_dumpable=0` at boot, XLA without ptxas, GPU test matmul-only, IPython
  README false positive. B 56 PASS / 0 WARN; Lambda Stack 19 PASS / 17 WARN
  on the same GPU and driver, within 2% on speed. Lambda's own install fails
  on a fresh 24.04 (Lambda Stack finding 15).
- [x] M2 update video and summary page (2026-10-29): `video/m2/`, 3:38, same
  voice. The two videos now share `video/kit.css` and `video/kit.js`; both
  build scripts take the video's folder (`node video/render.mjs video/m2`).
  The voiced MP4 is an asset of the v0.1.1 release (uploaded at the user's
  request); the version without the voice stays in `video/m2/out/`. The
  summary page (https://claude.ai/artifact/PMapXo4STPLTyPhiQq72nM) is at
  version 6 (2026-10-30): a new "On real Lambda hardware" lead section
  (before/after on the A100, the audit's seven attacks replayed, a step-by-step
  token→root chain visual with where our stack cuts each link, findings
  86–92, the `sgs-check` scoring change), the old v0.1.1 section renamed to
  "M2", Lambda Stack findings 16–33 added to the findings list, and the two
  Lambda A100s added to the scoreboard and sources bar. Its source is rebuilt
  from the published page (Artifact read), not kept in the repo.
- [x] License (2026-10-29): AGPL-3.0-or-later, `LICENSE` from gnu.org,
  copyright "RZ3M"; release tarballs ship it. Committed and pushed.
- [x] M2 hill-climb, rounds AB–AF (2026-10-29), stopped after three thin
  rounds (AD, AE, AF) by the user's rule; written up in
  `docs/m2-test-bench.md`. Committed and pushed (8048669), not yet in a
  release. Findings 82–85:
  - 82: an upgrade could silently accept a pending IPython startup file
    (`STARTUP_RENAMED`).
  - 83: `torch.compile`'s cache in `/tmp/torchinductor_<user>` let any account
    run code as the user (measured: nobody → uid 1000). The startup hook sets
    `TORCHINDUCTOR_CACHE_DIR`, `QUACK_CACHE_DIR` and a private `TMPDIR`
    (`~/.cache/tmp`); `sgs-check` tests the hook and flags planted folders.
  - 84: installs under a strict umask made the stack root-only; the
    installer sets umask 022 and repairs modes on every run.
  - 85: `sgs-check` now requires `nobody` to load the frameworks.
  Declined, to keep features: a login umask of 027 (breaks non-root Docker
  images), wheels-only `sgs-venv`. Final: VM 58 PASS / 0 WARN on the RTX
  3080, also with `--no-cuda-toolkit`; GPU containers work. M2's VMs
  `a`–`e` are stopped, disks kept (122 GB in `~/sgs-vm`).
- [ ] Run `docs/lambda-test-plan.md` on real Lambda instances: Lambda's cloud
  image, data-center GPUs, multi-GPU NCCL. **Instance A audited 2026-10-30**
  (Lambda's default image, `gpu_1x_a100_sxm4`): `docs/lambda-instance-audit.md`,
  2 Critical / 9 High / 7 Medium / 4 Low; `sgs-check` 24 PASS / 30 WARN / 1 SKIP;
  all three frameworks on the A100. The token → root chain was verified
  end-to-end (POC-1) and the `sgs-check` blind spots/scoring changes are
  documented in `docs/lambda-instance-pocs.md` and `docs/sgs-check-gaps.md`.
  **Instance B done 2026-10-30** (Lambda's Ubuntu 24.04.2, `gpu_1x_a100_sxm4`,
  got an A100-SXM4-**80GB**): `docs/lambda-test-bench.md`, raw output in
  `tests/results/lambda/b/`. Install 18m42s; `sgs-check --gpu-test` 58 PASS /
  0 WARN; user checks 13/13; attack demo 7 PASS + 1 SKIP (Lambda's firewall);
  every earlier finding re-proved by direct attack; strict egress survived a
  reboot on Lambda. Same-GPU speed vs Lambda Stack's PyTorch 2.7.0: ResNet-50
  1,943 vs 1,900 img/s, GPT 187,640 vs 177,696 tok/s. Findings 86–90 fixed
  and re-verified there (MIG opens `/dev/nvidia-nvswitchctl`; CDI specs
  unaudited on fresh installs; PyTorch+TensorFlow in one process crash, now a
  warning; persistenced socket 0777; persistence mode off cost 3.5 s per CUDA
  start). `install.sh` says 0.1.2: committed and pushed to `stack/v0.1`
  on 2026-10-30, not yet a release. Still pending: multi-GPU NCCL/NVSwitch/InfiniBand, cloud-init via the
  Lambda API.
- [x] Lambda Stack audit applied (2026-10-30): `docs/lambda-audit-response.md`.
  `sgs-check` rates every WARN (CRITICAL/HIGH/MEDIUM/LOW), rates chains
  ("Combined risks"), reports coverage, writes `--json`, has `--fail-on`, and
  closes G-01..G-20 (tunnels and their public edge, any Jupyter's sudo/token/
  Host header, pipx and per-environment pip-audit, network-facing update
  severity, repo staleness, RDMA, CPU, capabilities, disk group, SSH
  algorithms, metadata precision). Stack: SSH algorithms and key files
  (behind a lockout check), kexec/userfaultfd pinned, 35 audit rules, RDMA
  udev rule (untested on InfiniBand), `sgs-jupyter` token outside the URL +
  `--rotate` + public address (finding 91), per-environment pip-audit
  (finding 92), `dpkg --verify` of sshd/sudo/PAM/systemd/libc. On B: every
  audit PoC fails, 12 planted Lambda-style problems all caught (1 CRITICAL,
  7 HIGH), our stack 0 WARN. An independent review then found 6 real bugs
  (root parsing users' tunnel configs and fetching their hostnames; a token
  echoed by `dirname`; the RDMA rule opening umad; forced root keys rated LOW
  without `no-port-forwarding`; `sudo` wrappers counted as Jupyter; 4xx/5xx
  plain HTTP missed) plus minor ones, all fixed and re-verified on B; also
  `tests/jupyter-cell.py`'s reply/idle race. Final on B: `sgs-check
  --gpu-test` 69 PASS / 0 WARN, coverage 69/69. Committed and pushed
  2026-10-30 in two commits: the user's audit (their DeepSeek agents, not
  Claude; Lambda Stack findings 16–33 now in the findings summary), then
  this work. Instance B was still running at ~$1.99/hr at that point.
- [ ] v0.2 candidates are listed at the end of `docs/design.md`.

## Environment notes

- **The Mac:** Apple Silicon (arm64), with Multipass 1.16.4 installed through
  Homebrew. Local VMs are arm64. Lambda's Ubuntu Server and GPU Base images are
  x86-64 only.
- **Multipass and `permissions`:** Multipass rewrites the user-data it's given
  and turns `permissions: "0644"` into the integer 420, which fails cloud-init's
  schema check. Leave `permissions` out when 0644 (the default) is wanted.
- **Claude's Bash sandbox:** it blocks the multipass client from reaching VMs
  ("No route to host"). Run `multipass exec` and `multipass transfer` with the
  sandbox disabled. `nc` and `ssh` to VM IPs work either way.

## Working with the user

- The user is new to infrastructure security. Explain in plain language, define
  terms the first time they come up, and give step-by-step instructions.
- Learning path:
  1. Linux server basics
  2. GPU software layers (driver, CUDA, cuDNN, NCCL)
  3. Docker
  4. cloud-init
  5. Hardening
  6. Python packaging and virtual environments
  7. ML-specific risks (pickle files, supply chain, secrets)
  8. Jupyter security
