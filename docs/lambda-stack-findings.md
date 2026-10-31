# Lambda Stack: security findings

**Checked:** 2026-10-28, against Lambda's public install script, the apt
repository at `archive.lambdalabs.com`, and a test Ubuntu 24.04 machine with
Lambda's repository installed (findings 1–15); then on 2026-10-30, on a real
Lambda Cloud instance running Lambda's default image (findings 16–33). Every
finding comes with the evidence and a way to reproduce it.

**Scope:** the software Lambda Stack installs on Ubuntu 24.04 ("noble"), and
since 2026-10-30 Lambda Cloud's default image as well: JupyterLab exposure,
default users, sudo, Docker, devices, network and logging.

> **Real instance checked 2026-10-30.** A fresh Lambda Stack 24.04
> `gpu_1x_a100_sxm4` instance was audited read-only. The full report, with
> evidence and remediation, is [`docs/lambda-instance-audit.md`](lambda-instance-audit.md);
> the raw domain reports are in [`docs/audit/`](audit/). The token → root
> chain was then executed end-to-end (POC-1), and the public HTTP transport was
> confirmed with a dummy token (POC-2): see
> [`docs/lambda-instance-pocs.md`](lambda-instance-pocs.md). The `sgs-check`
> blind spots and proposed scoring changes are in
> [`docs/sgs-check-gaps.md`](sgs-check-gaps.md). It found 2 Critical,
> 9 High, 7 Medium and 4 Low issues, including a public JupyterLab over plain
> HTTP whose token is root via passwordless sudo, and 228 pending security
> updates with automatic updates disabled. `sgs-check` scored the instance
> **24 PASS / 30 WARN / 1 SKIP**. The "Not yet verified" list that used to end
> this document is replaced by the verified addendum at the end.

