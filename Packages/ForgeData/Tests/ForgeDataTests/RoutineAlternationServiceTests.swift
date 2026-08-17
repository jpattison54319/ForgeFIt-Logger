import Foundation
import SwiftData
import Testing
@testable import ForgeData

@MainActor
struct RoutineAlternationServiceTests {
    private enum ForcedSaveFailure: Error {
        case failed
    }

    private let userID = UUID()
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    private func routine(_ name: String) -> RoutineModel {
        RoutineModel(userID: userID, name: name)
    }

    private func workout(
        id: UUID = UUID(),
        routineID: UUID,
        completedAt: Date?,
        deletedAt: Date? = nil
    ) -> WorkoutModel {
        WorkoutModel(
            id: id,
            userID: userID,
            routineID: routineID,
            startedAt: completedAt?.addingTimeInterval(-1_800) ?? base,
            endedAt: completedAt,
            deletedAt: deletedAt
        )
    }

    @Test func ownerStartsThenLatestCompletionMakesTheOtherMemberDue() throws {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            createdAt: base.addingTimeInterval(-1)
        )

        #expect(RoutineAlternationService.dueRoutineID(for: alternation, workouts: []) == owner.id)
        let beforePairing = workout(routineID: partner.id, completedAt: base.addingTimeInterval(-10))
        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [beforePairing]
        ) == owner.id)

        let axFirst = workout(routineID: owner.id, completedAt: base)
        #expect(RoutineAlternationService.dueRoutineID(for: alternation, workouts: [axFirst]) == partner.id)

        let cindy = workout(routineID: partner.id, completedAt: base.addingTimeInterval(100))
        #expect(RoutineAlternationService.dueRoutineID(for: alternation, workouts: [axFirst, cindy]) == owner.id)

        let repeatedAX = workout(routineID: owner.id, completedAt: base.addingTimeInterval(200))
        #expect(RoutineAlternationService.dueRoutineID(for: alternation, workouts: [axFirst, cindy, repeatedAX]) == partner.id)
    }

    @Test func incompleteAndDeletedWorkoutsDoNotAdvanceThePair() throws {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            createdAt: base.addingTimeInterval(-1)
        )
        let incomplete = workout(routineID: owner.id, completedAt: nil)
        let deleted = workout(routineID: owner.id, completedAt: base, deletedAt: base.addingTimeInterval(1))

        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [incomplete, deleted]
        ) == owner.id)
    }

    @Test func unrelatedAndPartnerFirstCompletionsKeepTheOwnerDue() {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let unrelated = routine("Push")
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            createdAt: base.addingTimeInterval(-1)
        )
        let unrelatedCompletion = workout(
            routineID: unrelated.id,
            completedAt: base.addingTimeInterval(10)
        )
        let partnerCompletion = workout(
            routineID: partner.id,
            completedAt: base.addingTimeInterval(20)
        )

        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [unrelatedCompletion]
        ) == owner.id)
        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [unrelatedCompletion, partnerCompletion]
        ) == owner.id)
    }

    @Test func equalCompletionTimesResolveDeterministicallyRegardlessOfFetchOrder() throws {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            createdAt: base.addingTimeInterval(-1)
        )
        let ownerCompletion = workout(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            routineID: owner.id,
            completedAt: base
        )
        let partnerCompletion = workout(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            routineID: partner.id,
            completedAt: base
        )

        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [ownerCompletion, partnerCompletion]
        ) == owner.id)
        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [partnerCompletion, ownerCompletion]
        ) == owner.id)
    }

    @Test func stateRequiresBothMembersToBeLive() throws {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            createdAt: base.addingTimeInterval(-1)
        )

        #expect(RoutineAlternationService.state(
            for: alternation,
            routines: [owner, partner],
            workouts: []
        )?.due.id == owner.id)

        partner.archivedAt = base
        #expect(RoutineAlternationService.state(
            for: alternation,
            routines: [owner, partner],
            workouts: []
        ) == nil)

        partner.archivedAt = nil
        alternation.deletedAt = base
        #expect(RoutineAlternationService.state(
            for: alternation,
            routines: [owner, partner],
            workouts: []
        ) == nil)
    }

    @Test func createEnforcesOnePairPerRoutineAndRemovalAllowsRepairing() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let third = routine("Fran")
        [owner, partner, third].forEach(context.insert)

        let first = try RoutineAlternationService.create(
            owner: owner,
            partner: partner,
            in: context,
            now: base
        )
        #expect(throws: RoutineAlternationService.ServiceError.alreadyPaired) {
            try RoutineAlternationService.create(owner: owner, partner: third, in: context)
        }

        try RoutineAlternationService.remove(first, in: context, now: base.addingTimeInterval(1))
        let replacement = try RoutineAlternationService.create(owner: owner, partner: third, in: context)
        #expect(replacement.ownerRoutineID == owner.id)
        #expect(replacement.partnerRoutineID == third.id)
    }

    @Test func overlappingCloudRecordsResolveNewestWithoutDuplicatingARoutine() throws {
        let owner = routine("AX400")
        let olderPartner = routine("Cindy")
        let newerPartner = routine("Fran")
        let older = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: olderPartner.id,
            updatedAt: base
        )
        let newer = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: newerPartner.id,
            updatedAt: base.addingTimeInterval(1)
        )

        let states = RoutineAlternationService.states(
            alternations: [older, newer],
            routines: [owner, olderPartner, newerPartner],
            workouts: []
        )

        #expect(states.count == 1)
        #expect(states.first?.alternation.id == newer.id)
        #expect(states.first?.partner.id == newerPartner.id)
    }

    @Test func failedCreateAndRemoveLeaveNoPendingAlternationMutation() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let owner = routine("AX400")
        let partner = routine("Cindy")
        [owner, partner].forEach(context.insert)
        try context.save()

        #expect(throws: ForcedSaveFailure.self) {
            try RoutineAlternationService.create(
                owner: owner,
                partner: partner,
                in: context,
                save: { _ in throw ForcedSaveFailure.failed }
            )
        }
        try context.save()
        #expect(try ModelContext(container).fetch(
            FetchDescriptor<RoutineAlternationModel>()
        ).isEmpty)

        let alternation = try RoutineAlternationService.create(
            owner: owner,
            partner: partner,
            in: context
        )
        let originalUpdatedAt = alternation.updatedAt
        #expect(throws: ForcedSaveFailure.self) {
            try RoutineAlternationService.remove(
                alternation,
                in: context,
                save: { _ in throw ForcedSaveFailure.failed }
            )
        }
        #expect(alternation.deletedAt == nil)
        #expect(alternation.updatedAt == originalUpdatedAt)

        try context.save()
        let persisted = try #require(ModelContext(container).fetch(
            FetchDescriptor<RoutineAlternationModel>()
        ).first)
        #expect(persisted.deletedAt == nil)
    }
}
