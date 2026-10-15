# HarperPopup (macOS)

Added in this fork (taehee-pd/harperSwift). A SwiftUI replacement for the egui suggestion popup in the Harper Desktop highlighter, used on macOS only. Windows and Linux keep the egui popup.

This fork builds Harper Desktop for Apple Silicon Macs only. Intel and universal macOS builds stop with an error in `build_swift.rs`, and `just build-desktop-macos` builds for `aarch64-apple-darwin`.

## Build

Nothing to do by hand. `src-tauri/build.rs` calls `build_swift.rs`, which runs `swift build` for `arm64-apple-macosx13.0` and links the static library `libHarperPopup.a` plus the Swift runtime. `pnpm tauri dev`, `pnpm tauri build` and plain `cargo build` all go through it. Requirements: Xcode or the Xcode command line tools.

## Test

```sh
swift test --package-path harper-desktop/macos-popup   # placement, coordinates, payload, action codes
cd harper-desktop/src-tauri && cargo test native_popup  # Rust side: action mapping, show/update/hide, clicks
```

`Tests/HarperPopupTests/Fixtures/popup.json` is read by both test suites, so the JSON format cannot drift between Rust and Swift.

## How it works

| Direction | Call | Notes |
|---|---|---|
| Rust to Swift | `harper_popup_show(json)` | New lint: fade and scale in from the word (or swap in place if already open), VoiceOver announcement |
| Rust to Swift | `harper_popup_update(json)` | Same lint moved or changed: re-measure and re-place |
| Rust to Swift | `harper_popup_hide()` | Fade and scale back toward the word; a `show` during the fade reverses it |
| Rust to Swift | `harper_popup_contains_point(x, y)` | Lets Rust ignore clicks that land on the popup |
| Swift to Rust | action callback `(popup_id, kind, index)` | Close, ApplySuggestion(index), IgnoreLint, AddToDictionary, DisableRule |

- Rust (`src-tauri/src/highlighter/native_popup/`) owns all state. Each frame it runs queued actions through `RenderState::apply_card_action` (shared with the egui card), handles clicks, then mirrors `RenderState`'s highlighted lint into the panel.
- Actions carry the popup id. Rust drops actions whose id or content no longer matches.
- The popup is an `NSPanel` with `.nonactivatingPanel` that can never become key, so the edited app keeps focus.
- The underline overlay stays click-through on macOS. Rust compares the system mouse-down counters each frame: a left click on an underline opens the popup; any other click outside the popup closes it.
- The popup also closes when the text under it changes (typing) or another app becomes active.

## Clarity (Apple Intelligence)

`Sources/HarperPopup/Clarity/` checks sentences with Apple's on-device model for the Clarity suggestions (`src-tauri/src/clarity/`). Rust decides what to check and when; Swift runs one request at a time.

| Direction | Call | Notes |
|---|---|---|
| Rust to Swift | `harper_clarity_availability()` | Code: 0 available, 1 Low Power Mode, 2 battery below 20%, 3 device not eligible, 4 Apple Intelligence off, 5 model not ready, 6 macOS older than 27 |
| Rust to Swift | `harper_clarity_prewarm()` | Prewarms the session the next request will use |
| Rust to Swift | `harper_clarity_submit(id, sentence)` | Fresh `LanguageModelSession` per request, greedy sampling, guided generation |
| Rust to Swift | `harper_clarity_cancel(id)` | |
| Swift to Rust | result callback `(id, json)` | JSON array of `{original, replacement, reason}`; empty on any failure |

- Uses macOS 27 Foundation Models APIs only, and only `SystemLanguageModel.default`, so text stays on the Mac. On older macOS the availability code is 6 and nothing runs.
- FoundationModels is weak-linked automatically (every reference is gated to macOS 27), so the app still launches on macOS 13.
- `ClarityResult` asks the model to quote the problem phrase before writing fixes. On a 15-sentence sample this cut false alarms on clear sentences from 5 of 5 to 0 of 5, at the cost of catching 6 instead of 10 of 10 wordy sentences.
- Failures (context window, guardrails, cancellation) are logged at debug level under subsystem `com.elijahpotter.harper-desktop`, category `Clarity`, and count as "no issues".

## Coordinates

Accessibility rects use global coordinates with the origin at the top-left of the primary display (y down). AppKit uses the bottom-left of the primary display (y up). `PopupGeometry.appKitRect` flips y with the primary display height, which works for every monitor, including monitors above or left of the main one. Both systems use points, so scale factors do not matter. Placement uses the `visibleFrame` of the screen that shows the word.

## Design

- Background: Liquid Glass (`NSGlassEffectView`, corner radius 16) on macOS 26 and later, the `.popover` material with a hairline border (radius 12) before. Builds with Xcode older than 26 always use the material.
- Suggestions show the text as it will read after the change: a replacement shows the new text, an insertion shows the word with its addition ("However,"), a removal shows the word struck through. The tooltip and VoiceOver label keep the full description.
- The first suggestion is filled with the system accent color, like a default button. The lint kind color appears only as the dot next to the kind name, matching the underline.
- Harper quotes words in code spans; the popup shows them in bold instead of a monospaced font.
- With Reduce Motion on, only the fades run.
