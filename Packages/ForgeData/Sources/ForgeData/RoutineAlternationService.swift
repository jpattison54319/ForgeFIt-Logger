import Foundation
import SwiftData

/// Deterministic membership and next-routine resolution for ordered routine
/// cycles. Configuration syncs as plan data; the due member is derived from
/// completed local workouts so no mutable cursor can drift from history.
@MainActor
public enum RoutineAlternationService {
    public enum ServiceError: LocalizedError, Equatable {
        case sameRoutine
        case tooFewMembers
        case duplicateMember
        case unavailableRoutine
        case differentUsers
        case alreadyPaired
        case invalidConfiguration
        case cycleChanged

        public var errorDescription: String? {
            switch self {
            case .sameRoutine: "Choose a different routine."
            case .tooFewMembers: "Choose at least two routines."
            case .duplicateMember: "Each routine can appear only once in a cycle."
            case .unavailableRoutine: "Every routine in the cycle must be available."
            case .differentUsers: "Every routine in the cycle must belong to the same library."
            case .alreadyPaired: "One of these routines already belongs to another alternating cycle."
            case .invalidConfiguration: "The alternating cycle couldn't be saved."
            case .cycleChanged: "This alternating cycle changed on another device. Close it and try again."
            }
        }
    }

    public struct State {
        public let alternation: RoutineAlternationModel
        /// Stable library/microcycle slot anchor. It does not define cycle
        /// order once a user reorders the members.
        public let owner: RoutineModel
        /// Every live member in configured cyclic order.
        public let members: [RoutineModel]
        public let due: RoutineModel

        public var memberIDs: Set<UUID> { Set(members.map(\.id)) }

        /// Compatibility projection for pair-shaped callers. New code should
        /// use `members` or `next(after:)`.
        public var partner: RoutineModel {
            next(after: owner.id) ?? members.first(where: { $0.id != owner.id }) ?? owner
        }

        /// Compatibility projection that now means the cyclic successor of
        /// the due member.
        public var other: RoutineModel { next(after: due.id) ?? owner }

        public init(
            alternation: RoutineAlternationModel,
            owner: RoutineModel,
            members: [RoutineModel],
            due: RoutineModel
        ) {
            self.alternation = alternation
            self.owner = owner
            self.members = members
            self.due = due
        }

        /// Retains source compatibility for pair-focused fixtures and tests.
        public init(
            alternation: RoutineAlternationModel,
            owner: RoutineModel,
            partner: RoutineModel,
            due: RoutineModel
        ) {
            self.init(
                alternation: alternation,
                owner: owner,
                members: [owner, partner],
                due: due
            )
        }

        public func next(after routineID: UUID) -> RoutineModel? {
            guard members.count >= 2,
                  let index = members.firstIndex(where: { $0.id == routineID }) else {
                return nil
            }
            return members[(index + 1) % members.count]
        }

        public func position(of routineID: UUID) -> Int? {
            members.firstIndex(where: { $0.id == routineID })
        }

        /// Compact copy for existing surfaces that say “Alternates with …”.
        public func memberSummary(excluding routineID: UUID) -> String? {
            let others = members.filter { $0.id != routineID }
            guard let first = others.first else { return nil }
            if others.count == 1 { return first.name }
            return "\(first.name) + \(others.count - 1) more"
        }
    }

    private struct Completion {
        let routineID: UUID
        let endedAt: Date
        let workoutID: UUID
    }

    private struct ConfigurationRead {
        let configuration: RoutineAlternationConfiguration
        /// IDs recovered from the atomic payload even when this build cannot
        /// safely execute its version. They remain claimed so older scalar
        /// mirrors cannot free only part of a newer cycle.
        let structuralMemberIDs: [UUID]
        let isSupported: Bool
    }

    public static func live(_ alternations: [RoutineAlternationModel]) -> [RoutineAlternationModel] {
        alternations
            .filter { $0.deletedAt == nil }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
    }

