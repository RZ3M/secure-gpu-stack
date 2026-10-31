# 03 — Patching and software supply chain
**Host:** `ubuntu@<instance>` — Lambda Cloud, Ubuntu 24.04.4, kernel
`6.8.0-1046-nvidia`, A100-SXM4-40GB, `lambda-stack-cuda 0.1.17~24.04.1`.
**Audited:** 2026-10-30, 20:42–20:58 UTC, live instance, read-only: apt
simulations only (`apt-get -s`, `unattended-upgrade --dry-run`); no packages
changed. OSV.dev queried per installed version; CVSS 3.1 computed from OSV
vectors. "Fixed by update" = OSV lists a fixed version in the same Ubuntu series
at or below the candidate.

## Summary
| ID | Severity | Finding |
|---|---|---|
| SUP-01 | Critical | Automatic security updates disabled; 228 `noble-security` updates pending, incl. OpenSSH 13.20 (CVE-2026-60002, 9.4, AV:N) |
| SUP-02 | High | `apt upgrade` holds back the kernel; only `full-upgrade` installs 6.8.0-1064 — the command Lambda documents as broken |
| SUP-03 | High | Lambda's apt pin blocks Ubuntu's NVIDIA 580.178.04 security update; driver stays 580.105.08 |
| SUP-04 | High | ML frameworks frozen at April–May 2025 Lambda builds with public RCE-class CVEs; no repo update path |
| SUP-05 | High | System pip is root-writable and unpinned: `EXTERNALLY-MANAGED` overridden, no hashes/index allowlist, 6 pip CVEs open |
| SUP-06 | Medium | Lambda/Mellanox keys trusted globally; Lambda repo HTTP with no `signed-by`; keys never expire |
| SUP-07 | Medium | Lambda repo is a frozen 2025-12-31 snapshot with no `Valid-Until`; HTTPS not offered |
| SUP-08 | Medium | Docker, containerd, cloudflared, Azure, NVIDIA/Mellanox packages, plus classic snaps, outside auto-updates |
| SUP-09 | Low | No vulnerability scanner, SBOM, apt install history, or Ubuntu Pro/ESM tooling |
| SUP-10 | Low | cuDNN exists only inside Lambda's Python debs (plus a license package) |
| SUP-11 | Low | Eight DKMS modules, unsigned, no Secure Boot, no holds; kernel upgrade forces untested rebuilds |
**Counts: 1 Critical, 4 High, 3 Medium, 3 Low.**

## SUP-01 — Automatic security updates are disabled; 228 pending
```text
$ apt list --upgradable 2>/dev/null | tail -n +2 | wc -l
303
$ apt list --upgradable 2>/dev/null | grep -c security
228
$ apt-config shell UnattendedUpgradeInterval APT::Periodic::Unattended-Upgrade
UnattendedUpgradeInterval='0'
$ grep -v '^#' /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
```
The service runs only its shutdown helper; both timers are enabled, but
`/usr/lib/apt/apt.systemd.daily` exits when the interval is 0.
`/var/lib/apt/periodic` has only `update-success-stamp` (no unattended stamp: it
has never run). A dry-run (writes a log, changes nothing) shows an Ubuntu-only
allowlist and sets `docker-ce`/`cloudflared` candidates back to installed.

| Package | Installed → candidate | CVEs affecting / fixed | Max CVSS |
|---|---|---|---|
| `openssh-server` | 1:9.6p1-3ubuntu13.14 → 13.20 | 29 / 28 | **9.4** CVE-2026-60002 (AV:N/AC:L/PR:N) |
| `libc6` | 2.39-0ubuntu8.7 → 8.9 | 20 / 13 | 9.8 CVE-2026-5450 |
| `libssl3t64` | 3.0.13-0ubuntu3.7 → .16 | 27 / 27 | 9.8 CVE-2026-31789 |
| `curl`/`libcurl4t64` | 8.5.0-2ubuntu10.7 → .16 | 33 / 33 | 9.8 CVE-2026-8925 |
| `bind9-libs` | 1:9.18.39-0ubuntu0.24.04.2 → .8 | 29 / 25 | 8.6 CVE-2026-13321 |
| `python3.12` | 3.12.3-1ubuntu0.11 → .17 | 44 / 17 | 8.2 CVE-2025-69534 |
| `linux-image-nvidia` | 6.8.0-1046.49 → 1064.67 | see SUP-02 | kernel |

