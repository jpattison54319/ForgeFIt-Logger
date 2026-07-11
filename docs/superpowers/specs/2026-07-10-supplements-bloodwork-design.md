# Supplements + Bloodwork Tracking — Design

**Date:** 2026-07-10
**Status:** Approved (pending spec review)
**Scope:** Add two independent tracking features — a daily supplement check-off with reminders, and a manual bloodwork panel tracker with built-in biomarker catalog and editable reference ranges.

## Background

ForgeFit is a SwiftUI iOS/watchOS 26 fitness app with SwiftData + CloudKit sync. The app tracks strength workouts, cardio, yoga, bodyweight, recovery, and daily check-ins. A tester suggested supplement and bloodwork tracking; since all data is local (CloudKit private DB), there is no security or legal concern with storing lab results on-device.

The existing patterns this design builds on:

- **SwiftData models** in `Packages/ForgeData/Sources/ForgeData/Models.swift` — 21 `@Model` classes with a consistent shape: `UUID` id, `userID`, `createdAt`/`updatedAt`/`deletedAt`, `@Relationship(deleteRule: .cascade)` for parent→children, enums stored as raw-value Strings, no `@Attribute(.unique)` (CloudKit-incompatible). `DailyCheckinModel` (line 1489) is the closest analog to a daily supplement log; `CardioSessionModel` (line 1029) with its child `CardioSplitModel` rows is the closest analog to a bloodwork panel with child results.
- **Schema registry** — `ForgeDataSchema.models` array (line 6) lists every model for the `ModelContainer`. New models must be added here.
- **Domain logic** in `Packages/ForgeCore/Sources/ForgeCore/` — pure Swift (no SwiftUI/SwiftData). `DistanceUnit.swift` is the template for unit enums: `String, Codable, Sendable, CaseIterable` with display helpers.
- **Deterministic UUID seeding** — `ExerciseCatalog.deterministicID(for slug:)` (line 111) derives a stable UUID from a slug via SHA256, so re-seeding is idempotent and IDs are consistent across installs and CloudKit sync.
- **`@Observable` stores** — e.g. `HealthMetricsStore` (`ForgeFit/Health/HealthMetricsStore.swift`), an `@Observable` singleton holding HealthKit-derived caches, injected via `.environment()`.
- **`@Query` in views** — no separate ViewModel layer; views query SwiftData directly.
- **Design system** (`ForgeFit/DesignSystem/`) — `ScreenScaffold`, `Card`, `PrimaryButton`, `SectionHeader` components; `Fmt` static formatter in `Format.swift`; `MetricPoint` + `TimeChartRange` (4W/12W/1Y/All) in `Charts.swift`.
- **Feature folders** — `ForgeFit/{Home,Workout,Insights,Profile,Settings,Health,Cardio,Yoga}/`.
- **Navigation** — `TabView` with 4 tabs (Home, Workout, Insights, Profile) driven by `AppTab` enum in `ContentView.swift`.

## Goals

1. **Supplement tracking** — a user-maintained library of recurring supplements with dose, unit, frequency, and optional reminders. Each day surfaces the scheduled doses for one-tap check-off. Adherence % is computed against the plan over time.
2. **Bloodwork tracking** — manual entry of lab panel results against a built-in ~25-biomarker catalog with editable reference ranges. Each biomarker shows a time-series chart with the reference range as a shaded band.

## Non-goals (v1)

- **No cross-feature correlation.** Supplements and bloodwork do not reference each other. No "this supplement raised this lab value" inference.
- **No HealthKit integration** for supplements or lab results. Apple's HealthKit support for supplements and lab results is too thin to rely on; manual entry is the source of truth for both features.
- **No OCR / PDF lab import.** Manual entry only.
- **No age/sex-specific reference ranges.** v1 ships flat default ranges, user-editable per biomarker.
- **No automatic unit conversion** (e.g. ng/mL ↔ nmol/L). Each result stores the unit the lab used; the user picks the unit.
- **No supplement inventory/cost/expiration tracking.** A supplement library entry is just name + dose + frequency — not a product catalog.
- **No Watch app or Widget surfaces** for supplements or bloodwork in v1. Both are primarily iPhone activities.
- **No AI interpretation** of bloodwork results. The app shows values, reference ranges, and flags — never diagnoses.

## Architecture decision: two independent features