    /// Reads ordered membership. Only a nil JSON value is a legacy pair;
    /// malformed or semantically invalid payloads return no executable
    /// members, while structurally valid future payloads remain inspectable.
    public static func configuration(
        for alternation: RoutineAlternationModel
    ) -> RoutineAlternationConfiguration {
        configurationRead(for: alternation).configuration
    }

    public static func configuredMemberRoutineIDs(
        for alternation: RoutineAlternationModel
    ) -> [UUID] {
        configurationRead(for: alternation).structuralMemberIDs
    }

    /// Resolves structural CloudKit overlaps newest-first without requiring
    /// every referenced routine to have arrived. Older overlapping records
    /// remain suppressed until an explicit edit repairs them atomically.
    public static func resolved(
        _ alternations: [RoutineAlternationModel]
    ) -> [RoutineAlternationModel] {
        var claimedRoutineIDs: Set<UUID> = []
        var result: [RoutineAlternationModel] = []
        for alternation in live(alternations) {
            let configuredIDs = Set(configuredMemberRoutineIDs(for: alternation))
            guard !configuredIDs.isEmpty,
                  configuredIDs.isDisjoint(with: claimedRoutineIDs) else { continue }
            claimedRoutineIDs.formUnion(configuredIDs)
            result.append(alternation)
        }
        return result
    }

    public static func alternation(
        containing routineID: UUID,
        in alternations: [RoutineAlternationModel]
    ) -> RoutineAlternationModel? {
        resolved(alternations).first {
            let read = configurationRead(for: $0)
            return read.isSupported && read.structuralMemberIDs.contains(routineID)
        }
    }

