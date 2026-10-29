# M2: the stack on a modern GPU, in a Lambda-shaped VM

krabs (`docs/krabs-test-bench.md`) proved the stack on real hardware, but its
GTX 1070 is Pascal: PyTorch and JAX can't use it, and neither can TensorFlow's
convolutions. M2 is a desktop with an **RTX 3080** (Ampere, compute capability
8.6), the generation Lambda's A10 and A100 belong to. It runs CachyOS, not
Ubuntu, so the stack doesn't install on it directly. Instead the card is handed
to an Ubuntu 24.04 virtual machine. That's also how a Lambda Cloud instance
gets its GPU: Lambda's docs describe on-demand instances as GPU-backed virtual
machines, and the instance gets the whole card.

Everything below was tested on 2026-10-29. Raw results are in
`tests/results/m2-2026-10-29/`.

## The setup

- **Host:** Ryzen 9 5900X, 32 GB, RTX 3080 10 GB. The CPU's IOMMU (the
  hardware that lets a VM own a PCI device safely) is on, and the card sits in
  its own IOMMU group with only its HDMI audio.
- **Handing the GPU over:** `tests/gpu-vm/gpu-handoff.sh to-vm` ends the
  desktop session, unloads the NVIDIA driver and binds the card to `vfio-pci`
  (the driver that lends devices to VMs). `to-host` reverses it. Nothing
  changes the host's boot settings, so a reboot also undoes it. On M2 the
  handoff took 9 seconds each way.
