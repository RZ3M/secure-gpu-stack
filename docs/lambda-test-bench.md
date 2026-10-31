# Lambda Cloud: the stack on a real Lambda A100

The last open item of the plan (`docs/lambda-test-plan.md`): the stack on
Lambda's own machines, with a data-center GPU, instead of krabs's laptop GPU
or M2's desktop card in a VM. Tested on 2026-10-30, on two single-GPU A100
instances in Lambda's Virginia region (the only GPU types Lambda had free were
1x A10 and 1x A100):

- **Instance A, "before":** Lambda's default image, Lambda Stack 24.04.
  Audited by another agent; its report is `docs/lambda-instance-audit.md`
  (evidence in `docs/audit/`).
- **Instance B, "after":** Lambda's plain Ubuntu 24.04 image with Secure GPU
  Stack 0.1.2 installed. This document. Raw output is in
  `tests/results/lambda/b/`.

**Bottom line:** the stack installs unattended on Lambda's image, runs all
three frameworks on the A100 at full speed, and every security property
proven earlier on VMs, krabs and M2 held on Lambda's hardware when attacked
directly. Lambda's hardware also turned up five new findings (86–90). All are
fixed and re-verified on the same instance, through cold reboots. Final
`sgs-check --gpu-test`: **58 PASS, 0 WARN, 0 SKIP**, against Lambda Stack's
**24 PASS, 30 WARN, 1 SKIP** on the same kind of instance.

## The setup (instance B)