    public static func state(
        for alternation: RoutineAlternationModel,
        routines: [RoutineModel],
        workouts: [WorkoutModel]
    ) -> State? {
        let read = configurationRead(for: alternation)
        guard read.isSupported else { return nil }
        let liveRoutinesByID = Dictionary(
            routines.lazy.filter(isLive).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return state(
            for: alternation,
            configuration: read.configuration,
            liveRoutinesByID: liveRoutinesByID,
            latestCompletions: latestCompletions(in: workouts)
        )
    }

    public static func state(
        containing routineID: UUID,
        alternations: [RoutineAlternationModel],
        routines: [RoutineModel],
        workouts: [WorkoutModel]
    ) -> State? {
        states(alternations: alternations, routines: routines, workouts: workouts).first {
            $0.memberIDs.contains(routineID)
        }
    }

    /// Resolves CloudKit overlaps newest-first. A newer structural record
    /// claims all configured IDs even if a routine has not arrived yet, so an
    /// older overlapping cycle cannot temporarily resurrect.
    public static func states(
        alternations: [RoutineAlternationModel],
        routines: [RoutineModel],
        workouts: [WorkoutModel]
    ) -> [State] {
        var claimedRoutineIDs: Set<UUID> = []
        let completions = latestCompletions(in: workouts)
        let liveRoutinesByID = Dictionary(
            routines.lazy.filter(isLive).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [State] = []
        for alternation in live(alternations) {
            let read = configurationRead(for: alternation)
            let configuredIDs = Set(read.structuralMemberIDs)
            guard !configuredIDs.isEmpty,
                  configuredIDs.isDisjoint(with: claimedRoutineIDs) else { continue }
            claimedRoutineIDs.formUnion(configuredIDs)
            guard read.isSupported else { continue }
            if let state = state(
                for: alternation,
                configuration: read.configuration,
                liveRoutinesByID: liveRoutinesByID,
                latestCompletions: completions
            ) {
                result.append(state)
            }
        }
        return result
    }

    public static func dueRoutineID(
        for alternation: RoutineAlternationModel,
        workouts: [WorkoutModel]
    ) -> UUID {
        let read = configurationRead(for: alternation)
        guard read.isSupported else { return alternation.ownerRoutineID }
        return dueRoutineID(
            for: read.configuration,
            latestCompletions: latestCompletions(in: workouts)
        ) ?? alternation.ownerRoutineID
    }

    @discardableResult
    public static func create(
        owner: RoutineModel,
        partner: RoutineModel,
        in context: ModelContext,
        now: Date = .now,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> RoutineAlternationModel {
        guard owner.id != partner.id else { throw ServiceError.sameRoutine }
        return try create(
            owner: owner,
            members: [owner, partner],
            in: context,
            now: now,
            save: save
        )
    }

    @discardableResult
    public static func create(
        owner: RoutineModel,
        members: [RoutineModel],
        in context: ModelContext,
        now: Date = .now,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> RoutineAlternationModel {
        try validate(members, owner: owner)
        let memberIDs = members.map(\.id)
        let existing = try context.fetch(FetchDescriptor<RoutineAlternationModel>())
        let liveExisting = live(existing)
        let resolvedExisting = resolved(liveExisting)
        guard resolvedExisting.allSatisfy({ existing in
            Set(configuredMemberRoutineIDs(for: existing)).isDisjoint(with: memberIDs)
        }) else {
            throw ServiceError.alreadyPaired
        }
        let resolvedIDs = Set(resolvedExisting.map(\.id))
        let staleOverlaps = liveExisting.filter { candidate in
            !resolvedIDs.contains(candidate.id)
                && !Set(configuredMemberRoutineIDs(for: candidate)).isDisjoint(with: memberIDs)
        }
        let alternation = RoutineAlternationModel(
            userID: owner.userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: successorID(after: owner.id, in: memberIDs),
            memberRoutineIDs: memberIDs,
            createdAt: now,
            updatedAt: now
        )
        context.insert(alternation)
        let staleSnapshots = staleOverlaps.map(mutationSnapshot)
        for stale in staleOverlaps {
            stale.deletedAt = now
            stale.updatedAt = now
        }
        do {
            try save(context)
        } catch {
            context.delete(alternation)
            for (stale, snapshot) in zip(staleOverlaps, staleSnapshots) {
                restore(snapshot, to: stale)
            }
            throw error
        }
        return alternation
    }

    public static func update(
        _ alternation: RoutineAlternationModel,
        orderedMembers: [RoutineModel],
        in context: ModelContext,
        now: Date = .now,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let originalRead = configurationRead(for: alternation)
        guard originalRead.isSupported else {
            throw ServiceError.invalidConfiguration
        }
        let previous = mutationSnapshot(of: alternation)
        let originalMemberIDs = Set(originalRead.structuralMemberIDs)
        let owner = orderedMembers.first(where: { $0.id == alternation.ownerRoutineID })
            ?? orderedMembers.first
        guard let owner else { throw ServiceError.tooFewMembers }
        try validate(orderedMembers, owner: owner)
        let memberIDs = orderedMembers.map(\.id)
        let existing = try context.fetch(FetchDescriptor<RoutineAlternationModel>())
        let liveExisting = live(existing)
        guard liveExisting.first(where: {
            !Set(configuredMemberRoutineIDs(for: $0)).isDisjoint(with: originalMemberIDs)
        })?.id == alternation.id else {
            throw ServiceError.cycleChanged
        }
        let staleOverlaps = liveExisting.filter { candidate in
            candidate.id != alternation.id
                && !Set(configuredMemberRoutineIDs(for: candidate)).isDisjoint(
                    with: originalMemberIDs
                )
        }
        let staleOverlapIDs = Set(staleOverlaps.map(\.id))
        guard liveExisting.allSatisfy({ candidate in
            candidate.id == alternation.id
                || staleOverlapIDs.contains(candidate.id)
                || Set(configuredMemberRoutineIDs(for: candidate)).isDisjoint(with: memberIDs)
        }) else {
            throw ServiceError.alreadyPaired
        }

        let previousMembers = Dictionary(
            uniqueKeysWithValues: originalRead.configuration.members.map {
                ($0.routineID, $0)
            }
        )
        let members = memberIDs.map {
            previousMembers[$0] ?? .init(routineID: $0, joinedAt: now)
        }
        let configuration = RoutineAlternationConfiguration(members: members)
        guard let json = configuration.encoded() else {
            throw ServiceError.invalidConfiguration
        }

        alternation.ownerRoutineID = owner.id
        alternation.partnerRoutineID = successorID(after: owner.id, in: memberIDs)
        alternation.memberConfigurationJSON = json
        alternation.updatedAt = now
        alternation.deletedAt = nil
        let staleSnapshots = staleOverlaps.map(mutationSnapshot)
        for stale in staleOverlaps {
            stale.deletedAt = now
            stale.updatedAt = now
        }
        do {
            try save(context)
        } catch {
            restore(previous, to: alternation)
            for (stale, snapshot) in zip(staleOverlaps, staleSnapshots) {
                restore(snapshot, to: stale)
            }
            throw error
        }
    }

    public static func remove(
        _ alternation: RoutineAlternationModel,
        in context: ModelContext,
        now: Date = .now,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let originalMemberIDs = Set(configuredMemberRoutineIDs(for: alternation))
        let liveExisting = live(try context.fetch(FetchDescriptor<RoutineAlternationModel>()))
        guard liveExisting.first(where: {
            !Set(configuredMemberRoutineIDs(for: $0)).isDisjoint(with: originalMemberIDs)
        })?.id == alternation.id else {
            throw ServiceError.cycleChanged
        }
        let matches = liveExisting.filter {
            !Set(configuredMemberRoutineIDs(for: $0)).isDisjoint(with: originalMemberIDs)
        }
        let snapshots = matches.map(mutationSnapshot)
        for match in matches {
            match.deletedAt = now
            match.updatedAt = now
        }
        do {
            try save(context)
        } catch {
            for (match, snapshot) in zip(matches, snapshots) {
                restore(snapshot, to: match)
            }
            throw error
        }
    }

    /// Removes every record that directly contains a routine. Routine deletion
    /// uses `detachRoutine`; the editor uses `remove` so all winner conflicts
    /// are repaired in the same transaction.
    public static func removeAll(
        containing routineID: UUID,
        in context: ModelContext,
        now: Date = .now,
        saveChanges: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let matches = live(try context.fetch(FetchDescriptor<RoutineAlternationModel>()))
            .filter { configuredMemberRoutineIDs(for: $0).contains(routineID) }
        let snapshots = matches.map(mutationSnapshot)
        for alternation in matches {
            alternation.deletedAt = now
            alternation.updatedAt = now
        }
        guard saveChanges, !matches.isEmpty else { return }
        do {
            try save(context)
        } catch {
            for (alternation, snapshot) in zip(matches, snapshots) {
                restore(snapshot, to: alternation)
            }
            throw error
        }
    }

    /// Detaches a routine only from the structurally resolved winner. Any
    /// suppressed record that contains the routine or overlaps that winner is
    /// tombstoned instead of being rewritten with a fresh timestamp, which
    /// prevents a stale remainder from resurrecting or stealing another
    /// winner's members.
    public static func detachRoutine(
        _ routineID: UUID,
        in context: ModelContext,
        now: Date = .now,
        saveChanges: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let liveExisting = live(try context.fetch(FetchDescriptor<RoutineAlternationModel>()))
        let resolvedExisting = resolved(liveExisting)
        let resolvedIDs = Set(resolvedExisting.map(\.id))
        let affectedWinners = resolvedExisting.filter {
            configuredMemberRoutineIDs(for: $0).contains(routineID)
        }
        let affectedMemberIDs = Set(affectedWinners.flatMap {
            configuredMemberRoutineIDs(for: $0)
        })
        let suppressedMatches = liveExisting.filter { candidate in
            guard !resolvedIDs.contains(candidate.id) else { return false }
            let candidateIDs = Set(configuredMemberRoutineIDs(for: candidate))
            return candidateIDs.contains(routineID)
                || !candidateIDs.isDisjoint(with: affectedMemberIDs)
        }
        let matches = affectedWinners + suppressedMatches
        let snapshots = matches.map(mutationSnapshot)

        for suppressed in suppressedMatches {
            suppressed.deletedAt = now
            suppressed.updatedAt = now
        }
        for alternation in affectedWinners {
            let read = configurationRead(for: alternation)
            guard read.isSupported else {
                alternation.deletedAt = now
                alternation.updatedAt = now
                continue
            }
            let remaining = read.configuration.members.filter {
                $0.routineID != routineID
            }
            guard remaining.count >= 2,
                  let json = RoutineAlternationConfiguration(members: remaining).encoded() else {
                alternation.deletedAt = now
                alternation.updatedAt = now
                continue
            }
            let memberIDs = remaining.map(\.routineID)
            let ownerID = memberIDs.contains(alternation.ownerRoutineID)
                ? alternation.ownerRoutineID
                : memberIDs[0]
            alternation.ownerRoutineID = ownerID
            alternation.partnerRoutineID = successorID(after: ownerID, in: memberIDs)
            alternation.memberConfigurationJSON = json
            alternation.updatedAt = now
        }
        guard saveChanges, !matches.isEmpty else { return }
        do {
            try save(context)
        } catch {
            for (alternation, snapshot) in zip(matches, snapshots) {
                restore(snapshot, to: alternation)
            }
            throw error
        }
    }

    private struct MutationSnapshot {
        let ownerRoutineID: UUID
        let partnerRoutineID: UUID
        let memberConfigurationJSON: String?
        let updatedAt: Date
        let deletedAt: Date?
    }

    private static func state(
        for alternation: RoutineAlternationModel,
        configuration: RoutineAlternationConfiguration,
        liveRoutinesByID: [UUID: RoutineModel],
        latestCompletions: [UUID: Completion]
    ) -> State? {
        guard alternation.deletedAt == nil else { return nil }
        let members = configuration.members.compactMap { member in
            liveRoutinesByID[member.routineID]
        }
        guard members.count == configuration.members.count,
              members.count >= 2,
              let owner = members.first(where: { $0.id == alternation.ownerRoutineID })
                ?? members.first,
              let dueID = dueRoutineID(
                for: configuration,
                latestCompletions: latestCompletions
              ),
              let due = members.first(where: { $0.id == dueID }) else {
            return nil
        }
        return State(
            alternation: alternation,
            owner: owner,
            members: members,
            due: due
        )
    }

    private static func dueRoutineID(
        for configuration: RoutineAlternationConfiguration,
        latestCompletions: [UUID: Completion]
    ) -> UUID? {
        guard let first = configuration.members.first else { return nil }
        let latest = configuration.members.compactMap { member -> Completion? in
            guard let completion = latestCompletions[member.routineID],
                  completion.endedAt >= member.joinedAt else { return nil }
            return completion
        }.max(by: completionSort)
        guard let latest,
              let index = configuration.members.firstIndex(where: {
                  $0.routineID == latest.routineID
              }) else {
            return first.routineID
        }
        return configuration.members[(index + 1) % configuration.members.count].routineID
    }

    private static func latestCompletions(
        in workouts: [WorkoutModel]
    ) -> [UUID: Completion] {
        var result: [UUID: Completion] = [:]
        for workout in workouts {
            guard workout.deletedAt == nil,
                  let endedAt = workout.endedAt,
                  let routineID = workout.routineID else { continue }
            let candidate = Completion(
                routineID: routineID,
                endedAt: endedAt,
                workoutID: workout.id
            )
            if let existing = result[routineID],
               !completionSort(existing, candidate) {
                continue
            }
            result[routineID] = candidate
        }
        return result
    }

    private static func completionSort(_ lhs: Completion, _ rhs: Completion) -> Bool {
        if lhs.endedAt != rhs.endedAt { return lhs.endedAt < rhs.endedAt }
        return lhs.workoutID.uuidString < rhs.workoutID.uuidString
    }

    private static func validate(
        _ members: [RoutineModel],
        owner: RoutineModel
    ) throws {
        guard members.count >= 2 else { throw ServiceError.tooFewMembers }
        let ids = members.map(\.id)
        guard Set(ids).count == ids.count else { throw ServiceError.duplicateMember }
        guard ids.contains(owner.id) else { throw ServiceError.unavailableRoutine }
        guard members.allSatisfy(isLive) else { throw ServiceError.unavailableRoutine }
        guard members.allSatisfy({ $0.userID == owner.userID }) else {
            throw ServiceError.differentUsers
        }
    }

    private static func successorID(after routineID: UUID, in memberIDs: [UUID]) -> UUID {
        guard let index = memberIDs.firstIndex(of: routineID), memberIDs.count >= 2 else {
            return memberIDs.first ?? routineID
        }
        return memberIDs[(index + 1) % memberIDs.count]
    }

    private static func configurationRead(
        for alternation: RoutineAlternationModel
    ) -> ConfigurationRead {
        guard alternation.memberConfigurationJSON != nil else {
            let memberIDs = legacyMemberIDs(for: alternation)
            return ConfigurationRead(
                configuration: RoutineAlternationConfiguration(
                    memberRoutineIDs: memberIDs,
                    joinedAt: alternation.createdAt
                ),
                structuralMemberIDs: memberIDs,
                isSupported: memberIDs.count >= 2 && Set(memberIDs).count == memberIDs.count
            )
        }

        guard let decoded = RoutineAlternationConfiguration.decode(
            from: alternation.memberConfigurationJSON
        ) else {
            return invalidConfigurationRead()
        }
        let rawMemberIDs = decoded.members.map(\.routineID)
        var seen: Set<UUID> = []
        let recoveredMemberIDs = rawMemberIDs.filter { seen.insert($0).inserted }
        guard rawMemberIDs.count >= 2,
              recoveredMemberIDs.count == rawMemberIDs.count else {
            return invalidConfigurationRead(structuralMemberIDs: recoveredMemberIDs)
        }
        return ConfigurationRead(
            configuration: decoded,
            structuralMemberIDs: recoveredMemberIDs,
            isSupported: decoded.version == RoutineAlternationConfiguration.currentVersion
        )
    }

    private static func invalidConfigurationRead(
        structuralMemberIDs: [UUID] = []
    ) -> ConfigurationRead {
        ConfigurationRead(
            configuration: RoutineAlternationConfiguration(members: []),
            structuralMemberIDs: structuralMemberIDs,
            isSupported: false
        )
    }

    private static func legacyMemberIDs(for alternation: RoutineAlternationModel) -> [UUID] {
        if alternation.ownerRoutineID == alternation.partnerRoutineID {
            return [alternation.ownerRoutineID]
        }
        return [alternation.ownerRoutineID, alternation.partnerRoutineID]
    }

    private static func mutationSnapshot(
        of alternation: RoutineAlternationModel
    ) -> MutationSnapshot {
        MutationSnapshot(
            ownerRoutineID: alternation.ownerRoutineID,
            partnerRoutineID: alternation.partnerRoutineID,
            memberConfigurationJSON: alternation.memberConfigurationJSON,
            updatedAt: alternation.updatedAt,
            deletedAt: alternation.deletedAt
        )
    }

    private static func restore(
        _ snapshot: MutationSnapshot,
        to alternation: RoutineAlternationModel
    ) {
        alternation.ownerRoutineID = snapshot.ownerRoutineID
        alternation.partnerRoutineID = snapshot.partnerRoutineID
        alternation.memberConfigurationJSON = snapshot.memberConfigurationJSON
        alternation.updatedAt = snapshot.updatedAt
        alternation.deletedAt = snapshot.deletedAt
    }

    private static func isLive(_ routine: RoutineModel) -> Bool {
        routine.deletedAt == nil && routine.archivedAt == nil
    }
}
