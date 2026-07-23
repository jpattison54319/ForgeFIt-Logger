# History-Aware Exercise Replacements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rank biomechanically valid replacement exercises using decayed frequency and recency, with transparent history captions in both live workouts and routine editing.

**Architecture:** ForgeCore owns movement-family inference, usage scoring, and final ranking. A small app adapter derives per-exercise completed-session dates from existing SwiftData history, and the shared replacement sheet maps those results into visible reasons. The broad picker receives replacement-specific title, modality, and exclusion context without becoming a second ranking engine.

**Tech Stack:** Swift 6.2, Swift Testing, ForgeCore, ForgeData, SwiftData, SwiftUI, iOS 26.

## Global Constraints

- Preserve the current same-modality, shared-primary-muscle, not-in-use eligibility rules.
- A known movement-family mismatch is never a valid substitute, regardless of usage.
- No schema, CloudKit, network, or synced-data changes.
- Weights remain in the user's display unit; this feature performs no weight conversion.
- Use fixed reference dates in tests.
- Preserve all pre-existing user edits. `ExerciseSwapSheet.swift` and `ExercisePickerView.swift` are already dirty; do not stage or commit those files automatically.
- Use `TestStore.make()` for every app-target SwiftData test.

---

### Task 1: Normalize movement families

**Files:**
- Create: `Packages/ForgeCore/Sources/ForgeCore/ExerciseMovementFamily.swift`
- Create: `Packages/ForgeCore/Tests/ForgeCoreTests/ExerciseMovementFamilyTests.swift`

**Interfaces:**
- Produces: `public enum ExerciseMovementFamily` with `static func infer(movementPattern:primaryMuscles:) -> ExerciseMovementFamily?`.
- Consumes: `MuscleTaxonomy.canonical(_:)`.

- [ ] **Step 1: Write failing family-inference tests**

Cover lower-body override, precise push/pull patterns, muscle fallbacks, ambiguous shoulders, cardio, underscores, and unknown metadata. The key regression is:

```swift
@Test func lowerBodyMusclesOverrideLegacyPushForce() {
    #expect(ExerciseMovementFamily.infer(
        movementPattern: "push",
        primaryMuscles: ["quadriceps", "glutes"]
    ) == .legs)
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --package-path Packages/ForgeCore --filter ExerciseMovementFamilyTests
```

Expected: compilation failure because `ExerciseMovementFamily` does not exist.

- [ ] **Step 3: Implement the family mapper**

Create a public `String`-backed, `Sendable` enum with cases `push`, `pull`, `legs`, `core`, and `cardio`. Normalize punctuation to spaces, canonicalize muscles through `MuscleTaxonomy`, resolve lower body before generic push/pull, then use exact pattern tokens followed by unambiguous muscle sets. Return `nil` for empty or conflicting upper-body muscle families.

```swift
public enum ExerciseMovementFamily: String, Sendable {
    case push, pull, legs, core, cardio

    public static func infer(
        movementPattern: String?,
        primaryMuscles: [String]
    ) -> ExerciseMovementFamily? {
        // Normalize pattern and canonical muscles, resolve legs first,
        // then exact pattern tokens and unambiguous muscle fallbacks.
    }
}
```

- [ ] **Step 4: Verify GREEN**

Run the focused test command and then:

```bash
swift test --package-path Packages/ForgeCore --filter MuscleTaxonomyTests
```

Expected: both suites pass.

- [ ] **Step 5: Checkpoint without staging user work**

Run `git diff --check -- Packages/ForgeCore/Sources/ForgeCore/ExerciseMovementFamily.swift Packages/ForgeCore/Tests/ForgeCoreTests/ExerciseMovementFamilyTests.swift` and record the passing result.

### Task 2: Add deterministic usage affinity to the swap engine

**Files:**
- Modify: `Packages/ForgeCore/Sources/ForgeCore/ExerciseSwapSuggester.swift`
- Modify: `Packages/ForgeCore/Tests/ForgeCoreTests/ExerciseSwapSuggesterTests.swift`

**Interfaces:**
- Produces: `ExerciseSwapSuggester.UsageProfile(sessionDates: [Date])`.
- Changes: `suggest(... usageByID: [UUID: UsageProfile] = [:], referenceDate: Date = .now, ...)`.
- Adds facets: `.sameMovementFamily(ExerciseMovementFamily)` and `.usage(recentSessionCount:lastUsedAt:)`.

- [ ] **Step 1: Write failing scoring tests**

Use a fixed `2026-07-22` reference date. Add separate tests proving recent frequent use outranks a close unfamiliar exercise, one use scores below repeated use, 180-day-old history fades, future timestamps clamp to today, incompatible known families are excluded, unknown family falls back to primary overlap, and empty history preserves current order.

- [ ] **Step 2: Verify RED**

Run `swift test --package-path Packages/ForgeCore --filter ExerciseSwapSuggesterTests`.

Expected: compilation failures for `UsageProfile`, `usageByID`, and the new facets.

- [ ] **Step 3: Implement usage scoring and family filtering**

For each candidate:

```swift
let recency = 1.2 * pow(2, -daysSinceLastUse / 28)
let weightedUses = dates.reduce(0.0) { total, date in
    total + pow(2, -daysSince(date, referenceDate) / 56)
}
let frequency = 1.4 * (1 - exp(-weightedUses / 3))
score += recency + frequency
```

Use elapsed days clamped to zero. Add `sameMovementFamily` scoring after the hard mismatch check. Retain exact movement-pattern scoring. Skip the force bonus when normalized target and candidate `force` values merely duplicate their normalized movement patterns. Remove the old trained Boolean quality-band reorder; sort by final score then name. Emit one usage facet containing the count within 90 elapsed days and most recent date.

