import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// Cardio modality resolution for library exercises: an explicit kind chosen
/// in the creation form wins; otherwise the kind is inferred from
/// name/equipment exactly as before (built-in library, legacy customs).
struct ExerciseModalityTests {
    @Test func storedKindWinsOverInference() {
        let exercise = ExerciseLibraryModel(name: "Morning Run", isCardio: true, cardioKindRaw: "cycle")
        #expect(exercise.resolvedCardioKind == .cycle)
    }

    @Test func nilKindInfersFromNameAndEquipment() {
        #expect(ExerciseLibraryModel(name: "Treadmill Run", isCardio: true).resolvedCardioKind == .run)
        #expect(ExerciseLibraryModel(name: "Row Erg", isCardio: true).resolvedCardioKind == .row)
        #expect(ExerciseLibraryModel(name: "Stair Climber", isCardio: true).resolvedCardioKind == .stair)
    }

    @Test func unknownStoredKindFallsBackToInference() {
        let exercise = ExerciseLibraryModel(name: "Evening Walk", isCardio: true, cardioKindRaw: "zumba")
        #expect(exercise.resolvedCardioKind == .walk)
    }

    /// The cardio default classification: Cardiovascular leads the primaries
    /// for every modality.
    @Test func cardioMusclesLeadWithCardiovascular() {
        for kind in CardioKind.allCases {
            #expect(kind.musclesWorked.first == "cardiovascular")
        }
    }
}
