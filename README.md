# Secure GPU Stack

A drop-in alternative to Lambda Stack for people who rent GPUs on Lambda. It
installs the same tools the same way, but every default is chosen for security,
and a check command proves it.

## Walkthrough

- **Video** (8:50, narrated and captioned): what the stack is, how it differs
  from Lambda Stack, what testing found and fixed, and what isn't proven yet.
  Download it from the
  [v0.1.0 release](https://github.com/RZ3M/secure-gpu-stack/releases/tag/v0.1.0).
  Its source is in [video/](video/).
- **Summary page:** [Secure GPU Stack](https://claude.ai/artifact/PMapXo4STPLTyPhiQq72nM).

## Goal

**Secure GPU Stack v0.1:** with one command on Ubuntu 24.04, a Lambda customer
gets everything Lambda Stack gives them, with every problem in
[docs/lambda-stack-findings.md](docs/lambda-stack-findings.md) fixed, and
`sgs-check` showing the difference.

### Success criteria

| # | Criterion | How it's checked |
|---|---|---|
| 1 | Same tools as Lambda Stack: NVIDIA driver, CUDA toolkit, cuDNN, NCCL, PyTorch, torchvision, TensorFlow, Keras, JAX, Triton, JupyterLab, Docker with GPU support | Installer output, `sgs-check` |
| 2 | One-command install on Ubuntu 24.04, x86-64 and arm64 | Local VM test, then Lambda |
| 3 | Zero known vulnerabilities in the stack's Python packages at release time (the OS, driver and CUDA get Ubuntu's and NVIDIA's security updates automatically) | `sgs-check` runs pip-audit, and checks that updates install |
| 4 | NVIDIA driver from a supported branch (R580 LTS), still receiving Ubuntu security updates, and no apt pin above 1000 | `sgs-check` |
| 5 | Every third-party package source uses HTTPS and a key scoped to that source, with its fingerprint verified at install | `sgs-check` |
| 6 | Nothing reachable from the network except SSH. Jupyter is reached through an SSH tunnel, and Docker-published ports don't bypass the firewall | `sgs-check` plus an attack demo |
| 7 | The stack's Python packages are hash-verified wheels only: no running of package build scripts. (Users' own `sgs-venv` environments install whatever they choose.) | Installer, `sgs-check` file integrity check |
| 8 | ML code that runs on Lambda Stack runs here, at the same speed | GPU smoke test and benchmark (needs a real Lambda GPU); on krabs, the hardening itself costs no measurable speed (GPU matmul −0.5%, DataLoader within noise, in the sandboxed Jupyter kernel) |

Criteria 1–7 are tested on local VMs first. Criterion 8 and the GPU parts of 1
need the real Lambda environment.

## How it compares

| | Lambda Stack | Secure GPU Stack |
|---|---|---|
| Install | `wget … \| sh`, unverified | Same one command, with a SHA-256 to check first, and an optional signature (`ssh-keygen`) that the Lambda cloud-init wrapper verifies |
| Package trust | One key trusted for every repository; HTTP; pin 1001 overrides Ubuntu | Per-source keys with checked fingerprints, HTTPS, no override pins |
| NVIDIA driver | R570 (end of life); Ubuntu's driver security fixes blocked | R580 LTS from Ubuntu's archive; security fixes flow through Ubuntu |
| ML frameworks | System Python, last updated Dec 2025, known CVEs | Isolated, read-only environment, current versions, hash-locked, zero known CVEs |
| Jupyter | Running on the cloud image | Listens only on a Unix socket its user alone can open (no port, not even on localhost), and its kernels too; requires its token everywhere except Jupyter's public version and login pages; notebook code can't `sudo` to root, and runs in a systemd sandbox (exposure 8.5 → 2.2) that hides other users' processes; the token stays out of the logs; you connect through an SSH tunnel |
| Docker | Published ports go around the firewall | Ports publish to localhost by default, on every network including `docker compose` ones; no root-equivalent `docker` group; `no-new-privileges`; GPU only when a container asks; running containers with root over the machine (`--privileged`, the Docker socket) reported |
| Updates | Automatic updates with no time limit (a hung job can block them for months); Ubuntu packages only | Time limits; Docker and NVIDIA packages included; `sgs-check` checks that a run actually completed |
| GPU device files | Not covered in Lambda's docs (Ubuntu's default is 0666: every local user and service account reaches the driver) | `video` group only: created 0660 and locked, so the driver's own library can't reopen them. A looping attacker got in 20 of 20 times when the mode was only re-applied, 0 times in 17 million tries with the lock |
| Cloud metadata | Reachable by any account and container (baseline VM) | Root only, so a malicious package or a tricked container can't read credentials or launch data |
| Kernel exploit surface | Ubuntu's defaults: io_uring open to every user, user namespaces one `aa-exec` away, and any user can load line-discipline modules (verified on VMs) | io_uring for root only; user namespaces closed to ordinary users, bypass included, tested by `sgs-check` the way an attacker would try; only root loads line disciplines; no ICMP redirects |
| Kernel integrity | Lockdown off without Secure Boot (baseline VM): root can load unsigned kernel modules and write kernel memory | Lockdown on, from Secure Boot or the kernel command line; left off, with the reason reported, while unsigned DKMS modules are installed |
| SSH | Ubuntu's defaults: root can log in with a key, X11 forwarding on (baseline VM) | Keys only, no root login, no X11 forwarding |
| Audit trail | No auditd | auditd rules for package sources, sudo, SSH, Docker, GPU hooks and the stack |
| Proof | None | `sgs-check`, re-run daily with the result shown at login, including a check of every installed file, Python and native (driver, CUDA, cuDNN, NCCL, container toolkit, Docker), against its package's recorded hash, and of every place code uses to come back (cron, services, shell and IPython startup, SSH keys, `/etc/ld.so.preload`) against the last accepted record; `sgs-sbom`, a CycloneDX list of everything installed |

