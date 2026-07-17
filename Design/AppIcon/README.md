# ForgeFit app icon — the Anvil-F

Source layers for the iOS 26 Liquid Glass app icon. The mark fuses the two
brand ideas into one silhouette: an anvil (face + right-facing horn + flared
footing) whose concave throat extends downward as the letter F's single
vertical stem. Sage duotone (`#3ADFA0 → #3F9A63`) on the slate obsidian
canvas — replaces the legacy purple icon.

## What's shipping now

The flat renders are **already installed** in the asset catalogs, so builds
show the Anvil-F today — no Icon Composer step required to get off the legacy
purple icon:

- `ForgeFit/Assets.xcassets/AppIcon.appiconset/icon-1024.png` ← `flat-1024.svg`
  (default + dark appearances)
- `.../icon-tinted-1024.png` ← `flat-tinted-1024.svg` (grayscale, system tints it)
- `ForgeFitWatch Watch App/.../icon-1024.png` ← `flat-watch-1024.svg` (mark at
  80% so the horn/foot clear the circular watch mask)

iOS 26's asset-catalog pipeline (`actool`) flattens the icons and applies its
default Liquid Glass treatment to the flat art automatically. To regenerate,
re-rasterize the `flat-*.svg` files to 1024 px PNGs and overwrite those
filenames (the render used `qlmanage -t -s 1024 -o <dir> flat-*.svg`).

## Files

- `flat-1024.svg` / `flat-tinted-1024.svg` / `flat-watch-1024.svg` — the
  full-bleed compositions that are rasterized into the asset catalogs above.
- `background.svg` — slate gradient background layer, for Icon Composer.
- `mark.svg` — the Anvil-F on a transparent canvas, for Icon Composer.
- `preview.svg` — reference render approximating the glass look. Never ship
  it: baked gloss fights the system's live rendering and breaks the tinted /
  clear appearance modes.

Geometry note: the mark is a single compound path using the default nonzero
fill rule. Sub-paths must all wind the same direction — an accidental reversed
sub-path punches a hole (the throat/footing read as cut-outs). If you edit the
path and see holes, the fix is winding, not fill-rule.

## Upgrade path: the layered .icon in Icon Composer

The flat PNGs are the fast, correct baseline. For the full multilayer glass
effect (specular that tracks device tilt, inter-layer depth), build a `.icon`:

1. Open **Icon Composer** (ships with Xcode 26) → New Icon.
2. Set the background from `background.svg`; add `mark.svg` as a layer above.
3. Leave the system glass defaults on for the mark layer (specular on); do
   not add manual shadows or highlights.
4. Check all four appearance modes — Default, Dark, Clear, Tinted — and the
   small-size preview. The throat and horn must stay legible at 29 pt.
5. Save as `AppIcon.icon` into the Xcode project and select it in the
   ForgeFit target's App Icon setting, replacing the legacy asset at
   `ForgeFit/Assets.xcassets/AppIcon.appiconset`.
6. Export the 1024 px marketing PNG from Icon Composer for App Store
   Connect / TestFlight.

The watch app has its own icon asset (`ForgeFitWatch Watch App/
Assets.xcassets/AppIcon.appiconset`) with a circular mask — reuse `mark.svg`
centered at ~80% scale so the horn clears the circle.

Keep this folder as the design source of truth: edit the SVGs, re-import in
Icon Composer, never hand-edit the generated `.icon`.