Also pending: `libxml2` (9.8), `sudo` (7.8), `libssh-4` (7.5),
`ca-certificates` (USN-8944-1), and `apparmor` (`noble-updates` only, not
security-classified). The kernel row is not counted: OSV's Ubuntu data for this
flavour is not version-reliable (73 entries, mostly old unfixed CVEs), so I rely
on Ubuntu's `noble-security` class. The other 66 upgrades are `noble-updates`; 8
are third-party and one (`python3-mpmath`) is Lambda's.
**Impact.** Nothing installs these automatically, with no notification. On a
cloud host whose management plane is SSH, the pending OpenSSH fix rated 9.4 with
`AV:N/AC:L/PR:N/UI:N` is the sharpest consequence.
**Fix.** Set `APT::Periodic::Unattended-Upgrade "1"`, add third-party origins once
signed/HTTPS, add a mail/JSON hook, test with `unattended-upgrade --dry-run`.

## SUP-02 — `apt upgrade` holds back the kernel
```text
$ apt-get -s upgrade | sed -n '/kept back/,/^[0-9]* upgraded/p'
The following packages have been kept back:
  linux-firmware linux-headers-nvidia linux-image-nvidia linux-nvidia linux-tools-nvidia
298 upgraded, 0 newly installed, 0 to remove and 5 not upgraded.
$ apt-get -s full-upgrade | tail -1; echo rc=$?
303 upgraded, 25 newly installed, 0 to remove and 0 not upgraded.
rc=0
```
`linux-image-nvidia 6.8.0-1064.67` depends on new packages
(`linux-image-6.8.0-1064-nvidia`, split `linux-firmware-*`) that `apt upgrade`
will not install. `full-upgrade` installs them but **no NVIDIA driver package**
(SUP-03). Lambda's docs say `full-upgrade`/`dist-upgrade` fail on 24.04; that does
**not** reproduce in simulation. This is a resolver check only: a real upgrade
could still fail in a post-install script, and it moves the kernel while leaving
the pinned driver behind.
**Impact.** The documented `apt upgrade` path leaves kernel and firmware
unpatched; only the command Lambda calls broken installs the kernel.
**Fix.** Stage kernel and driver together, test DKMS before reboot, fix the
held-back meta packages in the image build, add a post-upgrade DKMS/`nvidia-smi`
check.

## SUP-03 — Lambda's pin blocks Ubuntu's NVIDIA security update
```text
$ apt-cache policy nvidia-utils-580-server
  Installed: 580.105.08-0lambda0.24.04.1
  Candidate: 580.105.08-0lambda0.24.04.1
     580.178.04-0ubuntu0.24.04.1 500   # noble-updates + noble-security/restricted
 *** 580.105.08-0lambda0.24.04.1 1001  # archive.lambdalabs.com noble/main
```
`/etc/apt/preferences.d/lambda-repository` is `Package: * / Pin: origin
archive.lambdalabs.com / Pin-Priority: 1001`; 1001 beats the security suite's 500
and permits downgrades. No NVIDIA package is in `apt list --upgradable` and none
appears in the `full-upgrade` `Inst` lines. R580 is still the supported LTS
branch (through 2028), so this is not EOL: the installed build is eight months
behind (580.105.08 vs 580.178.04). The existing findings file records NVIDIA's
R580 security releases 580.126.09, 580.159.03 (CVE-2026-24187, 8.8) and
580.178.04, all postdating 580.105.08.
**Impact.** Driver fixes never arrive through `apt`, despite Ubuntu shipping them
in `noble-security`.
**Fix.** Replace the origin-wide pin with per-package pins that do not override
`noble-security`, or use Ubuntu's signed driver packages. If pinning, hold
packages explicitly, track NVIDIA bulletins, validate driver + kernel together.

## SUP-04 — ML frameworks frozen at April–May 2025 builds
Every framework is a Lambda `.deb`; `installed == candidate` and Lambda's
changelogs contain only "New upstream release" with no later security entries
(e.g. Keras 3.10.0, 2025-05-28). OSV.dev for the installed versions:

| Package | Installed (source) | CVEs | Max CVSS | Representative (fixed) |
|---|---|---|---|---|
| PyTorch | 2.7.0 (Lambda) | 14 | 8.8 | CVE-2026-24747 (2.10.0); CVE-2026-4538 7.8, no fix |
| Keras | 3.10.0 (Lambda) | 16 | **9.8** | CVE-2025-12060 (3.12.0); CVE-2026-12481 safe-mode bypass → code exec (3.12.3) |
| fsspec | 2024.3.1 (Lambda) | 1 | 8.8 | CVE-2026-104851 SSTI → RCE (2026.6.0) |
| TensorFlow | 2.19.0 (Lambda) | 0 | — | none for this version |
| JAX/JAXLIB, Triton, NumPy | 0.6.0, 3.3.0, 1.26.4 | 0 | — | no OSV entries for these versions |

