# 08 — Logging, monitoring and incident readiness

**Target:** `ubuntu@<instance>` — Lambda Cloud A100, Ubuntu 24.04.4 LTS, kernel 6.8.0-1046-nvidia,
default Lambda Stack image. **Audited:** 2026-10-30, 20:42–20:52 UTC; the instance booted at 20:30 UTC,
so every log below came from the image's own boot or from this audit. **Method:** read-only SSH
(`ubuntu` has passwordless sudo), plus one wrong-token request and one failed `POST /login` against
Jupyter to test auth-failure logging. Nothing installed, no config changed, no reboot. Token, tunnel
ID/secret, account tag, egress IP and key fingerprints are redacted.

## Summary

| ID | Finding | Sev |
|---|---|---|
| LOG-01 | Public Jupyter/Cloudflare path has no usable detection: requests log `127.0.0.1`, a wrong token is an ordinary `302`, nothing alerts, Cloudflare logs are off-host | Critical |
| LOG-02 | No auditd and no rules; kernel audit records are generated then discarded (only AppArmor denials survive) | High |
| LOG-03 | No off-host copy, no tamper evidence; passwordless `sudo` can vacuum or delete every log | High |
| LOG-04 | No IDS/EDR/FIM/rootkit/vulnerability scanning, no SIEM, no working alerting path | High |
| LOG-05 | Jupyter token in a 0644 config (home 0750) and root-only vendor-data; static, never rotated; **not** printed at startup | High |
| LOG-06 | Cloudflare tunnel credentials (`TunnelSecret`) world-readable at `/etc/cloudflared/jupyter-tunnel.json` | Medium |
| LOG-07 | No command accounting: no `acct`/`psacct`, no Bash history, no sudo I/O logging | Medium |
| LOG-08 | Image ships without `/var/log/dpkg.log` or `/var/log/apt/history.log`; package changes unreconstructable | Medium |
| LOG-09 | Retention short and inconsistent (rsyslog 4 weeks, sysstat 7 days, wtmp 1 month, journal default); no policy | Medium |
| LOG-10 | 298 pending updates, unattended-upgrades disabled, no reboot-required or update notice at login | Medium |
| LOG-11 | `glances` runs as root, unauthenticated on loopback, logs nothing and is consumed by nothing | Low |
| LOG-12 | World-readable package inventory; no audit of who reads or exports logs | Low |
| LOG-13 | systemd running stale unit definitions since boot (`daemon-reload` never run) | Low |

**13 findings: 1 Critical, 4 High, 5 Medium, 3 Low.**

## Detailed findings

### LOG-01 Public Jupyter/Cloudflare path has no usable detection — Critical

`$ curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:7000/lab?token=<wrong>'` → `302`; `$ journalctl -q -u lambda-jupyter --since -40s | grep ' 302 '` → `[I ... LabApp] 302 GET /lab?token=[secret] (@127.0.0.1) 0.56ms`; `grep -c ' 401 '` → `0`; `$ curl -s http://127.0.0.1:20241/metrics` → `tunnel_total_requests 81`, `ha_connections 4`.

`cloudflared` fronts Jupyter, so every request logs `@127.0.0.1`, and a wrong token is a `302` to `/login` logged as an
ordinary INFO request: no failure marker, counter, lockout or alert. Cloudflare's request logs stay off-host (no
Logpush export visible from the host), no authenticating proxy exists, `cloudflared` writes only 18 startup lines, and
its metrics are unscraped. **Impact:** token theft is indistinguishable from the owner, and a notebook is root via sudo.
**Fix:** Cloudflare Access, `CF-Connecting-IP` logging, alerts on `401`/`403` bursts and new tunnel replicas.
Ref: Cloudflare Tunnel logging; OWASP Logging Cheat Sheet.

### LOG-02 No auditd; privileged actions have no syscall record — High

`$ dpkg -l auditd | grep '^ii'` → nothing; `$ sudo auditctl -l` → command not found; `$ ls /etc/audit /var/log/audit` → both missing; `$ systemctl is-enabled systemd-journald-audit.socket` → `disabled`; `$ sudo dmesg | grep kauditd` → `kauditd_printk_skb: 116 callbacks suppressed`.

