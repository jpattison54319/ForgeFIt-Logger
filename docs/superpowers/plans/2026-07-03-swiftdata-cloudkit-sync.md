# SwiftData + CloudKit Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the DEBUG-only Supabase sync layer with native SwiftData ↔ CloudKit sync (Approach A from the approved design).

**Architecture:** Set `ModelConfiguration(cloudKitDatabase: .automatic)` so SwiftData auto-mirrors all 16 `@Model` types to the user's private CloudKit database. Remove `@Attribute(.unique)` (unsupported by CloudKit) from every model. Delete the Supabase `SyncEngine`/`SyncPayloads`, the `ForgeNetwork` stub package, and the `supabase/` backend dir. Remove the 24 `requestSync` call sites — CloudKit sync is automatic. Watch app unchanged (phone owns CloudKit; watch is a WCSession mirror).

**Tech Stack:** SwiftData (iOS 26), CloudKit, Xcode synchronized folder groups, local SPM packages.

## Global Constraints

- iOS/watchOS 26 deployment target (do not lower).
- Swift 6 language mode, swift-tools-version 6.2.
- No third-party dependencies (project has none; do not add any).
- Bundle ID `org.xpetsllc.ForgeFit`; iCloud container `iCloud.org.xpetsllc.ForgeFit`.
- The project uses Xcode `PBXFileSystemSynchronizedRootGroup` — Swift files deleted from disk are automatically removed from the build; no per-file pbxproj edits needed for `.swift` files. Only the `ForgeNetwork` package reference needs pbxproj editing.
- TDD caveat: this is config/deletion work with no new behavior to drive with failing tests. Verification per task = build + existing test suite. Do not invent throwaway tests for "annotation removed."

---

### Task 1: Remove `@Attribute(.unique)` from all 16 models

CloudKit does not support unique constraints. Every model declares
`@Attribute(.unique) public var id: UUID`; each must become `public var id: UUID`.

**Files:**
- Modify: `Packages/ForgeData/Sources/ForgeData/Models.swift` (lines 32, 67, 158, 185, 226, 269, 314, 361, 467, 508, 537, 569, 633, 831, 943, 982)

- [ ] **Step 1: Replace all 16 occurrences**

In `Packages/ForgeData/Sources/ForgeData/Models.swift`, replace every instance of:

```swift
    @Attribute(.unique) public var id: UUID
```

with:

```swift
    public var id: UUID
```

Use a replace-all on that exact string (all 16 are identical, 4-space indented). Do not touch any other property.

- [ ] **Step 2: Verify ForgeData builds + tests pass**

Run:
```bash
make test-data
```
Expected: `cd Packages/ForgeData && swift test` builds and all package tests pass. (UUIDs remain unique by generation, so no dedup regression.)

- [ ] **Step 3: Verify the app target still compiles the model**