Keras' CVE-2026-12481 is the notable one: OSV describes a lambda-deserialization
path that bypasses `safe_mode=True` and executes code; CVE-2025-8747 is another
safe-mode bypass. Loading a model from Hugging Face or a shared checkpoint is
routine ML workflow.
**Impact.** Three framework packages carry public RCE-class issues with no fix
path through configured repos — the result of the stale repo (SUP-07) and
Lambda-built debs (SUP-10).
**Fix.** Move frameworks to a versioned venv with pinned, hash-checked wheels (or
rebuild the debs); run `pip-audit` in the release pipeline; keep
`safetensors`/`weights_only=True` and treat model files as untrusted.

## SUP-05 — System pip is root-writable and unpinned
```text
$ cat /etc/pip.conf
[global]
break-system-packages = true          # overrides /usr/lib/python3.12/EXTERNALLY-MANAGED
$ python3 -m pip --version
pip 24.0 from /usr/lib/python3/dist-packages/pip (python 3.12)
$ sudo -n -l | tail -1
    (ALL) NOPASSWD: ALL
```
`pip config debug` shows only `break-system-packages`; no `index-url`, no
`trusted-host`, no `require-hashes`. `sudo pip install` writes to
`/usr/local/lib/python3.12/dist-packages`, which precedes
`/usr/lib/python3/dist-packages` on `sys.path`, so a wheel can shadow apt's
`torch`, `cryptography` or any other module. pipx is fine (own venvs, e.g.
`jupyter-core 5.9.1`); system pip is the problem.

pip 24.0 has 6 open CVEs (OSV PyPI): CVE-2025-8869 (tar symlink extraction,
25.3), CVE-2026-1703 (path traversal, 26.0), CVE-2026-3219 and CVE-2026-6357
(26.1), CVE-2026-13346 (26.2), CVE-2026-8643 (8.0, 26.1.2). Ubuntu's
`python3-pip 24.0+dfsg-1ubuntu1.3` changelog backports five older, mostly
vendored-library CVEs but none of these; its candidate equals the installed
version. setuptools is better: Ubuntu backported CVE-2024-6345 and CVE-2025-47273,
so those are **not** findings here; only CVE-2026-59890 (6.1) is open.
**Impact.** Any user who runs `pip install`, or is tricked into `sudo pip
install`, can place unverified code in a path that shadows distribution packages.
**Fix.** Remove `break-system-packages`, keep the `EXTERNALLY-MANAGED` guard,
require venvs/pipx, set an approved `index-url` plus `require-hashes`, never run
pip as root, check `/usr/local/lib/python3.12/dist-packages` is empty at boot.

## SUP-06 — Global key trust and keys that never expire
```text
$ cat /etc/apt/sources.list.d/lambda-repository.list
deb http://archive.lambdalabs.com/ubuntu noble main          # no signed-by
$ ls -l /etc/apt/trusted.gpg.d/lambda-keyring.gpg
... -> /usr/share/keyrings/lambda-keyring.gpg
$ gpg --show-keys --with-colons /usr/share/keyrings/lambda-keyring.gpg
pub  rsa4096 2018-04-05 ... expires=never
uid  Lambda Labs (Repository Signing Key) <software@lambdalabs.com>
```
Keys in `/etc/apt/trusted.gpg.d/` are trusted for every source. The Mellanox key
(2013/2014/2018, never expires) is both globally trusted and named by
`signed-by=` on the DOCA source, so `signed-by` buys nothing there. The
cloud-init keys are correctly per-repo but created 2015–2017 and none expires.
`apt-config dump` is otherwise sane: `AllowInsecureRepositories "0"`, no
`AllowUnauthenticated`, no proxy, no `trusted=yes` anywhere. Docker's keyring is
a GnuPG keybox, not OpenPGP, but `gpgv` verifies Docker's `InRelease` with it.
**Impact.** A stolen Lambda or Mellanox key can sign metadata for any repository
the machine trusts; HTTP exposes which ML packages are installed; up to
twelve-year-old non-expiring keys are a rotation failure.
**Fix.** Add `signed-by=` for Lambda, remove the Lambda/Mellanox keys from
`trusted.gpg.d`, rotate them, use HTTPS where offered (Lambda does not offer it:
`curl` to `https://archive.lambdalabs.com` times out).