## Results so far

**Local VMs** (Ubuntu 24.04, arm64, no GPU), with the same `sgs-check`:

| Test | Lambda Stack (its repository and packages) | Secure GPU Stack |
|---|---|---|
| `sgs-check` | 16 PASS, **15 WARN**, 2 SKIP | 47 PASS, **0 WARN**, 1 SKIP (no GPU) |
| Vulnerability advisories in ML packages | 44 (Keras 28, PyTorch 15, fsspec 1) | 0 in 149 packages |
| User checks (`tests/user-checks.sh`) | not applicable | 11 of 11 pass |
| Attack demo (`tests/attack-demo.sh`) | not run (no Docker or Jupyter in the baseline VM) | 8 of 8 pass (the GPU step skips: no GPU) |

**Real GPU: the krabs test bench** (a lived-in Ubuntu 24.04 laptop, x86-64,
GTX 1070). `sgs-check --gpu-test`: 55 PASS, 3 WARN (the machine's own, not
the stack's), 2 SKIP (PyTorch and JAX don't support this GPU). TensorFlow and
GPU containers work, user checks pass 13/13, and the attack demo passes 9/9:
from the local network, plus a service account trying to open the GPU and
reach Jupyter. Installing on a real machine, an independent code review,
15 open-weight model reviews and attacks measured on the machines (a looping
attacker against the GPU's device files, `aa-exec` against user namespaces,
planted persistence, a DKMS module under kernel lockdown) produced 75
numbered findings: bugs, blind spots and hardening gaps, each fixed and
verified (on krabs, or on a VM where krabs can't show it), plus a few
properties confirmed (GPU memory is cleared between processes); see
[docs/krabs-test-bench.md](docs/krabs-test-bench.md).

Full output is in `tests/results/`. PyTorch and JAX on a current GPU, Lambda's
cloud image and the performance comparison still need a Lambda instance; see
[docs/lambda-test-plan.md](docs/lambda-test-plan.md).

## Quick start

1. Build the release on your computer. It prints the SHA-256 to publish.
   With `SGS_SIGNING_KEY` set to an SSH ed25519 key, it also signs
   `SHA256SUMS`:

   ```bash
   scripts/release.sh
   ```

2. On the GPU machine (Ubuntu 24.04), check the tarball, then install. The
   check only means something if `SHA256SUMS` (or its signature's public key)
   came from somewhere other than the tarball's download host, such as the
   git repository; otherwise it only catches corruption:

   ```bash
   sha256sum -c SHA256SUMS && tar -xzf secure-gpu-stack-0.1.0.tar.gz && sudo secure-gpu-stack-0.1.0/install.sh
   ```

3. Reboot if the installer says so, then check the machine:

   ```bash
   sudo reboot
   ```

   ```bash
   sudo sgs-check --gpu-test
   ```

4. Only members of the `video` group can use the GPU; the installer adds the
   user it installs for. To give another user the GPU:

   ```bash
   sudo usermod -aG video NAME
   ```

5. Open JupyterLab: on the GPU machine, `sgs-jupyter` prints the SSH tunnel
   command to run on your own computer, and the URL to open.

6. Each login shows the result of the daily check. If it reports changed
   startup files (a cron job, `~/.bashrc`, an SSH key and so on), look at
   each one. If the changes are yours, record them:

   ```bash
   sudo sgs-check --accept-changes
   ```

7. Optional, for sensitive work: limit outbound traffic to the domains in
   `/etc/sgs/egress-allow` (experimental; keep the provider's console handy
   before rebooting with it on). `sudo sgs-egress open` turns it off:

   ```bash
   sudo sgs-egress strict
   ```

To test locally without a GPU, run `tests/test-local.sh`. It needs Multipass.

## Layout

- `install.sh`: the installer.
- `bin/`: commands installed on the machine:
  - `sgs-check`: the audit
  - `sgs-venv`: makes your own environment on top of the stack
  - `sgs-jupyter`: prints the URL and SSH tunnel command
  - `sgs-sbom`: lists every installed apt and Python package as CycloneDX JSON
  - `sgs-egress`: an optional, experimental strict mode that limits outbound traffic to allowed domains
- `python/`:
  - `requirements.in`: the ML stack
  - `lock-*.txt`: hash-locked lockfiles, one per architecture
  - `lock.sh`: regenerates the lockfiles
- `docs/`: findings, design decisions, the threat model, the Lambda test plan.
- `tests/`:
  - `test-local.sh`: VM install and audit
  - `user-checks.sh`: does the stack work for a normal user?
  - `gpu-memory-test.py`: does GPU memory carry over from one process to the next?
  - `attack-demo.sh`: what can be reached from outside?
- `scripts/release.sh`: builds a release tarball and its checksum, and signs the
  checksum with `ssh-keygen` when given a key.
- `scripts/model-review.py`: has open-weight models (via OpenRouter) red-team
  the code; their findings are checked on the test bench before anything changes.
- `cloud-init/`: first-boot setup for Lambda Cloud.
- `exercise-01/`: the learning exercise this project grew from.
