# 05 — GPU and container security: Lambda Stack 24.04 on a live instance

**Audited:** 2026-10-30, `ubuntu@<instance>` — Ubuntu 24.04.4, kernel 6.8.0-1046-nvidia, A100-SXM4-40GB, driver 580.105.08 (open
module), Docker 29.2.1 / containerd 2.2.1 / runc 1.3.4, toolkit 1.18.1. Read-only; the only GPU work was a 64 MiB allocation and the
existing zeroing test. No fixes applied; test containers/image and `/tmp` files removed.

**Scope:** GPU device permissions and isolation, driver, NVIDIA Container Toolkit, Docker/containerd, container escape surface, GPU
scheduling. Confirms `docs/lambda-stack-findings.md` #4 **at NVIDIA's source** (unconfirmed there) and supplies the live evidence for that
file's "Not yet verified" GPU-device item.

## Summary — 0 Critical, 3 High, 3 Medium, 3 Low

| ID | Finding | Severity | Status |
|---|---|---|---|
| GPU-01 | GPU device nodes are world-writable (0666): any local account can use the GPU | High | Verified |
| GPU-02 | Driver 580.105.08 predates the R580 fix 580.178.04; the Lambda pin blocks it | High | Verified, CVE at source |
| GPU-03 | Container Toolkit 1.18.1 affected by CVE-2026-24260 (CVSS 8.5) | High | Verified, CVE at source |
| GPU-04 | No GPU memory isolation: one user or container can take all 40 GB | Medium | Verified |
| GPU-05 | Containers run as root, no userns-remap; `--gpus all` hands over the GPU | Medium | Verified |
| GPU-06 | Docker defaults: uncapped logs, bridge with ICC + masquerade | Medium | Verified |
| GPU-07 | Stale runc 1.3.4 / containerd 2.2.1 (DoS, image-integrity advisories) | Low | Verified |
| GPU-08 | Unsigned out-of-tree DKMS modules; no lockdown; OFED/xpmem/knem added | Low | Verified |
| GPU-09 | Host persistenced socket (0777) and CDI spec exposed to users/containers | Low | Verified |

## GPU-01 — GPU device nodes are world-writable: any local user owns the GPU — **High**

**Verified.**

```text
$ ls -l /dev/nvidia*
crw-rw-rw- 1 root root 195, 254 /dev/nvidia-modeset
crw-rw-rw- 1 root root 234,   0 /dev/nvidia-uvm
crw-rw-rw- 1 root root 234,   1 /dev/nvidia-uvm-tools
crw-rw-rw- 1 root root 195,   0 /dev/nvidia0
crw-rw-rw- 1 root root 195, 255 /dev/nvidiactl
$ sudo -u nobody nvidia-smi -L
GPU 0: NVIDIA A100-SXM4-40GB (UUID: GPU-ac7f697f-e000-eda0-00c9-bff83a7da6c3)
$ sudo -u nobody env HOME=/tmp python3 -c 'import torch; ... 64 MiB ...'
uid 65534 / cuda avail True / allocated 64 MiB on NVIDIA A100-SXM4-40GB
```

The cause is the driver packaging, not a Lambda edit: `NVreg_DeviceFileMode=438` (0666), `DeviceFileGID=0`, and
`/lib/nvidia/bin/manage-device-nodes`, which runs `mknod -m 0666`. `/dev/dri/*` are correctly `660 root:video`/`render`.

