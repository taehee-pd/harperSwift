# Icons

Added in this fork (taehee-pd/harperSwift).

| File | Used for | Source |
|---|---|---|
| `icon.icon` | macOS 26 and later: Liquid Glass icon with light, dark, tinted and clear variants. Tauri compiles it into `Assets.car` and sets `CFBundleIconName`. | Icon Composer document. Edit it in Icon Composer. |
| `icon.icns` | macOS 13 to 15, where `Assets.car` icons are not used | Rendered from `icon.icon` (see below) |
| `*.png`, `icon.ico` | Windows and Linux | Upstream, unchanged |
| `menu-bar-icon.png` | Menu bar template icon | Upstream, unchanged |

`icon.icon` keeps the Harper mark (round glasses with raised brows) from `logo.svg`, redrawn with heavier strokes so it reads at small sizes. Its three layers are full-canvas (1024 x 1024) SVGs: `brows`, `frame` (rims, bridge, temple tabs) and `lenses` (translucent glass).

## Re-rendering `icon.icns` after editing `icon.icon`

```sh
ICTOOL="/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICTOOL" icon.icon --export-image --output-file render.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

Place `render.png` at 824 x 824 on a 1024 x 1024 canvas with a soft drop shadow (the pre-macOS 26 icon grid), export the `.iconset` sizes from 16 to 1024, then run `iconutil -c icns`.
