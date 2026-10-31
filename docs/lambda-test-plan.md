# Test plan for a real Lambda environment

> **Status, 2026-10-30:** run on two single-GPU A100 instances. Instance B
> (Secure GPU Stack) is written up in `docs/lambda-test-bench.md`, instance A
> (Lambda Stack) in `docs/lambda-instance-audit.md`. Everything below that
> one GPU can show passed, after findings 86–90 were fixed. Still open: the
> multi-GPU items (NCCL across GPUs, NVSwitch and Fabric Manager, InfiniBand)
> and the cloud-init route (needs an API key). The release is now 0.1.2;
> substitute it for 0.1.1 in the commands below. Lambda's firewall blocks
> the attack demo's Docker-port control, so that part SKIPs on Lambda.

What the local VMs couldn't test: the NVIDIA driver install, the GPU itself,
x86-64, Lambda Cloud's own default image, and performance. This plan needs two
instances of the same GPU type. A single-GPU instance is enough; budget about
2 hours each.

This plan has already run once, on M2: an RTX 3080 handed to two Ubuntu 24.04
VMs (`docs/m2-test-bench.md`, scripts in `tests/gpu-vm/`). The driver path,
all three frameworks, the speed comparison and the attack demo passed there.
What's left needs Lambda itself: its cloud image, data-center GPUs and
multi-GPU NCCL. Lambda's published install script no longer works on a fresh
Ubuntu 24.04 (Lambda Stack finding 15), so instance A has to use Lambda's
image, as planned below.