Supplements and bloodwork are **not** unified under a shared "Health Tracking" abstraction. They get separate feature folders, separate stores, separate models, and separate navigation entry points. The only shared infrastructure is the existing design system (`Card`, `ScreenScaffold`, `Fmt`, `MetricPoint`, `TimeChartRange`) and one new reusable chart component (`ReferenceRangeBand`).

This is deliberate: unifying them would create a premature abstraction that serves neither feature well, and the convolution risk of a "Health Tracking" mega-feature is exactly what the tester's feedback should not introduce.

## Placement

Both features surface where their job-to-be-done lives — a hybrid approach that avoids new top-level tabs:

| Surface | Supplements | Bloodwork |
|---|---|---|
| **Home tab** | "Today's Supplements" card — pending doses as tappable chips (1 tap = taken). Setup prompt when library is empty. | — |
| **Profile tab** | Health section → Supplements (full library management, log history) | Health section → Bloodwork (full panel management, biomarker catalog) |
| **Insights tab** | Adherence % card over 4W/12W/1Y/All + weekly bar chart. Tap → per-supplement breakdown. | Last panel date, flag count, trending biomarkers (delta since previous panel). Tap → Bloodwork panels list. |

No new top-level tab is added. The Profile "Health" section groups both features behind a single navigation entry, keeping the tab bar clean.

## Data model

Add 5 `@Model` classes to `Packages/ForgeData/Sources/ForgeData/Models.swift` and register all 5 in `ForgeDataSchema.models` (line 6). Same conventions as every existing model: `UUID` id (client-generated), `userID`, `createdAt`/`updatedAt`/`deletedAt`, `@Relationship(deleteRule: .cascade)` for parent→children with inverse, enums stored as raw-value Strings, no `@Attribute(.unique)`.

### Supplement library: `SupplementModel`

A user-created recurring supplement definition. Mirrors how `RoutineModel` is a template that generates `WorkoutModel` sessions — a `SupplementModel` is a template that generates daily `SupplementLogModel` rows.

```swift
@Model
public final class SupplementModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var name: String = ""
    public var doseAmount: Double = 0
    public var doseUnitRaw: String = DoseUnit.mg.rawValue
    public var frequencyRaw: String = SupplementFrequency.daily.rawValue
    /// Time-of-day for the dose (nil = no specific time). Drives reminder
    /// scheduling and the Home card's sort order.
    public var scheduledTime: Date?
    /// Per-supplement reminder toggle. Master toggle lives in Settings.
    public var reminderEnabled: Bool = false
    public var notes: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \SupplementLogModel.supplement)
    private var storedLogs: [SupplementLogModel]?
    public var logs: [SupplementLogModel] {
        get { storedLogs ?? [] }
        set { storedLogs = newValue }
    }

    public var doseUnit: DoseUnit {
        get { DoseUnit(rawValue: doseUnitRaw) ?? .mg }
        set { doseUnitRaw = newValue.rawValue }
    }

    public var frequency: SupplementFrequency {
        get { SupplementFrequency(rawValue: frequencyRaw) ?? .daily }
        set { frequencyRaw = newValue.rawValue }
    }
}
```

### Supplement dose log: `SupplementLogModel`

One row per planned dose per day. `SupplementStore` lazy-creates today's pending rows from the library on first access, so the user never manually creates "today's creatine" — it's already there to check off.

```swift
@Model
public final class SupplementLogModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    /// Denormalized for CloudKit-safe queries without a relationship hop.
    public var supplementID: UUID = UUID()
    /// Start-of-day for the day this dose belongs to (date-only, time zeroed).
    public var scheduledDate: Date = Date()
    public var statusRaw: String = SupplementLogStatus.pending.rawValue
    /// When the user marked the dose taken (nil = pending or skipped).
    public var takenAt: Date?
    /// If the user adjusted the dose at check-off (nil = planned dose used).
    public var actualDoseAmount: Double?
    public var actualDoseUnitRaw: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    public var supplement: SupplementModel?

    public var status: SupplementLogStatus {
        get { SupplementLogStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    public var actualDoseUnit: DoseUnit? {
        get { actualDoseUnitRaw.flatMap(DoseUnit.init(rawValue:)) }
        set { actualDoseUnitRaw = newValue?.rawValue }
    }
}
```

### Bloodwork panel: `BloodworkPanelModel`

One per lab visit. Mirrors `CardioSessionModel` (session with child splits) — a panel with child results.

