import CoreLocation
import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// FF-005: completing an outdoor GPS workout must preserve the athlete's
/// manually labeled interval splits while still recording route and distance.
/// Every outdoor/aerobic completion route (phone cardio card, watch
/// `completeCardio`, `WorkoutFinisher`, HealthKit importer, GPX import) funnels
/// into `CardioRouteMath.replaceRoute` → `replaceSplits`, so these tests pin
/// the shared mutation primitive every route shares: manual splits survive and
/// free-form distance-split generation still works.
@MainActor
struct CardioRouteSplitPreservationTests {

    private func makeSession() throws -> (container: ModelContainer, context: ModelContext, session: CardioSessionModel) {
        let (container, context) = try TestStore.make()
        let session = CardioSessionModel(userID: ForgeFitDemo.userID, modality: "run")
        context.insert(session)
        return (container, context, session)
    }

    /// A split the way `IntervalRunner.recordSplit` writes it: labeled and
    /// linked to the session.
    private func manualSplit(_ index: Int, label: String, session: CardioSessionModel) -> CardioSplitModel {
        let split = CardioSplitModel(
            userID: ForgeFitDemo.userID,
            cardioSessionID: session.id,
            index: index,
            distanceMeters: 400,
            durationSeconds: 90 + index * 10,
            paceSecondsPerKm: 225,
            label: label,
            startedAt: session.startedAt.addingTimeInterval(TimeInterval(index * 100)),
            endedAt: session.startedAt.addingTimeInterval(TimeInterval(index * 100 + 90))
        )
        split.cardioSession = session
        return split
    }

    /// ~111 m per 0.001° of latitude, so `count` points sum to a real distance.
    private func insertRoutePoints(_ count: Int, session: CardioSessionModel, context: ModelContext, start: Date = Date()) -> [CardioRoutePointModel] {
        let points = (0..<count).map { i in
            CardioRoutePointModel(
                userID: ForgeFitDemo.userID,
                cardioSessionID: session.id,
                timestamp: start.addingTimeInterval(Double(i) * 60),
                latitude: 37.33 + Double(i) * 0.001,
                longitude: -122.01
            )
        }
        for point in points { context.insert(point) }
        session.routePoints = points
        return points
    }

