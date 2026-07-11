import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// Incomplete (ghost/seeded) sets must not look performed in history or share,
/// and must not contribute volume.
struct IncompleteSetHistoryPresentationTests {
    private let userID = ForgeFitDemo.userID

    @Test func incompleteSeededSetDoesNotRenderAsPerformed() {
        let incomplete = SetModel(
            userID: userID,
            position: 0,
            setType: .working,
            reps: 10,
            weight: 80,
            completedAt: nil
        )

        #expect(HistoricalSetPresentation.isCompleted(incomplete) == false)
        #expect(HistoricalSetPresentation.loadText(incomplete, unit: .kg) == "—")
        #expect(HistoricalSetPresentation.outputText(incomplete) == "Not done")
        #expect(HistoricalSetPresentation.shareValue(incomplete, unit: .kg) == "Not done")
    }

    @Test func completedSetStillRendersLoggedValues() {
        let done = SetModel(
            userID: userID,
            position: 0,
            setType: .working,
            reps: 8,
            weight: 100,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        done.recomputeDerivedMetrics()

        #expect(HistoricalSetPresentation.isCompleted(done) == true)
        #expect(HistoricalSetPresentation.loadText(done, unit: .kg) == Fmt.loadUnit(100, unit: .kg))
        #expect(HistoricalSetPresentation.outputText(done) == "8 reps")
        #expect(HistoricalSetPresentation.shareValue(done, unit: .kg).contains("8"))
        #expect(HistoricalSetPresentation.shareValue(done, unit: .kg).contains(Fmt.load(100, unit: .kg)))
    }

    @Test func incompleteSeededSetDoesNotContributeVolume() {
        let incomplete = SetModel(
            userID: userID,
            position: 0,
            reps: 10,
            weight: 50,
            completedAt: nil
        )
        incomplete.recomputeDerivedMetrics()
        // Seeded targets store tonnage on the set even when unfinished.
        #expect((incomplete.totalVolume ?? 0) > 0)

        let we = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: [incomplete])
        let workout = WorkoutModel(userID: userID, title: "Skip Day", exercises: [we])
        workout.recomputeTotalVolume()

        #expect(HistoricalSetPresentation.tonnageContributingToVolume(incomplete) == 0)
        #expect(abs((workout.totalVolume ?? -1) - 0) < 0.0001)
        #expect(abs(HistoricalSetPresentation.workoutVolume(from: [incomplete]) - 0) < 0.0001)
    }

    @Test func completedSetContributesVolume() {
        let done = SetModel(
            userID: userID,
            position: 0,
            reps: 10,
            weight: 50,
            completedAt: Date()
        )
        done.recomputeDerivedMetrics()

        #expect(abs(HistoricalSetPresentation.tonnageContributingToVolume(done) - 500) < 0.0001)
        #expect(abs(HistoricalSetPresentation.workoutVolume(from: [done]) - 500) < 0.0001)
    }
}