## Summary

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | Lambda's apt pin blocks Ubuntu's NVIDIA driver security updates | High | Verified; on Lambda too (audit H-04) |
| 2 | Default driver branch (R570) is end of life | High | Verified |
| 3 | ML packages are months stale, with known code-execution CVEs | High | Verified |
| 4 | NVIDIA Container Toolkit 1.18.1 predates a High CVE fix | High | Verified at NVIDIA's source (bulletin 5850) and on Lambda (H-04) |
| 5 | Package repository is HTTP-only, with no expiry on its metadata | Medium | Verified; on Lambda too, frozen at 2025-12-31 (H-05) |
| 6 | Lambda's signing key is trusted for every repository on the machine | Medium | Verified; on Lambda too (H-05) |
| 7 | The install chain verifies nothing before running as root | Medium | Verified |
| 8 | Ships flash-attn with an unfixed insecure-deserialization CVE | Medium | Verified |
| 9 | Ubuntu's user-namespace restriction is bypassable, and Lambda Stack leaves it so | Medium | Verified (baseline VM, and on Lambda: M-02, POC-4) |
| 10 | io_uring, behind most kCTF kernel exploits, is open to every user | Low | Verified (baseline VM, and on Lambda: M-02) |
| 11 | Any user can load terminal line-discipline modules, and ICMP redirects are accepted | Low | Verified (baseline VM, and on Lambda: M-02) |
| 12 | SSH allows X11 forwarding | Low | Verified (baseline VM, and on Lambda: M-03) |
| 13 | Nothing stops ordinary users or containers from reaching cloud metadata | Medium | Verified (baseline VM, and on Lambda: reachable by every account, but no data served there, L-01) |
| 14 | Kernel lockdown is off | Low | Verified (baseline VM, M2 with a GPU, and on Lambda: M-02) |
| 15 | The one-line install leaves a current Ubuntu 24.04 without a GPU driver | High | Verified (M2, RTX 3080 in a VM) |
| 16 | JupyterLab is public on the internet over plain HTTP, with the token in the URL and no HSTS; the token is root | Critical | Verified on Lambda (audit C-01; executed as POC-1 and POC-2) |
| 17 | 228 security updates are pending and automatic updates are off, the internet-facing OpenSSH among them | Critical | Verified on Lambda (C-02) |
| 18 | Jupyter runs as a passwordless sudoer, with terminals on and no sandbox | High | Verified on Lambda (H-01; POC-1) |
| 19 | The Jupyter and ML packages carry more than 100 known advisories, and JupyterLab sits in a pipx environment that neither apt nor automatic updates see | High | Verified on Lambda (H-02) |
| 20 | The Cloudflare tunnel credential is readable by every account; cloudflared runs as root, unsandboxed, with debug endpoints on loopback; no Cloudflare Access in front | High | Verified on Lambda (H-03; POC-5, POC-6, POC-7) |
| 21 | GPU, RDMA and knem device files are open to every account, and RDMA traffic bypasses the IP firewall | High | Verified on Lambda (H-06; POC-3, POC-5) |
| 22 | No host firewall: `INPUT ACCEPT`, postfix and rpcbind listening on every interface, on a shared /20 private network | High | Verified on Lambda (H-07; reachability from neighbours inferred) |
| 23 | No audit or detection layer: no auditd, logs local and wipeable with sudo, nothing notices a token being used | High | Verified on Lambda (H-08) |
| 24 | The Jupyter token is fixed for the instance's life, stored 0644, accepted in the URL and never rotated; clones and snapshots inherit it | High | Verified on Lambda (H-09) |
| 25 | The running kernel is 18 releases behind, and a full upgrade forces DKMS rebuilds against the pinned driver | High | Verified on Lambda (H-04, with findings 1 and 4) |
| 26 | CPU microcode is behind: SRSO and TSA report "Vulnerable, no microcode" | Medium | Verified on Lambda (M-01) |
| 27 | SSH allows root key login (to a forced command), agent forwarding and weak MACs, with no idle timeout or login throttling | Medium | Verified on Lambda (M-03) |
| 28 | Root services run unsandboxed: cloudflared, Glances (no authentication), postfix, rpcbind | Medium | Verified on Lambda (M-04) |
| 29 | Docker's defaults: rootful, no user-namespace remap, inter-container traffic on, uncapped logs | Medium | Verified on Lambda (M-05) |
| 30 | Outbound traffic, DNS and NTP are unrestricted and unlogged | Medium | Verified on Lambda (M-06) |
| 31 | pip is configured to override PEP 668's protection of the system Python; no hashes, index allowlist or scanners; apt and dpkg history stripped from the image | Medium | Verified on Lambda (M-07) |
| 32 | `torch.compile` writes its cache group-writable under `/tmp` | Low | Verified on Lambda (L-02); the attack it allows is our finding 83 |
| 33 | `pam_unix nullok`, umask 0002, unlimited locked memory, `/var/crash` mode 3777, no Jupyter idle culling, classic snaps and extra file capabilities | Low | Verified on Lambda (L-03, L-04) |

## 1. Lambda's apt pin blocks Ubuntu's NVIDIA driver security updates

**What happens.** The `lambda-repository` package writes this file:

```text
# /etc/apt/preferences.d/lambda-repository
Package: *
Pin: origin archive.lambdalabs.com
Pin-Priority: 1001
```

A priority above 1000 tells apt to prefer Lambda's version of **every** package
Lambda publishes, even when Ubuntu has a newer one, and even if that means a
downgrade.

**Evidence.** On a test Ubuntu 24.04 machine with Lambda's repository added:

- 260 of Lambda's 335 packages also exist in Ubuntu's own archive.
- For 96 NVIDIA driver packages, the pin makes apt choose an older upstream
  driver than Ubuntu offers. A further 15 differ only in packaging labels; they
  are not counted here.
- Example: `nvidia-driver-580-server-open`. Lambda pins 580.105.08. Ubuntu
  ships 580.178.04 in `noble-security`, its security channel.
- NVIDIA's 2026 bulletins list R580 fixes in 580.126.09 (January), 580.159.03
  (May; includes CVE-2026-24187, a Linux use-after-free rated CVSS 8.8) and
  580.178.04 (September 30). Lambda's 580.105.08 predates all three.

**Impact.** On a Lambda Stack machine, `apt upgrade` and Ubuntu's automatic
security updates will never install those driver fixes. The pin wins over
Ubuntu's security channel.

**Reproduce.**

```bash
sudo dpkg -i lambda-stack-repo.deb && sudo apt-get update
```

