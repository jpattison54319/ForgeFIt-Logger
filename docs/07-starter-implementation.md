# H — Starter Implementation

> Concrete first steps for **E0 + E1**, with copy-pasteable structure, Swift model sketches, the first migration, and testable acceptance criteria. This is the on-ramp; not the whole app.

---

## 1. Project structure

```
ForgeFit/
├── ForgeFit.xcworkspace
├── App-iOS/
│   ├── ForgeFitApp.swift            // @main, injects ModelContainer + stores
│   ├── RootTabView.swift            // Home / Routines / History / Recovery / Profile
│   └── Info.plist                   // Health usage strings (added per phase)
├── App-Watch/
│   ├── ForgeFitWatchApp.swift
│   └── WorkoutView.swift
├── Packages/
│   ├── ForgeCore/        // pure logic: domain types + math (no UIKit/HealthKit)
│   ├── ForgeData/        // SwiftData @Models + repositories
│   ├── ForgeHealth/      // HealthKit wrappers
│   ├── ForgeWorkoutSession/ // HKWorkoutSession/Builder/mirroring controller
│   └── ForgeUI/          // shared SwiftUI components, tokens, charts
└── docs/                            // this folder
```

Each `Packages/*` is a local Swift Package added to the workspace; both app targets depend on the relevant ones.

---

## 2. First Swift models (sketch)

`ForgeCore` (platform-free domain + math):

```swift
public enum SetType: String, Codable, CaseIterable {
    case warmup, working, drop, restPause, backoff, amrap, myoRep, cluster
}

public enum WeightMode: String, Codable {
    case external, bodyweight, bodyweightAssisted, bodyweightAdded
}

public struct SetEntry: Identifiable, Codable, Equatable {
    public var id: UUID                  // UUIDv7, created on device
    public var setType: SetType
    public var weightMode: WeightMode
    public var reps: Int?
    public var weight: Double?
    public var rpe: Double?
    public var rir: Int?
    public var holdSeconds: Int?
    public var partialReps: Int?
    public var addedWeight: Double?
    public var assistanceWeight: Double?
    public var bodyweightKg: Double?
    public var isUnilateral: Bool
    public var implementWeight: Double?  // one dumbbell
    public var limbCount: Int            // default 2
    public var isEccentric: Bool
    public var isPaused: Bool
}

public enum VolumeMath {
    /// Resolves true working volume. Single source of truth; all math
    /// computed on-device via ForgeCore.
    public static func effectiveLoad(_ s: SetEntry) -> Double {
        switch s.weightMode {
        case .external:            return s.isUnilateral ? (s.implementWeight ?? 0) : (s.weight ?? 0)
        case .bodyweight:          return s.bodyweightKg ?? 0
        case .bodyweightAdded:     return (s.bodyweightKg ?? 0) + (s.addedWeight ?? 0)
        case .bodyweightAssisted:  return max(0, (s.bodyweightKg ?? 0) - (s.assistanceWeight ?? 0))
        }
    }

    public static func totalVolume(_ s: SetEntry) -> Double {
        let reps = Double((s.reps ?? 0) + (s.partialReps ?? 0) / 2) // partials half-weighted
        let limbs = s.isUnilateral ? Double(s.limbCount) : 1
        return effectiveLoad(s) * reps * limbs
    }

    /// Epley e1RM (one option; rule is documented & versioned).
    public static func estimated1RM(_ s: SetEntry) -> Double? {
        guard let reps = s.reps, reps > 0 else { return nil }
        let load = effectiveLoad(s)
        return load * (1 + Double(reps) / 30.0)
    }
}
```

`ForgeData` (SwiftData persistence — mirrors the schema):