`CONFIG_AUDIT=y` and no `audit=0`, so the kernel generates records; with no daemon and the socket off they are printed
to the ring buffer and dropped. Only AppArmor `type=1400` survives (27 this boot, e.g. `userns_create`), in
`dmesg`/`kern.log`. Logins and `sudo COMMAND=` lines reach `auth.log`; `useradd`, `chmod`, `insmod`, edits to
sudoers/`authorized_keys`/units and Docker starts go unrecorded. **Impact:** a compromise leaves no persistence, file
or module record. **Fix:** `auditd` + `audispd-plugins` with the CIS rules, audit socket on, `audit=1` explicit.
Ref: CIS 24.04 §4.1; `auditd(8)`.

### LOG-03 No off-host copy and no tamper evidence — High

`$ grep -rniE '@@|omfwd|target=' /etc/rsyslog.conf /etc/rsyslog.d/` → nothing; `$ dpkg -l systemd-journal-remote | grep '^ii'` → nothing; `$ sudo lsattr /var/log/auth.log /var/log/journal/*/system.journal` → no `+a`/`+i`; `$ sudo journalctl --header | grep -i seal` → unsealed.

No remote syslog, no journal upload, no append-only attribute, no sealing, no hashes, no snapshot: whoever can read the
logs can destroy them (`sudo journalctl --vacuum-time=1s`, `> /var/log/auth.log`, `rm -rf /var/log/journal`), and
nothing proves the survivors are complete. **Impact:** anti-forensics is one command. **Fix:** `omfwd` over TLS or
`systemd-journal-upload` to a host the instance cannot write, `chattr +a`, a daily signed hash manifest off-host, and a
written retention policy. Ref: NIST SP 800-92 §4–5.

### LOG-04 No detection tooling and no alerting path — High

`$ for p in fail2ban sshguard snort suricata zeek aide tripwire rkhunter chkrootkit osquery wazuh-agent clamav-daemon auditbeat filebeat logwatch; do dpkg-query -W -f='${Status}' $p 2>/dev/null | grep -q 'install ok installed' && echo $p; done` → nothing; `$ command -v trivy grype pip-audit oscap lynis debsecan pro` → nothing; `$ sudo postconf -n | grep relayhost` → `relayhost =`; `$ sudo ls /var/mail` → empty.

No IDS/IPS, EDR, file-integrity monitoring (AIDE/Tripwire/IMA), rootkit scanner, container/image scanner, vulnerability
scanner, CIS tool, SIEM or agent of any kind. The only detection-shaped hook is `logrotate`'s `logger -t logrotate
"ALERT exited abnormally"` — a line nobody reads. `postfix` has an empty `relayhost` and the root mail spool is empty,
so no webhook, Slack, PagerDuty or email can fire; no `sgs-check`-style daily posture check or baseline exists, so a new
`authorized_keys`, sudoers entry or Jupyter config edit is noticed only by hand. **Impact:** nothing can raise an alarm.
**Fix:** working alert transport, auditd keyed rules plus daily hash diff, `fail2ban`, container scanning in CI.
Ref: CIS 24.04 §1.1, §4.2.

### LOG-05 Jupyter token sits in a 0644 file and is static — High

`$ sudo grep -n 'ServerApp.token' /home/ubuntu/.jupyter/jupyter_config.py` → `963:c.ServerApp.token = '<redacted>'`; `$ sudo stat -c '%a %U:%G' ...` → `644 ubuntu:ubuntu`; the file also sets `c.ServerApp.allow_remote_access = True`.

**Correction (parent, 2026-10-30):** the two `token=` lines in the journal are the startup banner
`http://127.0.0.1:7000/lab?token=...` — a literal ellipsis, not the secret. Jupyter does not print a
config-sourced token, and a search for the real value in the journal returns zero. What *is* logged is
the request URL: a fake-token test produced `302 GET /lab?token=[secret]`, so a real token used in a
URL would be recorded. The token itself is a per-instance value injected through Lambda's `vendor-data`
(0600, and `obj.pkl`) and written into a 0644 config; the 0750 home is the only thing preventing other
local users from reading it. There is no rotation, no second factor and no revocation short of editing
the file and restarting. **Impact:** one 32-hex string grants root-equivalent access, is recoverable by
any process as `ubuntu` (a malicious notebook or pip package), and persists in config, vendor-data and
snapshots. **Fix:** 0600 config, rotate, stop URL-token login, real identity in front (LOG-01).
Audit side effect: the audit's own `sudo grep <token>` wrote the token into `auth.log`/the root journal;
rotate the token or terminate the instance. Ref: Jupyter `IdentityProvider.token`; CIS 24.04 §6.1.

