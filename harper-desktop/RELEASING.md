# Releasing Harper Desktop for macOS

Added in this fork (taehee-pd/harperSwift).

This fork numbers its own releases (starting at 1.0.0) and updates from its own GitHub releases, not from writewithharper.com. Official Harper releases are signed with a different key, so the app never installs them.

## How updates work

- `src-tauri/tauri.conf.json` sets the app `version`, the updater's public key, and the endpoint `https://github.com/taehee-pd/harperSwift/releases/latest/download/latest.json`.
- Each release carries `latest.json`, the update archive (`Harper_<version>_aarch64.app.tar.gz`) and its signature. The app installs an update only when the archive's signature matches the public key.
- Settings shows the latest version from the same `latest.json`.

## The signing key

The private key lives outside the repository at `~/.tauri/harperswift-updater.key`; its public half is in `tauri.conf.json`. Keep a backup of it. Without it, existing installs can no longer be updated, and a new key needs a manual reinstall.

Never commit the private key.

## Release steps

1. Raise `version` in `src-tauri/tauri.conf.json` above the last release, and merge it into `master`.
2. From `master`, run:

   ```sh
   harper-desktop/scripts/release-macos.sh
   ```

   It builds the app and dmg (signed ad hoc), signs the update archive with your key, and writes everything, including `latest.json`, to `src-tauri/target/aarch64-apple-darwin/release/bundle/release/`.

   The macOS app has no web UI: Settings, the first-run setup and the editor are SwiftUI windows, and `src-tauri/tauri.macos.conf.json` embeds a placeholder page instead of the Svelte app. The script therefore skips harper.js, the wasm build and the other web packages.
3. Create the GitHub release with the tag `v<version>` on that commit and upload all four files.

## Opening a downloaded build

Releases are signed ad hoc, not with an Apple Developer ID, so macOS blocks them after download. To open one:

- Drag Harper to Applications, then run `xattr -dr com.apple.quarantine /Applications/Harper.app`, or
- Try to open Harper once, then choose Open Anyway in System Settings → Privacy & Security.
