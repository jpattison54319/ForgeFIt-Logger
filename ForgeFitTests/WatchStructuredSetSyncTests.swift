import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct WatchStructuredSetSyncTests {
    private let userID = ForgeFitDemo.userID

    @Test func myoCommandsPersistActivationMiniSetsAndDerivedVolume() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let setID = UUID()
        let set = SetModel(
            id: setID,
            userID: userID,
            setType: .myoRep,
            weight: 50
        )
        let exercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            microRestSeconds: 30,
            sets: [set]
        )
        context.insert(WorkoutModel(userID: userID, title: "Watch Myo", exercises: [exercise]))
        try context.save()

        let timer = RestTimerController.shared
        timer.skip()
        defer {
            timer.skip()
            timer.onStateChange = nil
        }

        let link = WatchLink()
        link.configure(context: context)
        link.handle(.updateStructuredSet(
            setID: setID,
            update: WatchStructuredSetUpdate(
                progress: WatchStructuredSetProgress(activationReps: 12),
                event: .activation,
                side: 1,
                occurredAt: .now,
                weightKg: 50
            )
        ))

        #expect(set.reps == 12)
        #expect(set.totalVolume == 600)
        #expect(timer.ownerID == setID)
        #expect(timer.isMicro)

        link.handle(.updateStructuredSet(
            setID: setID,
            update: WatchStructuredSetUpdate(
                progress: WatchStructuredSetProgress(
                    activationReps: 12,
                    miniReps: [4, 3]
                ),
                event: .miniSet,
                side: 1,
                occurredAt: .now,
                weightKg: 50
            )
        ))

        #expect(set.miniReps == [4, 3])
        #expect(set.totalVolume == 950)

        let verificationContext = ModelContext(container)
        let descriptor = FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == setID }
        )
        let persisted = try #require(try verificationContext.fetch(descriptor).first)
        #expect(persisted.reps == 12)
        #expect(persisted.miniReps == [4, 3])
        #expect(persisted.totalVolume == 950)
    }

    @Test func amrapCommandsPersistTheSelectedAndElapsedWindow() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let setID = UUID()
        let set = SetModel(id: setID, userID: userID, setType: .amrap)
        let exercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            sets: [set]
        )
        context.insert(WorkoutModel(userID: userID, title: "Watch AMRAP", exercises: [exercise]))
        try context.save()

        let timer = RestTimerController.shared
        timer.skip()
        defer {
            timer.skip()
            timer.onStateChange = nil
        }

        let link = WatchLink()
        link.configure(context: context)
        link.handle(.startSetTimer(
            setID: setID,
            durationSeconds: 60,
            endsAt: .now.addingTimeInterval(60)
        ))

        #expect(set.durationSeconds == 60)
        #expect(timer.ownerID == setID)

        link.handle(.stopSetTimer(setID: setID, elapsedSeconds: 37))

        #expect(set.durationSeconds == 37)
        #expect(!timer.isRunning)

        let verificationContext = ModelContext(container)
        let descriptor = FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == setID }
        )
        let persisted = try #require(try verificationContext.fetch(descriptor).first)
        #expect(persisted.durationSeconds == 37)
    }
}
