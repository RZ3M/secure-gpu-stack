# Lambda Cloud, instance B: Secure GPU Stack 0.1.2 (2026-10-30)

Raw output from instance B (1x A100 instance, A100-SXM4-80GB attached,
Lambda's Ubuntu 24.04.2 image). The write-up, findings 86–90 and the
comparison with Lambda Stack are in `docs/lambda-test-bench.md`.

| File | What |
|---|---|
| `install.log` | First install (exit 0, 18 min 42 s) |
| `sgs-check.txt` | `sgs-check --gpu-test` after the first install and reboot: 58 PASS / 0 WARN |
| `sgs-check-final.txt` | The same at the end, with every fix in place, after a cold reboot: 58 PASS / 0 WARN |
| `user-checks.txt` | `tests/user-checks.sh`: all 13 pass |
| `attack-demo.txt` | `tests/attack-demo.sh` from the Mac: 7 PASS, 1 SKIP (Lambda's firewall blocks the Docker-port control) |
| `pytorch-conv.txt` | PyTorch convolution, cuDNN 9.26, NCCL 2.30.7, CUDA 13.2 |
| `cache-and-memory.txt` | `torch.compile` cache attack (SAFE); GPU memory across users (0 marker hits in 72 GB) |
| `gpu-bench.jsonl` | Secure GPU Stack, three runs |
| `gpu-bench-lambda-torch.jsonl` | Lambda Stack's PyTorch 2.7.0+cu128 on the same GPU, three runs |
| `extra-checks.txt` | Metadata, persistenced, GPU container, `apt full-upgrade -s`, `/etc/nccl.conf` |
| `mig.txt` | MIG slices: memory across users, device files; finding 86 as found |
| `fix86-before-reboot.txt`, `fix86-after-reboot.txt` | Finding 86's fix, with MIG management still working |
| `reprove.txt` | Earlier findings attacked directly; finding 87's fix |
| `mixed-frameworks.txt` | Finding 88: which PyTorch/TensorFlow/JAX mixes warn, fail or work |
| `hw-tests.txt` | Findings 89 and 90: persistenced socket, CUDA start-up times, NCCL, memory with persistence mode |
| `final-reboot.txt` | Cold reboot with every fix in place |
| `egress-strict.txt` | Strict outbound mode, before and after a reboot, then off |
| `lambda-vendor-data.txt` | Lambda's first-boot cloud-init vendor data (no secrets in it) |
