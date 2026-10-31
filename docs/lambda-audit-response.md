# Responding to the Lambda Stack audit

Another agent audited a real Lambda Cloud A100 running Lambda's default image
(Lambda Stack 24.04) on 2026-10-30: `docs/lambda-instance-audit.md` (2
Critical, 9 High, 7 Medium, 4 Low), verified attack chains in
`docs/lambda-instance-pocs.md`, raw reports in `docs/audit/`, and the gaps in
our audit tool in `docs/sgs-check-gaps.md` (G-01 to G-20). This document
records what we did with all of it, on the same day, and what we chose not
to do. Every change was tested on instance B (Secure GPU Stack on Lambda's
plain Ubuntu 24.04, A100-SXM4-80GB; `docs/lambda-test-bench.md`). Raw output
is in `tests/results/lambda/b/`.

## Bottom line

- **Every attack that worked on Lambda Stack fails on ours.** The audit's PoCs
  were replayed against B as acceptance tests (table below). The headline
  chain, a Jupyter token to root, stops at `sudo`.
- **`sgs-check` is now a risk score, not only a checklist.** Lambda Stack
  scored 24 PASS / 30 WARN with a verified token-to-root chain, because every
  WARN counted the same and the public tunnel was invisible. Now each WARN has
  a severity, chains are rated as a whole, the CRITICAL and HIGH ones lead
  the summary, and a check that didn't run counts against coverage. Planted on
  B, Lambda's setup comes out as **1 CRITICAL, 7 HIGH**; our stack stays at
  **0 WARN** (69 PASS, coverage 69 of 69).
- **Most of the audit is about what Lambda's image adds** (the Cloudflare
  tunnel, the pipx JupyterLab, Lambda's HTTP repository, OFED, postfix,
  rpcbind, glances, classic snaps). Our stack never installs those, but
  `sgs-check` now detects each, so it can also catch a user adding one back.
- **The stack itself got hardened where the audit applies to plain Ubuntu:**
  SSH algorithms and key files, `kexec`, more audit rules, RDMA device files,
  Jupyter token handling, and `dpkg --verify` over the login path. Two new
  findings came out of testing on B (91, 92).

## `sgs-check`: the scoring model