## SUP-07 — Lambda's repo is a ten-month-old frozen snapshot
```text
$ curl -fsSL http://archive.lambdalabs.com/ubuntu/dists/noble/InRelease | head
Origin: lambdalabs.com
Codename: noble
Date: Wed, 31 Dec 2025 11:10:42 UTC        # no Valid-Until
$ ls -l /var/lib/apt/lists/archive.lambdalabs.com_..._InRelease
2025-12-31 11:12                           # unchanged after apt update
```
Ubuntu also omits `Valid-Until`, so that alone is not Lambda-specific; what is
specific is a stale repo over HTTP. apt cannot distinguish this snapshot from a
fresh one, and an on-path attacker need not forge a signature to keep serving it
(freeze/replay). The image was built 2026-02-25, so it was already ~2 months
stale at birth and is now 10 months stale.
**Impact.** No framework or driver update can appear no matter how often apt
runs, and there is no expiry signal to detect a replayed snapshot.
**Fix.** Move to official Ubuntu/NVIDIA repos, or publish over HTTPS with
`Valid-Until`; set `Acquire::Check-Valid-Until "true"` and monitor the repo
`Date` in the posture check.

## SUP-08 — Third-party packages and classic snaps outside auto-updates
```text
docker-ce        5:29.2.1 -> 5:29.9.2      containerd.io    2.2.1 -> 2.4.2
cloudflared      2026.2.0 -> 2026.10.7     azure-cli        2.83.0 -> 2.91.0
nvidia-container-toolkit 1.18.1 (Lambda; no candidate at all)
$ snap list
aws-cli           2.35.21  classic
google-cloud-sdk  558.0.0  classic
```
Unattended-upgrades covers only Ubuntu; the dry-run sets `docker-ce`,
`containerd.io`, `cloudflared` and `azure-cli` candidates back to installed.
None is in a `*-security` suite, so they are **not** counted in the 228: they are
upstream releases that include security fixes, but I did not verify specific
CVEs per delta. The classic snaps auto-refresh from the Snap Store, outside apt
and outside package pinning.
**Impact.** Container-runtime and tunnelling fixes lag indefinitely unless
someone runs `apt upgrade` manually; classic snaps are unsandboxed and update on
their own schedule.
**Fix.** Add the third-party repos to the unattended allowlist once HTTPS +
`signed-by`; pin and test Docker/containerd upgrades; decide deliberately whether
the classic snaps belong on the image.

## SUP-09 — No scanner, SBOM, package history, or Pro/ESM tooling
```text
$ for c in pip-audit grype trivy syft osv-scanner safety; do command -v $c; done
(no output)
$ ls /var/log/apt/
eipp.log.xz                     # no history.log: no install/remove history
$ pro status
bash: pro: command not found
```
`ubuntu-advantage-tools` is not installed, so the `UbuntuESM*` origins in
`50unattended-upgrades` are dead entries (ESM is not needed on 24.04 until 2029,
but there is no USN/CVE tooling either). No SBOM file exists under `/` at depth 3.
**Impact.** The machine cannot answer "what is installed and what is known
vulnerable" without an external scan.
**Fix.** Generate an SBOM at build time (syft or `dpkg-query`), run
`pip-audit`/trivy/grype in CI and on the host, retain apt history, attach Ubuntu
Pro if ESM coverage is wanted.

## SUP-10 — cuDNN lives inside Lambda's Python debs
```text
$ dpkg -L cudnn-license | head -1
/usr/share/doc/cudnn-license/LICENSE                 # license only, no libraries
$ find /usr/lib/python3/dist-packages -name 'libcudnn.so.9'
.../torch/lib/...  .../tensorflow/libcudnn.so.9  .../jax_cuda12_plugin/libcudnn.so.9
$ dpkg -S /usr/lib/cuda/bin/nvcc
nvidia-cuda-toolkit: /usr/lib/cuda/bin/nvcc          # CUDA is a system package
```
CUDA toolkit 12.8.93 and NCCL 2.26.2 are proper system packages, but cuDNN is
shipped three times inside the framework debs. `dpkg --verify` covers the files,
but there is no independent cuDNN package/CVE feed, and upgrading cuDNN means
rebuilding Lambda's framework debs.
**Impact.** A cuDNN vulnerability cannot be patched independently of PyTorch,
TensorFlow and JAX; the license package misleadingly suggests system-wide cuDNN.
**Fix.** Install cuDNN from NVIDIA's signed repo (or a pinned wheel set), record
its exact version in the SBOM, rebuild frameworks against it.

