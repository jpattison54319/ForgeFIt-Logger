import Combine
import ForgeData
import Foundation
import Observation
import SwiftData

nonisolated struct RenderPerformanceCollectionKey: Equatable {
    let revision: Int
    let primaryCount: Int
    let secondaryCount: Int

    init(revision: Int, primaryCount: Int, secondaryCount: Int = 0) {
        self.revision = revision
        self.primaryCount = primaryCount
        self.secondaryCount = secondaryCount
    }
}

/// Domains whose cached render projections are invalidated by a SwiftData
/// transaction. The change feed makes view-body keys O(1): the linear work is
/// paid once at a persistence boundary, never again for an unrelated SwiftUI
/// state update such as scrolling, typing, or a tab-bar animation.
nonisolated struct RenderPerformanceInvalidation: OptionSet, Sendable {
    let rawValue: UInt8

    static let homeSuggestion = Self(rawValue: 1 << 0)
    static let homeQuickStart = Self(rawValue: 1 << 1)
    static let historyAnalytics = Self(rawValue: 1 << 2)
    static let exerciseCatalog = Self(rawValue: 1 << 3)
    static let routineLibrary = Self(rawValue: 1 << 4)
    static let archive = Self(rawValue: 1 << 5)

    static let all: Self = [
        .homeSuggestion,
        .homeQuickStart,
        .historyAnalytics,
        .exerciseCatalog,
        .routineLibrary,
        .archive,
    ]
}

