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

    private func makeContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    @Test func legacyPairWithoutConfigurationJSONKeepsItsOriginalOrderAndJoinDate() {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let createdAt = base.addingTimeInterval(-100)
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            createdAt: createdAt
        )

        #expect(alternation.memberConfigurationJSON == nil)
        let configuration = RoutineAlternationService.configuration(for: alternation)
        #expect(configuration.members.map(\.routineID) == [owner.id, partner.id])
        #expect(configuration.members.map(\.joinedAt) == [createdAt, createdAt])
        #expect(RoutineAlternationService.dueRoutineID(for: alternation, workouts: []) == owner.id)
    }

    @Test func threeMembersAdvanceCyclicallyAndAnOutOfOrderCompletionUsesItsSuccessor() throws {
        let first = routine("A")
        let second = routine("B")
        let third = routine("C")
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: second.id,
            memberRoutineIDs: [first.id, second.id, third.id],
            createdAt: base
        )
        let completedFirst = workout(
            routineID: first.id,
            completedAt: base.addingTimeInterval(10)
        )
        let completedSecond = workout(
            routineID: second.id,
            completedAt: base.addingTimeInterval(20)
        )
        let completedThird = workout(
            routineID: third.id,
            completedAt: base.addingTimeInterval(30)
        )

        #expect(RoutineAlternationService.dueRoutineID(for: alternation, workouts: []) == first.id)
        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [completedFirst]
        ) == second.id)
        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [completedFirst, completedSecond]
        ) == third.id)
        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [completedFirst, completedSecond, completedThird]
        ) == first.id)

        let outOfOrderSecond = workout(
            routineID: second.id,
            completedAt: base.addingTimeInterval(40)
        )
        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [completedFirst, completedSecond, completedThird, outOfOrderSecond]
        ) == third.id)

        let state = try #require(RoutineAlternationService.state(
            for: alternation,
            routines: [third, first, second],
            workouts: [completedFirst, completedSecond, completedThird, outOfOrderSecond]
        ))
        #expect(state.members.map(\.id) == [first.id, second.id, third.id])
        #expect(state.due.id == third.id)
        #expect(state.next(after: third.id)?.id == first.id)
    }

    @Test func newlyAddedMemberIgnoresCompletionsBeforeItsJoinDate() throws {
        let (container, context) = try makeContainer()
        defer { _ = container }
        let first = routine("A")
        let second = routine("B")
        let added = routine("C")
        [first, second, added].forEach(context.insert)
        try context.save()

        let alternation = try RoutineAlternationService.create(
            owner: first,
            partner: second,
            in: context,
            now: base
        )
        let firstCompletion = workout(
            routineID: first.id,
            completedAt: base.addingTimeInterval(20)
        )
        let oldAddedCompletion = workout(
            routineID: added.id,
            completedAt: base.addingTimeInterval(80)
        )
        let joinedAt = base.addingTimeInterval(100)

        try RoutineAlternationService.update(
            alternation,
            orderedMembers: [first, second, added],
            in: context,
            now: joinedAt
        )

        let configuration = RoutineAlternationService.configuration(for: alternation)
        #expect(configuration.members.first { $0.routineID == first.id }?.joinedAt == base)
        #expect(configuration.members.first { $0.routineID == second.id }?.joinedAt == base)
        #expect(configuration.members.first { $0.routineID == added.id }?.joinedAt == joinedAt)
        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [firstCompletion, oldAddedCompletion]
        ) == second.id)

        let newAddedCompletion = workout(
            routineID: added.id,
            completedAt: joinedAt.addingTimeInterval(10)
        )
        #expect(RoutineAlternationService.dueRoutineID(
            for: alternation,
            workouts: [firstCompletion, oldAddedCompletion, newAddedCompletion]
        ) == first.id)
    }

    @Test func reorderPreservesJoinDatesAndPersistsOrderAcrossContexts() throws {
        let (container, context) = try makeContainer()
        let first = routine("A")
        let second = routine("B")
        let third = routine("C")
        [first, second, third].forEach(context.insert)
        try context.save()

        let alternation = try RoutineAlternationService.create(
            owner: first,
            partner: second,
            in: context,
            now: base
        )
        let thirdJoinedAt = base.addingTimeInterval(10)
        try RoutineAlternationService.update(
            alternation,
            orderedMembers: [first, second, third],
            in: context,
            now: thirdJoinedAt
        )
        let beforeReorder = Dictionary(uniqueKeysWithValues:
            RoutineAlternationService.configuration(for: alternation).members.map {
                ($0.routineID, $0.joinedAt)
            }
        )

        try RoutineAlternationService.update(
            alternation,
            orderedMembers: [third, first, second],
            in: context,
            now: base.addingTimeInterval(20)
        )

        #expect(alternation.ownerRoutineID == first.id)
        #expect(alternation.partnerRoutineID == second.id)
        let fresh = ModelContext(container)
        let persisted = try #require(fresh.fetch(
            FetchDescriptor<RoutineAlternationModel>()
        ).first)
        let persistedConfiguration = RoutineAlternationService.configuration(for: persisted)
        #expect(persistedConfiguration.members.map(\.routineID) == [third.id, first.id, second.id])
        #expect(Dictionary(uniqueKeysWithValues: persistedConfiguration.members.map {
            ($0.routineID, $0.joinedAt)
        }) == beforeReorder)
    }

    @Test func detachingTheOwnerReanchorsAThreeMemberCycleAndThenTombstonesAPair() throws {
        let (container, context) = try makeContainer()
        defer { _ = container }
        let first = routine("A")
        let second = routine("B")
        let third = routine("C")
        [first, second, third].forEach(context.insert)
        try context.save()
        let alternation = try RoutineAlternationService.create(
            owner: first,
            members: [first, second, third],
            in: context,
            now: base
        )

        try RoutineAlternationService.detachRoutine(
            first.id,
            in: context,
            now: base.addingTimeInterval(10)
        )

        #expect(alternation.deletedAt == nil)
        #expect(alternation.ownerRoutineID == second.id)
        #expect(alternation.partnerRoutineID == third.id)
        #expect(RoutineAlternationService.configuredMemberRoutineIDs(
            for: alternation
        ) == [second.id, third.id])

        let removedAt = base.addingTimeInterval(20)
        try RoutineAlternationService.detachRoutine(
            second.id,
            in: context,
            now: removedAt
        )
        #expect(alternation.deletedAt == removedAt)
        #expect(alternation.updatedAt == removedAt)
    }

    @Test func failedUpdateRestoresOrderAnchorMirrorAndTimestamps() throws {
        let (container, context) = try makeContainer()
        let first = routine("A")
        let second = routine("B")
        let third = routine("C")
        [first, second, third].forEach(context.insert)
        try context.save()
        let alternation = try RoutineAlternationService.create(
            owner: first,
            partner: second,
            in: context,
            now: base
        )
        let originalJSON = alternation.memberConfigurationJSON
        let originalUpdatedAt = alternation.updatedAt

        #expect(throws: ForcedSaveFailure.self) {
            try RoutineAlternationService.update(
                alternation,
                orderedMembers: [third, first, second],
                in: context,
                now: base.addingTimeInterval(100),
                save: { _ in throw ForcedSaveFailure.failed }
            )
        }

        #expect(alternation.ownerRoutineID == first.id)
        #expect(alternation.partnerRoutineID == second.id)
        #expect(alternation.memberConfigurationJSON == originalJSON)
        #expect(alternation.updatedAt == originalUpdatedAt)
        #expect(alternation.deletedAt == nil)

        try context.save()
        let persisted = try #require(ModelContext(container).fetch(
            FetchDescriptor<RoutineAlternationModel>()
        ).first)
        #expect(RoutineAlternationService.configuredMemberRoutineIDs(
            for: persisted
        ) == [first.id, second.id])
    }

    @Test func newestUnavailableGroupClaimsEveryMemberBeforeOlderGroupsResolve() {
        let first = routine("A")
        let olderPartner = routine("B")
        let sharedThird = routine("C")
        let unavailable = routine("D")
        let otherPartner = routine("E")
        let olderFirst = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: olderPartner.id,
            updatedAt: base
        )
        let olderThird = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: sharedThird.id,
            partnerRoutineID: otherPartner.id,
            updatedAt: base.addingTimeInterval(1)
        )
        let newest = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: sharedThird.id,
            memberRoutineIDs: [first.id, sharedThird.id, unavailable.id],
            updatedAt: base.addingTimeInterval(2)
        )

        let whileUnavailable = RoutineAlternationService.states(
            alternations: [olderFirst, olderThird, newest],
            routines: [first, olderPartner, sharedThird, otherPartner],
            workouts: []
        )
        #expect(whileUnavailable.isEmpty)

        let afterArrival = RoutineAlternationService.states(
            alternations: [olderFirst, olderThird, newest],
            routines: [first, olderPartner, sharedThird, unavailable, otherPartner],
            workouts: []
        )
        #expect(afterArrival.count == 1)
        #expect(afterArrival.first?.alternation.id == newest.id)
        #expect(afterArrival.first?.members.map(\.id) == [first.id, sharedThird.id, unavailable.id])
    }

    @Test func orderedJSONRemainsAuthoritativeWhenTheLegacyPartnerMirrorIsStale() throws {
        let first = routine("A")
        let second = routine("B")
        let third = routine("C")
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: second.id,
            memberRoutineIDs: [first.id, second.id, third.id],
            createdAt: base
        )
        alternation.partnerRoutineID = third.id

        #expect(RoutineAlternationService.configuredMemberRoutineIDs(
            for: alternation
        ) == [first.id, second.id, third.id])
        let state = try #require(RoutineAlternationService.state(
            for: alternation,
            routines: [first, second, third],
            workouts: []
        ))
        #expect(state.owner.id == first.id)
        #expect(state.partner.id == second.id)
    }

    @Test func nonNilMalformedConfigurationDoesNotCollapseToTheLegacyPair() {
        let first = routine("A")
        let second = routine("B")
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: second.id,
            createdAt: base
        )
        alternation.memberConfigurationJSON = "{malformed"

        #expect(RoutineAlternationService.configuration(
            for: alternation
        ).members.isEmpty)
        #expect(RoutineAlternationService.configuredMemberRoutineIDs(
            for: alternation
        ).isEmpty)
        #expect(RoutineAlternationService.state(
            for: alternation,
            routines: [first, second],
            workouts: []
        ) == nil)
        #expect(RoutineAlternationService.alternation(
            containing: first.id,
            in: [alternation]
        ) == nil)
    }

    @Test func futureConfigurationClaimsEveryMemberButCannotRunOrBeEdited() throws {
        let (container, context) = try makeContainer()
        defer { _ = container }
        let first = routine("A")
        let second = routine("B")
        let third = routine("C")
        let stalePartner = routine("D")
        let proposedPartner = routine("E")
        [first, second, third, stalePartner, proposedPartner].forEach(context.insert)
        let stale = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: third.id,
            partnerRoutineID: stalePartner.id,
            createdAt: base,
            updatedAt: base
        )
        let future = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: second.id,
            createdAt: base.addingTimeInterval(1),
            updatedAt: base.addingTimeInterval(1)
        )
        future.memberConfigurationJSON = RoutineAlternationConfiguration(
            version: RoutineAlternationConfiguration.currentVersion + 1,
            members: [first.id, second.id, third.id].map {
                .init(routineID: $0, joinedAt: base.addingTimeInterval(1))
            }
        ).encoded()
        context.insert(stale)
        context.insert(future)
        try context.save()

        #expect(RoutineAlternationService.configuredMemberRoutineIDs(
            for: future
        ) == [first.id, second.id, third.id])
        #expect(RoutineAlternationService.resolved([stale, future]).map(\.id) == [future.id])
        #expect(RoutineAlternationService.states(
            alternations: [stale, future],
            routines: [first, second, third, stalePartner, proposedPartner],
            workouts: []
        ).isEmpty)
        #expect(RoutineAlternationService.alternation(
            containing: third.id,
            in: [stale, future]
        ) == nil)
        #expect(throws: RoutineAlternationService.ServiceError.invalidConfiguration) {
            try RoutineAlternationService.update(
                future,
                orderedMembers: [first, second, third],
                in: context
            )
        }
        #expect(throws: RoutineAlternationService.ServiceError.alreadyPaired) {
            try RoutineAlternationService.create(
                owner: third,
                partner: proposedPartner,
                in: context
            )
        }
        #expect(future.deletedAt == nil)
        #expect(stale.deletedAt == nil)
    }

    @Test func updatingTheNewestCycleTombstonesAnOlderOverlapInTheSameSave() throws {
        let (container, context) = try makeContainer()
        let first = routine("A")
        let second = routine("B")
        let third = routine("C")
        [first, second, third].forEach(context.insert)
        let older = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: third.id,
            createdAt: base,
            updatedAt: base
        )
        let newer = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: second.id,
            memberRoutineIDs: [first.id, second.id],
            createdAt: base.addingTimeInterval(1),
            updatedAt: base.addingTimeInterval(1)
        )
        context.insert(older)
        context.insert(newer)
        try context.save()
        let repairedAt = base.addingTimeInterval(2)

        try RoutineAlternationService.update(
            newer,
            orderedMembers: [third, first, second],
            in: context,
            now: repairedAt
        )

        #expect(older.deletedAt == repairedAt)
        #expect(RoutineAlternationService.configuredMemberRoutineIDs(
            for: newer
        ) == [third.id, first.id, second.id])
        let fresh = ModelContext(container)
        let persisted = try fresh.fetch(FetchDescriptor<RoutineAlternationModel>())
        let states = RoutineAlternationService.states(
            alternations: persisted,
            routines: try fresh.fetch(FetchDescriptor<RoutineModel>()),
            workouts: []
        )
        #expect(states.count == 1)
        #expect(states.first?.alternation.id == newer.id)
    }

    @Test func stoppingTheNewestCycleAlsoTombstonesAnOlderOverlap() throws {
        let (container, context) = try makeContainer()
        let first = routine("A")
        let second = routine("B")
        let third = routine("C")
        [first, second, third].forEach(context.insert)
        let older = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: second.id,
            partnerRoutineID: third.id,
            createdAt: base,
            updatedAt: base
        )
        let newer = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: second.id,
            createdAt: base.addingTimeInterval(1),
            updatedAt: base.addingTimeInterval(1)
        )
        context.insert(older)
        context.insert(newer)
        try context.save()
        let removedAt = base.addingTimeInterval(2)

        #expect(RoutineAlternationService.alternation(
            containing: third.id,
            in: [older, newer]
        ) == nil)
        try RoutineAlternationService.remove(newer, in: context, now: removedAt)

        #expect(newer.deletedAt == removedAt)
        #expect(older.deletedAt == removedAt)
        let fresh = ModelContext(container)
        #expect(RoutineAlternationService.states(
            alternations: try fresh.fetch(FetchDescriptor<RoutineAlternationModel>()),
            routines: try fresh.fetch(FetchDescriptor<RoutineModel>()),
            workouts: []
        ).isEmpty)
    }

    @Test func detachingFromAResolvedWinnerTombstonesATransitiveBridgeWithoutStealing() throws {
        let (container, context) = try makeContainer()
        let deleted = routine("A")
        let firstPartner = routine("B")
        let secondPartner = routine("C")
        let bridgeOnly = routine("D")
        let otherOwner = routine("E")
        let otherPartner = routine("F")
        [deleted, firstPartner, secondPartner, bridgeOnly, otherOwner, otherPartner]
            .forEach(context.insert)
        let bridge = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: deleted.id,
            partnerRoutineID: bridgeOnly.id,
            memberRoutineIDs: [deleted.id, bridgeOnly.id, otherOwner.id],
            createdAt: base,
            updatedAt: base
        )
        let otherWinner = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: otherOwner.id,
            partnerRoutineID: otherPartner.id,
            memberRoutineIDs: [otherOwner.id, otherPartner.id],
            createdAt: base.addingTimeInterval(1),
            updatedAt: base.addingTimeInterval(1)
        )
        let affectedWinner = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: deleted.id,
            partnerRoutineID: firstPartner.id,
            memberRoutineIDs: [deleted.id, firstPartner.id, secondPartner.id],
            createdAt: base.addingTimeInterval(2),
            updatedAt: base.addingTimeInterval(2)
        )
        context.insert(bridge)
        context.insert(otherWinner)
        context.insert(affectedWinner)
        try context.save()
        let deletedAt = base.addingTimeInterval(3)

        #expect(Set(RoutineAlternationService.resolved(
            [bridge, otherWinner, affectedWinner]
        ).map(\.id)) == Set([affectedWinner.id, otherWinner.id]))
        try RoutineAlternationService.detachRoutine(
            deleted.id,
            in: context,
            now: deletedAt
        )

        #expect(bridge.deletedAt == deletedAt)
        #expect(RoutineAlternationService.configuredMemberRoutineIDs(
            for: affectedWinner
        ) == [firstPartner.id, secondPartner.id])
        #expect(affectedWinner.ownerRoutineID == firstPartner.id)
        #expect(otherWinner.deletedAt == nil)
        #expect(otherWinner.updatedAt == base.addingTimeInterval(1))

        let fresh = ModelContext(container)
        let states = RoutineAlternationService.states(
            alternations: try fresh.fetch(FetchDescriptor<RoutineAlternationModel>()),
            routines: try fresh.fetch(FetchDescriptor<RoutineModel>()),
            workouts: []
        )
        #expect(Set(states.map(\.alternation.id)) == Set([
            affectedWinner.id,
            otherWinner.id
        ]))
    }

    @Test func creatingFromAFreeMemberTombstonesItsHiddenStaleOverlap() throws {
        let (container, context) = try makeContainer()
        let winnerOwner = routine("A")
        let winnerPartner = routine("B")
        let freeMember = routine("C")
        let newPartner = routine("D")
        [winnerOwner, winnerPartner, freeMember, newPartner].forEach(context.insert)
        let stale = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: winnerOwner.id,
            partnerRoutineID: freeMember.id,
            createdAt: base,
            updatedAt: base
        )
        let winner = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: winnerOwner.id,
            partnerRoutineID: winnerPartner.id,
            createdAt: base.addingTimeInterval(1),
            updatedAt: base.addingTimeInterval(1)
        )
        context.insert(stale)
        context.insert(winner)
        try context.save()
        let createdAt = base.addingTimeInterval(2)

        #expect(RoutineAlternationService.alternation(
            containing: freeMember.id,
            in: [stale, winner]
        ) == nil)
        let created = try RoutineAlternationService.create(
            owner: freeMember,
            partner: newPartner,
            in: context,
            now: createdAt
        )

        #expect(stale.deletedAt == createdAt)
        #expect(stale.updatedAt == createdAt)
        #expect(created.deletedAt == nil)
        let fresh = ModelContext(container)
        let persistedAlternations = try fresh.fetch(
            FetchDescriptor<RoutineAlternationModel>()
        )
        let persistedRoutines = try fresh.fetch(FetchDescriptor<RoutineModel>())
        let states = RoutineAlternationService.states(
            alternations: persistedAlternations,
            routines: persistedRoutines,
            workouts: []
        )
        #expect(Set(states.map(\.alternation.id)) == Set([winner.id, created.id]))
    }

    @Test func createStillRejectsOverlapWithAResolvedWinnerWithoutMutatingLosers() throws {
        let (container, context) = try makeContainer()
        defer { _ = container }
        let winnerOwner = routine("A")
        let winnerPartner = routine("B")
        let stalePartner = routine("C")
        let proposedPartner = routine("D")
        [winnerOwner, winnerPartner, stalePartner, proposedPartner].forEach(context.insert)
        let stale = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: winnerOwner.id,
            partnerRoutineID: stalePartner.id,
            createdAt: base,
            updatedAt: base
        )
        let winner = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: winnerOwner.id,
            partnerRoutineID: winnerPartner.id,
            createdAt: base.addingTimeInterval(1),
            updatedAt: base.addingTimeInterval(1)
        )
        context.insert(stale)
        context.insert(winner)
        try context.save()

        #expect(throws: RoutineAlternationService.ServiceError.alreadyPaired) {
            try RoutineAlternationService.create(
                owner: winnerOwner,
                partner: proposedPartner,
                in: context,
                now: base.addingTimeInterval(2)
            )
        }

        #expect(stale.deletedAt == nil)
        #expect(stale.updatedAt == base)
        #expect(winner.deletedAt == nil)
        #expect(try context.fetch(FetchDescriptor<RoutineAlternationModel>()).count == 2)
    }

    @Test func failedCreateRestoresAHiddenStaleOverlapAndLeavesNoNewCycle() throws {
        let (container, context) = try makeContainer()
        let winnerOwner = routine("A")
        let winnerPartner = routine("B")
        let freeMember = routine("C")
        let newPartner = routine("D")
        [winnerOwner, winnerPartner, freeMember, newPartner].forEach(context.insert)
        let stale = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: winnerOwner.id,
            partnerRoutineID: freeMember.id,
            createdAt: base,
            updatedAt: base
        )
        let winner = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: winnerOwner.id,
            partnerRoutineID: winnerPartner.id,
            createdAt: base.addingTimeInterval(1),
            updatedAt: base.addingTimeInterval(1)
        )
        context.insert(stale)
        context.insert(winner)
        try context.save()

        #expect(throws: ForcedSaveFailure.self) {
            try RoutineAlternationService.create(
                owner: freeMember,
                partner: newPartner,
                in: context,
                now: base.addingTimeInterval(2),
                save: { _ in throw ForcedSaveFailure.failed }
            )
        }

        #expect(stale.deletedAt == nil)
        #expect(stale.updatedAt == base)
        try context.save()
        let persisted = try ModelContext(container).fetch(
            FetchDescriptor<RoutineAlternationModel>()
        )
        #expect(Set(persisted.map(\.id)) == Set([stale.id, winner.id]))
        #expect(persisted.first(where: { $0.id == stale.id })?.deletedAt == nil)
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