```swift
@Model
public final class BloodworkPanelModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var drawDate: Date = Date()
    public var labName: String?
    public var notes: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \BloodworkResultModel.panel)
    private var storedResults: [BloodworkResultModel]?
    public var results: [BloodworkResultModel] {
        get { storedResults ?? [] }
        set { storedResults = newValue }
    }
}
```

### Bloodwork result: `BloodworkResultModel`

One biomarker value within a panel. `unit` is stored per-result (not per-biomarker) because different labs report the same biomarker in different units (e.g. Vitamin D as ng/mL or nmol/L).

```swift
@Model
public final class BloodworkResultModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var panelID: UUID = UUID()
    /// Denormalized for CloudKit-safe queries without a relationship hop.
    public var biomarkerID: UUID = UUID()
    public var value: Double = 0
    public var unitRaw: String = ""
    /// Auto-suggested from the biomarker's reference range at entry, but
    /// user-editable (a user may disagree with the default range).
    public var flagRaw: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    public var panel: BloodworkPanelModel?

    public var unit: BiomarkerUnit {
        get { BiomarkerUnit(rawValue: unitRaw) ?? .plainNumber }
        set { unitRaw = newValue.rawValue }
    }

    public var flag: ResultFlag? {
        get { flagRaw.flatMap(ResultFlag.init(rawValue:)) }
        set { flagRaw = newValue?.rawValue }
    }
}
```

### Biomarker catalog: `BiomarkerModel`

A catalog entry (built-in or user-created). Built-in rows use **deterministic UUIDs** derived from a stable slug (e.g. `"builtin-vitamin-d-25oh"`) via the same SHA256 approach as `ExerciseCatalog.deterministicID(for:)` (line 111). This makes seeding idempotent and CloudKit-sync-safe: two devices seeding independently produce identical UUIDs, so CloudKit brings them together without duplicates.

```swift
@Model
public final class BiomarkerModel {
    public var id: UUID = UUID()
    public var name: String = ""
    public var categoryRaw: String = BiomarkerCategory.other.rawValue
    public var defaultUnitRaw: String = BiomarkerUnit.plainNumber.rawValue
    public var referenceLow: Double?
    public var referenceHigh: Double?
    /// True for the ~25 built-in biomarkers seeded on first launch.
    public var isBuiltin: Bool = false
    public var sortOrder: Int = 0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public var category: BiomarkerCategory {
        get { BiomarkerCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    public var defaultUnit: BiomarkerUnit {
        get { BiomarkerUnit(rawValue: defaultUnitRaw) ?? .plainNumber }
        set { defaultUnitRaw = newValue.rawValue }
    }
}
```

### Schema registration

All 5 models are appended to `ForgeDataSchema.models`:

```swift
public static var models: [any PersistentModel.Type] {
    [
        // ... existing 21 models ...
        SupplementModel.self,
        SupplementLogModel.self,
        BloodworkPanelModel.self,
        BloodworkResultModel.self,
        BiomarkerModel.self
    ]
}
```

CloudKit sync is automatic — no new sync code, no container changes. These models inherit the existing `cloudKitDatabase: .automatic` configuration.

## Domain logic (`Packages/ForgeCore/Sources/ForgeCore/`)

New files, pure Swift (no SwiftUI, no SwiftData). The `DoseUnit`, `BiomarkerUnit`, and related enums follow the `DistanceUnit.swift` pattern: `String, Codable, Sendable, CaseIterable` with display helpers.

### `SupplementDomain.swift`

```swift
public enum DoseUnit: String, Codable, Sendable, CaseIterable {
    case mg, ug, iu, mL, capsule, tablet, scoop, drop
    public var title: String { /* "Milligrams", "Micrograms", "IU", ... */ }
    public var abbreviation: String { /* "mg", "µg", "IU", ... */ }
}

public enum SupplementFrequency: String, Codable, Sendable, CaseIterable {
    case daily, weekly, asNeeded
    public var title: String { /* "Daily", "Weekly", "As needed" */ }
}

public enum SupplementLogStatus: String, Codable, Sendable, CaseIterable {
    case pending, taken, skipped
}

/// Lightweight value type the store builds from `SupplementModel` before
/// calling domain math. Keeps ForgeCore free of SwiftData/SwiftUI imports
/// (same pattern as `CardioSampleSeries` working with value snapshots).
public struct SupplementPlan: Sendable {
    public let id: UUID
    public let frequency: SupplementFrequency
    public let scheduledTime: Date?
}

public enum SupplementDomain {
    /// Given a library and a date, returns the IDs of supplements whose dose
    /// should be logged that day. Handles `daily` (every day), `weekly`
    /// (specific day-of-week from the supplement's `scheduledTime`), and
    /// `asNeeded` (never auto-logged — only appears on manual add).
    public static func plannedSupplementIDs(for plans: [SupplementPlan], on date: Date) -> [UUID]

    /// Adherence % over a date range: taken / (taken + skipped) where pending
    /// doses in the past count as skipped. Returns nil if no scheduled doses.
    /// Takes plain dates (not `TimeChartRange`, which is SwiftUI-dependent and
    /// lives in the DesignSystem); the store converts `TimeChartRange` → dates.
    public static func adherenceRate(logStatuses: [SupplementLogStatus], from start: Date, to end: Date) -> Double?
}
```

