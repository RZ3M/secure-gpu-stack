# 04 — Kernel and host hardening: Lambda Stack 24.04 on a live instance

**Target:** `ubuntu@<instance>` — Lambda Cloud A100, Ubuntu 24.04.4 LTS,
kernel `6.8.0-1046-nvidia` (#49, 2026-01-28), image files dated 2026-02-25.
**Audited:** 2026-10-30, 20:42–21:05 UTC, fresh boot. **Method:** read-only SSH,
passwordless sudo, two `/tmp` probes (io_uring, `TIOCSETD`) later removed, one
`aa-exec` test; no sysctl, module, GRUB or package changes, no reboot. **Side
effect, declared:** the ldisc probe autoloaded `ppp_async`/`slip`; unloading was
out of scope, so they stay loaded (refcount 0, no functional change).
**Scope:** sysctls, AppArmor, boot/module integrity, CPU/firmware, kernel
integrity and filesystem exposure, kernel CVEs. GPU/containers are 05; logging
and IDS are 08 (cross-referenced, not double-counted).

## Summary

| ID | Finding | Severity |
|---|---|---|
| KRN-01 | Kernel is 18 releases (base 6.8.0-100.100 → 146.146) and 1,457 CVE IDs behind `noble-security` | High |
| KRN-02 | Automatic security updates are off; 303 packages upgradable, 228 from security pockets | High |
| KRN-03 | AppArmor userns restriction bypassable via `aa-exec` into 91 unconfined or 11 complain profiles | Medium |
| KRN-04 | Jupyter and every other service run unsandboxed; Jupyter runs as `ubuntu`, who has passwordless sudo | Medium |
| KRN-05 | No Secure Boot/lockdown, unsigned modules load, kexec allowed, IMA not measuring, no TPM | Medium |
| KRN-06 | io_uring open to every user; `io_uring_setup` succeeds unprivileged | Medium |
| KRN-07 | `dev.tty.ldisc_autoload=1`: unprivileged user autoloads `ppp_async`/`slip` via a pty | Low |
| KRN-08 | IPv4/IPv6 gaps: redirects, martians, loose `rp_filter`, IPv6 RA | Low |
| KRN-09 | `/tmp`, `/var/tmp` on `/` with no `nodev,nosuid,noexec`; `/dev/shm` lacks `noexec`, 109 GB | Low |
| KRN-10 | SRSO and TSA report "no microcode"; `amd64-microcode` behind; no ESM/livepatch | Low |

**Counts: 0 Critical, 2 High, 4 Medium, 4 Low.** Confirms findings #9, #10, #11
and #14 of `docs/lambda-stack-findings.md` on real hardware; #12 (SSH) and #13
(cloud metadata) are outside this file's scope.

## Sysctl inventory vs a server baseline

`sysctl -a` has 1,189 keys; only deviations are listed, everything else matched
the CIS Ubuntu 24.04 baseline (e.g. `kptr_restrict=1`,
`dmesg_restrict=1`, `ptrace_scope=1`, `unprivileged_bpf_disabled=2`,
`perf_event_paranoid=4`, `unprivileged_userfaultfd=0`, `randomize_va_space=2`,
`mmap_min_addr=65536`, `suid_dumpable=0`, all four `fs.protected_*`,
`tcp_syncookies=1`, `accept_source_route=0`, `legacy_tiocsti=0`).

| Setting | Value | Assessment |
|---|---|---|
| `kernel.apparmor_restrict_unprivileged_userns` | 1 | pass (blocks plain `unshare -Ur`) |
| `kernel.apparmor_restrict_unprivileged_unconfined` | 0 | **gap** — 1 (KRN-03) |
| `kernel.io_uring_disabled` | 0 | **gap** — 1 or 2 (KRN-06) |
| `dev.tty.ldisc_autoload` | 1 | **gap** — 0 (KRN-07) |
| `kernel.modules_disabled` / `kernel.kexec_load_disabled` | 0 / 0 | modules expected; **gap** kexec = 1 (KRN-05) |
| `kernel.sysrq` | 176 | partial — sync/remount-ro/reboot only |
| `kernel.panic_on_oops` / `panic_on_warn` | 0 / 0 | **gap** — 1 (KRN-05) |
| `kernel.core_pattern` | `core` | note — no apport; cores 0600 |
| `net.ipv4.conf.all.accept_redirects` | 0 | pass on forwarding interfaces (KRN-08) |
| `net.ipv4.conf.all.send_redirects` / `secure_redirects` | 1 / 1 | **gap** — 0 / 0 |
| `net.ipv4.conf.all.log_martians` / `rp_filter` / `tcp_rfc1337` | 0 / 2 / 0 | **gap** — 1 / 1 / 1 |
| `net.ipv4.ip_forward` | 1 | required by Docker; document it |
| `net.ipv6.conf.all.accept_ra` / `accept_redirects` | 1 / 1 | **gap** — 0 / 0 (KRN-08) |

No Lambda-specific hardening file exists: `/etc/sysctl.d/` holds only stock
Ubuntu and cloud-init files, so every value above is a kernel or Ubuntu default.

## Detailed findings

### KRN-01 — Kernel is 18 releases and 1,457 CVE IDs behind — High

`uname -r` → `6.8.0-1046-nvidia`; `apt-cache policy linux-image-nvidia` →
installed `6.8.0-1046.49`, candidate **`6.8.0-1064.67`** in `noble-security`.
The running build is based on Ubuntu **6.8.0-100.100**; the candidate
(2026-09-14) on **6.8.0-146.146** — 18 releases later, with **1,457 distinct
CVE IDs** in between. Missing, e.g., `CVE-2025-37899` (ksmbd UAF, fixed in the
next kernel), `CVE-2026-23231`/`CVE-2026-23392` (nf_tables UAF, CVSS 7.8),
`CVE-2026-31673` (af_unix race). KRN-03 supplies the `CAP_NET_ADMIN` needed to
reach nf_tables.

**Fix.** Install 1064.67 and reboot after verifying the NVIDIA DKMS module (or
use Ubuntu's signed `nvidia-driver-580-server-open` 580.178.04, blocked today by
the Lambda pin — 05/GPU-02); have `sgs-check` compare installed vs candidate.

### KRN-02 — Automatic security updates are disabled — High

```
$ grep -v '^//' /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
$ apt list --upgradable 2>/dev/null | grep -c security        # 228 of 303
```

The active `unattended-upgrades` unit is the shutdown helper; the upgrade step
(`apt.systemd.daily install`) exits while the periodic setting is 0. Ubuntu's
shipped default is `"1"`; the 228 security-origin upgrades include the kernel
meta, `apparmor`, `curl`, `bind9`, `cloud-init` and `amd64-microcode`.

**Fix.** Set `APT::Periodic::Unattended-Upgrade "1"`, add the Lambda/NVIDIA
origins to `Allowed-Origins` (unattended-upgrades does not cover
`archive.lambdalabs.com`), verify with `unattended-upgrade --dry-run`, and
surface `/var/run/reboot-required`. KRN-01 is the kernel half of the same
failure; its visibility half is 08/LOG-10.

### KRN-03 — The userns restriction is bypassable with `aa-exec` — Medium

```
$ unshare -Ur id -u
unshare: write failed /proc/self/uid_map: Operation not permitted
$ aa-exec -p 1password -- unshare -Ur id -u
0
$ aa-exec -p 1password -- unshare -Urn sh -c 'ip link set lo up; nft add table inet nstest'
netns-ok
nft-ok
```

`kernel.apparmor_restrict_unprivileged_unconfined` is 0; `aa-status` shows 123
profiles loaded — 21 enforcing, 11 in complain mode, 91 in unconfined mode.
Plain `unshare -Ur` is blocked, as is `aa-exec` into the enforced
`unprivileged_userns` and `tcpdump` profiles. But entering an unconfined profile
(`1password` tested) or a complain-mode one (`snap.aws-cli.aws`,
`snap.google-cloud-sdk.{anthoscli,bq}` tested) skips the transition to
`unprivileged_userns`, and the namespace is fully usable: mount, netns and
nftables all work. This is the Qualys bypass, unchanged from Ubuntu's default —
root in a namespace with `CAP_SYS_ADMIN`/`CAP_NET_ADMIN`, the enabling half of
KRN-01.

**Fix.** `kernel.apparmor_restrict_unprivileged_unconfined = 1` in
`/etc/sysctl.d/`, verify the `aa-exec` test fails, add it to `sgs-check` (design
round J).

### KRN-04 — Services are unsandboxed; Jupyter is root-equivalent — Medium

```
$ systemd-analyze security lambda-jupyter.service | tail -1
→ Overall exposure level for lambda-jupyter.service: 9.2 UNSAFE :-{
$ sudo -n true && echo ok
ok
```

The unit is a bare `User=ubuntu` service running `jupyter lab --config ...`;
`systemctl show ... -p NoNewPrivileges -p ProtectSystem -p ProtectHome` reports
all three `no`; `glances`, `cloudflared`, `docker`, `postfix` and `ssh` all
score 9.6 UNSAFE with the same empty settings. Notebook code inherits `ubuntu`
and therefore host root via passwordless sudo, with no sandbox to cross.
(Jupyter's network exposure is 08/LOG-01; this is the host-side blast radius.)

**Fix.** Drop-ins: `NoNewPrivileges=yes`, `ProtectSystem=strict`,
`ProtectHome=read-only`, `PrivateTmp=yes`, `CapabilityBoundingSet=`,
`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`,
`SystemCallFilter=@system-service`, `UMask=0077`, `DevicePolicy=closed` +
`DeviceAllow=/dev/nvidiactl /dev/nvidia0 /dev/nvidia-uvm`. Run Jupyter as a
dedicated account with no sudo (as `sgs-jupyter` does).

### KRN-05 — No lockdown, unsigned modules, kexec, no attestation — Medium

```
$ cat /sys/kernel/security/lockdown
[none] integrity confidentiality
$ cat /proc/sys/kernel/tainted
12288                      # 0x3000 = out-of-tree (4096) + unsigned (8192)
$ sudo dmesg | grep 'module verification'
mlx_compat: module verification failed: signature and/or required key missing - tainting kernel
```

`mokutil --sb-state` says "EFI variables are not supported" and
`/sys/firmware/efi` does not exist: legacy BIOS, so no Secure Boot.
`MODULE_SIG_FORCE` is unset. 19 out-of-tree modules load (NVIDIA, Mellanox OFED,
knem, xpmem); the DKMS-built `nvidia.ko` has no `sig_id`/`signer`.
`kexec_load_disabled=0`, `CONFIG_KEXEC_SIG_FORCE` is unset and
`panic_on_oops=0`. IMA has no policy (`runtime_measurements_count` = 1, the boot
aggregate) and there is no TPM (`/dev/tpm*` absent), so nothing attests the host.

**Impact.** Anyone reaching root — here `ubuntu` via sudo — can load an unsigned
module or kexec an unsigned kernel and hide from userspace; 05/GPU-08 covers the
unsigned-DKMS half.

**Fix.** Add `lockdown=integrity` to the cmdline, set
`kernel.kexec_load_disabled=1` and `kernel.panic_on_oops=1`, and sign the DKMS
build with a MOK-enrolled key first: lockdown refuses the current unsigned
`nvidia.ko`. Add an IMA policy or AIDE and ship the log off-host.

### KRN-06 — io_uring is available to every user — Medium

`sysctl -n kernel.io_uring_disabled` → `0`; `CONFIG_IO_URING=y`. A minimal probe
run as `ubuntu` (`./iouring-probe`, `io_uring_setup(8, &p)`) printed
**`io_uring_setup: OK fd=3 sq_entries=8 cq_entries=16 features=0x3fff`**. Two
io_uring CVEs are fixed only in newer kernels: `CVE-2026-46315` (waitid result
leak, 5.5) and `CVE-2026-23113` (io-wq exit hang, 5.5); io_uring was behind most
kernel exploits in Google's kCTF programme, and no part of an ML stack needs it.

**Fix.** `kernel.io_uring_disabled = 1` (root only) or 2; re-test PyTorch, TF,
JAX and the notebook kernel (round H found no regression on krabs); add the
probe to `sgs-check`.

### KRN-07 — Any user can autoload line-discipline modules — Low

`sysctl -n dev.tty.ldisc_autoload` → `1`. `./ldisc-probe 3` as `ubuntu` (open
`/dev/ptmx`, `TIOCSETD` N_PPP) printed **`TIOCSETD(3): OK`**, and `/proc/modules`
then held `ppp_async` and `slip`. `TIOCSETD` is not privileged; attaching the PPP
discipline made the kernel load two modules for an unprivileged user
(`TIOCSETD(1)`, N_SLIP, returned EPERM). Bugs in such modules (`n_hdlc`,
`n_gsm`) have given local root before. The modules remain loaded; unloading was
out of scope.

**Fix.** `dev.tty.ldisc_autoload = 0`; assert it in `sgs-check`.

### KRN-08 — IPv4/IPv6 hardening gaps — Low

`send_redirects=1`, `secure_redirects=1`, `log_martians=0`, `rp_filter=2`,
`tcp_rfc1337=0`, `ip_forward=1`; IPv6 `accept_ra=1` and `accept_redirects=1`.
`accept_redirects` is 0 in `all` and the documented rule disables redirects on
forwarding interfaces (all of them forward here), so ICMP redirects are not
accepted today; per-interface values remain 1, which is fragile. Loose
reverse-path filtering weakens source-spoofing checks, martians are not logged,
and IPv6 accepts RAs and redirects (only link-local addresses exist today).

**Fix.** `send_redirects=0`, `secure_redirects=0`, `log_martians=1`,
`tcp_rfc1337=1`, `rp_filter=1` (or document 2), IPv6 `accept_ra=0` /
`accept_redirects=0`. `ip_forward=1` is Docker's requirement.

### KRN-09 — `/tmp` and `/var/tmp` have no mount hardening — Low

`findmnt /tmp` and `findmnt /var/tmp` return nothing: both are directories on
`/`, mounted `rw,relatime,discard,errors=remount-ro,commit=30` with no
`nodev,nosuid,noexec`. `/dev/shm` is `rw,nosuid,nodev` (no `noexec`) and
`df -h` shows **109G**, 50 % of RAM. Every dropper gets an executable staging
area, and any process can exhaust half of RAM.

**Fix.** Mount `/tmp` as tmpfs with `nodev,nosuid,noexec,size=…`, add `noexec`
to `/dev/shm` and cap it, give `/var/tmp` `nodev,nosuid` (keep exec for apt/pip).
Test the installer and `torch.compile` caches first.

### KRN-10 — SRSO/TSA mitigations are incomplete; microcode is stale — Low

`cat /sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow` →
**`Vulnerable: Safe RET, no microcode`**; `.../tsa` → **`Vulnerable: Clear CPU
buffers attempted, no microcode`**; dmesg adds `IBPB-extending microcode not
applied!`. The CPU is
an AMD EPYC 7J13 (Zen 3); the guest loads no microcode patch, so the pending
`amd64-microcode` upgrade (3.20250311 → 3.20251202) would not change this — the
missing microcode is the hypervisor's. SMT is off (`smt/active=0`).

**Fix.** Escalate to Lambda for host microcode/BIOS; install `amd64-microcode`
3.20251202; keep SMT off for multi-tenant work. No guest-side fix beyond the
active safe-RET/VERW mitigation.

## Checked and not a finding

- **dmesg / kptr** — `dmesg` denied; `/dev/kmsg` read denied despite 0644;
  `/proc/kallsyms` returns zeros (`dmesg_restrict=1`, `kptr_restrict=1`).
- **BPF / perf / userfaultfd / memory layout** — `unprivileged_bpf_disabled=2`,
  `perf_event_paranoid=4`, `unprivileged_userfaultfd=0`, ASLR 2, `mmap_min_addr`
  65536, all four `fs.protected_*`.
- **Core dumps / swap** — no apport/systemd-coredump, `fs.suid_dumpable=0`,
  soft limit 0, cores 0600 to the crashing user (round AA: no cross-user leak);
  `swapon --show` and `/proc/swaps` empty.
- **Device nodes** — `/dev/mem` 0640 root:kmem with `STRICT_DEVMEM`; no
  `/dev/kmem`; `/proc/kcore` 0400; `/proc/sysrq-trigger` 0200.
- **Docker access** — `ubuntu` is not in the `docker` group; socket 0660
  root:docker (containers are 05).
- **CPU / TIOCSTI / vsyscall** — `smt/active=0`, no MCE or AER errors, remaining
  dmesg warnings benign (GPT header, `regulatory.db`, VM clock);
  `legacy_tiocsti=0`; `LEGACY_VSYSCALL_XONLY=y`.
- **Overlap** — auditd, IDS/FIM and patch visibility are 08/LOG-02, LOG-04 and
  LOG-10; not counted again.

## References

- [CVE-2026-23392](https://ubuntu.com/security/CVE-2026-23392),
  [CVE-2026-23231](https://ubuntu.com/security/CVE-2026-23231),
  [CVE-2026-31673](https://ubuntu.com/security/CVE-2026-31673),
  [CVE-2025-37899](https://ubuntu.com/security/CVE-2025-37899)
- [`linux-nvidia` 6.8.0-1064.67 changelog](https://changelogs.ubuntu.com/changelogs/pool/main/l/linux-nvidia/linux-nvidia_6.8.0-1064.67/changelog)
- [Qualys advisories](https://www.qualys.com/research/security-advisories/) (2025
  AppArmor bypass); [Google kCTF](https://google.github.io/security-research/pocs/linux/kernelctf/);
  CIS Ubuntu 24.04 Benchmark; [kernel SRSO docs](https://docs.kernel.org/admin-guide/hw-vuln/srso.html)
