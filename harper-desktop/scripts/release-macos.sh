#!/usr/bin/env bash
# Added in this fork (taehee-pd/harperSwift).
#
# Builds a release of Harper Desktop for Apple Silicon Macs: the app and dmg signed with a
# Developer ID and notarized by Apple, plus the signed update archive and the `latest.json`
# manifest the in-app updater reads from this fork's GitHub releases. See RELEASING.md.
#
# A Developer ID signature keeps Harper's Accessibility permission across updates: macOS ties the
# permission to the signing team, while an ad hoc signature changes with every build.
#
# The macOS app has no web UI (`src-tauri/tauri.macos.conf.json`), so harper.js, the wasm build
# and the other web packages are not needed.
#
# Environment:
#   TAURI_SIGNING_PRIVATE_KEY_PATH      Updater key (default ~/.tauri/harperswift-updater.key)
#   TAURI_SIGNING_PRIVATE_KEY_PASSWORD  Its password (default: none)
#   APPLE_SIGNING_IDENTITY              Code signing identity (default: the first "Developer ID
#                                       Application" certificate in the keychain)
#   HARPER_NOTARY_ENV                   File that sets APPLE_API_KEY, APPLE_API_ISSUER and
#                                       APPLE_API_KEY_PATH for notarization (default
#                                       ~/.tauri/harperswift-notary.env)

set -euo pipefail

REPO="taehee-pd/harperSwift"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DESKTOP="$ROOT/harper-desktop"
KEY="${TAURI_SIGNING_PRIVATE_KEY_PATH:-$HOME/.tauri/harperswift-updater.key}"

if [ ! -f "$KEY" ]; then
  echo "Missing the updater signing key at $KEY (see RELEASING.md)." >&2
  exit 1
fi

IDENTITY="${APPLE_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning |
  sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application certificate in the keychain (see RELEASING.md)." >&2
  exit 1
fi

NOTARY_ENV="${HARPER_NOTARY_ENV:-$HOME/.tauri/harperswift-notary.env}"
if [ -f "$NOTARY_ENV" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$NOTARY_ENV"
  set +a
fi
for name in APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH; do
  if [ -z "${!name:-}" ]; then
    echo "Missing $name for notarization; set it in $NOTARY_ENV (see RELEASING.md)." >&2
    exit 1
  fi
done
if [ ! -f "$APPLE_API_KEY_PATH" ]; then
  echo "Missing the App Store Connect API key at $APPLE_API_KEY_PATH (see RELEASING.md)." >&2
  exit 1
fi

VERSION="$(node -p "require('$DESKTOP/src-tauri/tauri.conf.json').version")"
TAG="v$VERSION"
echo "Building Harper $VERSION, signed by $IDENTITY"

cd "$DESKTOP"
# For the Tauri CLI.
pnpm install
# Runs actool with stdin open so it can compile icons/icon.icon (see the script).
export PATH="$DESKTOP/scripts/actool-shim:$PATH"
TAURI_SIGNING_PRIVATE_KEY="$(cat "$KEY")"
export TAURI_SIGNING_PRIVATE_KEY
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
# With APPLE_API_* set, Tauri notarizes the app and staples the ticket before it makes the dmg
# and the update archive.
CONFIG="$(IDENTITY="$IDENTITY" node -p 'JSON.stringify({bundle: {createUpdaterArtifacts: true,
  macOS: {signingIdentity: process.env.IDENTITY, hardenedRuntime: true}}})')"
pnpm tauri build -b app,dmg --target aarch64-apple-darwin --config "$CONFIG"

BUNDLE="$DESKTOP/src-tauri/target/aarch64-apple-darwin/release/bundle"
APP="$BUNDLE/macos/Harper.app"
DMG="$BUNDLE/dmg/Harper_${VERSION}_aarch64.dmg"

# The dmg is what people download, so it is signed and notarized too.
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" \
  --issuer "$APPLE_API_ISSUER" --wait
xcrun stapler staple "$DMG"

# Stop here rather than publish something Gatekeeper would block.
codesign --verify --deep --strict "$APP"
spctl --assess --type execute "$APP"
xcrun stapler validate "$APP"
spctl --assess --type open --context context:primary-signature "$DMG"
xcrun stapler validate "$DMG"
UNPACKED="$(mktemp -d)"
tar -xzf "$BUNDLE/macos/Harper.app.tar.gz" -C "$UNPACKED"
xcrun stapler validate "$UNPACKED/Harper.app"
rm -rf "$UNPACKED"

OUT="$BUNDLE/release"
ARCHIVE="Harper_${VERSION}_aarch64.app.tar.gz"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$DMG" "$OUT/"
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