### `BiomarkerDomain.swift`

```swift
public enum BiomarkerUnit: String, Codable, Sendable, CaseIterable {
    case ngPerMl, nmolPerL, ugPerDL, mgPerD, pgPerMl, mIUPerL, percent, mmolPerL, gPerDL, fL, plainNumber
    public var title: String { /* "ng/mL", "nmol/L", ... */ }
    public var abbreviation: String { /* "ng/mL", "nmol/L", ... */ }
}

public enum BiomarkerCategory: String, Codable, Sendable, CaseIterable {
    case hormone, lipid, metabolic, hematology, vitamin, mineral, liver, kidney, thyroid, inflammation, other
    public var title: String { /* "Hormones", "Lipids", ... */ }
}

public enum ResultFlag: String, Codable, Sendable, CaseIterable {
    case normal, low, high, critical
    public var title: String { /* "Normal", "Low", "High", "Critical" */ }
}

public enum BiomarkerDomain {
    /// Classifies a value against the reference range.
    public static func referenceRangeStatus(value: Double, low: Double?, high: Double?) -> ResultFlag?

    /// Trending biomarkers since a previous panel: returns biomarkers where
    /// the percentage change between the two most recent values exceeds 15%
    /// (arbitrary threshold, sufficient to filter noise without missing real
    /// shifts). Direction (up/down) is included.
    public static func trendingBiomarkers(current: [(biomarkerID: UUID, value: Double, low: Double?, high: Double?)], previous: [(biomarkerID: UUID, value: Double)]) -> [(biomarkerID: UUID, delta: Double, direction: TrendDirection)]
}

public enum TrendDirection: String, Codable, Sendable {
    case up, down
}
```

## Supplements feature (`ForgeFit/Supplements/`)

### `SupplementStore.swift` — `@Observable` singleton

Mirrors `HealthMetricsStore`. Holds today's pending doses and an adherence cache for the selected `TimeChartRange`.

**Log generation:** On first access each day, `SupplementStore` lazy-creates today's pending `SupplementLogModel` rows from the active supplement library. It calls `SupplementDomain.plannedSupplementIDs(for:on:)` to get the IDs due today, then for each checks if a log already exists for `(supplementID, scheduledDate)` and creates one if not. This is idempotent — re-running on the same day doesn't duplicate logs.

**Methods:**
- `markTaken(log:)` — sets `status = .taken`, `takenAt = Date()`, bumps `updatedAt`.
- `markSkipped(log:)` — sets `status = .skipped`, `takenAt = nil`.
- `markPending(log:)` — resets to pending (undo).
- `adherence(for range:) -> Double?` — delegates to `SupplementDomain.adherenceRate`.

**Injection:** Instantiated once at the app root (alongside `HealthMetricsStore`), injected via `.environment()`.

### Views

- **`SupplementsLibraryView.swift`** — `@Query` list of `SupplementModel` (not deleted). Each row: name, dose + unit, frequency, reminder indicator. Add/edit via `SupplementFormView`. Swipe-to-delete soft-deletes (`deletedAt = Date()`).
- **`SupplementFormView.swift`** — Form fields: name (text), dose amount (decimal), unit (picker from `DoseUnit.allCases`), frequency (picker), scheduled time (DatePicker, hidden when `asNeeded`), reminder toggle (hidden when master toggle off or `asNeeded`), notes (text). Save creates/updates `SupplementModel` and syncs reminders.
- **`SupplementLogHistoryView.swift`** — `@Query` of `SupplementLogModel` filtered by supplement, grouped by date. Shows status + actual dose if different from planned.