### LOG-06 Cloudflare tunnel credentials are world-readable — Medium

`$ sudo stat -c '%a %U:%G %n' /etc/cloudflared/jupyter-tunnel.json` → `644 root:root /etc/cloudflared/jupyter-tunnel.json`; `$ sudo python3 -c "import json;print(sorted(json.load(open(...))))"` → `['AccountTag', 'TunnelID', 'TunnelName', 'TunnelSecret']`; `config.yml` is 0644 too.

The credentials file holds the tunnel secret and is readable by every local account and unprivileged process. With it
anyone can run a second connector for the same tunnel — Cloudflare balances across replicas — serve a fake Jupyter login
on the public hostname to harvest tokens, or sit on the traffic. **Impact:** public-endpoint impersonation from any local
compromise or copied file, independent of the Jupyter token. **Fix:** `chmod 600` both files, run `cloudflared` as a
dedicated user, rotate the tunnel if it was ever copied. Ref: Cloudflare Tunnel credentials docs; CIS 24.04 §6.1.

### LOG-07 No command accounting and no shell history — Medium

`$ dpkg -l acct psacct | grep '^ii'` → nothing; `$ ls -la /home/ubuntu/.bash_history` → No such file; `$ grep -iE 'HISTCONTROL|HISTTIMEFORMAT' /home/ubuntu/.bashrc` → `HISTCONTROL=ignoreboth`; `$ sudo grep -iE 'log_input|log_output' /etc/sudoers*` → nothing.

Sudo records `ubuntu : PWD=... ; USER=root ; COMMAND=/usr/bin/...` (392 lines on this fresh boot, so it works), but
there is no session recording and no process accounting, so arguments are all you get and only for sudo. `ignoreboth`
drops duplicate and space-prefixed commands, `HISTTIMEFORMAT` is unset, and an intruder would simply unset `HISTFILE`.
**Impact:** what an attacker ran outside sudo is unrecoverable. **Fix:** `acct`/`psacct` or auditd `execve` rules,
`Defaults log_input, log_output`, set `HISTTIMEFORMAT`. Ref: CIS 24.04 §4.1.1.

### LOG-08 Package and apt history is missing from the image — Medium

