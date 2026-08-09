import Foundation
import SwiftData
import Testing
@testable import ForgeData

@MainActor
struct RoutineAlternationServiceTests {
    private let userID = UUID()
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    private func routine(_ name: String) -> RoutineModel {
        RoutineModel(userID: userID, name: name)
    }

    private func workout(
        routineID: UUID,
        completedAt: Date?,
        deletedAt: Date? = nil
    ) -> WorkoutModel {
        WorkoutModel(
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
}