**Impact.** Any local account — second admin, service account, Jupyter kernel, non-root container — can allocate GPU memory, run GPU work
and submit driver ioctls (GPU-02's precondition), with no accounting and a trivial DoS. `nvidia-smi` showed a `nobody`-owned process to
`ubuntu`. On this single-user box `ubuntu` already has `NOPASSWD: ALL`, so the exposure is the multi-user and service-account posture rather
than that account. **Remediation.** `0660 root:video` plus `NVreg_DeviceFileGID=44`, trusted users only, or 0440 nodes locked with a
read-only bind mount (SGS `docs/design.md` §10 tests this and closes the udev race).

## GPU-02 — Driver 580.105.08 is months behind the R580 security fix — **High**

**Verified on the instance; affected range confirmed at NVIDIA's source.**

```text
$ cat /proc/driver/nvidia/version
NVRM version: ... 580.105.08 ... Wed Oct 29 22:29:53 UTC 2025
$ apt-cache policy nvidia-driver-580-server-open
  Candidate: 580.105.08-0lambda0.24.04.1     # headless metapackage is installed
     580.178.04-0ubuntu0.24.04.1 500  noble-updates, noble-security/restricted
     580.105.08-0lambda0.24.04.1 1001 http://archive.lambdalabs.com/ubuntu
```

NVIDIA bulletin **5861** (Sept 2026, updated 2026-09-30): Tesla / Linux(R580), *"All driver versions prior to 580.178.04"* affected, fixed
**580.178.04**. Dozens of 7.8-High bugs needing only an unprivileged local user: CVE-2026-47561 (unvalidated ioctl size → kernel OOB write),
CVE-2026-47559 (read another user's process memory), CVE-2026-47599/-47601 (open module DMA-mapping permissions), CVE-2026-47572 (type
confusion). Ubuntu ships the fix in `noble-security`, but Lambda's `Pin-Priority: 1001` wins and unattended-upgrades covers Ubuntu origins
only, so it never installs automatically.

**Impact.** Kernel-level code execution, privilege escalation and cross-process GPU memory disclosure from any local account — and GPU-01
makes every account qualify. The most consequential item here. **Remediation.** 580.178.04+ from `noble-security` (or NVIDIA's repo), scope
or drop the Lambda pin, add the origin to unattended-upgrades, stay on R580 (R570 is EOL). Ref: [bulletin
5861](https://github.com/NVIDIA/product-security/blob/main/2026/5861/5861.md).

## GPU-03 — Container Toolkit 1.18.1 is affected by CVE-2026-24260 — **High**

**Verified on the instance; CVE confirmed at NVIDIA's source.**

```text
$ nvidia-container-cli --version → cli-version: 1.18.1, lib-version: 1.18.1
$ apt-cache policy nvidia-container-toolkit
  Installed: 1.18.1-0lambda0.24.04.1
     1.20.1-1 500 https://nvidia.github.io/libnvidia-container/stable/deb/amd64
 *** 1.18.1-0lambda0.24.04.1 1001 http://archive.lambdalabs.com/ubuntu
```

NVIDIA bulletin **5850** (June 2026, updated 2026-06-30): **CVE-2026-24260**, CWE-367 TOCTOU race, CVSS **8.5**, "all versions up to and
including 1.19.0" affected, fixed **1.19.1**; code execution, privilege escalation, data tampering. This resolves `lambda-stack-findings.md`
#4: the CVE is real and the image is in range. NVIDIA's repo is configured and carries 1.20.1, but the pin holds 1.18.1, and
unattended-upgrades cannot update a Lambda-origin package.

**Impact.** Container escape / host code execution from a crafted container configuration, on a machine built to run third-party ML images.
**Remediation.** 1.19.1+ (ideally 1.20.1) from NVIDIA's repo, drop the pin for this package, add the NVIDIA origin to unattended-upgrades.
Ref: [bulletin 5850](https://github.com/NVIDIA/product-security/blob/main/2026/5850/5850.md).

## GPU-04 — No GPU memory isolation; one process can take the whole card — **Medium**

**Verified (allocation); full exhaustion not attempted.**

```text
$ nvidia-smi --query-gpu=mig.mode.current,compute_mode --format=csv
Disabled, Default
$ nvidia-smi mig -lgip   → 1g.5gb … 7g.40gb profiles available but unused
```

An 8 GB allocation from `nobody` succeeded with no error or accounting (GPU-01 and the zeroing test below). GPU memory is not a cgroup
resource, MIG is off, MPS is not running, and there is no per-user or per-container cap — first process to ask gets all 40 GB.

**Impact.** Trivial denial of service against co-tenants and jobs, unbounded noisy-neighbour effects, no way to give two users or containers
a slice. **Remediation.** For multi-tenant use, enable MIG (1g.5gb–7g.40gb) and hand out instances, or run MPS with limits; otherwise
document the single-tenant assumption.

## GPU-05 — Containers are root, with no userns-remap, and `--gpus all` gives the GPU — **Medium**

**Verified.**

```text
$ ls /etc/docker/daemon.json        # absent — no configuration at all
$ sudo docker info | sed -n '/Security Options/,/Kernel/p'
 apparmor / seccomp (Profile: builtin) / cgroupns
$ systemctl cat docker | grep ExecStart
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
$ sudo docker run --rm --gpus all ... --entrypoint /bin/sh ...   # inside:
crw-rw-rw- 1 0 0 195, 0 /dev/nvidia0      crw-rw-rw- 1 0 0 234, 0 /dev/nvidia-uvm
crw-rw-rw- 1 0 0 195, 255 /dev/nvidiactl  crw-rw-rw- 1 0 0 195, 254 /dev/nvidia-modeset
uid=0 gid=0 groups=0
```

`--gpus all` works out of the box: Docker 29 resolves it through CDI (the toolkit's `update-ldcache` hook runs) although no `nvidia` runtime
is registered; `--device nvidia.com/gpu=all` does the same. Without either flag a container gets no GPU (control: no `/dev/nvidia*`), so the
GPU is not exposed by default — only whenever an operator asks. No `daemon.json` means defaults everywhere: no `userns-remap`, no default
`no-new-privileges`, `live-restore` off, json-file logs uncapped. The `docker` group exists but is **empty** and the socket is `660
root:docker`, so today only root reaches the API — but adding one user to `docker` is root.

**Impact.** Any container is uid 0 with default capabilities and no user namespace, so an escape or a `--privileged`/host-namespace
container is host root. A GPU container also holds every 0666 node, so the container boundary adds nothing to GPU isolation.
**Remediation.** Keep the group empty and use `sudo docker` (as now); prefer rootless Docker or userns-remap; set `no-new-privileges` by
default; grant `--gpus all` only where needed.

## GPU-06 — Docker networking and logging left at permissive defaults — **Medium**

**Verified config; metadata reachability inferred, not tested.**

```text
$ sudo docker info | grep -E 'Logging Driver|Firewall Backend'
Logging Driver: json-file     Firewall Backend: iptables
$ sudo docker network inspect bridge --format '{{.IPAM.Config}} {{.Options}}'
[{172.17.0.0/16  172.17.0.1}] map[enable_icc:true enable_ip_masquerade:true
 host_binding_ipv4:0.0.0.0]
```

**Impact.** Inter-container traffic is on, containers are NATed to the instance network, and json-file logs have no `max-size`/`max-file`,
so a chatty container can fill `/var/lib/docker` until the host is unusable. Default bridge plus masquerade also lets a container reach
`169.254.169.254` and the host network — the same gap as `lambda-stack-findings.md` #13, with containers as a second path. Metadata from a
container was not tested: no local image has `curl` and downloads were out of scope. **Remediation.** `log-opts` max-size/max-file; disable
ICC where containers need not talk; default address pools; block metadata from containers at the host firewall (SGS `sgs-guard`).

## GPU-07 — Container runtime is behind on published advisories — **Low**

**Verified versions, matched to OSV ranges.**

```text
$ runc --version → runc version 1.3.4
$ sudo docker version | grep -A2 containerd → Version: v2.2.1
```

OSV, checked 2026-10-30: **GHSA-xjvp-4fhw-gc47** (runc before **1.3.6**; a malicious image with a `/dev` symlink can cause limited host
filesystem integrity violations); **GHSA-jpcc-p29g-p8mq** (containerd 2.2.0–2.2.4, image-triggered runtime DoS); **GHSA-rp3h-jf77-q9p4**
(2.2.x before **2.2.8**, unpack DoS); **GHSA-pg57-6jwg-q645** (before **2.2.9**, image-pull DoS). The other 16 of containerd's 20 advisories
are CRI-only, and `disabled_plugins = ["cri"]` makes them inapplicable.

**Impact.** Availability and image-integrity problems reachable by running an untrusted image, not privilege escalation — low on a
single-tenant box, but the image invites pulling arbitrary ML containers. **Remediation.** Track docker-ce / containerd.io / runc from
Docker's repo and cover that origin in unattended-upgrades; it is already the configured repo, so this is an update-policy gap.

## GPU-08 — Unsigned out-of-tree kernel modules, no lockdown, extra module surface — **Low**

**Verified.**

```text
$ cat /proc/sys/kernel/tainted → 12288     (out-of-tree + unsigned)
$ cat /sys/module/nvidia/taint → OE
$ dmesg | grep -i taint
mlx_compat: loading out-of-tree module taints kernel.
mlx_compat: module verification failed: signature and/or required key missing
$ cat /sys/kernel/security/lockdown → [none] integrity confidentiality
$ dkms status → nvidia-srv/580.105.08, mlnx-ofed-kernel, iser, isert, srp, knem, …
```

The driver is DKMS-built (`/lib/modules/.../updates/dkms/nvidia.ko.zst`), not Ubuntu's signed prebuilt module; there is no Secure Boot
(`mokutil`: "EFI variables are not supported"), so lockdown can never turn itself on. The image also adds Mellanox OFED, `knem`, `xpmem` and
`kernel-mft` out-of-tree modules; `nvidia-fs` is packaged but not loaded, `nvidia_peermem` is loaded (expected).

**Impact.** Kernel integrity cannot be established — a tampered or rebuilt module is indistinguishable from the shipped one — and root can
load any module with no lockdown. `dpkg --verify` is clean today, so this is a detectability gap, not evidence of tampering.
**Remediation.** Prefer signed prebuilt modules; set `lockdown=integrity` once no local DKMS module must load (SGS Round Y); drop
OFED/xpmem/knem where multi-node RDMA is not needed; keep `dpkg --verify` in the check.

## GPU-09 — Host persistenced socket and CDI spec exposed to containers and users — **Low**

**Verified.**

```text
$ ls -l /run/nvidia-persistenced/
srwxrwxrwx 1 nvidia-persistenced ... socket
$ stat -c '%a %U:%G %n' /var/run/cdi/nvidia.yaml → 644 root:root
```

The CDI spec bind-mounts `/run/nvidia-persistenced/socket` into every GPU container (`ro,nosuid,nodev,noexec`), and read-only does not
prevent `connect()`. The spec is world-readable and lists host paths and driver versions.

**Impact.** Any local user, and any user inside a GPU container, can talk to a host daemon started by root. The incremental gain today is
small — GPU-01 already gives them the same devices — but the socket survives a GPU-01 fix. Low. **Remediation.** Drop the socket from the
CDI spec (or make it `0660 root:root`); make the spec `0640`; generate it from a root-owned directory.

## Checked and not a finding

- **No setuid NVIDIA helper.** No `nvidia-modprobe` at all; `nvidia-smi`, `nvidia-container-cli`, `nvidia-ctk` are `0755 root:root` — no setuid path to root through the toolkit.
- **Sockets are root-only:** Docker `660 root:docker` with zero members (`docker ps` → permission denied); containerd `660 root:root`. No remote API: `dockerd -H fd://` only, nothing on 2375/2376.
- **No containers, images, volumes or plugins** — no privileged / host-PID / host-IPC / socket-mounted container to assess today.
- **Seccomp, AppArmor and cgroup namespaces on** (builtin seccomp, `docker-default` AppArmor); `docker info` prints no warnings. A plain container gets no GPU (control: no `/dev/nvidia*`).
- **GPU memory is zeroed between processes.** `tests/gpu-memory-test.py`: `ubuntu` wrote an 8 GB marker, `nobody` read 8 GB fresh → `marker found 0 times; non-zero bytes 0`. Confirms krabs on data-centre hardware and driver 580.105.08.
- **ECC enabled, persistence mode on, no Xid errors**; MIG disabled; `RmProfilingAdminOnly=1` keeps profiling counters to root. `nvidia-fabricmanager` is installed but disabled and inactive — correct for one GPU with no NVSwitch. `nvidia-smi` shows other users' GPU processes (PID, name, memory) — standard Linux, noted under GPU-01.
- **`/dev/nvidia-caps` locked down**: `cap1` `0400`, `cap2` `0444`, dir `0755`; `render` group empty. The CDI spec carries `disable-device-node-modification`, so a container cannot relax node modes.
- **`dpkg --verify` clean** across all NVIDIA, CUDA, Docker and containerd packages. **No rootless Docker** (service inactive, no linger); `subuid` unused; `podman` installed but unused.

## Not verified / limits

- **Metadata from containers** (`169.254.169.254`): inferred from the default bridge and masquerade; no local image with network tools, downloads out of scope. Another audit covers metadata from the host.
- **Full GPU exhaustion** not attempted (no heavy workloads); **`--runtime=nvidia`** is not registered and untested (CDI paths work).
- **Docker Engine 29.2.1 advisories** (`docker cp` race, `PUT /containers/{id}/archive`): OSV Go ranges do not map onto the `docker-ce` package, so affectedness is unproven; any exploit needs API access, root-only.
- GPU-01's severity depends on whether the image is used by more than one account; only `ubuntu` and service accounts were observed.

## Sources

- [NVIDIA bulletin 5861 — GPU Display Driver, September 2026](https://github.com/NVIDIA/product-security/blob/main/2026/5861/5861.md)
- [NVIDIA bulletin 5850 — Container Toolkit, June 2026](https://github.com/NVIDIA/product-security/blob/main/2026/5850/5850.md)
- OSV: [runc GHSA-xjvp-4fhw-gc47](https://osv.dev/vulnerability/GHSA-xjvp-4fhw-gc47), [containerd GHSA-jpcc-p29g-p8mq](https://osv.dev/vulnerability/GHSA-jpcc-p29g-p8mq), [GHSA-rp3h-jf77-q9p4](https://osv.dev/vulnerability/GHSA-rp3h-jf77-q9p4), [GHSA-pg57-6jwg-q645](https://osv.dev/vulnerability/GHSA-pg57-6jwg-q645)
- `docs/lambda-stack-findings.md` #1, #2, #4, #13; `docs/design.md` §10
