# SwiftData + CloudKit Sync (Replace Supabase)

**Date:** 2026-07-03
**Status:** Approved
**Approach:** A — Native SwiftData CloudKit sync

## Goal

Replace the DEBUG-only Supabase sync layer with native SwiftData ↔ CloudKit
sync, giving ForgeFit automatic, iCloud-backed, multi-device sync across the
user's Apple devices with no auth UI and no third-party backend.

## Context

ForgeFit is iOS/watchOS 26 only, SwiftData-native (16 `@Model` types in the
`ForgeData` package), private-only (no social sharing), and ships a bundled
exercise seed that each user owns. The existing Supabase sync
(`Sync/SyncEngine.swift`, `Sync/SyncPayloads.swift`) is DEBUG-only, hand-rolled
over PostgREST, and uses a single `forgefit_records` table with last-write-wins.
None of it ships to production. CloudKit is a strictly better fit: free,
Apple-maintained, identity via iCloud account, automatic across iOS + watchOS.

The watch app remains a non-persisting mirror of the phone via
WatchConnectivity (`WatchStore.swift`). Only the phone owns SwiftData + CloudKit.

## Non-Goals

- Cross-platform (web/Android) support — Apple ecosystem only, permanently.
- Social sharing / `CKShare` — private database only.
- CloudKit public database — bundled seed, user-owned library.
- Server-side logic (triggers, RLS, progression rules) — CloudKit has none.
- Removing the `userID` / `ForgeFitDemo.userID` concept — vestigial but
  harmless under private-only CloudKit; removing it would force a painful
  schema migration and break existing queries. Out of scope.

## Design

### 1. Remove `@Attribute(.unique)` from all 16 models

CloudKit does not support unique constraints. All 16 `@Model` classes in
`Packages/ForgeData/Sources/ForgeData/Models.swift` declare:

```swift
@Attribute(.unique) public var id: UUID
```

at lines 32, 67, 158, 185, 226, 269, 314, 361, 467, 508, 537, 569, 633, 831,
943, 982. Each becomes:

```swift
public var id: UUID
```

The `id` remains a `UUID` (still used for relationships, fetches, and
`ownerID`/`parentID` linking) — only the DB-level unique constraint is removed.
Dedup risk is negligible: IDs are client-generated UUIDs and CloudKit's record
name provides the true identity.

### 2. Enable CloudKit in `ModelConfiguration`

`ForgeFit/ForgeFitApp.swift` — the existing `ModelConfiguration` becomes:

```swift
let modelConfiguration = ModelConfiguration(
    schema: schema,
    isStoredInMemoryOnly: false,
    cloudKitDatabase: .automatic
)
```

`cloudKitDatabase: .automatic` makes SwiftData mirror every model in the schema
to CloudKit and auto-sync. The existing crash-recovery/backup logic stays
unchanged. SwiftData uploads existing local records to the user's private
CloudKit database on first launch when iCloud is available; it degrades to
local-only gracefully when iCloud is unavailable.

### 3. Add iCloud + CloudKit entitlements

`ForgeFit/ForgeFit.entitlements` gains:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.org.xpetsllc.ForgeFit</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
<key>com.apple.developer.ck-environment</key>
<string>Development</string>
```

(`ck-environment` moves to `Production` before release.) The watch and widget
entitlements are unchanged — neither uses CloudKit.

### 4. Remove the Supabase sync layer

Delete:
- `ForgeFit/ForgeFit/Sync/SyncEngine.swift` (291 lines)
- `ForgeFit/ForgeFit/Sync/SyncPayloads.swift` (583 lines)
- `ForgeFit/ForgeFit/Sync/` directory (becomes empty)
- `Packages/ForgeNetwork/` (the stub `ForgeNetworkConfiguration` type — unused
  by anything other than the now-deleted SyncEngine)
- `supabase/` directory (migrations, config, snippets — no longer the backend)

### 5. Remove `requestSync` call sites

24 occurrences across 12 files. Each `SyncEngine.shared.requestSync(...)`
or `syncEngine.requestSync(...)` call is deleted. CloudKit sync is automatic;
nothing in the app triggers it manually.

Files:
`ContentView`, `ExercisePickerView`, `ActiveWorkoutLoggerView`,
`WorkoutDetailView`, `RoutineTemplateCatalog`, `RoutineEditorView`,
`WorkoutView`, `WorkoutFinisher`, `AppRefresh`, `HomeView`, `InsightsView`.

The `syncEngine` property in `ContentView` (line 63) is removed.

### 6. Clean `AccountResetService.clearAppDefaults()`

Drop Supabase keys from the wipe list:
`supabaseURL`, `supabaseAnonKey`, `supabaseAccessToken`, `supabaseUserID`,
`syncLastSuccessAt`, `syncLastPushAt`, `syncLastPullAt`, `cloudSyncEnabled`.
Keep all other defaults.

### 7. Watch app — no change

The watch remains a non-persisting mirror via `WatchConnectivity`. The phone
syncs to CloudKit; the watch gets live data via `WCSession`. No watch
entitlement changes, no CloudKit on watch.

### 8. Project file updates

`project.pbxproj` must be updated to:
- Remove `SyncEngine.swift` and `SyncPayloads.swift` from the build phase.
- Remove the `ForgeNetwork` package dependency from the app target (and the
  project-level package reference if it becomes unreferenced).

## Out-of-band tasks (require Xcode UI / Developer portal)

Cannot be done via code edits — the user must perform these:

1. Enable the **iCloud** capability for App ID `org.xpetsllc.ForgeFit` in the
   Apple Developer portal (iCloud + CloudKit checkbox, container
   `iCloud.org.xpetsllc.ForgeFit`).
2. In Xcode → Signing & Capabilities, confirm the iCloud capability is attached
   and regenerate / update provisioning profiles so they include the iCloud
   entitlement.
3. Flip `ck-environment` to `Production` before release.

## Verification

- App builds (`xcodebuild` / Xcode).
- Existing test suite (`ForgeFitTests`) passes — `@Attribute(.unique)` removal
  shouldn't break tests since UUIDs remain unique by generation.
- Manual two-device check: sign into the same iCloud account on two devices,
  create a workout on one, confirm it appears on the other.

CloudKit sync itself cannot be unit-tested without an iCloud account; we rely
on build + existing-test pass + the manual two-device check.

## Risk

- **`@Attribute(.unique)` removal**: low risk. UUIDs are client-generated and
  collision-free in practice. CloudKit record name is the true identity.
- **Existing local data**: no migration needed. SwiftData auto-uploads existing
  local records when iCloud becomes available.
- **Conflict resolution**: CloudKit uses last-writer-wins per field, less
  sophisticated than the Supabase LWW. Acceptable for a single-user private DB.