nonisolated enum RenderPerformanceInvalidationSource: Int, Comparable, Sendable {
    case mainContextSave
    case externalContextSave
    case remoteStoreChange

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct RenderPerformanceSaveDelivery: Sendable {
    let entityNames: Set<String>
    let invalidation: RenderPerformanceInvalidation
    let source: RenderPerformanceInvalidationSource
}

/// Routes persistent entity changes to the smallest affected render cache.
/// Child plan rows are included even though normal authoring also stamps the
/// parent; this keeps CloudKit/import changes correct when they arrive alone.
nonisolated enum RenderPerformanceInvalidationPolicy {
    private static let routineStructureEntities: Set<String> = [
        "RoutineModel",
        "RoutineExerciseModel",
        "RoutineSetModel",
        "RoutineBlockModel",
    ]

    private static let historyPresentationEntities: Set<String> = [
        "WorkoutModel",
        "WorkoutBlockModel",
        "WorkoutExerciseModel",
        "SetModel",
        "CardioSessionModel",
        "CardioSplitModel",
    ]

    static func invalidation(for entityNames: some Sequence<String>) -> RenderPerformanceInvalidation {
        var result: RenderPerformanceInvalidation = []
        for entityName in entityNames {
            if routineStructureEntities.contains(entityName) {
                result.formUnion([.homeSuggestion, .homeQuickStart, .routineLibrary])
                if entityName == "RoutineModel" { result.insert(.archive) }
            }
            if entityName == "RoutineFolderModel" {
                result.formUnion([.homeSuggestion, .routineLibrary, .archive])
            }
            if entityName == "RoutineAlternationModel" {
                result.formUnion([.homeSuggestion, .routineLibrary])
            }
            if historyPresentationEntities.contains(entityName) {
                result.insert(.historyAnalytics)
                // Alternation ordering and Home's next-routine choice only
                // read terminal WorkoutModel fields. Nested logger saves must
                // not rebuild either library behind an active workout.
                if entityName == "WorkoutModel" {
                    result.formUnion([.homeSuggestion, .routineLibrary])
                }
            }
            if entityName == "ExerciseLibraryModel" {
                result.formUnion([.exerciseCatalog, .historyAnalytics])
            }
        }
        return result
    }

    /// CloudKit imports are persistent-store transactions rather than saves
    /// made by an app-owned `ModelContext`, so their notifications do not carry
    /// entity identifiers. The next visible render must conservatively refresh
    /// every bounded projection; each tab still coalesces repeated changes into
    /// one revision delivery.
    static var remoteStoreInvalidation: RenderPerformanceInvalidation { .all }

    static func invalidation(
        from notification: Notification,
        matching container: ModelContainer
    ) -> RenderPerformanceInvalidation {
        guard let names = entityNames(
            from: notification,
            matchingContainerIdentifier: ObjectIdentifier(container)
        ) else { return [] }
        return invalidation(for: names)
    }

    private static func entityNames(
        from notification: Notification,
        matchingContainerIdentifier containerIdentifier: ObjectIdentifier
    ) -> Set<String>? {
        // `ModelContext.didSave` is delivered synchronously on the saving
        // context's executor. Read the context only at that boundary; worker
        // contexts can be released immediately after save returns.
        guard let savingContext = notification.object as? ModelContext,
              ObjectIdentifier(savingContext.container) == containerIdentifier else {
            return nil
        }
        let keys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers,
            .updatedIdentifiers,
            .deletedIdentifiers,
        ]
        return Set(keys.lazy.flatMap { key in
            let identifiers = notification.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? []
            return identifiers.lazy.map(\.entityName)
        })
    }

    /// Classifies every save from this store, including worker contexts. An
    /// object-filtered notification subscription sees only the view context
    /// and silently misses same-count edits made by migrations, finishers, and
    /// other isolated transactions; those edits still need a settled cache
    /// revision after their query generation merges.
    static func delivery(
        from notification: Notification,
        matchingContainerIdentifier containerIdentifier: ObjectIdentifier,
        viewContextIdentifier: ObjectIdentifier
    ) -> RenderPerformanceSaveDelivery? {
        guard let savingContext = notification.object as? ModelContext,
              let names = entityNames(
                from: notification,
                matchingContainerIdentifier: containerIdentifier
              ) else { return nil }
        return RenderPerformanceSaveDelivery(
            entityNames: names,
            invalidation: invalidation(for: names),
            source: ObjectIdentifier(savingContext) == viewContextIdentifier
                ? .mainContextSave
                : .externalContextSave
        )
    }

    /// Snapshots a save while its originating context is guaranteed to be
    /// alive, then moves only immutable value data to the main queue. Deferring
    /// the raw notification can outlive a short-lived worker context and trap
    /// inside SwiftData when its container is queried.
    @MainActor
    static func saveDeliveries(
        for viewContext: ModelContext
    ) -> AnyPublisher<RenderPerformanceSaveDelivery, Never> {
        let containerIdentifier = ObjectIdentifier(viewContext.container)
        let viewContextIdentifier = ObjectIdentifier(viewContext)
        return NotificationCenter.default.publisher(for: ModelContext.didSave)
            .compactMap { notification in
                delivery(
                    from: notification,
                    matchingContainerIdentifier: containerIdentifier,
                    viewContextIdentifier: viewContextIdentifier
                )
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}

/// Monotonic O(1) keys stored by each keep-resident tab. `record` is invoked
/// only from the main-actor SwiftUI notification boundary.
@MainActor
struct RenderPerformanceRevisions: Equatable {
    private(set) var homeSuggestion = 0
    private(set) var homeQuickStart = 0
    private(set) var historyAnalytics = 0
    private(set) var exerciseCatalog = 0
    private(set) var routineLibrary = 0
    private(set) var archive = 0

    mutating func record(_ invalidation: RenderPerformanceInvalidation) {
        if invalidation.contains(.homeSuggestion) { homeSuggestion &+= 1 }
        if invalidation.contains(.homeQuickStart) { homeQuickStart &+= 1 }
        if invalidation.contains(.historyAnalytics) { historyAnalytics &+= 1 }
        if invalidation.contains(.exerciseCatalog) { exerciseCatalog &+= 1 }
        if invalidation.contains(.routineLibrary) { routineLibrary &+= 1 }
        if invalidation.contains(.archive) { archive &+= 1 }
    }
}

/// Non-observable buffer used by keep-resident tabs while the logger owns the
/// frame budget. It records every semantic invalidation without waking the
/// hidden SwiftUI subtree, then releases one coalesced change when logging
/// ends. Stored in `@State` only for stable reference identity.
@MainActor
final class RenderPerformanceInvalidationBuffer {
    private var pending: RenderPerformanceInvalidation = []

    func receive(
        _ invalidation: RenderPerformanceInvalidation,
        isDeferred: Bool
    ) -> RenderPerformanceInvalidation {
        guard !invalidation.isEmpty else { return [] }
        guard isDeferred else { return invalidation }
        pending.formUnion(invalidation)
        return []
    }

    func release() -> RenderPerformanceInvalidation {
        defer { pending = [] }
        return pending
    }
}

/// Owns the persistence-to-render handoff for one resident tab.
///
/// Hidden tabs accumulate identifiers without changing observable state, so a
/// save cannot wake their expensive projections. When the tab becomes visible,
/// `revisions(forActiveSurface:)` exposes that coalesced invalidation in the
/// same render that installs the newest parent query arrays; committing it on
/// the following lifecycle callback preserves the identical cache key.
///
/// Saves from another context and CloudKit changes are delivered only after a
/// short propagation window. That keeps a new cache revision from being spent
/// against the old `@Query` generation. The delay is outside every interaction
/// and render path and is injectable so ordering is deterministic in tests.
@MainActor
@Observable
final class RenderPerformanceRevisionController {
    typealias SettleOperation = @MainActor (RenderPerformanceInvalidationSource) async -> Void

    private(set) var committedRevisions = RenderPerformanceRevisions()

    @ObservationIgnored private var deferredInvalidation: RenderPerformanceInvalidation = []
    @ObservationIgnored private var settlingInvalidation: RenderPerformanceInvalidation = []
    @ObservationIgnored private var strongestSettlingSource: RenderPerformanceInvalidationSource = .mainContextSave
    @ObservationIgnored private var surfaceIsActive = false
    @ObservationIgnored private var deliveryGeneration = 0
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private let settleOperation: SettleOperation

    init(settleOperation: SettleOperation? = nil) {
        self.settleOperation = settleOperation ?? Self.waitForStorePropagation
    }

    /// Cache key used during body evaluation. A hidden invalidation becomes
    /// visible synchronously with the tab's fresh inputs, without publishing an
    /// intermediate observable change while the tab is still hidden.
    func revisions(forActiveSurface isActive: Bool) -> RenderPerformanceRevisions {
        var result = committedRevisions
        if isActive { result.record(deferredInvalidation) }
        return result
    }

    func receive(
        _ invalidation: RenderPerformanceInvalidation,
        source: RenderPerformanceInvalidationSource,
        surfaceIsActive isActive: Bool
    ) {
        guard !invalidation.isEmpty else { return }
        transitionSurfaceIfNeeded(to: isActive)
        settlingInvalidation.formUnion(invalidation)
        strongestSettlingSource = max(strongestSettlingSource, source)
        scheduleSettledDelivery()
    }

    func setSurfaceActive(_ isActive: Bool) {
        transitionSurfaceIfNeeded(to: isActive)
    }

    private func transitionSurfaceIfNeeded(to isActive: Bool) {
        guard surfaceIsActive != isActive else { return }
        surfaceIsActive = isActive
        if isActive {
            if !deferredInvalidation.isEmpty {
                let ready = deferredInvalidation
                deferredInvalidation = []
                committedRevisions.record(ready)
            }
        }
        if !settlingInvalidation.isEmpty, deliveryTask == nil {
            scheduleSettledDelivery()
        }
    }

    private func scheduleSettledDelivery() {
        guard !settlingInvalidation.isEmpty else { return }
        deliveryGeneration &+= 1
        let generation = deliveryGeneration
        let source = strongestSettlingSource
        deliveryTask?.cancel()
        deliveryTask = Task { @MainActor [weak self, settleOperation] in
            await settleOperation(source)
            guard let self,
                  !Task.isCancelled,
                  self.deliveryGeneration == generation else { return }
            let ready = self.settlingInvalidation
            self.settlingInvalidation = []
            self.strongestSettlingSource = .mainContextSave
            self.deliveryTask = nil
            guard !ready.isEmpty else { return }
            if self.surfaceIsActive {
                self.committedRevisions.record(ready)
            } else {
                // Observation-ignored by design: hidden descendants can
                // receive and settle remote transactions without waking their
                // SwiftUI subtree. Reveal consumes this ready revision with
                // the query generation that has now had time to merge.
                self.deferredInvalidation.formUnion(ready)
            }
        }
    }

    private static func waitForStorePropagation(
        _ source: RenderPerformanceInvalidationSource
    ) async {
        // A same-context save has already mutated the exact model instances
        // supplied to the view. Other contexts and CloudKit must first merge a
        // newer store generation into the view context.
        await Task.yield()
        switch source {
        case .mainContextSave:
            break
        case .externalContextSave:
            try? await Task.sleep(for: .milliseconds(60))
        case .remoteStoreChange:
            try? await Task.sleep(for: .milliseconds(180))
        }
        await Task.yield()
        await Task.yield()
    }
}
