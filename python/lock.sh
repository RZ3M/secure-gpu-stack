#!/usr/bin/env bash
# Regenerate the hash-locked requirement files for both CPU architectures.
#
# Maintainer tool: needs uv (https://docs.astral.sh/uv/). It only resolves
# versions and records hashes; it installs nothing. The installer itself uses
# plain pip with --require-hashes, so end users never need uv.
set -euo pipefail
cd "$(dirname "$0")"

# requirements.in -> lock-<arch>.txt (the ML stack)
# tools.in        -> tools-lock-<arch>.txt (pip-audit, modelscan)
# tf-cuda12.in    -> tf-cuda12-lock-<arch>.txt (TensorFlow's CUDA 12 libraries)
for arch in x86_64 aarch64; do
  for set in requirements:lock tools:tools-lock tf-cuda12:tf-cuda12-lock; do
    uv pip compile "${set%%:*}.in" \
      --python-version 3.12 \
      --python-platform "${arch}-manylinux_2_28" \
      --index-url https://pypi.org/simple \
      --generate-hashes \
      --emit-index-url \
      --quiet \
      --output-file "${set##*:}-${arch}.txt"
  done
done
