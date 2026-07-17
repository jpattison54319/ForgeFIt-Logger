import Foundation
import Testing
@testable import ForgeFit

/// Codec + store behavior for the floating quick-action bubble's preference.
/// Pure value tests — no model container needed; persistence goes through a
/// scratch UserDefaults suite (WarmupRampConfigTests pattern).
struct AppQuickActionTests {

    @Test func idFormatsAreStable() {
        let routineID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(AppQuickAction.emptyWorkout.id == "empty")
        #expect(AppQuickAction.logBodyweight.id == "bodyweight")
        #expect(AppQuickAction.cardio(.run).id == "cardio:run")
        #expect(AppQuickAction.routine(routineID).id == "routine:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(AppQuickAction.yoga("morning-flow").id == "yoga:morning-flow")
    }

    @Test func encodeDecodeRoundTrips() {
        let actions: [AppQuickAction] = [
            .emptyWorkout,
            .logBodyweight,
            .cardio(.row),
            .routine(UUID()),
            .yoga("evening-wind-down"),
        ]
        let decoded = AppQuickActionStore.decodeList(from: AppQuickActionStore.encodeList(actions))
        #expect(decoded == actions)
    }

    /// Unknown ids are dropped, never defaulted — an id written by a newer app
    /// version must not decode into a duplicate fallback action.
    @Test func unknownIDsAreDroppedNotDefaulted() {
        let json = #"["empty","future:thing","bodyweight","cardio:swim"]"#
        let decoded = AppQuickActionStore.decodeList(from: json)
        #expect(decoded == [.emptyWorkout, .logBodyweight])
    }

    @Test func malformedJSONYieldsEmpty() {
        #expect(AppQuickActionStore.decodeList(from: "not json").isEmpty)
        #expect(AppQuickActionStore.decodeList(from: "").isEmpty)
        #expect(AppQuickActionStore.decodeList(from: #"{"nope":1}"#).isEmpty)
    }

    @Test func loadFallsBackToDefaultsWhenAbsentOrEmpty() {
        let suite = "appQuickActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppQuickActionStore.load(defaults: defaults) == AppQuickActionStore.defaultActions)

        defaults.set("[]", forKey: AppQuickActionStore.key)
        #expect(AppQuickActionStore.load(defaults: defaults) == AppQuickActionStore.defaultActions)
    }

    @Test func decodeClampsToMaxCount() {
        let ids = ["empty", "bodyweight", "cardio:run", "cardio:cycle", "cardio:row", "cardio:walk", "yoga:flow"]
        let json = AppQuickActionStore.encodeList(ids.compactMap(AppQuickAction.init(id:)))
        // encodeList doesn't clamp (the editor gates adds); decode is the guard.
        let decoded = AppQuickActionStore.decodeList(from: json)
        #expect(decoded.count == AppQuickActionStore.maxCount)
        #expect(decoded.first == .emptyWorkout)
    }

    @Test func decodeDeduplicatesKeepingFirst() {
        let json = #"["cardio:run","empty","cardio:run","empty"]"#
        let decoded = AppQuickActionStore.decodeList(from: json)
        #expect(decoded == [.cardio(.run), .emptyWorkout])
    }

    @Test func filterDanglingDropsDeadRoutinesAndFlows() {
        let liveRoutine = UUID()
        let deadRoutine = UUID()
        let actions: [AppQuickAction] = [
            .routine(liveRoutine),
            .yoga("live-flow"),
            .routine(deadRoutine),
            .yoga("dead-flow"),
            .emptyWorkout,
        ]
        let filtered = AppQuickActionStore.filterDangling(
            actions,
            validRoutineIDs: [liveRoutine],
            validYogaSlugs: ["live-flow"]
        )
        #expect(filtered == [.routine(liveRoutine), .yoga("live-flow"), .emptyWorkout])
    }

    @Test func saveThenLoadRoundTripsThroughScratchDefaults() {
        let suite = "appQuickActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let actions: [AppQuickAction] = [.logBodyweight, .cardio(.walk), .emptyWorkout]
        AppQuickActionStore.save(actions, defaults: defaults)
        #expect(AppQuickActionStore.load(defaults: defaults) == actions)
        // Stored as a JSON string (not Data) so @AppStorage(String) observes it.
        #expect(defaults.string(forKey: AppQuickActionStore.key) != nil)
    }

    /// The drift guard AppPreferenceKeys exists for: an unregistered key would
    /// be missed by Erase All Data and the iCloud backup.
    @Test func preferenceKeyIsRegisteredForBackup() {
        #expect(AppPreferenceKeys.backedUp.contains(AppQuickActionStore.key))
    }
}