| Instance | Image | Purpose |
|---|---|---|
| A, "before" | Lambda Stack 24.04 (Lambda's default) | Baseline: findings on the real cloud image |
| B, "after" | Ubuntu Server 24.04 (plain) | Install Secure GPU Stack |

## Before you start

- Add your SSH public key in the Lambda console, and use it for both instances.
- Firewall rules: Lambda opens port 22 only by default. Leave it that way. The
  attack demo also tests ports 8080, 8081 and 8888 from outside. To see what
  the host itself exposes, add a temporary inbound rule for those ports,
  restricted to your own IP. Remove the rule afterwards.
- Terminate both instances when you're done. Lambda bills while they run.

## A: Lambda Stack baseline

1. Copy the audit and its tool lock over:

   ```bash
   scp bin/sgs-check python/tools-lock-x86_64.txt ubuntu@INSTANCE_A:
   ```

2. On the instance, set up pip-audit in a temporary environment and run the
   audit. The environment must be root's: `sgs-check` runs as root, so it
   refuses a pip-audit that anyone else could change.

   ```bash
   sudo python3 -m venv /tmp/audit && sudo /tmp/audit/bin/pip install -q --require-hashes --only-binary :all: --no-deps -r tools-lock-x86_64.txt
   ```

   ```bash
   sudo SGS_PIP_AUDIT=/tmp/audit/bin/pip-audit bash sgs-check --gpu-test | tee lambda-stack-check.txt
   ```

3. From your computer, run the attack demo:

   ```bash
   tests/attack-demo.sh INSTANCE_A
   ```

4. Note what the cloud image adds beyond Lambda Stack:
   - Is JupyterLab exposed, and how does it authenticate? Does the dashboard's
     "Launch Jupyter" button reach it, and through what?
   - Is `ubuntu` in the `docker` group?
   - Run `sudo apt full-upgrade -s`. Does it fail as Lambda's docs say?

## B: Secure GPU Stack

1. Build the release on your computer:

   ```bash
   scripts/release.sh
   ```

2. Copy it over:

   ```bash
   scp dist/secure-gpu-stack-0.1.1.tar.gz dist/SHA256SUMS ubuntu@INSTANCE_B:
   ```

3. On the instance, verify the tarball and install:

   ```bash
   sha256sum -c SHA256SUMS && tar -xzf secure-gpu-stack-0.1.1.tar.gz && sudo secure-gpu-stack-0.1.1/install.sh
   ```

4. Reboot so the driver loads:

   ```bash
   sudo reboot
   ```

5. Check the machine and run the user checks:

   ```bash
   sudo sgs-check --gpu-test | tee sgs-check.txt
   ```

   ```bash
   bash -l secure-gpu-stack-0.1.1/tests/user-checks.sh
   ```

6. From your computer, run the attack demo:

   ```bash
   tests/attack-demo.sh INSTANCE_B
   ```

Alternative for B: launch through the Lambda Cloud API with
`cloud-init/lambda-user-data.yaml`. That needs the release published at a URL
first. On first boot, Ubuntu's own apt jobs usually run while the installer
does; check `/var/log/cloud-init-output.log` for "Waiting for another apt
run" and an install that still finished (krabs test-bench finding 51).

## Can another account run code as you through `torch.compile`?

On both instances, as the default user (it uses sudo to act as `nobody`):

```bash
bash secure-gpu-stack-0.1.1/tests/compile-cache-attack.sh
```

VULNERABLE means another account's code ran as you through the compiled-code
cache in `/tmp` (M2 finding 83). Expect VULNERABLE on Lambda Stack if its
image has `python3-dev`, and SAFE on Secure GPU Stack.

## Same speed?

Run the same PyTorch benchmark on both instances. The `--gpu-test` matmul
figure is a first indication. A real training step (for example a small
ResNet or GPT for a few hundred iterations) is better. Record time per step
for each.

## What to look for

- **The driver path on B:** did it use Ubuntu's prebuilt modules or fall back
  to DKMS? Does `nvidia-smi` work after the reboot? Is the kernel line GA or
  HWE (the installer prints it)?
- **Kernel lockdown:** `cat /sys/kernel/security/lockdown` on both. On A, is
  it `[none]`, or does the instance boot with Secure Boot (`mokutil
  --sb-state`)? On B, after the reboot, `[integrity]` with `nvidia-smi`
  working, or, if the driver fell back to DKMS, `[none]` and the installer's
  note saying why.
- **All three frameworks on the GPU:** krabs (Pascal) could only prove
  TensorFlow. On a Turing or newer GPU, `--gpu-test` should PASS PyTorch, JAX
  and TensorFlow, each in its own process.
- **The separated CUDA libraries** (`docs/design.md` section 3), which matter
  most for PyTorch:
  - A PyTorch convolution: `python3 -c "import torch; c=torch.nn.Conv2d(3,16,3).cuda(); print(c(torch.randn(8,3,64,64,device='cuda')).shape, torch.backends.cudnn.version())"`. It should report cuDNN 9.26 (the CUDA 13 wheel), not 9.27.
  - On multi-GPU instances, an NCCL all-reduce with `torchrun`.
  - A TensorFlow convolution, which krabs's GPU can't run.
- **GPU device files** (`docs/design.md` section 10): on Lambda Stack (A),
  `stat -c '%a %G %n' /dev/nvidia*` after a `sudo nvidia-smi`, to see whether
  it keeps Ubuntu's 0666. On ours (B), all `660 video`; `nvidia-persistenced`,
  Fabric Manager and DCGM running; and, on NVSwitch machines, the
  `/dev/nvidia-nvswitch*` and `/dev/nvidia-nvlink` files not open to
  everyone (krabs had none to test).
- **Multi-node NCCL from a notebook over InfiniBand:** the Jupyter sandbox
  allows the InfiniBand verbs devices, untested on krabs (no InfiniBand).
  Run a two-node `torchrun` from a notebook terminal with `NCCL_DEBUG=INFO`
  and check it uses `NET/IB`, not sockets.
- **Cloud metadata:** on Lambda Stack (A), `curl -s http://169.254.169.254/`
  (and `/openstack/latest/meta_data.json`, `/latest/meta-data/`) as an
  ordinary user: is there a service, and does it return launch data or
  credentials? On ours (B), the same command must fail at once for an
  ordinary user and work as root.
- **GPU memory between users:** `tests/gpu-memory-test.py write` as one
  user, then `read` as another (in `video`); each takes 90% of free GPU
  memory. krabs read back zeros. Try it on the data-center GPUs, and with
  MIG if the instance has it.
- **Multi-GPU instances with NVSwitch:** is Fabric Manager running? The
  installer spots NVSwitch by PCI ID, and its list stops at Hopper. On an HGX
  Blackwell machine (8x B200), check that `lspci -d 10de:` shows a switch it
  recognizes. Otherwise CUDA fails with error 802.
- **The before/after table:** `sgs-check` results for A and B, side by side.
