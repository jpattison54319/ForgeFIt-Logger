import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct FeatureDiscoveryStoreTests {
    @Test func freshStoreEnrollsNowAndPersistsPermanentDismissal() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = FeatureDiscoveryStore(defaults: defaults, now: now)

        #expect(store.enrolledAt == now)
        #expect(store.status(for: .microcycleTracking) == nil)

        store.dismiss(.microcycleTracking, now: now.addingTimeInterval(60))
        let restored = FeatureDiscoveryStore(defaults: defaults, now: now.addingTimeInterval(120))
        #expect(restored.enrolledAt == now)
        #expect(restored.status(for: .microcycleTracking) == .dismissed)
    }

    @Test func adoptionCannotBeWeakenedByAStaleDismissal() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let store = FeatureDiscoveryStore(defaults: defaults, now: now)

        store.markAdopted(.microcycleTracking, now: now)
        store.dismiss(.microcycleTracking, now: now.addingTimeInterval(60))

        #expect(store.status(for: .microcycleTracking) == .adopted)
    }

    @Test func malformedOrFutureStateReenrollsWithoutRetroactiveEligibility() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
        defaults.set("not-json", forKey: FeatureDiscoveryStore.defaultsKey)

        let malformed = FeatureDiscoveryStore(defaults: defaults, now: now)
        #expect(malformed.enrolledAt == now)

        malformed.replaceForTesting(enrolledAt: now.addingTimeInterval(3_600))
        let future = FeatureDiscoveryStore(defaults: defaults, now: now)
        #expect(future.enrolledAt == now)
    }

    @Test func reloadPicksUpAStateRestoredThroughUserDefaults() throws {
        let defaults = try makeDefaults()
        let now = Date(timeIntervalSinceReferenceDate: 4_000_000)
        let live = FeatureDiscoveryStore(defaults: defaults, now: now)
        let backup = FeatureDiscoveryStore(defaults: defaults, now: now)
        backup.dismiss(.microcycleTracking, now: now)

        live.reloadIfChanged(now: now)

        #expect(live.status(for: .microcycleTracking) == .dismissed)
    }

    @Test func discoveryStateIsBackedUpAndResettable() {
        #expect(AppPreferenceKeys.backedUp.contains(FeatureDiscoveryStore.defaultsKey))
        #expect(AppPreferenceKeys.allResettable.contains(FeatureDiscoveryStore.defaultsKey))
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "FeatureDiscoveryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
