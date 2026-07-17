# Yoga Pose Visuals (Indemnified AI Illustrations)

**Date:** 2026-07-07
**Status:** Approved
**Approach:** 2 — Adobe Firefly (indemnified) + human curation, tintable flat line-art

## Goal

Give every pose in the bundled `yoga_poses.json` catalog (51 slugs) a clean,
on-brand visual so users can imitate the shape during a guided class —
replacing today's SF Symbol stand-ins — without introducing copyright risk.

## Context

`YogaPoseArt` (`ForgeFit/Exercises/ExerciseCatalog.swift:320`) already
implements a three-tier fallback:

1. **Photo slot** `yoga_pose_<slug>` — rendered as-is in original colors.
2. **Template slot** `yoga_<slug>` — tintable line-art that takes the theme accent.
3. **SF Symbol** — the catalog's `symbol` field, the current placeholder.

Slugs are stored with dashes (e.g. `mountain-pose`); both asset lookups replace
dashes with underscores, so `mountain-pose` resolves to `yoga_mountain_pose`.
The infrastructure is fully built — this spec is about *sourcing* assets, not
wiring up new rendering.

The catalog (`YogaPoseCatalog.swift`) already notes "names and sequences aren't
copyrightable; the cue scripts and illustrations are ours." Yoga asanas and
sequences are functional movements, excluded from copyright (Bikram 9th Cir.
2015; US Copyright Office). What *is* protectable is a specific illustration's
creative expression. So the task is: obtain illustration *expression* with
clear rights, via an indemnified generator.

The repo already has an attribution convention —
`docs/exercise-image-attribution.md` documents the `free-exercise-db` thumbnail
provenance, and `ForgeFit/scripts/build_exercise_thumbnails.js` rebuilds them.
This spec extends that pattern to yoga pose art.

## Non-Goals

- **Motion/video.** Static illustrations only. Motion (instructor video) is a
  deliberate, separately-scoped Phase 2 if the static set proves the feature's
  value. The guided player, flow builder, and row UI already render static art.
- **watchOS visuals.** The watch `YogaPoseArt` branch (`#else`, no UIKit) uses
  SF Symbols; pose art on a tiny screen is low-value. Out of scope.
- **Per-asset license manifest.** Provenance is captured at the doc level in
  `exercise-image-attribution.md` (one indemnified source, one date). A
  per-slug JSON manifest is gold-plating for this approach; revisit only if a
  second source is ever introduced and finer auditability is needed.
- **Server-side asset delivery.** Assets are bundled in the app binary.
- **Realistic photos.** Chosen style is tintable flat line-art (see Decision 1).

## Design

### 1. Source: Adobe Firefly (indemnified)

Generate illustrations with Adobe Firefly, which is trained on Adobe Stock,
public-domain, and licensed content, and carries Adobe's commercial IP
indemnification for Firefly outputs. This is the lowest-risk generative option
available and keeps cost negligible (a subscription) with no per-asset
licensing overhead.

A human reviews every output for anatomical accuracy before it ships (Section 4).

### 2. Asset style: tintable flat line-art (template slot)

Single-color flat silhouettes, ingested via the **template slot** `yoga_<slug>`
so they tint to the theme accent automatically via `YogaPoseArt`'s
`templateAsset(for:)` path.

- One illustration style works across every theme (no light/dark variants).
- Smallest app size; consistent across all 51 poses; matches the original
  "dedicated line-art" design intent recorded in `YogaPoseCatalog.swift`.
- Cheapest to keep stylistically consistent across 51 generations.

### 3. Sourcing workflow (per pose)

Repeatable loop, run per slug until the reviewer signs off:

1. Pull the pose's reference fields from `yoga_poses.json`: `name`,
   `sanskrit`, `cues.entry`, `symbol` (current SF Symbol stand-in).
