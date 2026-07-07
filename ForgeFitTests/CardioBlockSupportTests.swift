import Foundation
import Testing
@testable import ForgeFit

/// The pure logic behind cardio disclosure cards in mixed workouts: when a
/// workout counts as mixed, the compact card's title/subtitle text, and
/// slicing the whole-workout HR series down to one block's window.
struct CardioBlockSupportTests {
    // MARK: compactTitle

    @Test func titleJoinsDurationAndName() {
        #expect(CardioBlockSupport.compactTitle(durationSeconds: 1_080, name: "Run") == "18min Run")
        #expect(CardioBlockSupport.compactTitle(durationSeconds: 3_900, name: "Run") == "1h 5min Run")
    }

    @Test func titleFallsBackToNameWithoutDuration() {
        #expect(CardioBlockSupport.compactTitle(durationSeconds: nil, name: "Run") == "Run")
        #expect(CardioBlockSupport.compactTitle(durationSeconds: 0, name: "Bike") == "Bike")
    }

    // MARK: compactSubtitle

    @Test func subtitleJoinsAvailablePartsInOrder() {
        let full = CardioBlockSupport.compactSubtitle(distance: "5.2 km", avgHR: 152, calories: 240.7, effort: 7)
        #expect(full == "5.2 km · 152 bpm · 240 kcal · 7/10")

        let partial = CardioBlockSupport.compactSubtitle(distance: nil, avgHR: 138, calories: nil, effort: nil)
        #expect(partial == "138 bpm")
    }

    @Test func subtitleIsNilWhenNothingIsAvailable() {
        #expect(CardioBlockSupport.compactSubtitle(distance: nil, avgHR: nil, calories: nil, effort: nil) == nil)
    }

    // MARK: isMixedWorkout

    @Test func strengthPlusLinkedCardioIsMixed() {
        let strength = UUID(), cardioExercise = UUID()
        #expect(CardioBlockSupport.isMixedWorkout(
            exerciseIDs: [strength, cardioExercise],
            cardioLinkedExerciseIDs: [cardioExercise],
            cardioSessionCount: 1))
    }

    @Test func cardioOnlyIsNotMixed() {
        let cardioExercise = UUID()
        #expect(!CardioBlockSupport.isMixedWorkout(
            exerciseIDs: [cardioExercise],
            cardioLinkedExerciseIDs: [cardioExercise],
            cardioSessionCount: 1))
    }

    @Test func strengthOnlyIsNotMixed() {
        #expect(!CardioBlockSupport.isMixedWorkout(
            exerciseIDs: [UUID(), UUID()],
            cardioLinkedExerciseIDs: [],
            cardioSessionCount: 0))
    }

    /// Legacy whole-workout cardio sessions aren't linked to an exercise but
    /// still make a strength workout mixed.
    @Test func strengthPlusLegacyUnlinkedCardioIsMixed() {
        #expect(CardioBlockSupport.isMixedWorkout(
            exerciseIDs: [UUID()],
            cardioLinkedExerciseIDs: [],
            cardioSessionCount: 1))
    }

    @Test func emptyWorkoutIsNotMixed() {
        #expect(!CardioBlockSupport.isMixedWorkout(
            exerciseIDs: [], cardioLinkedExerciseIDs: [], cardioSessionCount: 0))
        // Legacy cardio with no strength at all is cardio-only, not mixed.
        #expect(!CardioBlockSupport.isMixedWorkout(
            exerciseIDs: [], cardioLinkedExerciseIDs: [], cardioSessionCount: 1))
    }

    // MARK: blockWindow

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func windowPrefersLiveStartAndRecordedEnd() {
        let live = base.addingTimeInterval(30)
        let end = base.addingTimeInterval(1_110)
        let window = CardioBlockSupport.blockWindow(
            startedAt: base, liveStartedAt: live, endedAt: end, durationSeconds: 900)
        #expect(window == live...end)
    }

    @Test func windowFallsBackToDurationWhenNoRecordedEnd() {
        let window = CardioBlockSupport.blockWindow(
            startedAt: base, liveStartedAt: nil, endedAt: nil, durationSeconds: 1_080)
        #expect(window == base...base.addingTimeInterval(1_080))
    }

    @Test func windowIsNilWhenNoEndIsDerivable() {
        #expect(CardioBlockSupport.blockWindow(
            startedAt: base, liveStartedAt: nil, endedAt: nil, durationSeconds: nil) == nil)
        #expect(CardioBlockSupport.blockWindow(
            startedAt: base, liveStartedAt: nil, endedAt: nil, durationSeconds: 0) == nil)
        // A recorded end before the start (clock skew) yields no window.
        #expect(CardioBlockSupport.blockWindow(
            startedAt: base, liveStartedAt: nil, endedAt: base.addingTimeInterval(-60), durationSeconds: nil) == nil)
    }

    // MARK: hrSlice

    @Test func sliceKeepsOnlyInWindowSamples() {
        let samples: [(date: Date, bpm: Int)] = (0..<10).map {
            (date: base.addingTimeInterval(Double($0) * 60), bpm: 120 + $0)
        }
        let window = base.addingTimeInterval(120)...base.addingTimeInterval(300)
        let slice = CardioBlockSupport.hrSlice(samples: samples, window: window)
        #expect(slice.map(\.bpm) == [122, 123, 124, 125])
    }

    @Test func sliceIsEmptyForDisjointWindow() {
        let samples = [(date: base, bpm: 130)]
        let window = base.addingTimeInterval(3_600)...base.addingTimeInterval(7_200)
        #expect(CardioBlockSupport.hrSlice(samples: samples, window: window).isEmpty)
    }
}