`$ ls /var/log/apt/` → only `eipp.log.xz` (created by this audit's dry-run); `$ ls /var/log/dpkg.log*` → `No such file or directory`.

`/var/log/apt/history.log`, `term.log` and `/var/log/dpkg.log` are absent on a freshly booted image, although logrotate
keeps rules for them (12 months) and `dpkg-db-backup.timer` exists. `dpkg -l` gives current state only, with no record of
when or why a package arrived. **Impact:** you cannot tell whether a package was in Lambda's image, added by a user, or
installed by an attacker; the incident timeline starts at "now". **Fix:** stop stripping `/var/log/apt` and `dpkg.log`
from published images, audit `dpkg`/`apt`, back up `/var/lib/dpkg/status` off-host. Ref: CIS 24.04 §1.2.1.

### LOG-09 Retention is short and inconsistent, with no policy — Medium

`$ grep -E 'rotate|weekly' /etc/logrotate.d/rsyslog | head -2` → `rotate 4` / `weekly` (≈4 weeks); `$ grep HISTORY /etc/sysstat/sysstat` → `7`; `$ systemd-analyze cat-config systemd/journald.conf | grep -vE '^#|^$'` → only `[Journal]` and `ForwardToSyslog=yes`.

The journal is the only long-lived store (default cap 10 % of the filesystem, max 4 GiB — months here), while
`auth.log`/`syslog` vanish after four weeks and sysstat after seven. `ForwardToSyslog=yes` (from Ubuntu's
`/usr/lib/systemd/journald.conf.d/syslog.conf`) duplicates every record into rsyslog, giving two copies with different
formats, rotation and retention. **Impact:** whether evidence exists depends on which log it landed in, and the shorter
copies are the human-readable ones. **Fix:** explicit `SystemMaxUse=` / `MaxRetentionSec=`, aligned retention, a
documented schedule, and off-host shipping (LOG-03). Ref: `journald.conf(5)`; NIST SP 800-92 §4.

### LOG-10 Patch state is invisible to an operator — Medium

`$ sudo apt-get -s upgrade | grep -c '^Inst'` → `298`; `$ grep -vE '^\s*//|^\s*$' /etc/apt/apt.conf.d/20auto-upgrades` → `APT::Periodic::Unattended-Upgrade "0";`; `$ ls /run/reboot-required*` → absent; `$ dpkg -l update-notifier-common` → not installed.

298 packages are upgradable, 224 of them from `noble-security` — `libc6`, `openssl`, `openssh-server`,
`linux-libc-dev`. Unattended-upgrades is "active" but the periodic switch is `0`, so it does nothing. `needrestart` is
installed but nothing reports its findings, `/run/reboot-required` is absent and `update-notifier-common` is missing, so
the motd shows only the ESM notice. **Impact:** the box can sit months behind while no log line, motd or dashboard says
so, and a required reboot is never surfaced. **Fix:** enable the periodic security upgrade, install
`update-notifier-common`, wire `needrestart`, alert on pending updates and reboot-required. Ref: CIS 24.04 §1.9.

### LOG-11 `glances` runs as root, unauthenticated, and logs nothing — Low

`$ systemctl show glances.service -p User -p ExecStart` → `User=` (empty) and `/usr/bin/glances -s -B 127.0.0.1`; `$ sudo ss -tlnp | grep 61209` → `LISTEN 0 5 127.0.0.1:61209 ... users:(("glances",pid=1635,fd=4))`.

It runs as root, serves an unauthenticated API on loopback and records nothing about who queries it; it is the closest
thing to monitoring here and it is passive. **Impact:** any local user or compromised process gets a root-level view of
processes, connections and mounts from an unmonitored root listener. **Fix:** dedicated user plus password, or remove
it; scrape metrics instead of exposing an interactive service. Ref: `glances(1)`; CIS 24.04 §2.1.

### LOG-12 World-readable inventory; log reads unaudited — Low

`$ stat -c '%a %U:%G' /var/log/package-list.md` → `644 root:root` (168 KB, the only world-readable file in `/var/log`); `$ getent group adm systemd-journal` → `adm:x:4:syslog` / `systemd-journal:x:999:` (no members).

Access control itself is sound (see below), but the package inventory is world-readable and useful for targeting, the
journal holds the Jupyter token and public hostname, and nothing records who reads, exports or copies logs. The
`adm`/`systemd-journal` split is nominal: `ubuntu` cannot read `auth.log` directly but reads it in one sudo command.
**Impact:** reconnaissance value for a local attacker, and no way to tell whether logs were read before being wiped.
**Fix:** 0640 the inventory, keep secrets out of logs, rely on off-host copies. Ref: CIS 24.04 §6.1; NIST SP 800-92 §5.

### LOG-13 systemd is running stale unit definitions — Low

`$ systemctl status systemd-journald --no-pager | head -2` → `Warning: The unit file ... of systemd-journald.service changed on disk. Run 'systemctl daemon-reload'`.

The same warning appears for `cloudflared.service`, `lambda-jupyter.service` and `lambda-first-boot.service`:
provisioning rewrote units after those services had started, and no `daemon-reload` ever ran. Nothing watches unit
files for change. **Impact:** systemd enforces the old definitions, so a hardening or logging change to a unit silently
does not apply, and "the unit changed" is ambiguous during triage. **Fix:** end provisioning with
`systemctl daemon-reload`; add units and drop-ins to the integrity watch (LOG-02/04). Ref: `systemd.unit(5)`; CIS §1.1.

## Checked and not a finding

- **Journald is persistent:** `/var/log/journal/<machine-id>/` holds `system.journal` and `user-1000.journal`;
  `Storage=auto` resolves to persistent; 8.0 MB used, 17 MB on disk; survives reboot.
- **Journal access control is correct:** `journalctl -F _UID` returns only `1000`; `_UID=0` returns nothing; reading
  `system.journal` is "Permission denied"; dirs are 2755 `root:systemd-journal` with ACL `group:adm:r-x` (adm holds
  only `syslog`); `systemd-journal` has no members.
- **rsyslog works:** 8.2312 enabled and active, writes `auth.log`, `syslog`, `kern.log`, `mail.log` as 0640
  `syslog:adm`; no remote destination (LOG-03).
- **sshd and sudo log auth events:** 826 sshd lines (`Accepted publickey for ubuntu from <ip>`, PAM session open/close,
  disconnects, 4 `Connection closed by` failures) and 392 sudo `COMMAND=` lines this boot; root logins are logged too
  (2 accepted, see note).
- **logrotate is healthy:** `su root adm`, `weekly`/`rotate 4`, per-service files for apt, dpkg, cloud-init,
  unattended-upgrades, btmp, wtmp; dry-run reports no errors; next run 00:00 UTC. `wtmp`/`lastlog` are 0664 and `btmp`
  0660 `root:utmp`; `btmp` is empty because sshd writes failures to `auth.log`, not `btmp`.
- **Hygiene is clean:** `systemctl --failed` empty; no OOM kills; no GPU Xid (only `NVRM: loading ... 580.105.08`);
  cloud-init `status: done`, `errors: []`; chrony synchronised, stratum 3; `/` 495 GB at 5 %; `/var/log` 18 MB; no crash
  dumps; Docker active with no containers; no rsyslog queue errors; sysstat collecting (`sa30`, 10-minute samples,
  `HISTORY=7`).
- **cloudflared is healthy:** 4 HA connections, 81 tunnel requests, 18 journal lines — enough for liveness, not for
  abuse detection (LOG-01). AppArmor is the only MAC telemetry and it works: 10 `DENIED` this boot including
  `userns_create`, but nothing watches them.

## Notes for the fix team

- **Not this thread, but material:** root SSH by key is enabled (`permitrootlogin without-password`;
  `/root/.ssh/authorized_keys`, 0600) and `auth.log` records two accepted root logins from the audit egress IP. That
  belongs to the SSH thread; it matters here because success on the public path lands directly at root, which is what
  this missing audit trail would have to reconstruct.
- **Biggest delta from Secure GPU Stack:** no `sgs-check`-style daily posture check, no accepted-state baseline, no
  change alerting — the first sign of a modified sudoers file, `authorized_keys`, unit or Jupyter config would be a human
  noticing by hand. **Suggested order:** alert transport and off-host logs (LOG-03/04), then `auditd` (LOG-02), then the
  Jupyter/Cloudflare identity path (LOG-01/05/06); without the first two the rest writes records nobody reads, to a disk
  the attacker can wipe.

## References

- CIS Ubuntu Linux 24.04 LTS Benchmark — §1.1–1.2 (integrity, package logs), §2.1 (services), §4.1–4.2 (auditd, process
  accounting), §6.1 (permissions).
- NIST SP 800-92, *Guide to Computer Security Log Management*; `auditd(8)`, `audit.rules(7)`, `journald.conf(5)`,
  `logrotate(8)`, `sudoers(5)`.
- Cloudflare Tunnel docs (credentials file, replicas, Logpush); Jupyter Server security docs (`IdentityProvider.token`,
  `allow_remote_access`).