```bash
apt-cache policy nvidia-driver-580-server-open
```

## 2. Default driver branch (R570) is end of life

`install-lambda-stack.sh` hard-codes `DRIVER_SERIES=570`. NVIDIA's supported
driver table no longer lists R570. As of this check it lists only R535 (end of
life June 2026), R580 (LTS, until June 2028), R595 and R610. Branches missing
from the table are end of life, so a new Lambda Stack install gets a driver
branch that no longer receives security fixes.

The 570 build Lambda ships (570.195.03 for `-server-open`) is also older than
Ubuntu's own final 570 package (570.211.01), and finding 1 keeps it that way.

## 3. ML packages are months stale, with known code-execution CVEs

Lambda's noble repository metadata was last updated 2025-12-31. Checked against
the OSV vulnerability database, by version:

| Package | Lambda ships | Current | Known vulnerabilities in Lambda's version |
|---|---|---|---|
| Keras | 3.10.0 | 3.15.1 | About 16 distinct CVEs. Several High, including code execution when loading a model even with `safe_mode=True` (CVE-2025-9905, CVE-2025-8747, CVE-2026-12481) |
| PyTorch | 2.7.0 | 2.15.0 | About 12 distinct CVEs, mostly memory corruption and denial of service (for example CVE-2025-2999, CVE-2025-3730) |
| fsspec | 2024.3.1 | 2026.9.0 | CVE-2026-104851 (High): template injection leading to remote code execution |
| TensorFlow | 2.19.0 | 2.21.0 | None listed |
| JAX | 0.6.0 | 0.12.0.1 | None listed |

Lambda builds its own `.deb` files, so in principle it could patch them without
changing version numbers. The Keras package changelog shows it didn't: the last
entry is "New upstream release" for 3.10.0 on 2025-05-28, with no security
fixes after it.

**Impact.** Loading an untrusted model is routine in ML work (Hugging Face,
shared checkpoints). On these versions, that can run an attacker's code.

## 4. NVIDIA Container Toolkit 1.18.1 predates a reported High CVE fix

Lambda ships `nvidia-container-toolkit` 1.18.1. Secondary sources describe NVIDIA
bulletin 5850 (June 2026): CVE-2026-24260, a race condition (CWE-367) rated
CVSS 8.5, affecting all versions up to 1.19.0 and fixed in 1.19.1. NVIDIA's
bulletin page blocked automated access and OSV has no entry yet, so this one is
unconfirmed at the source. NVIDIA's own CUDA repository currently carries
1.20.1.

**Fixes don't arrive on their own either** (verified 2026-10-29 on the baseline
VM, by asking unattended-upgrades' own matcher). The toolkit and
`libnvidia-container1` come from Lambda's repository, which
unattended-upgrades doesn't cover. So a container-escape fix only lands when
someone runs `apt upgrade` by hand. Secure GPU Stack takes the toolkit from
NVIDIA's repository and adds that repository to unattended-upgrades;
`sgs-check` verifies the coverage.

## 5. Package repository is HTTP-only, with no expiry on its metadata

- The source line is `deb http://archive.lambdalabs.com/ubuntu noble main`.
  HTTPS isn't offered: the connection is reset.
- The signed metadata (`InRelease`) has no `Valid-Until` field.

The signature means an attacker on the network can't forge packages. But with no
expiry, they can keep serving an old, validly signed snapshot forever, so the
machine never sees updates (a "freeze attack"). Plain HTTP also shows anyone on
the path exactly which ML packages a machine installs.

## 6. Lambda's signing key is trusted for every repository on the machine

The package installs the key and a symlink in apt's global trust directory:

```text
/etc/apt/trusted.gpg.d/lambda-keyring.gpg -> /usr/share/keyrings/lambda-keyring.gpg
```

Keys in that directory are trusted for **all** repositories, not just Lambda's.
If Lambda's key were stolen, it could vouch for fake Ubuntu packages too. The
modern practice is a `signed-by=` option on each source, which limits a key to
its own repository. The key itself is RSA-4096, created in 2018 and set never to
expire, so it hasn't been rotated in eight years.

## 7. The install chain verifies nothing before running as root

