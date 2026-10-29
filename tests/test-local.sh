#!/usr/bin/env bash
# Install Secure GPU Stack on a fresh local Ubuntu 24.04 VM and audit it.
#
#   tests/test-local.sh [vm-name]
#
# Needs Multipass (brew install --cask multipass). The first run downloads
# several GB (CUDA toolkit, PyTorch, TensorFlow, JAX), so allow 20–40 minutes.
# A Mac VM has no NVIDIA GPU: the installer checks the driver packages resolve
# but doesn't install them. Everything else is installed for real.
# Results are saved in tests/results/<vm-name>-*.txt.
set -euo pipefail

VM="${1:-sgs-test}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tests/results"
mkdir -p "$OUT"

if ! multipass info "$VM" >/dev/null 2>&1; then
  echo "==> Launching $VM"
  multipass launch 24.04 --name "$VM" --cpus 4 --memory 6G --disk 60G --timeout 900
fi

echo "==> Copying the installer to $VM"
tarball="$(mktemp -d)/sgs.tar.gz"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$ROOT" -czf "$tarball" install.sh bin files python
multipass transfer "$tarball" "$VM:/home/ubuntu/sgs.tar.gz"
multipass exec "$VM" -- bash -c 'rm -rf ~/sgs && mkdir ~/sgs && tar -xzf ~/sgs.tar.gz -C ~/sgs'

echo "==> Running the installer (log: $OUT/$VM-install.txt)"
multipass exec "$VM" -- sudo /home/ubuntu/sgs/install.sh 2>&1 | tee "$OUT/$VM-install.txt"

echo "==> Running sgs-check (saved: $OUT/$VM-check.txt)"
multipass exec "$VM" -- sudo sgs-check 2>&1 | tee "$OUT/$VM-check.txt" || true