2. Firefly prompt using a **locked style prefix** — e.g.
   *"minimalist single-color flat yoga illustration, clean silhouette,
   transparent background, front-facing, no text, no props"* — plus the
   pose's English name (and Sanskrit as a hint).
3. Generate ~4 variants; pick the most anatomically correct.
4. **Human review** (someone who knows the pose): verify joint angles, spine,
   limb placement, and that the silhouette reads as the target asana. Accept
   or regenerate with refinements.
5. Post-process: ensure a transparent background, export as transparent PNG at
   ≥2x the largest render size (rows use 30–46pt; the guided player is larger —
   author at 256pt or vectorize to PDF for crispness).
6. Ingest as `yoga_<slug-with-underscores>` in `ForgeFit/Assets.xcassets`.

### 4. Quality gate & human sign-off

A pose illustration ships only after human anatomical review. The reviewer need
not be a certified teacher — just someone who can recognize correct alignment
for each asana. The acceptance bar: a user familiar with the pose can identify
it from the silhouette and imitate it without being misled into poor alignment.

### 5. Asset pipeline & naming (no code change)

- **Format:** transparent PNG (or PDF vector if vectorized). Template rendering.
- **Naming:** `yoga_<slug>` with dashes → underscores, matching
  `templateAsset(for:)` (`ExerciseCatalog.swift:369`).
  Examples: `mountain-pose` → `yoga_mountain_pose`; `warrior-i` → `yoga_warrior_i`;
  `downward-facing-dog` → `yoga_downward_facing_dog`.
- **Location:** `ForgeFit/Assets.xcassets`, one imageset per pose.
- **No `YogaPoseArt` changes.** The fallback chain already prefers photo →
  template → SF Symbol; dropping assets into the template slot is sufficient.

### 6. Provenance & attribution

Extend `docs/exercise-image-attribution.md` with a **Yoga Pose Art** section
recording: source (Adobe Firefly), indemnification basis (Adobe's commercial
Firefly indemnification), generation date range, and reviewer. This matches the
existing attribution convention and is the copyright-evidence trail.

### 7. Validation test (hard coverage, all 51)

Add `ForgeFitTests/YogaPoseArtAssetTests.swift`. It decodes `yoga_poses.json`,
and for **every** slug asserts that `UIImage(named: "yoga_<slug>")` is non-nil
in the app bundle.

- **Hard gate, not incremental:** the test passes only when all 51 poses have
  ingested art. This enforces the chosen product bar — ship the complete,
  consistent set, not a mixed batch of illustrations + SF Symbols.
- During the build-out the test is red by design; it is the forcing function to
  complete the set before release. If CI noise on unrelated PRs becomes a
  problem during the weeks of generation, the test can be temporarily gated
  behind an env flag or `XCTSkipUnless` until the set is complete — flip the
  single line when ready. This is an operational convenience, not a relaxation
  of the shipping bar.

### 8. Rollout

No migration, no feature flag, no server. Approved assets appear automatically
in exercise rows, the flow builder, and the guided player on the next build.
Track progress as "x/51 ingested" against this spec; release the visual set
when the validation test goes green.

## Decisions

1. **Style:** tintable flat line-art via the `yoga_<slug>` template slot (not
   realistic photos). Chosen for themeability, consistency, size, and lowest
   generation cost.
2. **Source:** Adobe Firefly with human review. Chosen for indemnification
   (lowest copyright risk at negligible cost) and speed.
3. **Coverage gate:** hard — all 51 slugs must have art before the set ships.
   Chosen to avoid an inconsistent mix of illustration + SF Symbol visuals.
4. **Scope:** static illustrations now; motion deferred to a separate Phase 2.

## Open Items

- Confirm the reviewer (who signs off anatomy) and whether external review is
  budgeted. Does not block the spec; blockable at generation time.
- Vectorize-to-PDF vs high-res PNG: decide per pose during post-processing.
  PDF preferred for crispness at the guided player's larger render size; PNG is
  the fallback if vectorization isn't worth the step for a given silhouette.