- **The VMs** (`tests/gpu-vm/vm.sh`): Ubuntu 24.04.5 cloud image, its
  checksum list verified against Ubuntu's signing key (`D2EB 4462 … 7DB8
  7C81`); 12 vCPUs, 16 GB, 200 GB disk; kernel 6.8.0-147-generic. Networking
  is QEMU's user-mode network: the VM's SSH and the ports the attack demo
  probes are forwarded to a loopback address on the host, so nothing is
  reachable from outside M2.
- **B, Secure GPU Stack:** booted with `cloud-init/lambda-user-data.yaml`,
  pointing at the published v0.1.0 release on GitHub with its SHA-256 pinned.
  All 49 files in that tarball match the `v0.1.0` git tag. This is the path a
  Lambda customer would take.
- **A, Lambda Stack:** Lambda's `install-lambda-stack.sh` (SHA-256
  `1594f8d3…`), with `I_AGREE_TO_THE_CUDNN_LICENSE=1`, the license accepted by
  the user. It didn't install as published; see Lambda Stack finding 15 and
  "Lambda Stack on the same GPU" below.

## What it found

All fixed in this repository and verified on M2. Numbering continues from krabs.

### Stack bugs (installed fine, didn't work as claimed)

77. **Every TensorFlow convolution failed.** TensorFlow's cuDNN opens two of its
    sub-libraries by their full version (`libcudnn_graph.so.9.27.0`,
    `libcudnn_ops.so.9.27.0`), but the wheel names its files only `.so.9`. Its
    own folder is searched first and has no such name, so the system-wide CUDA
    13 cuDNN answered: same version number, other CUDA build. One process then
    mapped both builds, and convolutions failed with `cudnn status 1008`
    (sub-library loading failed). Matrix multiplies still worked, which is why
    nothing caught it (finding 80). krabs couldn't show it, because Pascal has
    no cuDNN 9.27 convolution kernels at all. Fixed: the installer gives the
    wheel's files their full-version names too (links), so the lookup finds
    TensorFlow's own copies, which are already loaded. After the fix a
    TensorFlow process maps cuDNN only from `/opt/sgs/tf-cuda12`, and Keras
    training works. PyTorch was never affected: it maps only its own cuDNN.
78. **`fs.suid_dumpable = 0` lasted until the first reboot.** Round AA's pin
    is applied by systemd at 2.5 s into boot. At 5.3 s apport, Ubuntu's crash
    reporter, starts and writes `2`. The earlier VM runs checked before
    rebooting. `sgs-check` caught it on the first boot of a fresh cloud image.
    Fixed: a drop-in puts 0 back after apport starts (`ExecStartPost`), and
    it's in the integrity record. Verified across a reboot.
79. **TensorFlow's XLA compiler couldn't find `ptxas` without a CUDA
    toolkit.** XLA (which Keras `model.fit` uses) looks for NVIDIA's GPU
    assembler on PATH, in `/usr/local/cuda` and in a CUDA 12 wheel next to
    TensorFlow, never in `/opt/sgs/tf-cuda12`. With `--no-cuda-toolkit` it
    found none, and every compiled convolution failed ("Autotuner could not
    compile any configs"). With the toolkit it silently used CUDA 13's tools.
    Found on M2's own host. Fixed: the TensorFlow hook points XLA at
    TensorFlow's own CUDA 12 tools (`--xla_gpu_cuda_data_dir`), unless the
    user set that flag. JAX still works when it inherits the setting.

### sgs-check blind spots

80. **The GPU test passed a TensorFlow that couldn't run a convolution.** It
    only multiplied matrices, which never touches cuDNN. Fixed: each framework
    also runs a convolution. A failed convolution is a WARN, except
    TensorFlow on a pre-Turing GPU, where it's an expected SKIP.
81. **IPython's own README flagged every new Jupyter user.** IPython writes
    `startup/README` the first time a kernel starts, and the startup-file
    watch (Round W) covered that whole folder. IPython only runs `*.py` and
    `*.ipy` there, so that's what's watched now. A planted `00-planted.py` is
    still caught, and the upgrade raised no "new watched place" alarm,
    because the installer accepts new places.

The test tooling had its own bug, fixed along the way: `vm.sh` exited
silently under `set -e` because an array assignment takes the exit status of
the `$(…)` inside it.

## What it confirmed (krabs couldn't)

Secure GPU Stack v0.1.0, installed by cloud-init from the published release,
then upgraded with the fixes above:

| Check | Result |
|---|---|
| Install and reboot | 8 minutes, unattended |
| Driver path for Turing and newer | NVIDIA's **open** kernel module 580.178.04 (Dual MIT/GPL), Ubuntu's prebuilt modules signed by Canonical, no DKMS |
| Kernel lockdown | `[integrity]` after the reboot, with `nvidia-smi` working |
| GPU device files | `root:video 0660`, locked; `nobody` tried 1,222,020 times while root used the GPU and opened none |
| `sgs-check --gpu-test` | v0.1.0: 55 PASS, 1 WARN (finding 78), 0 SKIP, with TensorFlow convolutions silently broken. With the fixes: **56 PASS, 0 WARN, 0 SKIP** |
| PyTorch 2.15 | Convolutions match the CPU; ResNet-18 trains at 2,648 img/s; `torch.compile` (Triton) works; single-GPU NCCL `all_reduce` works |
| JAX 0.12 | bf16 matmul 61.3 TFLOP/s; convolution with gradients |
| TensorFlow 2.21 | With the fixes: convolutions match the CPU, Keras `model.fit` works |
| JupyterLab through the SSH tunnel | A PyTorch cell (bf16 matmul 66.7 TFLOP/s, convolution) and a TensorFlow convolution, sent over the kernel websocket by `tests/jupyter-cell.py`. A notebook can't connect to Docker's socket (permission denied) |
| User checks | 13/13 |
| Attack demo | 9/9 |
| GPU memory between users | One account filled 8.4 GB with a marker; the next account found it 0 times |

## Lambda Stack on the same GPU

**The published install failed** (Lambda Stack finding 15). On this kernel,
Lambda's 570.207 driver doesn't compile under DKMS
(`nv-pci.c:240: too few arguments to function 'pci_resize_resource'`), and
neither does Lambda's 580.119.02 when the script asks for R580. To still get a
baseline, A got **the same driver as B**: Ubuntu's prebuilt 580.178.04-server,
through an apt pin for just that driver family
(`tests/results/m2-2026-10-29/a-lambda-script-and-pin.txt`). Then
`lambda-stack-cuda` was installed exactly as the script's last step does.
Everything below is Lambda Stack's own.

| Check | Lambda Stack (A) | Secure GPU Stack (B) |
|---|---|---|
| `sgs-check --gpu-test` (same version) | 19 PASS, 18 WARN, 2 SKIP. One WARN is the baseline's driver pin, so 17 are Lambda Stack's | 56 PASS, 0 WARN, 0 SKIP |
| GPU device files | `0666`, still after `sudo nvidia-smi`. `nobody` ran `nvidia-smi` and allocated 4 GB on the GPU | `root:video 0660`, locked |
| Kernel lockdown | `[none]` | `[integrity]` |
| io_uring, line disciplines, `suid_dumpable` | Open to all users, autoload on, 2 | Root only, off, 0 |
| Firewall | Inactive | Incoming blocked except SSH |
| SSH | `PermitRootLogin without-password` (root may log in with a key), X11 forwarding on | No root login, no X11 forwarding |
| Frameworks | PyTorch 2.7.0, TensorFlow 2.19.0, JAX 0.6.0, Keras 3.10.0 | PyTorch 2.15.0, TensorFlow 2.21.0, JAX 0.12.0.1, Keras 3.15.1 |
| Known vulnerabilities (pip-audit) | 44 advisories: Keras 28, PyTorch 15, fsspec 1 | None in 178 packages |
| Convolutions on the GPU, all three frameworks | Yes | Yes (after finding 77) |
| `torch.compile` | Fails: no `Python.h`, because the headless install leaves out `python3-dev` | Works |
| Audit log | `auditd` not installed | 23 rules |

All of A's WARNs are findings already in `docs/lambda-stack-findings.md`,
now seen with a GPU. The one about GPU device files settles an item that doc
listed as "not yet verified". `apt full-upgrade -s` ran without errors on A,
but A has Ubuntu's driver rather than Lambda's, so this says nothing about the
failure Lambda's docs describe.

## Speed

`tests/gpu-bench.py`, 100 steps, the median of three runs. ResNet-50 and a
small GPT-style model, both trained in bf16.

| Where | PyTorch | bf16 matmul (TFLOP/s) | ResNet-50 (images/s) | GPT (tokens/s) |
|---|---|---|---|---|
| M2's host, bare metal (driver 615, login screen on the GPU) | 2.15.0 | 66.0 | 904 | 62,912 |
| B: Secure GPU Stack, VM (driver 580) | 2.15.0 | 66.8 | 919 | 63,948 |
| A: Lambda Stack, VM (driver 580) | 2.7.0 | 66.8 | 902 | 63,465 |

- **Passing the GPU to a VM costs nothing measurable.** B is slightly faster
  than the host, which also drives the screen.
- **The security work costs nothing either.** On the same driver, B is
  within 2% of Lambda Stack and slightly ahead, most likely from its newer
  PyTorch and cuDNN (9.26 against 9.8).

## What M2 can't prove

- **Lambda's own cloud image:** whether its JupyterLab is exposed, default
  users and sudo, what its metadata address serves, and whether it boots with
  Secure Boot.
- **Whether existing Lambda Stack machines lose their driver on this kernel**
  (finding 15's second impact). That needs one on an older kernel.
- **Data-center features:** A100/H100 behaviour, MIG, NVLink, multi-GPU NCCL,
  NVSwitch and Fabric Manager.
- **The `apt full-upgrade` failure** Lambda documents, which needs Lambda's
  own driver packages.

`docs/lambda-test-plan.md` still covers these.

## Rebuilding the bench

On a Linux host with an IOMMU and an NVIDIA GPU (everything as root except
`vm.sh ssh`), with the Ubuntu cloud image and a `vm-key` next to the scripts:

```bash
sudo ./vm.sh create b 127.0.0.2 b-user-data
```

```bash
sudo ./gpu-handoff.sh to-vm
```

```bash
sudo ./vm.sh start b --gpu
```

```bash
./vm.sh ssh b sudo sgs-check --gpu-test
```

```bash
sudo ./vm.sh stop b
```

```bash
sudo ./gpu-handoff.sh to-host
```

The attack demo runs from the host against the VM's loopback address, with
SSH on port 2222 (an `~/.ssh/config` entry: `Host 127.0.0.2`, `Port 2222`):

```bash
bash attack-demo.sh 127.0.0.2 vm-key ubuntu
```