| | |
|---|---|
| Instance type | 1x A100 (40 GB SXM4), $1.99/hr, launched from the console |
| GPU actually attached | **A100-SXM4-80GB** (81,920 MiB, PCI ID `10de:20b2`). Instance A, same type, got a 40 GB card |
| Image | Lambda's "Ubuntu 24.04.2 LTS" |
| Kernel | the image ships 6.8.0-62; the machine booted 6.8.0-147 (GA line) after the install |
| Machine | KVM virtual machine, 30 vCPUs, 216 GB RAM, 512 GB virtio disk, BIOS boot: no EFI, so no Secure Boot |
| Network | only port 22 reachable from the internet (Lambda's default global firewall); private address on a shared `10.19.80.0/20` |
| Stack | 0.1.2: `855f399` plus this round's changes (committed after it on `stack/v0.1`), built with `scripts/release.sh` and copied over with `scp` |

Lambda takes cloud-init user data only through its API, and there was no API
key, so the release went over with `scp`, its checksum was checked, and
`install.sh` ran by hand. The cloud-init wrapper is still untested on Lambda.

- **Install:** exit 0 in **18 min 42 s**, most of it the Python stack. A
  re-run over an existing install takes about 45 s.
- **Driver path:** Ubuntu's prebuilt, Canonical-signed open kernel modules
  (`linux-modules-nvidia-580-server-open-6.8.0-147-generic`, driver
  580.178.04). No DKMS, so kernel lockdown stays on.
- **Reboot:** back on SSH in about 40 s, `lockdown=integrity` on the kernel
  line, `[integrity]` in `/sys/kernel/security/lockdown`, `nvidia-smi` working.

## Before and after

| | A: Lambda Stack (Lambda's default image) | B: Secure GPU Stack |
|---|---|---|
| `sgs-check --gpu-test` | 24 PASS, **30 WARN**, 1 SKIP | 58 PASS, **0 WARN**, 0 SKIP |
| JupyterLab | Public on the internet over plain HTTP through a Cloudflare tunnel, token in the URL; Jupyter runs as a passwordless sudoer | A private Unix socket, reached through an SSH tunnel; token required; sandboxed service |
| Security updates | 228 pending, automatic updates off | Automatic; `apt full-upgrade` works, driver and CUDA pins hold |
| GPU device files | `0666`: any account can use the GPU | `root:video 0660`, locked; `nobody` failed 771,450 tries while root used the GPU |
| Kernel | lockdown `none`; io_uring, user namespaces (`aa-exec` bypass) and line-discipline loading open | lockdown `integrity`; all three refused (tested below) |
| Host firewall | Inactive | Incoming blocked except SSH |
| Audit log | No `auditd` | 24 rules, checked live |
| `torch.compile` cache in `/tmp` | Shared, group-writable | Private (attack: SAFE) |
| PyTorch, JAX, TensorFlow on the GPU, convolutions included | Yes (PyTorch 2.7.0, JAX 0.6.0, TensorFlow 2.19.0) | Yes (PyTorch 2.15.0, JAX 0.12.0.1, TensorFlow 2.21.0) |

The A column comes from `docs/lambda-instance-audit.md`, which rates
Lambda Stack's image at 2 Critical, 9 High, 7 Medium and 4 Low findings.

## Speed

`tests/gpu-bench.py`, 100 steps, the median of three runs, nothing else on
the GPU. A and B had different cards (40 GB against 80 GB, whose memory is
faster), so A's numbers wouldn't be a fair comparison. Instead, Lambda Stack's
PyTorch version (2.7.0, CUDA 12.8, from PyTorch's own index) was installed in
a throwaway environment on B and run on **the same GPU**:

| On B's A100-SXM4-80GB | PyTorch | cuDNN | bf16 matmul (TFLOP/s) | ResNet-50 (images/s) | GPT (tokens/s) |
|---|---|---|---|---|---|
| Lambda Stack's PyTorch | 2.7.0+cu128 | 9.7 | 250.4 | 1,900 | 177,696 |
| Secure GPU Stack, shell | 2.15.0+cu132 | 9.26 | 245.8 | **1,943** | **187,640** |
| Secure GPU Stack, in a notebook kernel (one run, through the SSH tunnel) | 2.15.0+cu132 | 9.26 | 245.9 | 1,917 | 186,719 |

- **The security work costs nothing.** The stack trains 2% faster on
  ResNet-50 and 6% faster on the GPT model, most likely from its newer
  PyTorch and cuDNN. The matmul figure is within run-to-run noise (Lambda's
  runs ranged 244–259).
- **The sandboxed notebook kernel runs as fast as a shell** (within about
  1%), as Round S found on krabs.
- `sgs-check`'s fp32 matmul figures were close on both instances (PyTorch
  14.6 on A, 15.4 on B; TensorFlow 19.4 and 19.2 TFLOP/s).

## What it found

Numbering continues from M2 (77–85). All five are fixed in this repository and
verified on instance B.

86. **Turning MIG on opened a GPU device file to every account.** MIG
    (Multi-Instance GPU) splits an A100 into isolated slices.
    `sudo nvidia-smi -i 0 -mig 1` made root's NVIDIA library create
    `/dev/nvidia-nvswitchctl` 0666, on a machine with no NVSwitch at all, and
    `nobody` opened it read-write. The stack's lock covered only the files
    CUDA uses. `sgs-check` caught it at once (54 PASS, 1 WARN).
    - **The fix:** `sgs-gpu-devices` creates it `root:video` 0660 and locks
      it, whenever the driver has registered NVSwitch (it does on every
      machine). `sgs-check` holds it to the same standard as the CUDA files.
    - **Verified:** locked after a re-install and after a cold reboot; root
      still created and destroyed MIG slices and turned MIG off and on;
      `nobody` was refused.
87. **A fresh install didn't audit the container device specs.** The
    installer wrote audit watches only for paths that already existed.
    `/var/run/cdi` (the spec that says what devices and hooks GPU containers
    get) appears only at the first boot, and `/etc/cdi` doesn't exist on
    Lambda's image at all, though a spec planted there is honored. The first
    install had 22 rules; a re-run after the reboot, 23.
    - **The fix:** a path is watched if it or its folder exists; the kernel
      then records the path's creation. Only a missing folder stops auditd
      loading the rest.
    - **Verified:** 24 rules; creating `/etc/cdi/sgs-probe.yaml` was
      recorded; a write into `/run/cdi`, created after the rules loaded, was
      recorded too.
88. **A notebook that used PyTorch and TensorFlow died without a word.** The
    stack gives TensorFlow its own CUDA 12 libraries, separate from the CUDA
    13 ones PyTorch uses, but cuDNN and NCCL have the same names in both, so
    one process can only hold one build. On the A100, `import tensorflow`
    then a PyTorch convolution was a floating point exception that killed
    the process (in JupyterLab, the kernel restarted and the cell never
    returned). The other order failed TensorFlow's convolutions with cuDNN
    status 1008. `design.md` mentioned the trade-off; users were never told.
    On Lambda Stack all three frameworks share one CUDA, so the same notebook
    is expected to work there (not checked on A).
    - **The fix:** whichever of the two loads second prints a
      `RuntimeWarning` that names the problem and says to use separate
      processes. It shows in the notebook cell's output before anything
      fails. It fires on a real import only, not when a library only asks
      whether the other is installed.
    - **Verified:** no warning for PyTorch alone, TensorFlow alone, Keras
      `model.fit`, `find_spec` probes, or TensorFlow with JAX (which work
      together on the GPU; `tensorflow.lite` imports JAX itself). The
      warning appears for both PyTorch and TensorFlow orders, including in a
      notebook cell through the SSH tunnel.
89. **Any account could talk to `nvidia-persistenced`.** Its control socket,
    `/run/nvidia-persistenced/socket`, is 0777 (on Lambda Stack too). The
    daemon runs with the video group, which holds the GPU, so a bug in its
    request handling would let a service account past the "GPU for `video`
    only" boundary the rest of the stack enforces.
    - **The fix:** the stack's drop-in closes the socket's folder to
      accounts outside `video` (0750 `nvidia-persistenced:video`). GPU
      containers get the socket mounted in, past the folder. But
      `nvidia-cdi-refresh` (root without `CAP_DAC_OVERRIDE`) could then no
      longer see it to add it to the container spec, so it gets the video
      group too. `sgs-check` warns if the folder is open again.
    - **Verified:** `nobody` refused, `video` members connect, root's
      `nvidia-smi -pm` works, the socket is in the CDI spec and inside root
      and non-root GPU containers, after a cold reboot.
90. **Every CUDA program paid about 3.5 s to start.** Ubuntu's unit runs
    `nvidia-persistenced --no-persistence-mode`, so the driver tears the GPU
    down whenever nothing has it open. On the A100: 3.4–3.9 s for each
    program's first CUDA call, 2 s for each `nvidia-smi`. With persistence
    mode, which NVIDIA recommends for data-center GPUs: 0.18 s and 26 ms.
    Not a security bug, but every script, notebook kernel and `nvidia-smi`
    paid it.
    - **The fix:** the installer turns persistence mode on, except on
      machines with a battery, where it would keep the GPU from powering
      down (krabs is a laptop).
    - **Verified:** on after a cold reboot; GPU memory is still cleared
      between users with it on (72 GB written by one user, read by another:
      marker found 0 times).

## Earlier findings, re-proved on Lambda's hardware

Each was attacked directly on B, not just read from settings
(`tests/results/lambda/b/reprove.txt` and the other files there).

| Earlier finding | The attack on B | Result |
|---|---|---|
| GPU device files (Round G) | `nobody` retrying `open()` on every `/dev/nvidia*` while root used the GPU | 0 of 771,450 tries succeeded |
| GPU memory between users (Round M) | 72 GB marker written by one user, fresh allocation read by another; also inside a MIG slice (36 GB) | Marker found 0 times, all bytes zero |
| io_uring (Round H) | `io_uring_setup` as `ubuntu` | Operation not permitted |
| User namespaces (Round J) | `unshare -Ur`, then through `aa-exec -p 1password` and `-p Discord` | All refused |
| Line disciplines (Round L) | Attach PPP, HDLC, GSM to a pty as `ubuntu` | All refused, no module loaded |
| Kernel lockdown (Round Y) | Root reads `/dev/mem` | Refused (`/proc/kcore` stays readable: that needs `confidentiality`, not `integrity`) |
| Cloud metadata (Rounds V, X) | `curl 169.254.169.254` as `ubuntu`, from a bridge container and a host-network container | Refused in 9 ms; both containers refused; root still reaches it |
| Docker (rule 5, section 6) | `docker ps` without sudo; `docker run -p 8080:8080` | Permission denied; listens on 127.0.0.1 only |
| Root containers named (Round P) | `docker run --privileged` | `sgs-check` WARN names it |
| Persistence watch (Rounds W, Z) | Add a line to `~/.bashrc` and a crontab entry | `sgs-check` WARN names both; back to 0 WARN after undoing |
| `torch.compile` cache (finding 83) | `tests/compile-cache-attack.sh` | SAFE |
| Strict umask installs (finding 84) | Re-install under `umask 077` | Exit 0; `nobody` still imports the frameworks |
| Daily check, login message (Round N) | Start `sgs-check.service`; read the message of the day | Runs, succeeds, message shown |
| Jupyter (Round I) | From the Mac: no token, then a GPU cell through `ssh -L` to the socket | 403 without the token; PyTorch and TensorFlow cells ran on the A100 |
| Strict outbound mode (section 11) | As `ubuntu`: other domains, raw IP, a name not on the list, DNS to 8.8.8.8, containers; then a reboot in strict mode | All refused; PyPI, PyTorch's index, Hugging Face, GitHub, `pip download` and apt worked; same after the reboot, SSH back in 33 s |
| SSH | `sshd -T` | Keys only, no root login, no X11 forwarding |
| Patching | `apt-get full-upgrade -s` | Works: 70 bug-fix updates, none of them driver, CUDA, cuDNN, NCCL or Docker |

The strict outbound mode had only run on VMs before, and one VM had become
unreachable after a reboot in strict mode. On Lambda it came back normally.
It's still marked experimental, since that VM's failure was never explained.

## What Lambda does on every instance

Lambda hands cloud-init its data on a small virtual disk, `/dev/vdb`
(iso9660, label `cidata`, `root:disk` 0660, so ordinary users can't read it).
Its vendor data, saved in `tests/results/lambda/b/lambda-vendor-data.txt`,
runs as root at the first boot of **every** image, plain Ubuntu included:

- `systemctl disable --now nvidia-fabricmanager`, unconditionally.
- `/etc/nccl.conf` with `NCCL_IB_DISABLE=1`. NCCL picked it up on B and used
  sockets; with one GPU that changes nothing.
- A Python health check that reports to Lambda's host over a virtio serial
  port: network, GPU count through PyTorch, whether the image is Lambda's own
  (`is_lambda_image`), and on 8x H100 or B200 the NVLink topology. When that
  topology looks wrong, it restarts `nvidia-persistenced` to work around a
  driver bug (Lambda's ticket PRIM-349). The stack changes that service
  (finding 89 and 90 drop-ins, the video group), so test that restart on an
  8-GPU instance.

An nginx answers at 169.254.169.254 with 404 on the usual metadata paths. The
stack blocks it for everyone but root anyway.

## Hardware notes

- **BIOS boot, no Secure Boot:** kernel lockdown comes from the kernel line
  (`lockdown=integrity`), which the installer adds when there's no DKMS module.
- **The image's kernel is old** (6.8.0-62); the current GA kernel and its
  prebuilt NVIDIA modules were installed, and the reboot loaded them.
- **MIG works inside Lambda's VM** without a reboot; MIG mode survives a
  reboot, the slices don't.
- **No NVSwitch is visible** on the 1x A100, so the installer didn't add
  Fabric Manager. Correct here.
- **NCCL with the separated libraries:** a one-GPU `torchrun` all-reduce
  worked (NCCL 2.30.7).
- **TensorBoard isn't shipped**, so `torch.utils.tensorboard` fails to import.
  A v0.2 candidate if Lambda Stack ships it.

## Testing notes for next time

- **ausearch over `ssh`:** without a terminal it reads standard input, not the
  log, and finds nothing. Use `ausearch --input-logs`. This briefly looked like
  a broken audit setup.
- **A notebook cell that never returns** was a kernel that died and was
  restarted (the Jupyter service log says "restarting kernel"), or a race in
  `tests/jupyter-cell.py`: it waited for the cell's reply and then "idle",
  and hung when they came the other way round. It now accepts either order,
  fails when the kernel dies, and gives up after `CELL_TIMEOUT` seconds.
- **After a reboot, wait a few seconds** before checking
  `/run/nvidia-persistenced`: it's created at 0755 and closed by the
  service's post-start step about a second later.
- **From the Mac:** the shell is zsh, so put SSH options in an array
  (`O=(-o ...); ssh "${O[@]}"`); there's no `timeout` command;
  `tests/jupyter-cell.py` needs `tornado` (a scratch venv works); run `ssh` and
  `scp` with the Bash sandbox disabled.

## What this didn't cover

- **Multi-GPU:** NCCL across GPUs, Fabric Manager on NVSwitch, the per-switch
  NVSwitch device files, Lambda's `nvidia-persistenced` restart on 8x
  H100/B200, multi-node NCCL over InfiniBand. Needs an 8-GPU instance.
- **The cloud-init wrapper on Lambda.** Needs a Lambda API key.
- **The Docker-port defaults from outside:** Lambda's firewall blocks even the
  deliberately public demo container, so the attack demo SKIPs that part. It
  was shown on M2, and on B the port listened on 127.0.0.1 only.
- **Lambda Stack with PyTorch and TensorFlow in one process** (finding 88's
  comparison) and whether it ships TensorBoard: not checked on A.

## Re-running on a new instance

Launch "Ubuntu 24.04" from the Lambda console with your SSH key and no
filesystem, then from this repository:

```bash
scripts/release.sh
scp dist/secure-gpu-stack-0.1.2.tar.gz dist/SHA256SUMS tests/gpu-bench.py tests/gpu-memory-test.py tests/compile-cache-attack.sh ubuntu@IP:
ssh ubuntu@IP 'sha256sum -c SHA256SUMS && tar -xzf secure-gpu-stack-0.1.2.tar.gz && sudo secure-gpu-stack-0.1.2/install.sh && sudo reboot'
ssh ubuntu@IP 'sudo sgs-check --gpu-test; bash -l secure-gpu-stack-0.1.2/tests/user-checks.sh'
tests/attack-demo.sh IP
```

Then the speed runs (`python3 gpu-bench.py 100`, three times), the memory
test across two users, and the attacks in the table above. Terminate the
instance afterwards: Lambda bills while it runs.
