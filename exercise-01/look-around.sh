#!/usr/bin/env bash
# look-around.sh: "What's on this machine, and what can reach it?"
#
# Run it inside a VM with:  sudo bash look-around.sh
# It changes nothing except refreshing apt's list of available updates.
# This is the seed of the audit script you'll run on Lambda later.

set -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Run me with sudo:  sudo bash $0"
  exit 1
fi

passes=0
warns=0
ok()      { echo "  [PASS] $1"; passes=$((passes + 1)); }
bad()     { echo "  [WARN] $1"; warns=$((warns + 1)); }
section() { echo; echo "== $1"; }

section "Machine"
. /etc/os-release
echo "  $PRETTY_NAME, kernel $(uname -r), $(uname -m)"
echo "  $(dpkg-query -W -f='.\n' | wc -l | tr -d ' ') packages installed"
echo "  $(systemctl list-units --type=service --state=running --no-legend | wc -l | tr -d ' ') services running"

section "Who can log in"
# Accounts with a real shell (system accounts use nologin/false).
awk -F: '$7 !~ /(nologin|false|sync)$/ { print "  " $1 "  (shell " $7 ")" }' /etc/passwd
echo "  In the sudo group: $(getent group sudo | cut -d: -f4)"

section "SSH (the values sshd really uses, after all config files)"
sshd_settings=$(sshd -T 2>/dev/null)
if [ -z "$sshd_settings" ]; then
  bad "Couldn't read SSH settings (is openssh-server installed?)"
else
  setting() { echo "$sshd_settings" | awk -v k="$1" '$1 == k { print $2 }'; }
  [ "$(setting passwordauthentication)" = "no" ] \
    && ok "Password login is off" \
    || bad "Password login is on"
  [ "$(setting permitrootlogin)" = "no" ] \
    && ok "Root can't log in" \
    || bad "Root login allowed ($(setting permitrootlogin))"
fi

section "Network: programs waiting for connections"
# -t TCP, -u UDP, -l listening, -p process, -n numbers, -H no header
ss -tulpnH | awk '{ print "  " $1 "  " $5 "  " $7 }' \
  | sed -E 's/users:\(\("([^"]+)".*/\1/'
# Anything on TCP that isn't SSH and isn't loopback-only is reachable from outside.
exposed=$(ss -tlnH | awk '{ print $4 }' \
  | grep -vE '^(127\.|\[::1\]|\[::ffff:127\.)' | grep -vE ':22$' || true)
[ -z "$exposed" ] \
  && ok "Only SSH listens on the network" \
  || bad "Listening to the network besides SSH: $(echo $exposed)"

section "Firewall"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ok "Firewall is on"
  defaults=$(ufw status verbose | grep '^Default:')
  echo "$defaults" | grep -q 'deny (incoming)' \
    && ok "Blocks incoming connections by default" \
    || bad "Allows incoming connections by default"
  echo "$defaults" | grep -q 'allow (outgoing)' \
    && bad "Outgoing traffic is unrestricted (a later exercise fixes this)" \
    || ok "Outgoing traffic is restricted"
else
  bad "Firewall is off: every listening program is reachable"
fi

section "Updates"
apt-get update -qq >/dev/null 2>&1
pending=$(apt list --upgradable 2>/dev/null | grep -c 'upgradable from')
security=$(apt list --upgradable 2>/dev/null | grep -c -- '-security')
[ "$pending" -eq 0 ] \
  && ok "No pending updates" \
  || bad "$pending pending updates ($security of them security fixes)"
[ "$(apt-config dump APT::Periodic::Unattended-Upgrade | grep -o '"[0-9]*"')" = '"1"' ] \
  && ok "Automatic security updates are on" \
  || bad "Automatic security updates are off"
[ -f /var/run/reboot-required ] \
  && bad "Updates installed but waiting for a reboot to take effect" \
  || ok "No reboot needed"

echo
echo "== Result: $passes PASS, $warns WARN"
