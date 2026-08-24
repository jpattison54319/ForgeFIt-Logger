import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@Suite("Workout finalization status")
struct WorkoutFinalizationPresentationTests {
    private let end = Date(timeIntervalSince1970: 10_000)

    @Test("A recent expected heart-rate series stays finalizing until its tail arrives")
    func recentHeartRateCoverage() {
        let now = end.addingTimeInterval(20)

        #expect(WorkoutFinalizationPresentation.shouldShow(
            endedAt: end,
            now: now,
            expectsHeartRate: true,
            heartRateLoaded: false,
            latestHeartRateSampleAt: nil,
            hasPendingConditioningResult: false
        ))
        #expect(WorkoutFinalizationPresentation.shouldShow(
            endedAt: end,
            now: now,
            expectsHeartRate: true,
            heartRateLoaded: true,
            latestHeartRateSampleAt: end.addingTimeInterval(-10 * 60),
            hasPendingConditioningResult: false
        ))
        #expect(!WorkoutFinalizationPresentation.shouldShow(
            endedAt: end,
            now: now,
            expectsHeartRate: true,
            heartRateLoaded: true,
            latestHeartRateSampleAt: end.addingTimeInterval(-30),
            hasPendingConditioningResult: false
        ))
    }

    @Test("A recent completed conditioning run without its result is finalizing")
    func pendingConditioningResult() {
        #expect(WorkoutFinalizationPresentation.shouldShow(
            endedAt: end,
            now: end.addingTimeInterval(60),
            expectsHeartRate: false,
            heartRateLoaded: true,
            latestHeartRateSampleAt: nil,
            hasPendingConditioningResult: true
        ))
    }

    @Test("Any recent workout can expose active background enrichment")
    func appWideEnrichment() {
        #expect(WorkoutFinalizationPresentation.shouldShow(
            endedAt: end,
            now: end.addingTimeInterval(60),
            isEnrichmentPending: true,
            expectsHeartRate: false,
            heartRateLoaded: true,
            latestHeartRateSampleAt: nil,
            hasPendingConditioningResult: false
        ))
        #expect(!WorkoutFinalizationPresentation.shouldShow(
            endedAt: end,
            now: end.addingTimeInterval(WorkoutFinalizationPresentation.recentWorkoutWindow + 1),
            isEnrichmentPending: true,
            expectsHeartRate: false,
            heartRateLoaded: true,
            latestHeartRateSampleAt: nil,
            hasPendingConditioningResult: false
        ))
        #expect(WorkoutFinalizationPresentation.savedCardExpiration(endedAt: end)
            == end.addingTimeInterval(WorkoutFinalizationPresentation.recentWorkoutWindow))
    }

    @Test("The saved-card status is bounded and only replaces a real pending result")
    @MainActor
    func savedCardStatus() {
        let pendingBlock = WorkoutBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .conditioning,
            planSnapshotJSON: ConditioningPlan(sections: [
                ConditioningSection(name: "AX400", format: .forTime)
            ]).encodedJSON(),
            progressJSON: ConditioningProgress(status: .completed).encodedJSON()
        )
        let pending = WorkoutModel(
            userID: ForgeFitDemo.userID,
            startedAt: end.addingTimeInterval(-600),
            endedAt: end,
            blocks: [pendingBlock]
        )
        let settledBlock = WorkoutBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .conditioning,
            planSnapshotJSON: pendingBlock.planSnapshotJSON,
            progressJSON: pendingBlock.progressJSON,
            resultJSON: ConditioningResult(sectionResults: []).encodedJSON()
        )
        let settled = WorkoutModel(
            userID: ForgeFitDemo.userID,
            startedAt: end.addingTimeInterval(-600),
            endedAt: end,
            blocks: [settledBlock]
        )

        #expect(WorkoutFinalizationPresentation.shouldShowOnSavedCard(
            for: pending,
            now: end.addingTimeInterval(30)
        ))
        #expect(!WorkoutFinalizationPresentation.shouldShowOnSavedCard(
            for: settled,
            now: end.addingTimeInterval(30)
        ))
        #expect(!WorkoutFinalizationPresentation.shouldShowOnSavedCard(
            for: pending,
            now: end.addingTimeInterval(WorkoutFinalizationPresentation.recentWorkoutWindow + 1)
        ))
    }

    @Test("The status never persists on settled or old workouts")
    func boundedFallbacks() {
        #expect(!WorkoutFinalizationPresentation.shouldShow(
            endedAt: end,
            now: end.addingTimeInterval(60),
            expectsHeartRate: false,
            heartRateLoaded: true,
            latestHeartRateSampleAt: nil,
            hasPendingConditioningResult: false
        ))
        #expect(!WorkoutFinalizationPresentation.shouldShow(
            endedAt: end,
            now: end.addingTimeInterval(WorkoutFinalizationPresentation.recentWorkoutWindow + 1),
            expectsHeartRate: true,
            heartRateLoaded: false,
            latestHeartRateSampleAt: nil,
            hasPendingConditioningResult: true
        ))
        #expect(!WorkoutFinalizationPresentation.shouldShow(
            endedAt: nil,
            now: end,
            expectsHeartRate: true,
            heartRateLoaded: false,
            latestHeartRateSampleAt: nil,
            hasPendingConditioningResult: true
        ))
    }
}
