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
- **The M2 update** (3:38): what testing on an RTX 3080 showed, what it
  found, and what's next. Download it from the
  [v0.1.1 release](https://github.com/RZ3M/secure-gpu-stack/releases/tag/v0.1.1).
  Its source is in [video/m2/](video/m2/).
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
| 8 | ML code that runs on Lambda Stack runs here, at the same speed | GPU smoke test and benchmark (`tests/gpu-smoke.py`, `tests/gpu-bench.py`). On M2's RTX 3080, with the same driver, within 2% of Lambda Stack (slightly ahead); on krabs, the hardening itself costs no measurable speed (GPU matmul −0.5%, DataLoader within noise, in the sandboxed Jupyter kernel) |

Criteria 1–7 are tested on local VMs first. Criterion 8 and the GPU parts of 1
are tested on M2 (an RTX 3080 in a VM, the way Lambda instances get their
GPU), and still need confirming on Lambda's own data-center GPUs.

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

**Modern GPU: the M2 test bench** (an RTX 3080, Ampere, handed to Ubuntu
24.04 VMs, the way a Lambda instance gets its GPU). Both stacks on the same
card and the same driver:

| Test | Lambda Stack | Secure GPU Stack |
|---|---|---|
| Install on a fresh Ubuntu 24.04 | **Fails**: neither of Lambda's drivers compiles on the current kernel ([finding 15](docs/lambda-stack-findings.md)) | 8 minutes, unattended, from the published release |
| `sgs-check --gpu-test` | 19 PASS, **17 WARN**, 2 SKIP (plus one WARN from the baseline's driver workaround) | 56 PASS, **0 WARN**, 0 SKIP |
| PyTorch, JAX, TensorFlow on the GPU, convolutions included | Yes (`torch.compile` fails: no `python3-dev`) | Yes, `torch.compile` too |
| GPU device files | Open to every account: `nobody` ran `nvidia-smi` | Video group only, locked |
| Training speed (ResNet-50, GPT-style) | 902 images/s, 63,465 tokens/s | 919 images/s, 63,948 tokens/s |

M2 also found nine more bugs and blind spots, all fixed, among them
TensorFlow convolutions that failed on any GPU new enough to run them, and
a way for any other account to get its code run as you through
`torch.compile`'s cache in `/tmp`; see
[docs/m2-test-bench.md](docs/m2-test-bench.md).

**Real Lambda Cloud: two 1x A100 instances** (2026-10-30). One ran Lambda's
default image, the other Lambda's plain Ubuntu 24.04 with this stack
installed from the release tarball:

| Test | Lambda Stack (Lambda's default image) | Secure GPU Stack |
|---|---|---|
| `sgs-check --gpu-test` (the version the audit ran) | 24 PASS, **30 WARN**, 1 SKIP | 58 PASS, **0 WARN**, 0 SKIP |
| `sgs-check --gpu-test` after the audit's fixes (69 checks, each WARN rated) | Not re-run there; 12 of its problems planted on our instance were all caught: 1 CRITICAL, 7 HIGH, 4 MEDIUM, 1 LOW | 69 PASS, **0 WARN**, 0 at every severity |
| The audit's attacks (token to root, `nobody` on the GPU, the user-namespace bypass, RDMA, the tunnel past the firewall) | 7 of 7 worked | All blocked |
| JupyterLab | Public on the internet over plain HTTP, token in the URL | Private socket, SSH tunnel only |
| Security updates | 228 pending, automatic updates off | Automatic |
| GPU device files | Open to every account | Video group only, locked |
| Training speed on the same A100 (Lambda Stack's PyTorch 2.7.0 vs ours) | 1,900 images/s, 177,696 tokens/s | 1,943 images/s, 187,640 tokens/s |

Install: 19 minutes, unattended. Every earlier finding held when attacked
directly on Lambda's hardware, and Lambda's hardware turned up five more
(findings 86–90: a GPU device file that MIG opened to everyone, unaudited
container specs, PyTorch and TensorFlow crashing when mixed in one notebook,
an open persistence-daemon socket, and 3.5 s added to every CUDA program's
start), all fixed and re-verified there. See
[docs/lambda-test-bench.md](docs/lambda-test-bench.md).

A separate read-only audit of Lambda's default image on the other instance
found 2 Critical, 9 High, 7 Medium and 4 Low problems
([docs/lambda-instance-audit.md](docs/lambda-instance-audit.md), attacks in
[docs/lambda-instance-pocs.md](docs/lambda-instance-pocs.md); Lambda Stack
findings 16–33 in [docs/lambda-stack-findings.md](docs/lambda-stack-findings.md)).
The worst: JupyterLab is published to the internet over plain HTTP, and its
token gives root through passwordless `sudo`, which the audit carried out end
to end. Every finding was checked against this stack and every attack
replayed on our instance. The result is a stronger `sgs-check`: it now rates
each WARN as CRITICAL, HIGH, MEDIUM or LOW, flags combinations that add up to
a way in, reports which checks ran, writes JSON (`--json`), can fail a
pipeline (`--fail-on high`), and looks for what it missed on Lambda (public
tunnels, any Jupyter's `sudo` and token, pipx environments, RDMA devices).
Two more findings came out of it (91–92); see
[docs/lambda-audit-response.md](docs/lambda-audit-response.md).

Full output is in `tests/results/`. Multi-GPU NCCL, NVSwitch and InfiniBand
still need an 8-GPU instance; see
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
   sha256sum -c SHA256SUMS && tar -xzf secure-gpu-stack-0.1.1.tar.gz && sudo secure-gpu-stack-0.1.1/install.sh
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
   command to run on your own computer, the URL to open, and the token to
   paste on the login page (`sgs-jupyter --rotate` replaces it). Keep PyTorch and
   TensorFlow GPU work in separate notebooks or scripts: TensorFlow uses its
   own CUDA 12 libraries, and one process can't hold both builds of cuDNN
   (a warning says so if you import both). JAX mixes fine with either.

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
  - `sgs-check`: the audit; rates each WARN by severity, `--json` for a
    machine-readable report, `--fail-on LEVEL` for scripts
  - `sgs-venv`: makes your own environment on top of the stack
  - `sgs-jupyter`: prints the SSH tunnel command, URL and token;
    `--rotate` replaces the token
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

## License

Copyright (C) 2026 RZ3M.

Secure GPU Stack is free software under the
[GNU Affero General Public License, version 3](LICENSE), or (at your option)
any later version. Anyone may use, study, change and share it. Anyone who
distributes it, changed or not, must pass it on under the same license with
its source code, and anyone who changes it and lets others use it over a
network must offer those users the changed source too (section 13). It comes
with no warranty.
