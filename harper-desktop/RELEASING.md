# Releasing Harper Desktop for macOS

Added in this fork (taehee-pd/harperSwift).

This fork numbers its own releases (starting at 1.0.0) and updates from its own GitHub releases, not from writewithharper.com. Official Harper releases are signed with a different key, so the app never installs them.

## How updates work

- `src-tauri/tauri.conf.json` sets the app `version`, the updater's public key, and the endpoint `https://github.com/taehee-pd/harperSwift/releases/latest/download/latest.json`.
- Each release carries `latest.json`, the update archive (`Harper_<version>_aarch64.app.tar.gz`) and its signature. The app installs an update only when the archive's signature matches the public key.
- Settings shows the latest version from the same `latest.json`.

## The updater key

The private key lives outside the repository at `~/.tauri/harperswift-updater.key`; its public half is in `tauri.conf.json`. Keep a backup of it. Without it, existing installs can no longer be updated, and a new key needs a manual reinstall.

Never commit the private key.

## Developer ID signing and notarization

Releases are signed with a Developer ID and notarized by Apple, so macOS opens them without warnings and keeps Harper's Accessibility permission across updates. (macOS ties that permission to the signing team. Releases up to 1.2.0 were signed ad hoc, which changes with every build, so each update lost the permission.)

One-time setup, which needs a paid Apple Developer Program membership:

1. **Certificate.** In Xcode, open Settings → Accounts, select the team, choose Manage Certificates, and add a **Developer ID Application** certificate. Only the team's Account Holder can create one. Check it with `security find-identity -v -p codesigning`.
2. **Notarization key.** In App Store Connect, open Users and Access → Integrations → Team Keys and create a key with the Developer role. Download the `.p8` file (Apple offers it only once), and note the key ID and the issuer ID shown on that page. The browser saves the file to Downloads; move it:

   ```sh
   mkdir -p ~/.tauri
   mv ~/Downloads/AuthKey_*.p8 ~/.tauri/
   chmod 600 ~/.tauri/AuthKey_*.p8
   ```
3. **Settings file.** Create `~/.tauri/harperswift-notary.env`:

   ```sh
   APPLE_API_KEY=<key ID>
   APPLE_API_ISSUER=<issuer ID>
   APPLE_API_KEY_PATH=$HOME/.tauri/AuthKey_<key ID>.p8
   ```

Keep the `.p8` file and the certificate's private key out of the repository, like the updater key. If the keychain holds more than one Developer ID Application certificate (after a renewal, both have the same name), set `APPLE_SIGNING_IDENTITY` to the 40-character hash that `security find-identity -v -p codesigning` shows for the one to use.

## Release steps

1. Raise `version` in `src-tauri/tauri.conf.json` above the last release, and merge it into `master`.
2. From `master`, run:

   ```sh
   harper-desktop/scripts/release-macos.sh
   ```

   It builds the app with the hardened runtime, signs it with your Developer ID, has Apple notarize it, and staples the ticket. It then signs and notarizes the dmg, checks both with Gatekeeper (`spctl`), signs the update archive with your updater key, and writes everything, including `latest.json`, to `src-tauri/target/aarch64-apple-darwin/release/bundle/release/`. Notarization usually takes a few minutes. The script stops if signing or any check fails.

   The macOS app has no web UI: Settings, the first-run setup and the editor are SwiftUI windows, and `src-tauri/tauri.macos.conf.json` embeds a placeholder page instead of the Svelte app. The script therefore skips harper.js, the wasm build and the other web packages.
3. Create the GitHub release with the tag `v<version>` on that commit and upload all four files.

## Opening a downloaded build

Signed releases open normally after download.

Releases up to 1.2.0 were signed ad hoc, so macOS blocks them after download. To open one, drag Harper to Applications and run `xattr -dr com.apple.quarantine /Applications/Harper.app`, or open Harper once and choose Open Anyway in System Settings → Privacy & Security.

The first update from an ad hoc release to a signed one loses the Accessibility permission one last time. From 1.2.1, Harper notices at launch, opens Settings to say so, and starts checking as soon as access is back: in System Settings → Privacy & Security → Accessibility, turn Harper off and on again (or remove it and add it again). Say so in that release's notes.
