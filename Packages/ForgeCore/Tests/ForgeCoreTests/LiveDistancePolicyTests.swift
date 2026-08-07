import Foundation
import Testing
@testable import ForgeCore

struct LiveDistancePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func freshWatchDistanceWinsWhenGPSHasCrossedEarly() {
        let result = LiveDistanceArbiter.preferred(
            watch: .init(meters: 2.93 * 1_609.344, observedAt: now, source: .watch),
            phoneGPS: .init(meters: 3.01 * 1_609.344, observedAt: now, source: .phoneGPS),
            storedMeters: nil,
            at: now
        )

        #expect(result?.source == .watch)
        #expect(result?.meters == 2.93 * 1_609.344)
    }

    @Test func staleWatchFallsBackToPhoneGPS() {
        let result = LiveDistanceArbiter.preferred(
            watch: .init(meters: 1_500, observedAt: now.addingTimeInterval(-16), source: .watch),
            phoneGPS: .init(meters: 1_550, observedAt: now, source: .phoneGPS),
            storedMeters: 1_400,
            at: now
        )

        #expect(result?.source == .phoneGPS)
        #expect(result?.meters == 1_550)
    }

    @Test func storedDistanceIsLastResort() {
        let result = LiveDistanceArbiter.preferred(
            watch: nil,
            phoneGPS: nil,
            storedMeters: 800,
            at: now
        )

        #expect(result == .init(meters: 800, observedAt: now, source: .stored))
    }

    @Test func milestoneTrackerIsMonotonicAndNeverAnnouncesEarly() {
        var tracker = DistanceMilestoneTracker(boundaryMeters: 1_609.344)

        #expect(tracker.consume(distanceMeters: 2.93 * 1_609.344) == [1, 2])
        #expect(tracker.consume(distanceMeters: 2.99 * 1_609.344).isEmpty)
        #expect(tracker.consume(distanceMeters: 3.0 * 1_609.344) == [3])
        #expect(tracker.consume(distanceMeters: 2.98 * 1_609.344).isEmpty)
        #expect(tracker.consume(distanceMeters: 3.1 * 1_609.344).isEmpty)
    }

    @Test func milestoneTrackerHandlesMultiBoundaryGaps() {
        var tracker = DistanceMilestoneTracker(boundaryMeters: 1_000)

        #expect(tracker.consume(distanceMeters: 3_100) == [1, 2, 3])
        #expect(tracker.completedCount == 3)
    }
}