- [ ] **Step 4: Verify GREEN and regressions**

Run the focused suite, then all ForgeCore tests:

```bash
swift test --package-path Packages/ForgeCore
```

Expected: all tests pass, including the original equipment-preference cases.

- [ ] **Step 5: Checkpoint diff**

Run `git diff --check` on the two modified files and inspect the score changes line by line.

### Task 3: Derive honest usage profiles from SwiftData history

**Files:**
- Create: `ForgeFit/Exercises/ExerciseSwapUsageBuilder.swift`
- Create: `ForgeFitTests/ExerciseSwapUsageBuilderTests.swift`

**Interfaces:**
- Produces: `@MainActor enum ExerciseSwapUsageBuilder { static func profiles(from workouts: [WorkoutModel]) -> [UUID: ExerciseSwapSuggester.UsageProfile] }`.

- [ ] **Step 1: Write failing app tests**

Using `TestStore.make()`, create completed and unfinished strength/cardio workouts. Prove that five completed sets count once, duplicate exercise rows count once per workout, deleted/unfinished workouts do not count, and an ended cardio session counts without strength sets.

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:ForgeFitTests/ExerciseSwapUsageBuilderTests
```

Expected: compilation failure because the builder is missing.

- [ ] **Step 3: Implement the builder**

Filter to ended, nondeleted workouts. Build a per-workout `Set<UUID>` from strength rows with completed sets and session-backed rows whose matching `CardioSessionModel.endedAt` is nonnil. Append the workout's `endedAt` once per exercise ID, then create sorted `UsageProfile` values.

```swift
@MainActor
enum ExerciseSwapUsageBuilder {
    static func profiles(
        from workouts: [WorkoutModel]
    ) -> [UUID: ExerciseSwapSuggester.UsageProfile] {
        // Filter completed workouts, deduplicate IDs within each workout,
        // and return sorted completion dates per exercise.
    }
}
```

- [ ] **Step 4: Verify GREEN**

Repeat the focused app test. Expected: Swift Testing reports all builder tests passed and xcodebuild exits 0.

- [ ] **Step 5: Checkpoint diff**

Run `git diff --check` on the new builder and test files.

### Task 4: Wire ranking and transparent explanations into the shared UI

**Files:**
- Modify: `ForgeFit/Exercises/ExerciseSwapSheet.swift`
- Modify: `ForgeFit/Exercises/ExercisePickerView.swift`
- Modify: `ForgeFitTests/ForgeFitTests.swift` or create a focused presentation test file if a pure formatter is extracted.

**Interfaces:**
- Consumes: `ExerciseSwapUsageBuilder.profiles(from:)`.
- Adds picker inputs with safe defaults: `navigationTitle`, `presetModality`, and `excludedIDs`.

- [ ] **Step 1: Write failing presentation/filter tests**

Extract a small deterministic usage-caption formatter if necessary. Test `Last used today`, `Last used 6d ago`, and `5 sessions in 90d · Last used 6d ago`. Add a picker-filter test proving current and already-in-use IDs are excluded in replacement mode.

- [ ] **Step 2: Verify RED**

Run the focused app-target suites and confirm the new formatter/filter API is missing.

- [ ] **Step 3: Update the sheet**

Replace the local trained-ID scan with the usage builder, capture one `referenceDate` per computation, pass profiles into ForgeCore, and render movement/usage facets after shared muscles. Replace the consequence copy exactly with:

```text
Set structure stays for similar exercises. Unfinished values and exercise-specific targets reset; completed sets remain logged.
```

Keep the visible preference chips, six-row limit, accessibility labels, and `Search all exercises` action.

```swift
let usageByID = ExerciseSwapUsageBuilder.profiles(from: history)
suggestions = ExerciseSwapSuggester.suggest(
    replacing: target,
    from: pool,
    usageByID: usageByID,
    referenceDate: referenceDate,
    excluding: inUseIDs,
    preference: preference
)
```

- [ ] **Step 4: Harden replacement search context**

Give `ExercisePickerView` defaulted `navigationTitle` and `excludedIDs` inputs. Apply exclusions to both filtered and suggested lists. From `ExerciseSwapSheet`, pass `Replace Exercise`, `current.modality`, and `inUseIDs.union([current.id])`. The modality remains user-clearable and a row still commits immediately in single-selection mode.

```swift
ExercisePickerView(
    singleSelection: true,
    presetModality: current.modality,
    excludeYogaPoses: true,
    context: [current],
    history: history,
    navigationTitle: "Replace Exercise",
    excludedIDs: inUseIDs.union([current.id])
) { picked in
    if let first = picked.first { onPick(first) }
}
```

- [ ] **Step 5: Verify GREEN and build**

Run focused app tests, `swift test --package-path Packages/ForgeCore`, `make build-ios`, and `git diff --check` on all touched files.

- [ ] **Step 6: Inspect both rendered entry points**

On iPhone 17 Pro/iOS 26.5, open Replace from a live strength workout and from routine editing. Confirm identical ordering and captions, visible equipment chips, replacement-specific search title, excluded in-use exercises, VoiceOver labels, and readable Dynamic Type. Do not claim visual completion from the build alone.

### Task 5: Final scoped verification

**Files:** No new files.

- [ ] Run all ForgeCore tests.
- [ ] Run `ExerciseSwapUsageBuilderTests` and the focused presentation/filter tests.
- [ ] Run `make build-ios`.
- [ ] Run `git diff --check`.
- [ ] Inspect `git diff` and confirm no schema, privacy, HealthKit, or unrelated user changes entered the implementation diff.
