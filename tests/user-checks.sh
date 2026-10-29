#!/usr/bin/env bash
# Does the stack work for a normal user, and do its safety defaults hold?
# Run as the machine's normal user (not root), in a login shell:
#
#   bash -l tests/user-checks.sh
#
# Works on a local VM or a real Lambda instance. Prints PASS/FAIL per check.
set -u

fails=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; fails=$((fails + 1)); }
# Run Python quietly: TensorFlow and JAX print hardware warnings on machines
# without a GPU.
py() { "$@" 2>/dev/null; }

echo "== The stack works like Lambda Stack"
[ "$(command -v python3)" = /opt/sgs/venv/bin/python3 ] \
  && pass "python3 is the stack's Python" || fail "python3 is $(command -v python3)"
out=$(py python3 -c 'import torch, tensorflow as tf, jax, keras; print(torch.__version__, tf.__version__, jax.__version__, keras.__version__)')
[ -n "$out" ] && pass "torch, tensorflow, jax, keras import: $out" || fail "framework imports failed"
command -v nvcc >/dev/null && pass "nvcc: $(nvcc --version | grep -o 'release [0-9.]*')" || fail "nvcc not on PATH"
if [ -c /dev/nvidiactl ]; then
  nvidia-smi -L >/dev/null 2>&1 && pass "you can use the GPU (you're in the video group)" \
                                || fail "nvidia-smi fails for you (groups: $(id -nG))"
  open=$(find /dev -maxdepth 1 -name 'nvidia*' -type c -perm /006 | tr '\n' ' ')
  [ -z "$open" ] && pass "the GPU device files aren't open to every local user" \
                 || fail "GPU device files open to every local user: $open"
fi

# A small package that is not part of the stack (the stack already has six, rich, ...).
EXTRA=humanize

echo "== The stack can't be changed by accident"
# Test the permission itself: a failed `pip install` could just mean no network.
site=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
if touch "$site/.sgs-write-test" 2>/dev/null || touch /opt/sgs/venv/bin/.sgs-write-test 2>/dev/null; then
  rm -f "$site/.sgs-write-test" /opt/sgs/venv/bin/.sgs-write-test
  fail "a normal user can change the stack's files"
else
  pass "the stack's packages and commands are read-only for a normal user"
fi

echo "== Users get their own environment on top"
env_dir="$(mktemp -d)/env"
sgs-venv "$env_dir" >/dev/null
"$env_dir/bin/pip" install -q --disable-pip-version-check "$EXTRA" >/dev/null 2>&1
where=$(py "$env_dir/bin/python" -c "import torch, $EXTRA; print(torch.__file__.startswith('/opt/sgs/venv'), $EXTRA.__file__.startswith('$env_dir'))")
[ "$where" = "True True" ] && pass "sgs-venv sees the stack's torch and keeps new packages in its own folder" \
                           || fail "sgs-venv: got '$where'"

echo "== Jupyter is up, on a socket only you can open"
sock="/run/sgs-jupyter/$(id -un)/jupyter.sock"
token=$(cat "$HOME/.local/share/jupyter/sgs-token" 2>/dev/null)
with=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$sock" -H "Authorization: token $token" http://localhost/api/kernels)
without=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$sock" http://localhost/api/kernels)
[ "$with $without" = "200 403" ] && pass "JupyterLab answers on its private socket with its token, and refuses without ($sock)" \
                                 || fail "JupyterLab on $sock: HTTP $with with the token, $without without (want 200, 403)"
code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:8888/api)
[ "$code" = 000 ] && pass "nothing answers on localhost:8888, where any account could reach it" || fail "something answers on 127.0.0.1:8888 (HTTP $code)"
# The address other machines use (the default route's source), not a Docker bridge.
addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }')
if [ -z "$addr" ]; then
  echo "  [SKIP] no default route, so there's no network address to test"
else
  code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://$addr:8888/api")
  [ "$code" = 000 ] && pass "JupyterLab doesn't answer on the network address ($addr)" || fail "JupyterLab answers on $addr (HTTP $code)"
fi

echo "== Malicious model files: flagged by modelscan, refused by torch.load"
work="$(mktemp -d)"
# Model files that run a command when loaded. The payload only creates a file.
# model.pt uses PyTorch's normal torch.save format; model.pkl is a plain pickle.
py python3 - "$work" <<'EOF'
import os, pickle, sys, torch
class Payload:
    def __reduce__(self):
        return (os.system, (f"touch {sys.argv[1]}/pwned",))
torch.save({"weights": Payload()}, f"{sys.argv[1]}/model.pt")
with open(f"{sys.argv[1]}/model.pkl", "wb") as f:
    pickle.dump({"weights": Payload()}, f)
EOF
for f in model.pt model.pkl; do
  if modelscan -p "$work/$f" 2>/dev/null | grep -q 'CRITICAL: [1-9]'; then
    pass "modelscan flags the booby-trapped $f"
  else
    fail "modelscan didn't flag the booby-trapped $f"
  fi
done
# It must be refused for the right reason: an import error would also leave no
# "pwned" file behind.
out=$(python3 -c "import torch, sys; torch.load(sys.argv[1])" "$work/model.pt" 2>&1)
if [ -e "$work/pwned" ]; then
  fail "torch.load ran the model's hidden code"
elif echo "$out" | grep -q "Weights only load failed"; then
  pass "torch.load refuses to run the model's hidden code (weights_only default)"
else
  fail "torch.load failed for another reason: $(echo "$out" | tail -1 | cut -c1-120)"
fi
rm -rf "$work" "$(dirname "$env_dir")"

echo
[ "$fails" -eq 0 ] && echo "== All user checks passed" || echo "== $fails user check(s) failed"
[ "$fails" -eq 0 ]
