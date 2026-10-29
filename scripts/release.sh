#!/usr/bin/env bash
# Build a release tarball and its SHA256SUMS file in dist/.
#
#   scripts/release.sh
#
# Users (and cloud-init/lambda-user-data.yaml) download the tarball, check it
# against the published SHA-256 and only then run install.sh. That replaces
# Lambda Stack's unverified `wget ... | sh`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^SGS_VERSION="\(.*\)"/\1/p' "$ROOT/install.sh" | head -1)"
[[ "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "Bad SGS_VERSION in install.sh: '$VERSION'" >&2; exit 1; }
NAME="secure-gpu-stack-${VERSION}"
DIST="$ROOT/dist"
STAGE="$(mktemp -d)"

mkdir -p "$DIST" "$STAGE/$NAME/tests"
cp -R "$ROOT"/{install.sh,bin,files,python,docs,README.md} "$STAGE/$NAME/"
cp "$ROOT"/tests/{user-checks.sh,attack-demo.sh} "$STAGE/$NAME/tests/"
# Files are recorded as root's, so extracting as root doesn't hand them to
# whoever has the build machine's uid (1000 is "ubuntu" on Lambda). GNU tar
# (Linux) and bsdtar (macOS) spell that differently.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar_opts=(--owner=0 --group=0 --numeric-owner --no-xattrs)
else
  tar_opts=(--uid 0 --gid 0 --uname root --gname root --no-xattrs --no-mac-metadata)
fi
COPYFILE_DISABLE=1 tar "${tar_opts[@]}" -C "$STAGE" -czf "$DIST/$NAME.tar.gz" "$NAME"
rm -rf "$STAGE"

cd "$DIST"
# A signature from an earlier build would no longer match.
rm -f SHA256SUMS.sig
if command -v sha256sum >/dev/null; then sha256sum "$NAME.tar.gz"; else shasum -a 256 "$NAME.tar.gz"; fi > SHA256SUMS
echo "Built dist/$NAME.tar.gz"
cat SHA256SUMS

# A checksum fetched from the download host only catches corruption: whoever can
# replace the tarball can replace SHA256SUMS too. With SGS_SIGNING_KEY set to an
# SSH ed25519 private key, SHA256SUMS is signed (SHA256SUMS.sig). Publish the
# matching public key somewhere else (the git repository, say) as an
# allowed_signers line: "release@secure-gpu-stack ssh-ed25519 AAAA...". Verify:
#   ssh-keygen -Y verify -f allowed_signers -I release@secure-gpu-stack \
#     -n secure-gpu-stack-release -s SHA256SUMS.sig < SHA256SUMS && shasum -a 256 -c SHA256SUMS
if [ -n "${SGS_SIGNING_KEY:-}" ]; then
  ssh-keygen -Y sign -q -f "$SGS_SIGNING_KEY" -n secure-gpu-stack-release SHA256SUMS
  echo "Signed: dist/SHA256SUMS.sig"
fi