| Before | Now |
|---|---|
| PASS / WARN / SKIP, every WARN equal | Each WARN is CRITICAL, HIGH, MEDIUM (the default) or LOW. The definitions are at the top of the reporting code |
| The last line was the result | Then a "Most serious" list (CRITICAL, then HIGH), a severity count, coverage ("N of M checks ran", naming what didn't), and the unchanged `== Result:` line the login message and the daily service parse |
| A SKIP looked clean | Coverage says what wasn't assessed (`--quick` shows its skips) |
| Weaknesses reported one by one | A "Combined risks" section rates chains: a published Jupyter whose code can become root (CRITICAL), known Jupyter CVEs plus publication or root (HIGH/CRITICAL), network-facing security fixes pending with automatic updates off (CRITICAL), an open GPU with blocked driver fixes (HIGH), a tunnel with no audit trail (HIGH) |
| Human output only | `--json FILE` (id, section, status, severity, message, fix), `--fail-on critical|high|medium|low` |

The login message now shows the severity counts and lists the most serious
WARNs first. Exit status is unchanged by default (1 for any WARN), so the
daily service keeps treating a WARN as a result, not a failure.

## `sgs-check`: the gaps, one by one

| Gap | Status | What it does now |
|---|---|---|
| G-01 public edge | **Done** | Reads cloudflared's configs that root owns (and the running daemon's own `--config`; a user's config is named, never read: root mustn't fetch what a user listed), maps each published hostname (plain names only, at most 10) to its local service, and unless `--quick` fetches it from outside as `nobody`, without URL globbing or following redirects: anything but a redirect to HTTPS (a page, 401, 404, 500) means plain HTTP, CRITICAL for Jupyter, HIGH otherwise; a redirect to HTTPS without HSTS is LOW. A Jupyter published through a tunnel is HIGH by itself and CRITICAL when its code can become root. Also Tailscale Funnel (HIGH), and ngrok, frpc, bore, `code tunnel` and `ssh -R` (MEDIUM). Tailscale Serve is a note (tailnet only) |
| G-02 tunnel credential and daemon | **Done** | Tunnel credentials and the account certificate readable by `nobody` (HIGH); a `--token` on cloudflared's command line (HIGH); cloudflared as root, with its sandbox score; its `/debug/pprof` and `/config` answering `nobody`; routes it can't read |
| G-03 Jupyter service user | **Done** | For every running Jupyter server, however installed (judged on the process that owns the listening socket, not a `sudo` or shell above it): becomes root in one step (passwordless sudo without NoNewPrivileges, root itself, or the docker group with the socket visible) is HIGH; setuid programs reachable is MEDIUM |
| G-04 pipx and other environments | **Done** | pipx venvs (system, root's, every user's) and the environment of each running Jupyter are audited too, **each in its own pip-audit run** (finding 92), as the environment's owner when it sits in a home nobody else can read (the daily run otherwise skipped Lambda's pipx JupyterLab). Advisories in the running Jupyter's own environment feed the chain checks |
| G-05 token lifecycle | **Done** | The token on a command line (`--ServerApp.token`, `--IdentityProvider.token`, either form; every account can read `/proc/PID/cmdline`), or set in a config or runtime file `nobody` can actually open, is HIGH. `sgs-jupyter --rotate` replaces ours |
| G-06 update severity | **Done** | Pending security fixes for what faces the network (sshd, every program listening beyond localhost, glibc, OpenSSL) are HIGH, named, and CRITICAL with automatic updates off. CVSS lookup: not done (needs an online feed) |
| G-07 repository freshness | **Done** | A non-Ubuntu repository whose index hasn't changed in 180 days is MEDIUM (Lambda's: 2025-12-31). Key expiry and `Valid-Until`: not done (Ubuntu's own archive has no `Valid-Until`, so it would only add noise) |
| G-08 CPU side channels | **Done** | "Vulnerable" entries are MEDIUM on bare metal (microcode fixes them) and a note in a VM, where only the host can. Both Lambda instances: SRSO and TSA, "no microcode" |
| G-09 GPU and RDMA, functional | **Done** | `nobody` opening `/dev/nvidiactl` (nothing allocated); RDMA and shared-memory devices (`/dev/infiniband/*`, `knem`, `xpmem`) open to everyone are HIGH; strict outbound mode with RDMA present is MEDIUM (RDMA bypasses it) |
| G-10 firewall, Docker, east-west | Already covered | Firewall default-deny, Docker publishing and its localhost default, listeners beyond SSH. External probing stays with `tests/attack-demo.sh` |
| G-11 audit trail and detection | **Partly** | 35 audit rules now (accounts, PAM, root's SSH keys, units, cron, `ld.so.preload`); the daily check doubles as file-integrity monitoring. Off-host logging: documented as an opt-in, not a default (it needs a destination) |
| G-12 SSH hygiene | **Done** | SHA-1 and 64-bit MACs, RSA under 2048 bits and `authorized_keys2` are LOW; root keys that only run a forced command **and** can't forward ports (`no-port-forwarding` or `restrict`, as on Lambda) are LOW; a forced command alone still allows `ssh -N -L` to root-only sockets, so it stays MEDIUM |
| G-13 pip and model safety | **Done** | `break-system-packages` in any pip config or as `PIP_BREAK_SYSTEM_PACKAGES` in a login profile. Model loading: pip-audit covers Keras; `torch.load` defaults are in the user checks |
| G-14 other services' sandboxes | **Done** | Root services listening beyond localhost (sshd aside) with a systemd exposure of 8.0 or more |
| G-15 Jupyter Host header | **Done** | A request with `Host: rebind.example` must be refused, over each socket and port (DNS rebinding) |
| G-16 low sysctls | **Partly** | `kernel.kexec_load_disabled` and `vm.unprivileged_userfaultfd` are pinned and checked. `panic_on_oops`, `noexec` `/tmp` and `nullok`: declined (below) |
| G-17 apt history, reboot | Already covered | "Updates are waiting for a reboot" was there. apt history: Lambda's image build strips it; ours writes it normally |
| G-18 cloud-init seed | **Done** | Members of the `disk` group can read every disk, the seed included: HIGH. B's seed holds no secret (its vendor data has none; our user data holds a URL and a hash) |
| G-19 file capabilities | **Done** | Programs with capabilities beyond Ubuntu's own (`ping`, `mtr-packet`, `snap-confine`, `gst-ptp-helper`) are LOW. Classic snaps: not checked (none on the plain image) |
| G-20 persistenced socket | **Done** | Finding 89 (earlier the same day) |

The precision fixes the gaps document asked for are in too: cloud metadata
that answers 404 everywhere is "reachable, no data" (LOW) instead of "can
read" (HIGH only if a standard path returns data, or AWS's IMDSv2 answers 401,
a session token being one PUT away), the root forced command is
named, a Docker API on localhost TCP is HIGH and on the network CRITICAL, and
the localhost Jupyter WARN now has the tunnel check next to it.

### Proving the checks fire

A clean run only shows the checks pass. To show they fire, twelve
Lambda-style problems were planted on B (`tests/results/lambda/b/sgs-check-fixtures.txt`)
and removed afterwards:

| Planted | Reported as |
|---|---|
| A second JupyterLab on `127.0.0.1:8899`, token on its command line, any Host header, no NoNewPrivileges | MEDIUM localhost port; HIGH becomes root (passwordless sudo); HIGH token readable (command line); MEDIUM DNS rebinding |
| A cloudflared config publishing it, credential 0644 | HIGH credential readable; HIGH Jupyter published through a tunnel; **CRITICAL** chain |
| A pipx-style venv with `requests` 2.19.0 | HIGH: 49 advisories in that environment |
| `break-system-packages = true` in `/etc/pip.conf` | MEDIUM |
| `ubuntu` in the `disk` group | HIGH |
| A world-open `/dev/knem` | HIGH (RDMA) |
| A program with `cap_net_raw` | LOW |
| A repository index last changed 300 days ago | MEDIUM |
| (after the review) The fixture Jupyter started through `sudo -u ubuntu` | Still "becomes root" for the server; the root `sudo` above it isn't reported (0 "runs as root" lines); its command line is reported, since it holds the token too |
| (after the review) A user-owned `~/.cloudflared/config.yml` with the hostname `10.255.255.[1-2]:[1-2]` | Named as "not read"; nothing fetched |

Result: 1 CRITICAL, 7 HIGH, 4 MEDIUM, 1 LOW; the planted token appeared
nowhere in the output or the JSON; `--fail-on critical` exited 1. After
cleanup: 0 WARN.

Two of the planted problems weren't caught on the first try, which is what
the test was for: the tunnel's port wasn't extracted (a `sed` expression used
`|` as both its delimiter and its "or"), and the old `requests` was hidden by
pip-audit merging environments (finding 92).

## An independent review, and what it changed

A second agent reviewed every change (reading the code, without the
reasoning behind it). It found six bugs that mattered, all fixed and
re-verified on B:

1. **Root acted on user-written tunnel configs.** `sgs-check` parsed
   `~/.cloudflared/*.yml` of every account and fetched the hostnames listed
   there, as root: a user could stall the daily run with a curl URL pattern,
   point root at the metadata address, or name any file as a "credential".
   Now only root-owned configs are read, hostnames must be plain names,
   probes run as `nobody` (which the metadata guard covers) with globbing and
   redirects off, and credential paths are taken literally.
2. **A Jupyter token could reach the output.** The environment lookup passed
   every command-line argument to `dirname`, which echoes an unknown
   `--ServerApp.token=...` option in its error. Now only absolute paths are
   used, with no external command.
3. **The RDMA rule opened the fabric-management devices** (`umad`, `issm`),
   which the kernel keeps root-only. That line is gone.
4. **A forced root command without `no-port-forwarding` was rated LOW**,
   though `ssh -N -L` reaches root-only sockets with it.
5. **Wrapper processes counted as Jupyter.** A root `sudo -u ubuntu jupyter
   lab` was reported as "Jupyter runs as root" (and could fire a CRITICAL
   chain). Now only the process owning the listening socket is judged.
6. **Plain HTTP answering 401, 404 or 500 wasn't caught.** Now anything but a
   redirect to HTTPS is.

And smaller ones: `--quick` hid the "published through a tunnel" HIGH; JSON
records could be split by a newline in a file name; commented-out config
defaults counted as a token; Jupyter CVEs were read from any environment's
top twelve; AWS IMDSv2; `sgs-jupyter --rotate` deleting the token before
`sudo` was confirmed; the PyTorch/TensorFlow warning ordering under `-W
error` and where it points; a wireless mouse's battery turning persistence
mode off; `PIP_BREAK_SYSTEM_PACKAGES=0` counted as on. Testing the fixes on B
caught one more: the `--rotate` fix used `sudo -v`, which wants a password
unless every sudoers entry is passwordless, and Lambda's `ubuntu` also
matches `%sudo`; it now uses `sudo -n true`. The fixture run gained two
cases for these (a user-owned config with a URL pattern; Jupyter started
through `sudo -u`): neither is misreported.

## The stack: what changed

- **SSH** (`files/sshd-10-sgs.conf`): OpenSSH's MACs minus SHA-1 and
  64-bit ones, `RequiredRSASize 2048`, `AuthorizedKeysFile` without
  `authorized_keys2`, `ClientAliveInterval 300` (dead clients only),
  `DebianBanner no`. The installer applies it only if the user has a key that
  still works (an RSA key under 2048 bits doesn't count). Agent forwarding
  stays: people use `ssh -A` to clone private repositories.
- **Kernel** (`files/sysctl-60-sgs.conf`): `kernel.kexec_load_disabled = 1`
  (a backstop for when lockdown is off; no kdump on these images) and
  `vm.unprivileged_userfaultfd = 0` pinned.
- **Audit rules** (`install.sh`): 24 → 35. Accounts (`passwd`, `shadow`,
  `group`, `gshadow`), PAM, root's SSH keys, systemd units, cron,
  `ld.so.preload`. Every root command run for a user was left out: one
  `sudo apt upgrade` would rotate the rest out of the log.
- **RDMA device files** (`files/73-sgs-rdma-devices.rules`): verbs, MAD,
  `rdma_cm`, `knem`, `xpmem` for the video group only, 0660, with `:=` so
  rdma-core's later rules can't reopen them. **Untested on InfiniBand
  hardware**: single-GPU Lambda instances have no RDMA devices.
- **`sgs-jupyter`:** the token is printed apart from the URL, to paste on the
  login page, so it stays out of browser history and proxy logs (the audit's
  H-09); `--rotate` replaces it; and the tunnel command names the public
  address (finding 91).
- **`dpkg --verify`** now also covers sshd, sudo, PAM, systemd, the C library
  and OpenSSL: a replaced `sshd` or `sudo` shows like a replaced `libcuda`.

### New findings

91. **`sgs-jupyter` told Lambda users to tunnel to an address they can't
    reach.** It used the default route's source address, which behind
    Lambda's NAT is the private 10.19.x address. Lambda's instances name
    themselves after their public address (`150-136-35-202`), so that's used
    when the route's address is private; a LAN or VPN address (krabs) stays
    as it was, and the text says to use the address you SSH to otherwise.
92. **pip-audit merged environments.** Given several `--path`s it keeps one
    version per package name, so an old package in one environment could be
    hidden by a newer copy in another: the stack's tools environment shares
    `requests`, `urllib3` and others with the main one. Each environment now
    gets its own run (the main venv, TensorFlow's CUDA 12 folder, the tools,
    and any pipx or Jupyter environment).

## The audit's findings and our stack

"Lambda only" means the plain Ubuntu image doesn't have it (B's vendor data
and services confirm it); `sgs-check` now detects it on Lambda Stack.

| Finding | On our stack | Evidence |
|---|---|---|
| **C-01** public Jupyter over HTTP; token → root | Covered by design: socket only, firewall, NoNewPrivileges | POC-1, POC-2, POC-7 below |
| **C-02** 228 security updates, automatic updates off | Covered: automatic updates for Ubuntu, Docker and NVIDIA, time limits, applied at install | B: 0 pending; `full-upgrade -s` clean |
| **H-01** Jupyter as a passwordless sudoer, unsandboxed | Covered: same user, no sudo (NoNewPrivileges), exposure 2.2; web terminal in the same sandbox | POC-1 |
| **H-02** Jupyter/ML CVEs, pipx outside apt | Covered: hash-locked current versions, daily pip-audit (0 advisories). An update channel for the Python stack is still v0.2 | `sgs-check` |
| **H-03** tunnel secret 0644, root cloudflared | Lambda only; detected (G-01, G-02) | fixtures |
| **H-04** driver, toolkit, kernel pinned | Covered: Ubuntu's signed driver, prebuilt modules, toolkit updated automatically | test bench |
| **H-05** HTTP, frozen, globally trusted repository | Lambda only; HTTPS with per-source keys here; staleness now detected | fixtures |
| **H-06** GPU, RDMA, knem 0666 | GPU: covered (POC-3). RDMA: none on B; udev rule added, untested on InfiniBand | POC-3, POC-5 |
| **H-07** no host firewall; postfix, rpcbind | Covered: default deny; none of those services | POC-7, POC-8 |
| **H-08** no audit trail | Partly: auditd with 35 rules; daily integrity checks; off-host logging is an opt-in | install |
| **H-09** static token, URL login, clones | Partly: 0600, socket-only, token kept out of URLs, `--rotate` | POC-5 |
| **M-01** CPU microcode | Can't fix inside a VM; reported as a note | `sgs-check` |
| **M-02** kernel hardening | Covered (lockdown, io_uring, userns, ldisc, redirects), plus kexec and userfaultfd now | POC-4 |
| **M-03** SSH hygiene | Covered (keys only, no root, no X11) plus algorithms and key files now | `sshd -T` on B |
| **M-04** root services unsandboxed | Lambda only; detected (G-14) | POC-6 |
| **M-05** Docker defaults | Covered: localhost publishing, no-new-privileges, ICC off, log caps, nobody in `docker` | POC-8 |
| **M-06** open egress | Opt-in strict mode, tested on Lambda; RDMA bypass now reported | test bench |
| **M-07** supply chain | Covered: hashes, one index, pip-audit, modelscan, SBOM. `safetensors` and a secret scanner: v0.2 | — |
| **L-01** metadata reachable | Covered: blocked for every account but root, also through `ssh -L` | POC-8 |
| **L-02** `torch.compile` cache in `/tmp` | Covered (finding 83) | attack: SAFE |
| **L-03** `nullok`, umask, memlock, `/var/crash` | Declined (below) | — |
| **L-04** classic snaps, capabilities | Snaps: Lambda only. Capabilities: Ubuntu's own only, now checked | `sgs-check` |

## The PoCs, replayed against our stack (instance B)

`tests/results/lambda/b/pocs-replay.txt`; commands written for this from the
PoC document (non-destructive; the token never on a command line).

| PoC | Lambda Stack | Secure GPU Stack |
|---|---|---|
| 1. Token → notebook → `sudo -n` → root | root | `sudo`: "the 'no new privileges' flag is set"; capabilities all zero; `/etc/shadow` unreadable; `/etc` read-only; Docker socket refused; pid 1 invisible; the web terminal's shell has NoNewPrivs too. The SSH shell keeps sudo (the documented boundary) |
| 2. Public HTTP Jupyter, token in the URL | 200 over HTTP | Nothing answers from outside (000 on 80, 443, 8888, 7000); `Host: evil.example` gets 403; a wrong token goes to the login page |
| 3. `nobody` on the GPU | took 8 GB | "No CUDA GPUs are available"; `nvidia-smi` refused; no device file opens; a `video` member still gets 64 MiB |
| 4. `aa-exec` user namespace → `CAP_NET_ADMIN` | uid 0, `nft` worked | Refused through `docker-default`, 1password and Discord, as `ubuntu` and as `nobody` |
| 5. RDMA, tunnel secret, token | RDMA and knem open; secret readable | No RDMA devices, no cloudflared; token 0600, unreadable by `nobody`, not in the journal |
| 6. Root daemons' debug endpoints | cloudflared `/config` and pprof answered | Only sshd and the DNS resolver listen; every probe 000; a notebook reaches none |
| 7. Tunnel around the firewall | public Jupyter | Only 22 answers; firewall denies incoming; no tunnel clients |
| 8. Controls that held on Lambda | forced command | Root SSH refused outright; no token, 403; metadata blocked for `ubuntu` (root 404); `docker ps` refused, `docker` group empty |
| Extra: `ssh -L` to the metadata address | (any account could) | 000: the user's sshd process is refused by the metadata guard |

## Declined, with reasons

From the audit and the gaps document; each costs ML work more than it
protects, or doesn't apply:

- **A separate non-sudo Jupyter user.** Same result, already: the service
  can't sudo (NoNewPrivileges), and notebooks keep the user's files.
- **Taking away cloud-init's passwordless sudo.** `ubuntu` has no password,
  so it would lose sudo altogether.
- **Turning off agent forwarding, `AllowTcpForwarding local`.** They break
  `ssh -A` (cloning private repositories) and `ssh -R`.
- **`panic_on_oops=1`.** A GPU driver oops would reboot the machine and kill
  every job.
- **`noexec` on `/tmp`, a capped `/dev/shm`.** They break pip builds,
  installers and DataLoader workers; `python /tmp/x.py` runs anyway.
- **umask 027, removing `nullok`, fail2ban, `pam_faillock`.** Breaks shared
  Docker images (decided on M2); keys only, passwords locked.
- **userns-remap or rootless Docker by default, a `DOCKER-USER` drop rule.**
  They break bind-mounted datasets, `--net=host` and deliberate publishing.
- **MIG or MPS by default, Jupyter idle culling.** Single tenant; culling
  kills kernels holding a loaded model.
- **`rp_filter=1`, `accept_ra=0`, DNSSEC/DoT/NTS.** Break Docker, Tailscale or
  provider IPv6; brittle against provider resolvers.
- **Logging every root command (`execve` with `auid>=1000`).** One
  `sudo apt upgrade` would rotate everything else out of the audit log.
- **CDI spec 0640.** It holds no secret; its writability is checked.

## Still open

- **Multi-GPU and InfiniBand:** the RDMA udev rule, Fabric Manager, NCCL
  across GPUs and nodes. Needs an 8-GPU instance.
- **An update channel for the Python stack** (the v0.2 signed apt
  repository). Today pip-audit reports, a new release fixes.
- **Off-host logs and alerting**, as a documented opt-in.
- **`safetensors` and a secret scanner** in the lock (needs a re-lock).
- **CVSS for pending updates** (needs an online feed), repository key expiry.