1. Users are told to run `wget -nv -O- https://lambdalabs.com/install-lambda-stack.sh | sh -`.
   There's no published checksum or signature for the script.
2. The script downloads `lambda-stack-repo.deb` and installs it with
   `sudo dpkg -i`. `dpkg -i` doesn't check signatures, and this package is what
   installs the trust root (the key and the pin) for everything after it. It was
   last modified 2022-10-28.
3. The driver install uses `--allow-downgrades`.

Anyone who can change those two files on Lambda's web server can get root on
every machine that installs Lambda Stack afterwards.

## 8. Ships flash-attn with an unfixed insecure-deserialization CVE

Lambda ships `python3-flash-attn-cuda` 2.7.4.post1. OSV lists CVE-2026-31253
(High): insecure deserialization in checkpoint loading, with no fixed release
listed.

## 9. Ubuntu's user-namespace restriction is bypassable, and Lambda Stack leaves it so

Unprivileged user namespaces expose kernel code that's otherwise root-only,
and many privilege-escalation exploits start by creating one. Ubuntu 24.04
blocks them for ordinary users through AppArmor
(`kernel.apparmor_restrict_unprivileged_userns = 1`), except for programs
whose AppArmor profile allows them. Qualys showed in 2025 that any user can
switch into one of those profiles with `aa-exec`. Ubuntu's fix,
`kernel.apparmor_restrict_unprivileged_unconfined = 1`, is off by default.

