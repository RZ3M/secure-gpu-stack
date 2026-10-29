# Lambda Stack: security findings

**Checked:** 2026-10-28, against Lambda's public install script, the apt
repository at `archive.lambdalabs.com`, and a test Ubuntu 24.04 machine with
Lambda's repository installed. Every finding below comes with the evidence and a
way to reproduce it.

**Scope:** the software Lambda Stack installs on Ubuntu 24.04 ("noble"). Lambda
Cloud's default image (JupyterLab exposure, default users, sudo, Docker group)
still has to be checked on a real instance; see "Not yet verified" at the end.

## Summary

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | Lambda's apt pin blocks Ubuntu's NVIDIA driver security updates | High | Verified |
| 2 | Default driver branch (R570) is end of life | High | Verified |
| 3 | ML packages are months stale, with known code-execution CVEs | High | Verified |
| 4 | NVIDIA Container Toolkit 1.18.1 predates a reported High CVE fix | High | Reported, not confirmed at the source |
| 5 | Package repository is HTTP-only, with no expiry on its metadata | Medium | Verified |
| 6 | Lambda's signing key is trusted for every repository on the machine | Medium | Verified |
| 7 | The install chain verifies nothing before running as root | Medium | Verified |
| 8 | Ships flash-attn with an unfixed insecure-deserialization CVE | Medium | Verified |
| 9 | Ubuntu's user-namespace restriction is bypassable, and Lambda Stack leaves it so | Medium | Verified (baseline VM) |
| 10 | io_uring, behind most kCTF kernel exploits, is open to every user | Low | Verified (baseline VM) |
| 11 | Any user can load terminal line-discipline modules, and ICMP redirects are accepted | Low | Verified (baseline VM) |
| 12 | SSH allows X11 forwarding | Low | Verified (baseline VM) |
| 13 | Nothing stops ordinary users or containers from reaching cloud metadata | Medium | Verified (baseline VM); whether Lambda serves metadata there isn't |
| 14 | Kernel lockdown is off | Low | Verified (baseline VM, and M2 with a GPU) |
| 15 | The one-line install leaves a current Ubuntu 24.04 without a GPU driver | High | Verified (M2, RTX 3080 in a VM) |

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

## Not yet verified (needs a real Lambda instance)

- Whether JupyterLab on the default image is reachable from the internet, and
  how it authenticates.
- Default user setup: passwordless sudo, `docker` group membership, password
  policy.
- Lambda's documented failure of `apt full-upgrade` on 24.04 images. It's likely
  related to finding 1.
- Open ports and firewall state on a freshly launched instance.
- Whether the GPU device files are 0666 on Lambda's own image. With Lambda
  Stack installed and a real GPU (M2, `docs/m2-test-bench.md`) they are, and
  they stay so after `sudo nvidia-smi`: `nobody` ran `nvidia-smi` and
  allocated GPU memory.
- Whether instances boot with Secure Boot, and so with kernel lockdown
  (finding 14).

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