## SUP-11 — Eight unsigned DKMS modules, no holds
```text
$ dkms status
iser, isert, kernel-mft-dkms, knem, mlnx-ofed-kernel, nvidia-srv/580.105.08,
srp, xpmem — all only for 6.8.0-1046-nvidia
$ cat /proc/sys/kernel/tainted
12288                          # 0x3000 = out-of-tree (12) + unsigned (13)
$ mokutil --sb-state
EFI variables are not supported on this system     # no Secure Boot
$ apt-mark showhold
(none)
```
`nvidia-srv` built from `/usr/src/nvidia-srv-580.105.08` against 1046 with zero
errors in `make.log`. A kernel install runs `/etc/kernel/postinst.d/dkms`, which
rebuilds every module. I checked finding #15's known break: `pci_resize_resource`
has the **same 3-argument prototype** in the current 1046 headers and in the
extracted 1064 headers, so that specific Lambda failure does **not** apply to the
`-nvidia` flavour. Whether 580.105.08 builds against all other 1064 changes was
not tested (that needs a build/upgrade outside this audit's rules).
**Impact.** The driver stays at 580.105.08 while the kernel moves to 1064; eight
out-of-tree modules must rebuild, unsigned modules prevent lockdown, and a failed
rebuild leaves the new kernel without NVIDIA after reboot.
**Fix.** Build/test the kernel + driver + OFED set in staging, sign DKMS modules
with an enrolled MOK (or enable Secure Boot), hold the kernel until the driver
set is validated, check DKMS/`nvidia-smi` after every update.

## Checked and not a finding
- **flash-attn is not installed** (`dpkg -l`, `pip list`, `import flash_attn` all
  negative); finding #8 does not apply, though the package is available.
- **TensorFlow 2.19.0, JAX/JAXLIB 0.6.0, Triton 3.3.0, NumPy 1.26.4**: OSV lists
  no advisories affecting these exact versions (2026-10-30).
- **setuptools 68.1.2-2ubuntu1.2**: Ubuntu backported CVE-2024-6345 and
  CVE-2025-47273 — do not cite those; only CVE-2026-59890 (6.1) is open.
- **jupyter-core 5.3.2** (system): its only OSV advisory (CVE-2025-30167) is
  Windows-only. **Correction (parent):** JupyterLab 4.5.5 *is* installed, but in
  the pipx venv (`/home/ubuntu/.local/share/pipx/venvs/jupyter-core`), not as a
  system package; `pip list`/`dpkg -l` without that venv miss it. See
  `docs/audit/07-jupyter-ml.md` JUP-02/03 and the main report H-02.
- **`dpkg --verify`** on 11 key packages (NVIDIA, CUDA, NCCL, container toolkit,
  Docker, containerd, OpenSSH, sudo, glibc) returned no changes; repository
  config has no `trusted=yes`, no `AllowUnauthenticated`, no proxy and no
  duplicate sources. Docker's keybox is non-OpenPGP but `gpgv` verifies it.
- **Driver branch is not EOL** (R580 is supported LTS); no apt holds exist. No
  reboot marker: expected, because the 303 updates have not been applied.
- **npm, yarn, pnpm, conda and mamba are absent**; PyPI is reached only through
  system pip (SUP-05) and pipx venvs.

## References
- OSV.dev API per installed version, 2026-10-30: <https://api.osv.dev/v1/query>
  (PyPI and Ubuntu ecosystems); Ubuntu `noble-security` `InRelease`; Lambda
  `noble` `InRelease` (Date 2025-12-31, no `Valid-Until`).
- NVIDIA R580 bulletins and CVE-2026-24187: sources in
  `docs/lambda-stack-findings.md`.
- CVE details: CVE-2026-60002, CVE-2026-5450, CVE-2026-31789, CVE-2026-8925,
  CVE-2026-6653, CVE-2026-13321, CVE-2025-69534, CVE-2026-96512,
  CVE-2026-59850 (Ubuntu OSV); CVE-2026-24747, CVE-2026-4538, CVE-2026-12481,
  CVE-2026-104851, CVE-2025-12060, CVE-2025-8869, CVE-2026-8643 (PyPI OSV).
