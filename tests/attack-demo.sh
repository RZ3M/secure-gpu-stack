#!/usr/bin/env bash
# Try to reach a machine's services from outside, the way someone on the
# internet would, and show what the stack blocks.
#
#   tests/attack-demo.sh HOST [SSH_KEY] [USER]
#
# Run it from your own computer. SSH_KEY (default ~/.ssh/id_ed25519) must be
# authorized for USER (default ubuntu) on HOST; it's used for the tunnel and
# Docker steps. Host keys go to a throwaway known_hosts file, not yours.
set -u

HOST="${1:?usage: tests/attack-demo.sh HOST [SSH_KEY] [USER]}"
KEY="${2:-$HOME/.ssh/id_ed25519}"
USER_NAME="${3:-ubuntu}"
KNOWN="$(mktemp)"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)
on_host() { ssh "${SSH_OPTS[@]}" "$USER_NAME@$HOST" "$@"; }

fails=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; fails=$((fails + 1)); }
reachable() { curl -s -m 5 -o /dev/null "$1"; }
# Even if a step fails: never leave the deliberately public demo container running.
cleanup() {
  on_host 'sudo docker rm -f sgs-demo-default sgs-demo-public sgs-demo-net >/dev/null 2>&1
    sudo docker network rm sgs-demo-net >/dev/null 2>&1' >/dev/null 2>&1
  rm -f "$KNOWN"
}
trap cleanup EXIT

# "Not reachable" only means something if the machine is reachable at all.
echo "== Reaching the machine"
on_host true || { fail "can't log in as $USER_NAME@$HOST with $KEY, so nothing below would mean anything"; exit 1; }
pass "SSH with the key works, so the machine is reachable from here"

echo "== Jupyter"
reachable "http://$HOST:8888/api" && fail "JupyterLab answers directly on $HOST:8888" \
                                  || pass "JupyterLab is not reachable directly on $HOST:8888"
# The tunnel goes to Jupyter's Unix socket, which only its user can open.
ssh "${SSH_OPTS[@]}" -N -L 18888:"/run/sgs-jupyter/$USER_NAME/jupyter.sock" "$USER_NAME@$HOST" &
tunnel=$!
sleep 3
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://localhost:18888/api)
kill "$tunnel" 2>/dev/null
[ "$code" = 200 ] && pass "JupyterLab works through an SSH tunnel" || fail "JupyterLab not reachable through the tunnel (HTTP $code)"
# Another account on the machine (a compromised service) tries the socket and
# the usual localhost port.
other=$(on_host 'sudo -n true 2>/dev/null || { echo nosudo; exit 0; }
  s=$(sudo -n -u nobody curl -s -o /dev/null -m 3 -w %{http_code} --unix-socket "/run/sgs-jupyter/$(id -un)/jupyter.sock" http://localhost/api)
  p=$(sudo -n -u nobody curl -s -o /dev/null -m 3 -w %{http_code} http://127.0.0.1:8888/api)
  echo "socket:$s port:$p"')
case "$other" in
  "socket:000 port:000") pass "another account on the machine (nobody) can't reach JupyterLab at all" ;;
  nosudo) fail "couldn't test Jupyter as another account: sudo needs a password" ;;
  *) fail "another account on the machine (nobody) reaches JupyterLab (HTTP codes: ${other:-no output})" ;;
esac

echo "== SSH"
# Ask the server which login methods it offers, without trying any.
methods=$(ssh -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
            -o BatchMode=yes -o PreferredAuthentications=none "$USER_NAME@$HOST" true 2>&1 \
          | sed -nE 's/.*Permission denied \(([^)]*)\).*/\1/p' | head -1)
case ",$methods," in
  ,,) fail "couldn't read which login methods the server offers" ;;
  *,password,*|*,keyboard-interactive,*) fail "the server offers password logins ($methods)" ;;
  *) pass "the server only offers key logins ($methods)" ;;
esac
# From outside, a refused key looks the same as a disabled root account, so ask
# sshd for its effective setting.
root=$(on_host 'sudo sshd -T 2>/dev/null | awk "\$1 == \"permitrootlogin\" { print \$2 }"')
[ "$root" = no ] && pass "root can't log in over SSH (PermitRootLogin no)" \
                 || fail "root login over SSH is allowed (PermitRootLogin ${root:-unknown})"