Run:
```bash
make build-ios
```
Expected: build succeeds. (It will still reference `SyncEngine` — that is removed in Task 2; this step only confirms the model change didn't break compilation of model consumers. If build-ios fails *only* because of `SyncEngine` references, that is expected and acceptable; proceed.)

---

### Task 2: Remove all `SyncEngine` references and delete the Supabase sync layer

Remove every `requestSync` call site and the `syncEngine` property, then delete the sync files, the `ForgeNetwork` package, and the `supabase/` backend directory. After this task the app builds with no sync code at all.

**Files:**
- Modify: `ForgeFit/ContentView.swift` (property line 63 + call sites 242, 321, 392–394, 449)
- Modify: `ForgeFit/Exercises/ExercisePickerView.swift` (line 520)
- Modify: `ForgeFit/Workout/ActiveWorkoutLoggerView.swift` (lines 665, 929, 1401)
- Modify: `ForgeFit/Shared/WorkoutDetailView.swift` (lines 147–151)
- Modify: `ForgeFit/Workout/RoutineTemplateCatalog.swift` (line 86)
- Modify: `ForgeFit/Workout/RoutineEditorView.swift` (lines 112, 411)
- Modify: `ForgeFit/Workout/WorkoutView.swift` (lines 647, 650–653)
- Modify: `ForgeFit/Workout/WorkoutFinisher.swift` (lines 41, 54, 64, 103)
- Modify: `ForgeFit/Health/AppRefresh.swift` (line 15 + doc comment)
- Modify: `ForgeFit/Home/HomeView.swift` (line 480)
- Modify: `ForgeFit/Insights/InsightsView.swift` (line 493)
- Delete: `ForgeFit/Sync/SyncEngine.swift`
- Delete: `ForgeFit/Sync/SyncPayloads.swift`
- Delete: `ForgeFit/Sync/` directory (now empty)
- Delete: `Packages/ForgeNetwork/` (entire package)
- Delete: `supabase/` (entire directory)
- Modify: `ForgeFit.xcodeproj/project.pbxproj` (remove ForgeNetwork package ref + definition)

**Interfaces:**
- Consumes: none (this is removal).
- Produces: an app with no `SyncEngine` symbol and no Supabase references.

- [ ] **Step 1: ContentView.swift — remove `syncEngine` property**

In `ForgeFit/ContentView.swift`, delete line 63:

```swift
    @State private var syncEngine = SyncEngine.shared
```

- [ ] **Step 2: ContentView.swift — remove the four call sites**

(a) Line 242 inside `handleScenePhaseChange` — delete the line:
```swift
            syncEngine.requestSync(modelContext)
```

(b) Line 321 in `launchTasks` — delete the line:
```swift
        syncEngine.requestSync(modelContext)
```

(c) Lines 391–394 in `importHealthWorkoutHistory` — the call is the only body of an `if`. Replace:
```swift
        let imported = await HealthWorkoutImporter.shared.importRecent(in: modelContext)
        if imported > 0 {
            syncEngine.requestSync(modelContext)
        }
```
with:
```swift
        _ = await HealthWorkoutImporter.shared.importRecent(in: modelContext)
```

(d) Line 449 in the onboarding-slate cleanup — delete the line:
```swift
            syncEngine.requestSync(modelContext)
```

- [ ] **Step 3: ExercisePickerView.swift — remove call at line 520**

Delete:
```swift
        SyncEngine.shared.requestSync(modelContext)
```

- [ ] **Step 4: ActiveWorkoutLoggerView.swift — remove calls at lines 665, 929, 1401**

Delete each of these three lines (they are standalone statements after `try? modelContext.save()`; surrounding code remains):
```swift
        SyncEngine.shared.requestSync(modelContext)   // line 665
            SyncEngine.shared.requestSync(modelContext)   // line 929 (inside if-let block; keep the RoutineChangeSync.apply + save above it)
        SyncEngine.shared.requestSync(modelContext)   // line 1401
```

- [ ] **Step 5: WorkoutDetailView.swift — remove Task block (lines 147–151)**

The sync call lives in a `Task` whose only purpose was deferred sync. Delete the comment and the whole Task:
```swift
        // Sync after the pop transition — never in competition with it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            SyncEngine.shared.requestSync(modelContext)
        }
```
Keep the preceding `dismiss()`.

- [ ] **Step 6: RoutineTemplateCatalog.swift — remove call at line 86**

Delete:
```swift
        SyncEngine.shared.requestSync(context)
```

- [ ] **Step 7: RoutineEditorView.swift — remove calls at lines 112 and 411**

Both are standalone lines after `try? modelContext.save()` inside `save()` methods. Delete each:
```swift
        SyncEngine.shared.requestSync(modelContext)
```

- [ ] **Step 8: WorkoutView.swift — inline `saveAndRequestSync()` (lines 647, 650–653)**

The private helper `saveAndRequestSync()` becomes just a save once sync is gone. Remove the helper and inline the save at its single call site.

Replace lines 646–647:
```swift
        modelContext.insert(copy)
        saveAndRequestSync()
```
with:
```swift
        modelContext.insert(copy)
        try? modelContext.save()
```

And delete the helper (lines 650–653):
```swift
    private func saveAndRequestSync() {
        try? modelContext.save()
        SyncEngine.shared.requestSync(modelContext)
    }
```

- [ ] **Step 9: WorkoutFinisher.swift — remove calls at lines 41, 54, 64, 103**

Delete each standalone `SyncEngine.shared.requestSync(context)` line. All four sit immediately after a `try? context.save()`. No surrounding control flow depends on them.

- [ ] **Step 10: AppRefresh.swift — remove call (line 15) + update doc comment**

Delete line 15:
```swift
        SyncEngine.shared.requestSync(context)
```

Update the doc comment (lines 5–9) so it no longer mentions cloud sync. Replace:
```swift
/// One full data refresh, shared by pull-to-refresh on the main screens:
/// import any new Apple Health workouts, re-query the recovery series
/// (HRV/sleep/RHR/bodyweight/today's signals), kick a cloud sync, and
/// recompute the streak nudge + watch snapshot. Readiness recomputes
/// automatically once the observable store updates.
```
with:
```swift
/// One full data refresh, shared by pull-to-refresh on the main screens:
/// import any new Apple Health workouts, re-query the recovery series
/// (HRV/sleep/RHR/bodyweight/today's signals) and recompute the streak
/// nudge + watch snapshot. Readiness recomputes automatically once the
/// observable store updates.
```

- [ ] **Step 11: HomeView.swift — remove call at line 480**

Delete:
```swift
        SyncEngine.shared.requestSync(modelContext)
```

- [ ] **Step 12: InsightsView.swift — remove call at line 493**

Delete:
```swift
                SyncEngine.shared.requestSync(modelContext)
```

- [ ] **Step 13: Delete the Supabase sync files**

```bash
rm ForgeFit/Sync/SyncEngine.swift ForgeFit/Sync/SyncPayloads.swift
rmdir ForgeFit/Sync
```
(Synchronized folder groups mean no pbxproj edit is needed for these.)

- [ ] **Step 14: Delete the ForgeNetwork stub package**

```bash
rm -rf Packages/ForgeNetwork
```

- [ ] **Step 15: Remove ForgeNetwork from project.pbxproj**

`ForgeNetwork` is referenced in exactly two places (package ID `FF0000000000000000000009`), and is **not** linked as a product dependency to any target (verified: no `import ForgeNetwork` anywhere, no `XCSwiftPackageProductDependency` entry).

(a) In the `packageReferences` array, delete line 438:
```
				FF0000000000000000000009 /* XCLocalSwiftPackageReference "Packages/ForgeNetwork" */,
```

(b) In the `XCLocalSwiftPackageReference` section, delete lines 1186–1189:
```
		FF0000000000000000000009 /* XCLocalSwiftPackageReference "Packages/ForgeNetwork" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/ForgeNetwork;
		};
```

- [ ] **Step 16: Delete the supabase backend directory**

```bash
rm -rf supabase
```

- [ ] **Step 17: Verify no stray references remain**

```bash
grep -rn "SyncEngine\|SyncPayloads\|ForgeNetwork\|requestSync\|supabaseURL\|supabaseAnonKey" ForgeFit Packages --include=*.swift
```
Expected: no output. (AccountResetService still lists the Supabase UserDefaults keys — those are removed in Task 3, so this grep is scoped to `.swift` source and will still flag `AccountResetService.swift`; that is expected and handled next. If anything *other* than AccountResetService appears, fix it.)

- [ ] **Step 18: Verify the app builds**

```bash
make build-ios
```
Expected: `BUILD SUCCEEDED`. Also rebuild stubs (ForgeNetwork is gone, so `make build-stubs` must be updated — see Step 19).

- [ ] **Step 19: Update Makefile — drop ForgeNetwork from build-stubs**

`make build-stubs` builds `ForgeNetwork`. Remove that line. In `Makefile`, replace:
```make
build-stubs:
	cd Packages/ForgeHealth && swift build
	cd Packages/ForgeWorkoutSession && swift build
	cd Packages/ForgeNetwork && swift build
	cd Packages/ForgeUI && swift build
```
with:
```make
build-stubs:
	cd Packages/ForgeHealth && swift build
	cd Packages/ForgeWorkoutSession && swift build
	cd Packages/ForgeUI && swift build
```

Then run:
```bash
make build-stubs
```
Expected: all three remaining stub packages build.

- [ ] **Step 20: Commit**

```bash
git add -A
git commit -m "Remove Supabase sync layer (SyncEngine, SyncPayloads, ForgeNetwork, supabase backend)"
```
(If this is not a git repo, skip the commit — the changes are on disk.)

---

### Task 3: Clean Supabase keys from AccountResetService

**Files:**
- Modify: `ForgeFit/Settings/AccountResetService.swift` (lines 87–94 in `clearAppDefaults`)

- [ ] **Step 1: Remove Supabase UserDefaults keys**

In `clearAppDefaults()`, remove these entries from the wipe array:
`cloudSyncEnabled`, `supabaseURL`, `supabaseAnonKey`, `supabaseAccessToken`,
`supabaseUserID`, `syncLastSuccessAt`, `syncLastPushAt`, `syncLastPullAt`.

The array currently spans lines 76–100. After removal it should read:
```swift
    private static func clearAppDefaults() {
        let defaults = UserDefaults.standard
        [
            "didOnboard",
            "initialTab",
            "autoStartRoutine",
            "openSettings",
            "activeFolderID",
            "profileDisplayName",
            "liveSyncEnabled",
            "healthWriteEnabled",
            "weightUnitRaw",
            "showRPEInLogger",
            "reminderWeekdays",
            "reminderMinutes",
            "streakNudgeEnabled",
            PlateInventoryStore.key(for: .lb),
            PlateInventoryStore.key(for: .kg)
        ].forEach(defaults.removeObject(forKey:))
        Fmt.unit = .lb
    }
```
(Keep `liveSyncEnabled` — it is unrelated to Supabase cloud sync; verify before removing. If `liveSyncEnabled` is also Supabase-only, remove it too.)

- [ ] **Step 2: Verify build**

```bash
make build-ios
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ForgeFit/Settings/AccountResetService.swift
git commit -m "Drop Supabase UserDefaults keys from AccountResetService"
```

---

### Task 4: Enable CloudKit sync + entitlements

**Files:**
- Modify: `ForgeFit/ForgeFitApp.swift` (ModelConfiguration)
- Modify: `ForgeFit/ForgeFit.entitlements`

- [ ] **Step 1: Add `cloudKitDatabase: .automatic` to ModelConfiguration**

In `ForgeFit/ForgeFitApp.swift`, replace:
```swift
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
```
with:
```swift
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
```

- [ ] **Step 2: Add iCloud + CloudKit entitlements**

In `ForgeFit/ForgeFit.entitlements`, add (inside the top-level `<dict>`, after the existing HealthKit keys):
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

- [ ] **Step 3: Verify build**

```bash
make build-ios
```
Expected: `BUILD SUCCEEDED`. (Code signing may warn about iCloud capability if the provisioning profile doesn't include it yet — that is the out-of-band Xcode task below. `CODE_SIGNING_ALLOWED=NO` in the Makefile means the build itself won't fail on signing.)

- [ ] **Step 4: Commit**

```bash
git add ForgeFit/ForgeFitApp.swift ForgeFit/ForgeFit.entitlements
git commit -m "Enable SwiftData CloudKit sync (cloudKitDatabase .automatic + entitlements)"
```

---

### Task 5: Full verification

- [ ] **Step 1: Run the full package test suite**

```bash
make test
```
Expected: `test-core`, `test-data`, and `build-stubs` all succeed.

- [ ] **Step 2: Build the iOS app**

```bash
make build-ios
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Build the watch app**

```bash
make build-watch
```
Expected: `BUILD SUCCEEDED` (watch target is unchanged but must still compile against the modified ForgeData).

- [ ] **Step 4: Grep audit — no Supabase remnants**

```bash
grep -rni "supabase\|SyncEngine\|SyncPayloads\|ForgeNetwork\|requestSync" ForgeFit Packages Makefile
```
Expected: no output.

- [ ] **Step 5: Out-of-band handoff (cannot be automated)**

Tell the user to perform in Xcode / Apple Developer portal:
1. Enable the **iCloud** capability for App ID `org.xpetsllc.ForgeFit` (iCloud + CloudKit, container `iCloud.org.xpetsllc.ForgeFit`).
2. In Xcode → Signing & Capabilities, confirm iCloud is attached and let Xcode regenerate the provisioning profile.
3. Flip `ck-environment` to `Production` before release.
4. Manual two-device check: same iCloud account on two devices, create a workout on one, confirm it appears on the other.

---

## Self-Review

- **Spec coverage:** `@Attribute(.unique)` removal → Task 1. CloudKit config → Task 4. Entitlements → Task 4. Sync file deletion → Task 2. ForgeNetwork removal → Task 2. supabase dir deletion → Task 2. Call-site removal → Task 2 (all 24 sites enumerated). AccountResetService cleanup → Task 3. Watch unchanged → confirmed in Task 5 watch build. Out-of-band tasks → Task 5 Step 5. ✅
- **Placeholder scan:** no TBD/TODO; all steps have exact code/commands. ✅
- **Type consistency:** no new types introduced; only removals + one config parameter. ✅
- **Risk:** `liveSyncEnabled` flag in AccountResetService needs a quick check whether it's Supabase-related; flagged inline in Task 3 Step 1.