    /// Accurate fixes the recorder's filter accepts (horizontalAccuracy 0...100).
    private func locations(_ count: Int, start: Date = Date()) -> [CLLocation] {
        (0..<count).map { i in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 37.33 + Double(i) * 0.001, longitude: -122.01),
                altitude: 20,
                horizontalAccuracy: 10,
                verticalAccuracy: 8,
                timestamp: start.addingTimeInterval(Double(i) * 60)
            )
        }
    }

    private func routeDistance(_ session: CardioSessionModel) -> Double {
        let sorted = session.routePoints.sorted { $0.timestamp < $1.timestamp }
        return zip(sorted, sorted.dropFirst())
            .reduce(0) { $0 + CardioRouteMath.distanceMeters($1.0, $1.1) }
    }

    // MARK: - replaceSplits (the mutation all completion routes share)

    @Test func replaceSplitsPreservesManualIntervalSplits() throws {
        let (container, context, session) = try makeSession()
        defer { _ = container }
        session.splits = [
            manualSplit(0, label: "Warm-up", session: session),
            manualSplit(1, label: "Work 1", session: session),
            manualSplit(2, label: "Recover 1", session: session),
        ]
        insertRoutePoints(20, session: session, context: context)
        try context.save()

        CardioRouteMath.replaceSplits(for: session, in: context)

        let kept = session.splits.sorted { $0.index < $1.index }
        #expect(kept.count == 3)
        #expect(kept.map(\.label) == ["Warm-up", "Work 1", "Recover 1"])
        #expect(kept.map(\.durationSeconds) == [90, 100, 110])
        #expect(kept.allSatisfy { $0.label != nil })
        #expect(session.routePoints.count == 20)
        #expect(routeDistance(session) > 1000)
    }

    @Test func replaceSplitsPreservesManualSplitsWithoutARoute() throws {
        let (container, context, session) = try makeSession()
        defer { _ = container }
        session.splits = [
            manualSplit(0, label: "Work 1", session: session),
            manualSplit(1, label: "Recover 1", session: session),
        ]
        try context.save()

        CardioRouteMath.replaceSplits(for: session, in: context)

        let kept = session.splits.sorted { $0.index < $1.index }
        #expect(kept.count == 2)
        #expect(kept.map(\.label) == ["Work 1", "Recover 1"])
    }

    @Test func replaceSplitsStillGeneratesDistanceSplitsForFreeFormRuns() throws {
        let (container, context, session) = try makeSession()
        defer { _ = container }
        insertRoutePoints(20, session: session, context: context)
        try context.save()

        CardioRouteMath.replaceSplits(for: session, in: context)

        let generated = session.splits.sorted { $0.index < $1.index }
        #expect(!generated.isEmpty)
        #expect(generated.allSatisfy { $0.label == nil })
        #expect(generated.allSatisfy { $0.distanceMeters > 0 })
        #expect(session.routePoints.count == 20)
    }

    // MARK: - replaceRoute (the completion route all GPS paths call)

    @Test func replaceRoutePreservesManualSplitsWhileStoringRouteAndDistance() throws {
        let (container, context, session) = try makeSession()
        defer { _ = container }
        session.splits = [
            manualSplit(0, label: "Work 1", session: session),
            manualSplit(1, label: "Recover 1", session: session),
            manualSplit(2, label: "Work 2", session: session),
        ]
        try context.save()

        CardioRouteMath.replaceRoute(for: session, locations: locations(20, start: session.startedAt), in: context)

        let kept = session.splits.sorted { $0.index < $1.index }
        #expect(kept.count == 3)
        #expect(kept.map(\.label) == ["Work 1", "Recover 1", "Work 2"])
        #expect(kept.allSatisfy { $0.label != nil })
        #expect(session.routePoints.count == 20)
        // Route/distance from the same completion is still recorded — additive,
        // not destructive, to the interval structure.
        #expect(routeDistance(session) > 1000)
    }

    @Test func completionWithNoGpsFixesStillKeepsManualSplits() throws {
        let (container, context, session) = try makeSession()
        defer { _ = container }
        session.splits = [
            manualSplit(0, label: "Work 1", session: session),
            manualSplit(1, label: "Recover 1", session: session),
        ]
        try context.save()

        CardioRouteMath.replaceRoute(for: session, locations: [], in: context)

        #expect(session.splits.count == 2)
        #expect(session.splits.allSatisfy { $0.label != nil })
    }

    @Test func replaceRouteStillGeneratesDistanceSplitsForFreeFormRuns() throws {
        let (container, context, session) = try makeSession()
        defer { _ = container }
        try context.save()

        CardioRouteMath.replaceRoute(for: session, locations: locations(20, start: session.startedAt), in: context)

        let generated = session.splits.sorted { $0.index < $1.index }
        #expect(!generated.isEmpty)
        #expect(generated.allSatisfy { $0.label == nil })
        #expect(session.routePoints.count == 20)
        #expect(routeDistance(session) > 1000)
    }

    // MARK: - Auto-detection must never replace stored manual intervals

    @Test func applyDetectedIntervalsLeavesStoredManualSplitsUntouched() throws {
        let (container, context, session) = try makeSession()
        defer { _ = container }
        session.splits = [
            manualSplit(0, label: "Work 1", session: session),
            manualSplit(1, label: "Recover 1", session: session),
        ]
        try context.save()
        // Detection-ready segments with work bouts — the exact input that would
        // replace splits if the invariant were not enforced.
        let segments = [
            CardioSampleSeries.DetectedSegment(kind: .work, startT: 0, endT: 300),
            CardioSampleSeries.DetectedSegment(kind: .recover, startT: 300, endT: 600),
        ]

        CardioSeriesService.applyDetectedIntervals(
            segments,
            to: session,
            series: CardioSampleSeries(samples: [
                .init(t: 0, meters: 0),
                .init(t: 600, meters: 1200),
            ]),
            start: session.startedAt,
            in: context
        )

        let kept = session.splits.sorted { $0.index < $1.index }
        #expect(kept.count == 2)
        #expect(kept.map(\.label) == ["Work 1", "Recover 1"])
        #expect(kept.allSatisfy { !$0.autoDetected })
        #expect(session.intervalsAutoApplied == false)
    }

    @Test func applyDetectedIntervalsStillReplacesDerivedSplitsForFreeFormRuns() throws {
        let (container, context, session) = try makeSession()
        defer { _ = container }
        // A free-form GPS run that completed with plain distance laps — no
        // athlete-authored structure — must still get detected intervals.
        let distanceSplits = (0..<2).map { i in
            let split = CardioSplitModel(
                userID: ForgeFitDemo.userID,
                cardioSessionID: session.id,
                index: i,
                distanceMeters: 1000,
                durationSeconds: 300,
                paceSecondsPerKm: 300,
                startedAt: session.startedAt.addingTimeInterval(TimeInterval(i * 300)),
                endedAt: session.startedAt.addingTimeInterval(TimeInterval(i * 300 + 300))
            )
            split.cardioSession = session
            return split
        }
        session.splits = distanceSplits
        try context.save()
        let segments = [
            CardioSampleSeries.DetectedSegment(kind: .work, startT: 0, endT: 300),
            CardioSampleSeries.DetectedSegment(kind: .recover, startT: 300, endT: 600),
            CardioSampleSeries.DetectedSegment(kind: .work, startT: 600, endT: 900),
        ]

        CardioSeriesService.applyDetectedIntervals(
            segments,
            to: session,
            series: CardioSampleSeries(samples: [
                .init(t: 0, meters: 0),
                .init(t: 600, meters: 1200),
            ]),
            start: session.startedAt,
            in: context
        )

        let applied = session.splits.sorted { $0.index < $1.index }
        #expect(applied.count == 3)
        #expect(applied.allSatisfy { $0.autoDetected })
        #expect(applied.map(\.label) == ["Work 1", "Recover 1", "Work 2"])
        #expect(session.intervalsAutoApplied == true)
    }

    // MARK: - Derived-lap machinery must keep working for free-form runs

    @Test func revertAutoIntervalsStillRestoresDistanceSplits() throws {
        let (container, context, session) = try makeSession()
        defer { _ = container }
        insertRoutePoints(20, session: session, context: context)
        // Simulate the post-detection state: labeled laps flagged autoDetected
        // (the state `applyDetectedIntervals` produces).
        let detected = (0..<2).map { i in
            CardioSplitModel(
                userID: ForgeFitDemo.userID,
                cardioSessionID: session.id,
                index: i,
                distanceMeters: 700,
                durationSeconds: 300,
                paceSecondsPerKm: 430,
                label: i == 0 ? "Work 1" : "Recover 1",
                autoDetected: true,
                startedAt: session.startedAt.addingTimeInterval(TimeInterval(i * 300)),
                endedAt: session.startedAt.addingTimeInterval(TimeInterval(i * 300 + 300))
            )
        }
        detected.forEach { $0.cardioSession = session }
        session.splits = detected
        session.intervalsAutoApplied = true
        try context.save()

        CardioSeriesService.revertAutoIntervals(for: session, in: context)

        let restored = session.splits.sorted { $0.index < $1.index }
        #expect(!restored.isEmpty)
        #expect(restored.allSatisfy { $0.label == nil })
        #expect(session.intervalsAutoApplied == false)
        #expect(session.routePoints.count == 20)
    }
}