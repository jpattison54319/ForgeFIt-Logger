import Foundation
import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

/// AnalyticsFingerprint is the invalidation key for every tab's analytics
/// memos. In-progress workouts must NOT move it (a mid-workout save stamps
/// `updatedAt`/`totalVolume` on the active session; folding that in recomputed
/// full-history analytics in every kept-resident tab per logged set), while
/// finishing, editing a completed workout, or deleting must move it.
@MainActor
struct AnalyticsFingerprintTests {

    @Test func activeWorkoutMutationsDoNotMoveTheFingerprint() throws {
        let (container, context) = try TestStore.make()
        _ = container

        let done = WorkoutModel(userID: ForgeFitDemo.userID, title: "Done", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        done.endedAt = Date(timeIntervalSince1970: 1_700_003_600)
        done.totalVolume = 1000
        let active = WorkoutModel(userID: ForgeFitDemo.userID, title: "Live", startedAt: Date(timeIntervalSince1970: 1_700_100_000))
        context.insert(done)
        context.insert(active)

        let before = AnalyticsFingerprint.of([done, active])

        // The logger's recompute() path: every set edit stamps these.
        active.updatedAt = Date(timeIntervalSince1970: 1_700_100_500)
        active.totalVolume = 480

        #expect(AnalyticsFingerprint.of([done, active]) == before,
                "in-progress mutations must not invalidate completed-history memos")
    }

    @Test func finishingAWorkoutMovesTheFingerprint() throws {
        let (container, context) = try TestStore.make()
        _ = container

        let active = WorkoutModel(userID: ForgeFitDemo.userID, title: "Live", startedAt: Date(timeIntervalSince1970: 1_700_100_000))
        context.insert(active)
        let before = AnalyticsFingerprint.of([active])

        active.endedAt = Date(timeIntervalSince1970: 1_700_103_600)

        #expect(AnalyticsFingerprint.of([active]) != before, "finishing must refresh the memos")
    }

    @Test func editingACompletedWorkoutMovesTheFingerprint() throws {
        let (container, context) = try TestStore.make()
        _ = container

        let done = WorkoutModel(userID: ForgeFitDemo.userID, title: "Done", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        done.endedAt = Date(timeIntervalSince1970: 1_700_003_600)
        done.updatedAt = Date(timeIntervalSince1970: 1_700_003_600)
        context.insert(done)
        let before = AnalyticsFingerprint.of([done])

        done.updatedAt = Date(timeIntervalSince1970: 1_700_200_000)

        #expect(AnalyticsFingerprint.of([done]) != before, "historical edits must refresh the memos")
    }

    @Test func startingAndDeletingWorkoutsMoveTheFingerprint() throws {
        let (container, context) = try TestStore.make()
        _ = container

        let done = WorkoutModel(userID: ForgeFitDemo.userID, title: "Done", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        done.endedAt = Date(timeIntervalSince1970: 1_700_003_600)
        context.insert(done)
        let baseline = AnalyticsFingerprint.of([done])

        // Starting a session changes the live count (once, not per set).
        let active = WorkoutModel(userID: ForgeFitDemo.userID, title: "Live", startedAt: Date(timeIntervalSince1970: 1_700_100_000))
        context.insert(active)
        #expect(AnalyticsFingerprint.of([done, active]) != baseline)

        // Soft-deleting the completed workout changes both counts.
        done.deletedAt = Date(timeIntervalSince1970: 1_700_200_000)
        #expect(AnalyticsFingerprint.of([done, active]) != baseline)
    }
}
