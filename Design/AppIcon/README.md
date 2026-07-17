# ForgeFit app icon — the Anvil-F

Source layers for the iOS 26 Liquid Glass app icon. The mark fuses the two
brand ideas into one silhouette: an anvil (face + right-facing horn + flared
footing) whose concave throat extends downward as the letter F's single
vertical stem. Sage duotone (`#3ADFA0 → #3F9A63`) on the slate obsidian
canvas — replaces the legacy purple icon.

## Files

- `background.svg` — slate gradient background layer (flat).
- `mark.svg` — the Anvil-F on a transparent canvas (flat, brand gradient).
- `preview.svg` — reference render approximating the glass look. Never ship
  it: baked gloss fights the system's live rendering and breaks the tinted /
  clear appearance modes.

## Building the .icon in Icon Composer

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