echo "== Docker-published ports"
# sgs-demo-net is a network of its own, like the one docker compose creates
# per project: Docker's "ip" setting doesn't cover those.
on_host 'sudo docker rm -f sgs-demo-default sgs-demo-public sgs-demo-net >/dev/null 2>&1
  sudo docker network rm sgs-demo-net >/dev/null 2>&1
  sudo docker network create sgs-demo-net >/dev/null &&
  sudo docker run -d --name sgs-demo-default -p 8080:8080 busybox httpd -f -p 8080 >/dev/null &&
  sudo docker run -d --name sgs-demo-public -p 0.0.0.0:8081:8080 busybox httpd -f -p 8080 >/dev/null &&
  sudo docker run -d --name sgs-demo-net --network sgs-demo-net -p 8082:8080 busybox httpd -f -p 8080 >/dev/null' \
  || { fail "couldn't start the demo containers"; exit 1; }
sleep 2
# The deliberately public container is the positive control: if even it can't
# be reached (an outer firewall in the way), the other two prove nothing.
if reachable "http://$HOST:8081/"; then
  echo "  [NOTE] 'docker run -p 0.0.0.0:8081:8080' IS reachable, even with the firewall on:"
  echo "         Docker writes its own firewall rules. That's why the default matters."
  reachable "http://$HOST:8080/" && fail "'docker run -p 8080:8080' is open to the network" \
                                 || pass "'docker run -p 8080:8080' stays on localhost by default"
  reachable "http://$HOST:8082/" && fail "a port published on its own Docker network (as docker compose does) is open to the network" \
                                 || pass "a port published on its own Docker network (as docker compose does) stays on localhost"
else
  echo "  [SKIP] even 'docker run -p 0.0.0.0:8081:8080' isn't reachable from here (an outer"
  echo "         firewall blocks it), so this can't show what the stack's defaults block"
fi

echo "== A compromised service account on the machine"
# A service account (nobody, www-data, a model server's own user) shouldn't
# reach the NVIDIA kernel driver, whose bugs NVIDIA's bulletins patch often.
# It keeps trying to open every GPU device file, to read, write or both,
# while an admin runs `sudo nvidia-smi`: root's GPU use recreates the files,
# and an attacker that retries can catch any moment they're open.
gpu=$(on_host 'bash -s' <<'REMOTE'
[ -c /dev/nvidiactl ] || { echo nodriver; exit 0; }
sudo -n true 2>/dev/null || { echo nosudo; exit 0; }
t=$(mktemp); chmod 0644 "$t"
cat > "$t" <<'PY'
import glob, os, stat, sys, time
devs = [d for d in glob.glob("/dev/nvidia*") if stat.S_ISCHR(os.stat(d).st_mode)]
end, tries = time.time() + 4, 0
while time.time() < end:
    for d in devs:
        for flags in (os.O_RDONLY, os.O_WRONLY, os.O_RDWR):
            tries += 1
            try:
                os.close(os.open(d, flags))
                print("opened", d, "after", tries, "tries"); sys.exit(0)
            except OSError:
                pass
print("checked", len(devs), "files,", tries, "tries")
PY
sudo -n -u nobody /usr/bin/python3 -I "$t" & pid=$!
sleep 0.5
for i in 1 2 3 4 5; do sudo -n nvidia-smi -L >/dev/null 2>&1; done
wait $pid; rm -f "$t"
REMOTE
)
case "$gpu" in
  nodriver) echo "  [SKIP] no NVIDIA device files on this machine" ;;
  nosudo) fail "couldn't test the GPU as a service account: sudo needs a password" ;;
  checked*) pass "a service account (nobody) couldn't open any GPU device file while root used the GPU (${gpu#checked })" ;;
  opened*) fail "a service account (nobody) ${gpu}" ;;
  *) fail "couldn't test the GPU as a service account: ${gpu:-no output}" ;;
esac

echo
[ "$fails" -eq 0 ] && echo "== Nothing reachable that shouldn't be" || echo "== $fails check(s) failed"
[ "$fails" -eq 0 ]
