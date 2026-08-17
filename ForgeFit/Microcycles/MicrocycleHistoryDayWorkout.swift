import ForgeCore
import ForgeData
import Foundation

struct MicrocycleHistoryDayWorkout: Identifiable {
    let workout: WorkoutModel
    let assignment: MicrocycleDayAssignment?

    var id: UUID { workout.id }
    var isBackfilled: Bool { assignment != nil }
}
