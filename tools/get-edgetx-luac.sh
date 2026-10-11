#!/bin/sh
# Download the EdgeTX Lua compiler (edgetx-luac) that tests/check.sh uses for the exact
# EdgeTX syntax check. Source: https://github.com/EdgeTX/edgetx-luac-action (release v1.0.0).
# The SHA-256 sum of the archive is checked against the SHA256SUMS file of the release.
set -eu

VER="v1.0.0"
case "$(uname -s)" in
  Darwin) ASSET="edgetx-luac-$VER-macos-universal.tar.gz" ;;
  Linux)
    case "$(uname -m)" in
      aarch64|arm64) ASSET="edgetx-luac-$VER-linux-arm64.tar.gz" ;;
      *)             ASSET="edgetx-luac-$VER-linux-x64.tar.gz" ;;
    esac ;;
  *) echo "No edgetx-luac build for $(uname -s); see https://github.com/EdgeTX/edgetx-luac-action/releases"; exit 1 ;;
esac
BASE="https://github.com/EdgeTX/edgetx-luac-action/releases/download/$VER"
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/edgetx-luac.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
curl -fsSLO "$BASE/$ASSET"
curl -fsSLO "$BASE/SHA256SUMS"
WANT="$(grep " $ASSET\$" SHA256SUMS | cut -d ' ' -f 1)"
if command -v shasum >/dev/null 2>&1; then
  HAVE="$(shasum -a 256 "$ASSET" | cut -d ' ' -f 1)"
else
  HAVE="$(sha256sum "$ASSET" | cut -d ' ' -f 1)"
fi
if [ -z "$WANT" ] || [ "$WANT" != "$HAVE" ]; then
  echo "Checksum mismatch for $ASSET"
  exit 1
fi
tar xzf "$ASSET"
BIN="$(find . -name edgetx-luac -type f | head -n 1)"
cp "$BIN" "$DIR/edgetx-luac"
chmod +x "$DIR/edgetx-luac"
if [ "$(uname -s)" = "Darwin" ]; then
  xattr -d com.apple.quarantine "$DIR/edgetx-luac" 2>/dev/null || true
fi
echo "Installed $DIR/edgetx-luac"
