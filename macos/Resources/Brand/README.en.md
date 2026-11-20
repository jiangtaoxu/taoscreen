# TaoScreen Logo

English · [简体中文](README.md)

The artwork shows overlapping lavender and mint displays and a pointer on an indigo tile. The source PNG is 1254 × 1254 pixels with transparent padding.

- `TaoScreen-logo.png` is the source used for the project logo and app icon.
- [AppIcon.icns](../AppIcon.icns) includes the standard sizes and their 2× equivalents for macOS.
- To rebuild the icon, run `bash scripts/generate-app-icon.sh` from the `macos/` directory.

## Generation prompt

```text
Use case: logo-brand
Asset type: one production-ready TaoScreen remote-desktop macOS app icon and project logo, square 1024 × 1024.
Primary request: a new, recognizable mark for using one Mac to control another. On a dark indigo rounded macOS tile, combine a large ice-lavender display frame with a smaller mint-cyan display frame offset diagonally behind it. An oversized simple mint mouse pointer sits inside the larger screen and gives the composition one clear focal point. Use the minimum number of bold shapes required to communicate remote control. Break or occlude the rear outline cleanly where the frames overlap.
Style: precise front-facing geometry, thick rounded strokes, a restrained indigo-to-navy gradient, and a very subtle inset edge highlight. Calm native macOS utility character and sturdy high contrast. Keep the display glyph flat and the tile gently dimensional.
Composition: the rounded tile occupies about 83–85 percent of the canvas, optically centered, with real transparent space on every side. The mark occupies about 67 percent of the tile and remains legible in a 16- and 32-pixel Dock or Finder preview.
Constraints: single icon asset with actual alpha transparency around the tile. No text, initials, watermark, mockup, white canvas, external drop shadow, fine lines, stand feet, orbit sparkles, Wi-Fi symbols, or background clutter.
```

## Edge cleanup prompt

```text
Polish this exact TaoScreen macOS application icon for production. Preserve its visual design: centered 83–85%-wide indigo-to-navy rounded square with soft highlight contained inside the tile, behind one flat mint-cyan monitor outline and one ice-lavender monitor outline with a mint pointer. Keep the existing proportions, layout and colors. The only requested change is to make the tile silhouette and the surrounding transparent field pristine. The reference has stray faint blue pixels floating above the tile and beside the right edge. Remove every stray pixel. Everything outside the one clean rounded-square silhouette must be completely transparent (zero alpha), with only standard edge antialiasing. No outer glow, texture spill, drop shadow, speckles, islands, detached highlights, white/black background, text or other new marks. Full square canvas, one icon.
```