### Reminders

- **`UNUserNotificationCenter`** with `UNCalendarNotificationTrigger` per supplement (hour/minute from `scheduledTime`, repeats daily or weekly).
- **Identifier:** `"supplement-<supplementID.uuidString>"` for stable add/remove.
- **Permission flow:** Requested on first `reminderEnabled = true`, not at launch. If denied, the toggle shows a "Enable in Settings" affordance.
- **Sync triggers:** On supplement save (add/update/delete), on app foreground (to catch system-level changes), and on master toggle change. The sync function removes all pending notifications for deleted supplements and re-registers active ones.
- **Master toggle:** `@AppStorage("settings.supplements.remindersMasterEnabled")` in Settings. When off, all per-supplement notifications are cancelled; the per-supplement toggles remain set but inactive.

### Home card (`ForgeFit/Home/TodaySupplementsCard.swift`)

- Reads today's pending `SupplementLogModel` rows from `SupplementStore`.
- Each dose is a tappable chip (name + dose). Tap = `markTaken` (haptic). Long-press = context menu with "Skip" and "Edit dose".
- "All done" state when zero pending doses remain — shows a checkmark and the current streak (consecutive days where all planned doses were taken, resetting to 0 on any skipped or pending-past dose).
- Empty state when the supplement library is empty — "Add supplements to track your daily intake" with a button to `SupplementFormView`.
- Hidden entirely (returns `EmptyView`) when no supplements exist, so the Home tab stays clean for users who don't use this feature.

### Insights card (`SupplementAdherenceCard` in `InsightsView`)

- Overall adherence % over the selected `TimeChartRange` (4W/12W/1Y/All) as a large number with color (green ≥80%, amber ≥50%, red <50%).
- Weekly bar chart (7 bars, adherence % per day) for the last 7 days in the range.
- Tap → per-supplement breakdown (`SupplementAdherenceDetailView`) showing each supplement's individual adherence % and a sparkline.

## Bloodwork feature (`ForgeFit/Bloodwork/`)

### `BloodworkStore.swift` — `@Observable` singleton