On the baseline VM (Ubuntu 24.04 with Lambda's repository and packages):

```
$ sysctl kernel.apparmor_restrict_unprivileged_unconfined
kernel.apparmor_restrict_unprivileged_unconfined = 0
$ unshare -Ur id -u
unshare: write failed /proc/self/uid_map: Operation not permitted
$ aa-exec -p 1password -- unshare -Ur id -u
0
```

91 profiles shipped with Ubuntu allow user namespaces; `1password` is just
the first. This is Ubuntu's default, not something Lambda adds, but Lambda
Stack doesn't change it. Secure GPU Stack sets both settings and tests the
bypass in `sgs-check` (krabs test-bench finding 52).

## 10. io_uring is open to every user

`kernel.io_uring_disabled = 0` on the baseline VM, Ubuntu's default. io_uring
was behind most kernel exploits in Google's kCTF program, and nothing in an ML
stack needs it (krabs test-bench finding 48). Secure GPU Stack limits it to
root.

## 11. Any user can load terminal line-discipline modules, and ICMP redirects are accepted

On Ubuntu 24.04's 6.8 kernel, `dev.tty.ldisc_autoload = 1` and
`net.ipv4.conf.all.accept_redirects = 1`. On the baseline VM, the ordinary
`ubuntu` user attached the PPP line discipline to a terminal, and the kernel
loaded `ppp_async` and `slip` for them. Bugs in such modules (`n_hdlc`, `n_gsm`) have given local
root before. Ubuntu's defaults again, which Lambda Stack leaves in place.
Secure GPU Stack sets both to 0 (krabs test-bench finding 54).

## 12. SSH allows X11 forwarding

`sshd -T` on the baseline VM shows `x11forwarding yes`, from Ubuntu's
`sshd_config`. A GPU server never needs to open windows on the user's
desktop, and whoever takes over the server can reach the screen and
keystrokes of anyone connected with `ssh -X`. Secure GPU Stack turns it off,
and `sgs-check` verifies it.

## 13. Nothing stops ordinary users or containers from reaching cloud metadata

On the baseline VM any account, and any container, can open connections to
169.254.169.254, the address where clouds serve instance metadata:
credentials, and the user data given at launch, which can hold setup secrets.
A malicious package, or a service a web request tricks into asking (SSRF),
could read it. Whether Lambda serves metadata there needs an instance.
Secure GPU Stack keeps that address for root only (krabs test-bench finding
69).

## 14. Kernel lockdown is off

`/sys/kernel/security/lockdown` reads `[none]` on the baseline VM. Ubuntu
turns lockdown on only under Secure Boot. Without it, root can load an
unsigned kernel module or write kernel memory, the way a rootkit gets into
the kernel and stays out of sight of every tool that asks it. Whether
Lambda's instances boot with Secure Boot needs an instance; cloud VMs
usually don't. Secure GPU Stack sets `lockdown=integrity` when Secure Boot
doesn't (krabs test-bench finding 72).

## 15. The one-line install leaves a current Ubuntu 24.04 without a GPU driver

**What happens.** On a fresh Ubuntu 24.04.5 cloud image (kernel
6.8.0-147-generic, the current GA kernel) with an RTX 3080 passed through,
`install-lambda-stack.sh` (SHA-256 `1594f8d3…`) picks `nvidia-headless-570-open`.
The pin (finding 1) installs Lambda's 570.207, which DKMS has to compile on the
machine, and the compile fails:

```text
nvidia/nv-pci.c:240:9: error: too few arguments to function 'pci_resize_resource'
```

This kernel declares `pci_resize_resource(dev, i, size, exclude_bars)`, and
570.207 passes three arguments. The script stops there (`set -eu`), before
`lambda-stack-cuda`: no driver and no frameworks.

**Lambda's newer driver fails too.** With the script's one hard-coded number
changed to `DRIVER_SERIES=580`, Lambda's 580.119.02 fails the same way
(`nv-pci.c:232`). Ubuntu's own builds work: 580.178.04, in `noble-security`,
comes with prebuilt, signed modules for this kernel, and it's what Secure GPU
Stack installs. Ubuntu's 570 packages (570.211.01) have become transitional
packages that pull in R580. The pin picks Lambda's older builds over all of
them.

**Impact.**
- The documented install fails on a current Ubuntu 24.04 machine.
- Likely, not tested: a Lambda Stack machine that gets this kernel from
  automatic updates rebuilds the module with DKMS, the build fails, and after
  the next reboot the new kernel has no NVIDIA driver. Confirming it needs a
  Lambda Stack machine on an older kernel.

**Reproduce.** On a fresh Ubuntu 24.04 machine with an NVIDIA GPU, on kernel
6.8.0-147:

```bash
wget -nv -O- https://lambda.ai/install-lambda-stack.sh | I_AGREE_TO_THE_CUDNN_LICENSE=1 sh -
```

```bash
sudo grep ': error:' /var/lib/dkms/nvidia/*/build/make.log
```

Found on the M2 test bench (`docs/m2-test-bench.md`).

## Verified on a real Lambda instance (2026-10-30)

The instance: Lambda Cloud `gpu_1x_a100_sxm4`, Ubuntu 24.04.4, kernel
6.8.0-1046-nvidia, A100-SXM4-40GB, driver 580.105.08,
`lambda-stack-cuda 0.1.17`, image files dated 2026-02-25. Read-only audit as
`ubuntu` (passwordless sudo); no fixes applied. Full report:
[`docs/lambda-instance-audit.md`](lambda-instance-audit.md). Raw reports:
[`docs/audit/`](audit/), including the
[`sgs-check` baseline](audit/sgs-check-lambda-baseline.txt) (24 PASS / 30 WARN /
1 SKIP; all three frameworks on the GPU).

| # | Real-instance result |
|---|---|
| 1 | **Confirmed.** Lambda's 580.105.08 at `Pin-Priority: 1001`; Ubuntu's 580.178.04 in `noble-security` at 500; no NVIDIA package in `apt upgrade`. |
| 2 | **Update.** The public install script hardcodes R570, but this image uses R580 (supported LTS through 2028); the build is 73 patch releases behind, not an EOL branch. |
| 3 | **Confirmed.** Repo `InRelease` 2025-12-31; Keras 3.10.0, PyTorch 2.7.0, fsspec 2024.3.1; 16/14/1 CVEs (OSV, deduplicated), max 9.8; no newer Lambda build. |
| 4 | **Confirmed at NVIDIA's source.** Bulletin 5850, CVE-2026-24260, CVSS 8.5, fixed 1.19.1; NVIDIA's repo carries 1.20.1; the pin holds 1.18.1. |
| 5 | **Confirmed.** HTTP only (HTTPS times out); `InRelease` 2025-12-31; no `Valid-Until`. |
| 6 | **Confirmed.** `trusted.gpg.d` symlink; RSA-4096, 2018, no expiry; Mellanox's key is also global. |
| 7 | **Not tested** on this instance; unchanged from the public-script analysis. |
| 8 | **Not applicable** to this image: `flash-attn` is not installed. |
| 9 | **Confirmed.** `aa-exec -p docker-default -- unshare -Ur id -u` → 0; `unconfined=0`; 91 unconfined/11 complain profiles; namespace has `CAP_NET_ADMIN`. |
| 10 | **Confirmed.** `io_uring_disabled=0`; unprivileged `io_uring_setup` succeeds. |
| 11 | **Partly.** `ldisc_autoload=1`; `TIOCSETD` loaded `ppp_async`/`slip`. `all.accept_redirects=0` here, but `default`/`eno1`/`docker0` are 1 and `send_redirects=1`; `sgs-check` flags them. |
| 12 | **Confirmed.** `x11forwarding yes`. |
| 13 | **Updated.** The endpoint exists but returns a generic 404/405 for AWS/GCP/Azure/OpenStack paths; no data found; still reachable by every user; block for defence in depth. |
| 14 | **Confirmed.** Lockdown `[none]`; no Secure Boot/EFI; unsigned modules load; `kexec_load_disabled=0`. |
| 15 | **Not tested** here; the image already has a working driver. Related risk: `apt upgrade` holds the kernel, `full-upgrade` leaves the pinned driver and forces 8 DKMS rebuilds. |

**New findings not in #1–#15** are numbered 16–33 in the summary at the
top, each with the audit's own ID (C-01 to L-04) so it can be looked up in
the full report, which has the evidence and remediation. Our stack's answer
to each one, and its replay on our own Lambda instance, is in
[`docs/lambda-audit-response.md`](lambda-audit-response.md). `sgs-check`
independently flagged the repository, the pin, the driver, unsigned modules,
GPU device modes, the toolkit CVE, the firewall, auditd, root login, X11, the
update backlog and the disabled automatic updates; what it missed (the
public tunnel, the Jupyter-as-sudoer chain, the pipx environment, RDMA) is
listed in [`docs/sgs-check-gaps.md`](sgs-check-gaps.md) and has since been
added.

**Still unverified:** #7 install chain and #15 fresh-install failure; east-west
reachability from a second instance; whether the token differs between two
instances (per-instance evidence is strong, but one sample cannot prove it);
the Cloudflare dashboard/Access state; and CVE exploitation (the token chain and
local primitives were executed as PoCs; the OpenSSH/kernel/driver CVEs were not,
and the live tunnel was not hijacked). `apt-get full-upgrade` resolves in simulation on
this instance, so Lambda's documented failure did not reproduce; a real upgrade
was not attempted because it would change the driver/kernel pair.

## Sources

- [Lambda Stack page](https://lambda.ai/lambda-stack-deep-learning-software) and
  `https://lambda.ai/install-lambda-stack.sh`
- `http://archive.lambdalabs.com/ubuntu/dists/noble/InRelease` and `Packages.gz`
  (amd64 and arm64)
- [Lambda On-Demand Cloud docs](https://docs.lambda.ai/public-cloud/on-demand/)
- [NVIDIA supported drivers and CUDA versions](https://docs.nvidia.com/datacenter/tesla/drivers/supported-drivers-and-cuda-toolkit-versions.html)
- [GamingOnLinux: NVIDIA May 2026 bulletin](https://gamingonlinux.com/2026/05/nvidia-reveal-more-gpu-driver-security-flaws-for-may-2026)
  and [September 30 bulletin](https://www.gamingonlinux.com/2026/09/nvidia-security-bulletin-for-sept-30-notes-many-gpu-issues/page=1/)
- [lilting.ch summary of the September 2026 NVIDIA fixed versions](https://lilting.ch/en/articles/nvidia-gpu-driver-vgpu-security-fixes)
- [Wiz: CVE-2026-24260](https://www.wiz.io/fr-fr/vulnerability-database/cve/cve-2026-24260)
  and [HOL summary](https://hol.org/guard/security/cves/CVE-2026-24260-cisa-adp-vulnrichment)
- [OSV.dev](https://osv.dev) vulnerability database (queried via its API)
