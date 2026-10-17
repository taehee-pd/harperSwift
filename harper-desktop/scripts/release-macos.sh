#!/usr/bin/env bash
# Added in this fork (taehee-pd/harperSwift).
#
# Builds a release of Harper Desktop for Apple Silicon Macs: the app and dmg signed ad hoc, plus
# the signed update archive and the `latest.json` manifest the in-app updater reads from this
# fork's GitHub releases. See RELEASING.md.
#
# The macOS app has no web UI (`src-tauri/tauri.macos.conf.json`), so harper.js, the wasm build
# and the other web packages are not needed.
#
# Environment:
#   TAURI_SIGNING_PRIVATE_KEY_PATH      Updater key (default ~/.tauri/harperswift-updater.key)
#   TAURI_SIGNING_PRIVATE_KEY_PASSWORD  Its password (default: none)

set -euo pipefail

REPO="taehee-pd/harperSwift"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DESKTOP="$ROOT/harper-desktop"
KEY="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.tauri/harperswift-updater.key}"

if [ ! -f "$KEY" ]; then
  echo "Missing the updater signing key at $KEY (see RELEASING.md)." >&2
  exit 1
fi

VERSION="$(node -p "require('$DESKTOP/src-tauri/tauri.conf.json').version")"
TAG="v$VERSION"
echo "Building Harper $VERSION"

cd "$DESKTOP"
# For the Tauri CLI.
pnpm install
# Runs actool with stdin open so it can compile icons/icon.icon (see the script).
export PATH="$DESKTOP/scripts/actool-shim:$PATH"
TAURI_SIGNING_PRIVATE_KEY="$(cat "$KEY")"
export TAURI_SIGNING_PRIVATE_KEY
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
pnpm tauri build -b app,dmg --target aarch64-apple-darwin \
  --config '{"bundle":{"createUpdaterArtifacts":true,"macOS":{"signingIdentity":"-","hardenedRuntime":false}}}'

BUNDLE="$DESKTOP/src-tauri/target/aarch64-apple-darwin/release/bundle"
OUT="$BUNDLE/release"
ARCHIVE="Harper_${VERSION}_aarch64.app.tar.gz"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BUNDLE/dmg/Harper_${VERSION}_aarch64.dmg" "$OUT/"
cp "$BUNDLE/macos/Harper.app.tar.gz" "$OUT/$ARCHIVE"
cp "$BUNDLE/macos/Harper.app.tar.gz.sig" "$OUT/$ARCHIVE.sig"

VERSION="$VERSION" TAG="$TAG" REPO="$REPO" ARCHIVE="$ARCHIVE" \
  SIGNATURE="$(cat "$OUT/$ARCHIVE.sig")" PUB_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  node -e '
    const env = process.env;
    const manifest = {
      version: env.VERSION,
      notes: `https://github.com/${env.REPO}/releases/tag/${env.TAG}`,
      pub_date: env.PUB_DATE,
      platforms: {
        "darwin-aarch64": {
          signature: env.SIGNATURE,
          url: `https://github.com/${env.REPO}/releases/download/${env.TAG}/${env.ARCHIVE}`,
        },
      },
    };
    process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
  ' > "$OUT/latest.json"

echo "Release files for $TAG are in $OUT:"
ls -1 "$OUT"
