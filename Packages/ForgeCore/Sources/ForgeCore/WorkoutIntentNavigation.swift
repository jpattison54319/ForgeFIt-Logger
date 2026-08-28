import AppIntents
import Foundation
import Observation

/// A validated request for the app's existing workout-navigation boundary.
/// The request contains identifiers only; workout and health data stay in the
/// app's live stores and are resolved again before any user-visible action.
public enum ForgeFitIntentDestination: Equatable, Sendable {
    case startWorkout(choiceID: String)
    case startNextWorkout
    case resumeWorkout
    case chooseWorkout(message: String)
    case routine(UUID)
    case exercise(UUID)

    /// Converts an intent destination to an in-process deep link. These URLs
    /// are routed directly by ContentView and are never passed to OpenURLIntent.
    public var internalDeepLink: URL? {
        switch self {
        case .startWorkout(let choiceID):
            ForgeFitIntentDeepLink.startWorkout(choiceID: choiceID)
        case .startNextWorkout:
            ForgeFitIntentDeepLink.startNextWorkout
        case .resumeWorkout:
            ForgeFitIntentDeepLink.resumeWorkout
        case .chooseWorkout:
            ForgeFitIntentDeepLink.chooseWorkout
        case .routine(let id):
            ForgeFitIntentDeepLink.routine(id)
        case .exercise(let id):
            ForgeFitIntentDeepLink.exercise(id)
        }
    }

    /// DEBUG acceptance converts its launch fixture into the same typed
    /// request that production App Intents submit to the navigation model.
    public init?(internalDeepLink url: URL) {
        guard url.scheme?.lowercased() == "forgefit" else { return nil }

        switch url.host?.lowercased() {
        case "workout":
            self = .resumeWorkout
        case "start-choice":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let choiceID = components.queryItems?
                    .first(where: { $0.name == "id" })?
                    .value,
                  WorkoutChoiceTarget(identifier: choiceID) != nil else {
                return nil
            }
            self = .startWorkout(choiceID: choiceID)
        case "start-next":
            self = .startNextWorkout
        case "choose-workout":
            self = .chooseWorkout(message: "Choose the workout you want to start.")
        case "routine":
            guard let id = url.pathComponents.dropFirst().first.flatMap(UUID.init) else {
                return nil
            }
            self = .routine(id)
        case "exercise":
            guard let id = url.pathComponents.dropFirst().first.flatMap(UUID.init) else {
                return nil
            }
            self = .exercise(id)
        default:
            return nil
        }
    }
}

public struct ForgeFitIntentNavigationRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let destination: ForgeFitIntentDestination

    public init(
        id: UUID = UUID(),
        destination: ForgeFitIntentDestination
    ) {
        self.id = id
        self.destination = destination
    }
}

/// App Intents receive this exact instance through AppDependencyManager and
/// ContentView observes it through SwiftUI's environment. A pending request is
/// retained across cold-launch setup until the rendered shell is ready.
@MainActor
@Observable
public final class ForgeFitIntentNavigator {
    public private(set) var pendingRequest: ForgeFitIntentNavigationRequest?

    public init() {}

    public func navigate(to destination: ForgeFitIntentDestination) {
        pendingRequest = ForgeFitIntentNavigationRequest(destination: destination)
    }

    @discardableResult
    public func takePendingRequest() -> ForgeFitIntentNavigationRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}

// MARK: - Control Center actions shared by the app and widget extension

public struct ForgeFitControlWorkoutEntity: AppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Workout",
        numericFormat: "\(placeholder: .int) workouts"
    )
    public static let defaultQuery = ForgeFitControlWorkoutQuery()

    public let id: String
    public let name: String
    public let detail: String
    public let systemImageName: String

    public init(_ record: WorkoutChoiceRecord) {
        id = record.id
        name = record.title
        detail = record.subtitle
        systemImageName = record.systemImageName
    }

    private init(
        id: String,
        name: String,
        detail: String,
        systemImageName: String
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.systemImageName = systemImageName
    }

    public static let chooseWorkout = ForgeFitControlWorkoutEntity(
        id: "forgefit-control:choose-workout",
        name: "Choose Workout",
        detail: "Open the workout list",
        systemImageName: "dumbbell.fill"
    )

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(detail)",
            image: .init(systemName: systemImageName)
        )
    }
}

public struct ForgeFitControlWorkoutQuery: EntityStringQuery, EnumerableEntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ForgeFitControlWorkoutEntity] {
        let requested = Set(identifiers)
        var entities = WorkoutChoiceCatalogStore.load()
            .filter { requested.contains($0.id) }
            .map(ForgeFitControlWorkoutEntity.init)
        if requested.contains(ForgeFitControlWorkoutEntity.chooseWorkout.id) {
            entities.append(.chooseWorkout)
        }
        return entities
    }

    public func entities(matching string: String) async throws -> [ForgeFitControlWorkoutEntity] {
        WorkoutChoiceNameMatcher.matches(
            query: string,
            in: WorkoutChoiceCatalogStore.load()
        )
            .map(\.record)
            .map(ForgeFitControlWorkoutEntity.init)
    }

    public func allEntities() async throws -> [ForgeFitControlWorkoutEntity] {
        WorkoutChoiceCatalogStore.load().map(ForgeFitControlWorkoutEntity.init)
    }
}

public struct OpenForgeFitControlWorkoutIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Workout"
    public static var isDiscoverable: Bool { false }
    public static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Workout")
    public var target: ForgeFitControlWorkoutEntity

    @Dependency private var navigator: ForgeFitIntentNavigator

    public init() {}

    public init(target: ForgeFitControlWorkoutEntity) {
        self.target = target
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let destination: ForgeFitIntentDestination
        if target.id == ForgeFitControlWorkoutEntity.chooseWorkout.id {
            destination = .chooseWorkout(message: "Choose the workout you want to start.")
        } else if WorkoutChoiceTarget(identifier: target.id) != nil {
            destination = .startWorkout(choiceID: target.id)
        } else {
            destination = .chooseWorkout(
                message: "That workout is no longer available. Choose another workout."
            )
        }
        navigator.navigate(to: destination)
        return .result()
    }
}

public enum ForgeFitControlRoute: String, AppEnum {
    case startNextWorkout
    case resumeWorkout

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "ForgeFit Destination"
    )
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .startNextWorkout: DisplayRepresentation(title: "Start Next Workout"),
        .resumeWorkout: DisplayRepresentation(title: "Resume Workout"),
    ]
}

public struct OpenForgeFitControlRouteIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open ForgeFit"
    public static var isDiscoverable: Bool { false }
    public static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Destination")
    public var target: ForgeFitControlRoute

    @Dependency private var navigator: ForgeFitIntentNavigator

    public init() {}

    public init(target: ForgeFitControlRoute) {
        self.target = target
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        switch target {
        case .startNextWorkout:
            navigator.navigate(to: .startNextWorkout)
        case .resumeWorkout:
            navigator.navigate(to: .resumeWorkout)
        }
        return .result()
    }
}