Mirrors `SupplementStore` (and `HealthMetricsStore`). Holds:
- Last panel per biomarker cache (for the Insights card's "trending" computation).
- Trend series per biomarker for the selected `TimeChartRange`.

**Methods:**
- `trend(for biomarkerID:) -> [MetricPoint]` — all non-deleted `BloodworkResultModel` for that biomarker, sorted by `panel.drawDate`, mapped to `MetricPoint(date: value:)`.
- `flagForResult(value:unit:biomarker:) -> ResultFlag?` — delegates to `BiomarkerDomain.referenceRangeStatus` against the biomarker's `referenceLow`/`referenceHigh`.
- `trendingBiomarkers(since previousPanelDate:) -> [(biomarkerID, delta, direction)]` — biomarkers where the percentage change between the two most recent values exceeds 15% since the previous panel, with up/down direction. Delegates to `BiomarkerDomain.trendingBiomarkers`.

### Views

- **`BloodworkPanelsView.swift`** — `@Query` list of `BloodworkPanelModel` (not deleted), sorted by `drawDate` descending. Row: date, lab name, result count, flag summary (e.g. "2 high, 1 low"). Add via `BloodworkPanelFormView`. Swipe-to-delete soft-deletes.
- **`BloodworkPanelFormView.swift`** — Form fields: draw date (DatePicker), lab name (text, optional), notes (text, optional). Save creates the panel, then drills into `BloodworkPanelDetailView` for result entry.
- **`BloodworkPanelDetailView.swift`** — Results table for one panel. "Add result" button → `BloodworkResultFormView`. Existing results shown as rows: biomarker name, value + unit, flag color dot. Tap to edit.
- **`BloodworkResultFormView.swift`** — Fields: biomarker picker (from catalog, with "Add custom biomarker" option), value (decimal), unit (picker, defaulted from biomarker's `defaultUnit` but editable — because labs vary). Flag is auto-suggested from `BloodworkStore.flagForResult` but shown as an editable picker (user can override).
- **`BiomarkerCatalogView.swift`** — Browse/edit the biomarker catalog. Built-in and custom markers grouped by `BiomarkerCategory`. Tap to edit reference range (`referenceLow`, `referenceHigh`) and default unit. "Add custom biomarker" creates a new `BiomarkerModel` with `isBuiltin = false`. Built-in markers are editable but never deleted (soft-delete hides them from the picker but the row persists for existing results).
- **`BiomarkerTrendView.swift`** — Single biomarker over time: line chart using `MetricPoint` + `TimeChartRange` with the reference range rendered as a shaded band via the new `ReferenceRangeBand` component. Result list below the chart with flag color coding (green = normal, amber = low/high, red = critical). Tap a result to see the panel it belongs to.

### Insights card (`BloodworkTrendsCard` in `InsightsView`)

- Last panel date ("Last bloodwork: Jun 12").
- Flag count from the most recent panel (e.g. "2 out of range").
- Trending biomarkers: up to 3 biomarkers with the largest delta since the previous panel, shown with up/down arrows and the delta value.
- Tap → `BloodworkPanelsView`.
- Hidden entirely when no panels exist.

## Design system additions (`ForgeFit/DesignSystem/`)

### `Format.swift` — new `Fmt` helpers

```swift
extension Fmt {
    static func dose(_ amount: Double, unit: DoseUnit) -> String
    static func biomarker(_ value: Double, unit: BiomarkerUnit) -> String
}
```

These mirror `Fmt.volume(...)`, `Fmt.duration(...)`, etc. — formatting + unit abbreviation in one call.

### `Charts.swift` — `ReferenceRangeBand`

A reusable chart overlay that draws a shaded horizontal band between `referenceLow` and `referenceHigh` on a `Chart` with a `Y` axis. Used only by `BiomarkerTrendView` in v1, but kept as a shared component (not inlined) because it's a distinct visual concept that's easy to unit-test and reuse.

```swift
struct ReferenceRangeBand: View {
    let low: Double?
    let high: Double?
    // Renders as a RectangleMark with low opacity between [low, high]
}
```

When either bound is nil, the band extends to the chart edge on that side (open-ended range — common for biomarkers like "≥ 30 ng/mL" with no upper limit).

## Settings additions (`ForgeFit/Settings/SettingsView.swift`)

New `@AppStorage` keys, namespaced per the existing convention:

| Key | Type | Default | Purpose |
|---|---|---|---|
| `settings.supplements.defaultDoseUnit` | String | `mg` | Pre-selected unit in the supplement form |
| `settings.supplements.remindersMasterEnabled` | Bool | `true` | Master toggle for all supplement reminders |
| `settings.bloodwork.defaultBiomarkerUnit` | String | `ngPerMl` | Pre-selected unit for new custom biomarkers |
| `settings.bloodwork.rangeBandVisible` | Bool | `true` | Toggle the reference range band on trend charts |

These appear in a new "Health" section in Settings, below the existing HealthKit settings.

## Built-in biomarker catalog seeding

On first launch after this feature ships, the app seeds ~25 biomarkers covering hormones, lipids, metabolic, hematology, vitamins, minerals, liver, kidney, and thyroid.

### Seeding mechanism

A new `BiomarkerSeedRepository` in `Packages/ForgeData/Sources/ForgeData/` (mirroring `ExerciseSeedRepository.swift`):

1. Guarded by `@AppStorage("settings.bloodwork.catalogSeeded")` flag — runs once, never again on subsequent launches.
2. Each built-in biomarker gets a **deterministic UUID** from its slug (e.g. `"builtin-vitamin-d-25oh"`) using the same SHA256 approach as `ExerciseCatalog.deterministicID(for:)` (line 111). This makes the seed idempotent: if two devices seed independently before a CloudKit sync, the rows have identical UUIDs and CloudKit merges them without duplicates.
3. The seeder checks for existing rows by UUID before inserting — skip if present.
4. User edits to built-in biomarkers are **never overwritten** on later seed-version bumps. The seeder only inserts new markers; corrections to default ranges are left to the user (they own their copy, same convention as `ExerciseLibraryModel.userModified` in the exercise seed at line 176).

### Built-in catalog (~25 markers)

| Category | Biomarkers |
|---|---|
| Hormone | Total Testosterone, Free Testosterone, Estradiol, DHEA-S, Cortisol |
| Lipid | Total Cholesterol, HDL, LDL, Triglycerides |
| Metabolic | Fasting Glucose, HbA1c, Insulin |
| Hematology | WBC, RBC, Hemoglobin, Hematocrit, MCV, Ferritin, Iron |
| Vitamin | Vitamin D (25-OH), Vitamin B12, Folate |
| Thyroid | TSH, Free T3, Free T4 |
| Liver/Kidney | ALT, AST, Creatinine, eGFR |
| Inflammation | hs-CRP |

Each carries a `defaultUnit` and a flat `referenceLow`/`referenceHigh` pair based on standard adult ranges. These are **defaults**, not medical truth — the user is expected to adjust them to their lab's stated ranges. The app never claims these ranges are authoritative.

## Testing

### Unit tests (`ForgeFitTests`)

- **`SupplementDomainTests`** — adherence math edge cases (empty logs → nil, all taken → 100%, all skipped → 0%, pending in past counted as skipped); log generation across date boundaries (midnight rollover), weekly schedule day-of-week matching, DST transitions.
- **`BiomarkerDomainTests`** — reference range classification (below/within/above/critical, open-ended ranges with nil low or high); trend delta computation.
- **`BiomarkerSeedRepositoryTests`** — seeding is idempotent (run twice → same rows), deterministic UUIDs match expected values, user edits preserved on re-seed.

### UI tests (`ForgeFitUITests`)

- Add a supplement → mark taken → Home card updates to "all done".
- Add a bloodwork panel with 2 results → trend chart appears in `BiomarkerTrendView`.

### Manual verification

- Build succeeds for the phone target.
- Existing test suite passes.
- CloudKit sync: create a supplement on one device, confirm it appears on another.

## Files touched

**New:**
- `ForgeFit/Supplements/SupplementStore.swift`
- `ForgeFit/Supplements/SupplementsLibraryView.swift`
- `ForgeFit/Supplements/SupplementFormView.swift`
- `ForgeFit/Supplements/SupplementLogHistoryView.swift`
- `ForgeFit/Supplements/SupplementReminderSync.swift`
- `ForgeFit/Home/TodaySupplementsCard.swift`
- `ForgeFit/Insights/SupplementAdherenceCard.swift`
- `ForgeFit/Bloodwork/BloodworkStore.swift`
- `ForgeFit/Bloodwork/BloodworkPanelsView.swift`
- `ForgeFit/Bloodwork/BloodworkPanelFormView.swift`
- `ForgeFit/Bloodwork/BloodworkPanelDetailView.swift`
- `ForgeFit/Bloodwork/BloodworkResultFormView.swift`
- `ForgeFit/Bloodwork/BiomarkerCatalogView.swift`
- `ForgeFit/Bloodwork/BiomarkerTrendView.swift`
- `ForgeFit/Insights/BloodworkTrendsCard.swift`
- `Packages/ForgeCore/Sources/ForgeCore/SupplementDomain.swift`
- `Packages/ForgeCore/Sources/ForgeCore/BiomarkerDomain.swift`
- `Packages/ForgeData/Sources/ForgeData/BiomarkerSeedRepository.swift`

**Modified:**
- `Packages/ForgeData/Sources/ForgeData/Models.swift` — add 5 `@Model` classes + register in `ForgeDataSchema.models`
- `ForgeFit/DesignSystem/Format.swift` — add `Fmt.dose` and `Fmt.biomarker`
- `ForgeFit/DesignSystem/Charts.swift` — add `ReferenceRangeBand`
- `ForgeFit/Settings/SettingsView.swift` — add Health section with 4 `@AppStorage` keys
- `ForgeFit/ContentView.swift` — wire `SupplementStore` and `BloodworkStore` into the environment
- `ForgeFit/Home/HomeView.swift` — add `TodaySupplementsCard`
- `ForgeFit/Insights/InsightsView.swift` — add `SupplementAdherenceCard` and `BloodworkTrendsCard`
- `ForgeFit/Profile/ProfileView.swift` — add Health section linking to Supplements and Bloodwork management

**Tests (new):**
- `ForgeFitTests/SupplementDomainTests.swift`
- `ForgeFitTests/BiomarkerDomainTests.swift`
- `Packages/ForgeData/Tests/ForgeDataTests/BiomarkerSeedRepositoryTests.swift`

## Out of scope (v2+)

- HealthKit read/write for supplements or lab results.
- OCR / PDF lab report import.
- Cross-feature correlation (supplement → lab value inference).
- Age/sex-specific reference ranges (v1 ships flat defaults).
- Automatic unit conversion (ng/mL ↔ nmol/L).
- Supplement inventory, cost, or expiration tracking.
- Watch app surfaces for supplements or bloodwork.
- Widget or Live Activity for supplement reminders.
- AI interpretation of bloodwork results.
