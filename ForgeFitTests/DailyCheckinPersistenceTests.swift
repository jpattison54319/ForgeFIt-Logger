import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct DailyCheckinPersistenceTests {
    private struct InjectedFailure: Error {}

    @Test func failedCreationLeavesNoResidueAndRetryIsExact() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Initial")
        context.insert(routine)
        try context.save()
        routine.name = "First pending edit"

        let attempt = DailyCheckinCommitAttempt(
            id: UUID(),
            userID: ForgeFitDemo.userID,
            day: Date(timeIntervalSince1970: 1_800_000_000),
            tags: ["sore", "stressed"]
        )
        #expect(throws: InjectedFailure.self) {
            try attempt.commit(in: context, save: { _ in throw InjectedFailure() })
        }

        var verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<DailyCheckinModel>()).isEmpty)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Initial")

        // A later caller save cannot hitchhike a failed check-in placeholder.
        try context.save()
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<DailyCheckinModel>()).isEmpty)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "First pending edit")

        routine.name = "Second pending edit"
        _ = try attempt.commit(in: context)
        _ = try attempt.commit(in: context)

        verification = ModelContext(container)
        let checkins = try verification.fetch(FetchDescriptor<DailyCheckinModel>())
        #expect(checkins.count == 1)
        #expect(checkins.first?.id == attempt.id)
        #expect(checkins.first?.tags == ["sore", "stressed"])
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "First pending edit")
    }

    @Test func failedUpdateKeepsCommittedTagsAndUnrelatedEditPending() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let checkin = DailyCheckinModel(
            userID: ForgeFitDemo.userID,
            date: Calendar.current.startOfDay(for: day),
            tags: ["sore"]
        )
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Initial")
        context.insert(checkin)
        context.insert(routine)
        try context.save()
        routine.name = "Pending elsewhere"

        let attempt = DailyCheckinCommitAttempt(
            id: checkin.id,
            userID: ForgeFitDemo.userID,
            day: day,
            tags: ["slept-badly"]
        )
        #expect(throws: InjectedFailure.self) {
            try attempt.commit(in: context, save: { _ in throw InjectedFailure() })
        }

        var verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<DailyCheckinModel>()).first?.tags == ["sore"])
        let committed = try attempt.commit(in: context)
        #expect(committed.tags == ["slept-badly"])
        #expect(checkin.tags == ["slept-badly"])
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<DailyCheckinModel>()).first?.tags == ["slept-badly"])
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Initial")
    }
}