```swift
import SwiftData

@Model final class WorkoutModel {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var title: String?
    var sourceDevice: String?
    var hkWorkoutUUID: UUID?
    @Relationship(deleteRule: .cascade) var exercises: [WorkoutExerciseModel]
    var updatedAt: Date
    var deletedAt: Date?
    init(id: UUID, startedAt: Date) { self.id = id; self.startedAt = startedAt
        self.exercises = []; self.updatedAt = .now }
}

@Model final class SetModel {
    var id: UUID
    var position: Int
    var setTypeRaw: String
    var weightMode: String
    var reps: Int?
    var weight: Double?
    var rpe: Double?
    var isUnilateral: Bool
    var implementWeight: Double?
    var limbCount: Int
    // ...mirrors sets columns; computed fields filled by ForgeCore on save...
    var completedAt: Date?
    var updatedAt: Date
    init(id: UUID, position: Int) { self.id = id; self.position = position
        self.setTypeRaw = SetType.working.rawValue; self.weightMode = WeightMode.external.rawValue
        self.isUnilateral = false; self.limbCount = 2; self.updatedAt = .now }
}
```

(`WorkoutExerciseModel`, `RoutineModel`, etc. follow the same pattern; full set in E1.)

---

## 3. CloudKit sync setup

Sync is enabled by setting `cloudKitDatabase: .automatic` on the `ModelConfiguration` in `ForgeFitApp.swift`, plus adding the iCloud + CloudKit entitlements:

```swift
let modelConfiguration = ModelConfiguration(
    schema: schema,
    isStoredInMemoryOnly: false,
    cloudKitDatabase: .automatic
)
```

Entitlements (`ForgeFit.entitlements`):
- `com.apple.developer.icloud-container-identifiers`: `iCloud.org.xpetsllc.ForgeFit`
- `com.apple.developer.icloud-services`: `CloudKit`
- `com.apple.developer.ck-environment`: `Development` (→ `Production` before release)

In Xcode → Signing & Capabilities, enable the iCloud capability (CloudKit checkbox, select the container). Xcode regenerates the provisioning profile.

**Key constraint:** CloudKit does not support `@Attribute(.unique)`. All model IDs use plain `UUID` properties (client-generated).

---

## 4. First implementation steps (ordered)

1. **FF-001/002:** scaffold workspace, packages, SwiftData `ModelContainer`, app shell + tabs, design tokens.
2. **FF-003:** enable iCloud + CloudKit capability; configure `cloudKitDatabase: .automatic` on the ModelContainer.
3. **FF-010:** port domain models to `ForgeCore`; SwiftData `@Model`s to `ForgeData`.
4. **FF-011:** implement `VolumeMath` + e1RM with **golden-vector unit tests** (table below).
5. **FF-012:** SwiftData round-trip test (workout with unilateral + drop + weighted-bodyweight sets).
6. **Round-trip demo:** create → save → reload a workout containing a unilateral set + a drop set + a weighted-pullup set; assert computed volume/e1RM.

---

## 5. Testable acceptance criteria (E0 + E1 "done")

| # | Criterion | How verified |
|---|---|---|
| AC-1 | Both apps build & launch to a shell; CI green | `xcodebuild` both targets + unit tests in CI |
| AC-2 | CloudKit sync configured and building | iCloud capability enabled; `cloudKitDatabase: .automatic` set; build succeeds |
| AC-3 | **Unilateral volume correct**: 30 kg dumbbell × 10 reps × 2 arms = **600** total volume from a single 30 kg entry | `ForgeCore` golden test |
| AC-4 | **Weighted pullup**: BW 80 + added 20, 5 reps → effective 100, volume 500 | golden test |
| AC-5 | **Assisted dip**: BW 80 − assist 30, 8 reps → effective 50, volume 400 | golden test |
| AC-6 | e1RM(100 kg × 5) ≈ **116.7** (Epley) | golden test |
| AC-7 | Workout with unilateral + drop + weighted-bodyweight set round-trips through SwiftData unchanged | persistence test |
| AC-8 | CloudKit sync: workout created on one device appears on another (same iCloud account) | manual two-device check |
| AC-9 | All math computed on-device via `ForgeCore` (single source of truth, no server divergence) | no server math to diverge |
| AC-10 | **Muscle volume**: a working bench set → chest 1.0, triceps 0.5, front_delts 0.5; warm-ups 0; weekly aggregate sums correctly | `ForgeCore` `MuscleVolume` golden test |

When AC-1…AC-9 pass, mark **E0** and **E1** done in [EPICS.md](EPICS.md) and proceed to M1 (E2–E4).
