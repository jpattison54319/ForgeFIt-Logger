import Foundation
import Testing
@testable import ForgeCore

struct WorkoutIntentContractsTests {
    @Test func everyWorkoutChoiceTargetRoundTripsItsStableIdentifier() throws {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let targets: [WorkoutChoiceTarget] = [
            .next,
            .empty,
            .routine(id),
            .cardio("run"),
            .yogaBuiltIn("morning-flow"),
            .yogaSaved(id),
            .conditioningBuiltIn("cindy"),
            .conditioningSaved(id),
        ]

        for target in targets {
            #expect(WorkoutChoiceTarget(identifier: target.identifier) == target)
        }
    }

    @Test func spokenRoutineNamesMatchNumbersAcronymsAndConversationalWrappers() {
        let records = [
            WorkoutChoiceRecord(
                id: "routine:00000000-0000-7000-8000-000000000921",
                title: "AX400",
                subtitle: "Saved routine",
                systemImageName: "list.bullet.clipboard"
            ),
            WorkoutChoiceRecord(
                id: "routine:00000000-0000-7000-8000-000000000922",
                title: "Zone 2 Cardio",
                subtitle: "Saved routine",
                systemImageName: "list.bullet.clipboard"
            ),
            WorkoutChoiceRecord(
                id: "routine:00000000-0000-7000-8000-000000000923",
                title: "Push & Pull",
                subtitle: "Saved routine",
                systemImageName: "list.bullet.clipboard"
            ),
        ]

        let axQueries = [
            "AX400",
            "AX 400",
            "A X four hundred",
            "ay ex four hundred",
            "axe four hundred",
            "axe 400",
            "ay ex 400",
            "start my AX four hundred workout on ForgeFit",
            "begin the AX four zero zero routine with the ForgeFit app",
            "could you start the workout called A X four hundred on Forge Fit",
            "I want to start my AX400 routine using Forged Fit please",
        ]
        for query in axQueries {
            #expect(
                WorkoutChoiceNameMatcher.matches(query: query, in: records).map(\.record.title)
                    == ["AX400"],
                "Expected AX400 to match: \(query)"
            )
        }

        let zoneQueries = [
            "Zone 2 Cardio",
            "zone two cardio",
            "zone to cardio",
            "start my zone two cardio workout in ForgeFit",
        ]
        for query in zoneQueries {
            #expect(
                WorkoutChoiceNameMatcher.matches(query: query, in: records).map(\.record.title)
                    == ["Zone 2 Cardio"],
                "Expected Zone 2 Cardio to match: \(query)"
            )
        }

        #expect(
            WorkoutChoiceNameMatcher.matches(query: "push and pull", in: records)
                .map(\.record.title) == ["Push & Pull"]
        )

        let mixedCase = [WorkoutChoiceRecord(
            id: "routine:00000000-0000-7000-8000-000000000924",
            title: "Ax400",
            subtitle: "Saved routine",
            systemImageName: "list.bullet.clipboard"
        )]
        #expect(
            WorkoutChoiceNameMatcher.matches(
                query: "ay ex four hundred",
                in: mixedCase
            ).map(\.record.title) == ["Ax400"]
        )
    }

    @Test func matchingReturnsDuplicatesForSystemDisambiguationAndNeverGuessesUnknownNames() {
        let records = [
            WorkoutChoiceRecord(
                id: "routine:00000000-0000-7000-8000-000000000921",
                title: "Upper Strength",
                subtitle: "Saved routine",
                systemImageName: "list.bullet.clipboard"
            ),
            WorkoutChoiceRecord(
                id: "routine:00000000-0000-7000-8000-000000000922",
                title: "Upper Hypertrophy",
                subtitle: "Saved routine",
                systemImageName: "list.bullet.clipboard"
            ),
        ]

        let partial = WorkoutChoiceNameMatcher.matches(query: "upper", in: records)
        #expect(partial.map(\.quality) == [.partial, .partial])
        #expect(partial.map(\.record.title) == ["Upper Hypertrophy", "Upper Strength"])
        #expect(
            WorkoutChoiceNameMatcher.matches(query: "lower", in: records).isEmpty
        )
    }

    @Test func nextAndEmptyExposeConversationalAliasesWithoutCapturingUnknownRoutines() {
        let records = [
            WorkoutChoiceRecord(
                id: WorkoutChoiceTarget.next.identifier,
                title: "Next Workout",
                subtitle: "From your tracked microcycle",
                systemImageName: "forward.fill"
            ),
            WorkoutChoiceRecord(
                id: WorkoutChoiceTarget.empty.identifier,
                title: "Empty Workout",
                subtitle: "Build as you train",
                systemImageName: "square.and.pencil"
            ),
        ]

        #expect(
            WorkoutChoiceNameMatcher.matches(query: "today's workout", in: records)
                .map(\.record.id) == [WorkoutChoiceTarget.next.identifier]
        )
        #expect(
            WorkoutChoiceNameMatcher.matches(query: "blank workout", in: records)
                .map(\.record.id) == [WorkoutChoiceTarget.empty.identifier]
        )
        #expect(
            WorkoutChoiceNameMatcher.matches(query: "AX400", in: records).isEmpty
        )
    }

    @Test func diagnosticStoresOnlyTheLatestStructuredQueryAndExecution() async throws {
        let suite = "WorkoutIntentDiagnosticStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let timestamp = Date(timeIntervalSince1970: 2_000_000_000)
        let store = WorkoutIntentDiagnosticStore(
            suiteName: suite,
            now: { timestamp }
        )
        let record = WorkoutChoiceRecord(
            id: "routine:00000000-0000-7000-8000-000000000921",
            title: "AX400",
            subtitle: "Saved routine",
            systemImageName: "list.bullet.clipboard"
        )
        let match = WorkoutChoiceNameMatch(record: record, quality: .conversationalExact)

        await store.recordQuery("A X four hundred", matches: [match])
        #expect(await store.snapshot() == WorkoutIntentDiagnosticSnapshot(
            updatedAt: timestamp,
            queryText: "A X four hundred",
            candidateTitles: ["AX400"],
            selectedTitle: "AX400",
            selectedIdentifier: record.id,
            outcome: .queryMatched
        ))

        await store.recordExecution(selected: record, outcome: .namedWorkout)
        #expect(await store.snapshot()?.outcome == .namedWorkout)
        #expect(await store.snapshot()?.queryText == "A X four hundred")

        await store.clear()
        #expect(await store.snapshot() == nil)
    }

    @Test func malformedWorkoutChoiceIdentifiersFailClosed() {
        #expect(WorkoutChoiceTarget(identifier: "routine:not-a-uuid") == nil)
        #expect(WorkoutChoiceTarget(identifier: "cardio:") == nil)
        #expect(WorkoutChoiceTarget(identifier: "unknown:value") == nil)
    }

    @Test func sharedCatalogStoresOnlyThePublishedChoiceRecords() throws {
        let suite = "WorkoutIntentContractsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = [WorkoutChoiceRecord(
            id: "empty",
            title: "Empty Workout",
            subtitle: "Build as you train",
            systemImageName: "square.and.pencil"
        )]

        WorkoutChoiceCatalogStore.save(records, defaults: defaults)

        #expect(WorkoutChoiceCatalogStore.load(defaults: defaults) == records)
        WorkoutChoiceCatalogStore.clear(defaults: defaults)
        #expect(WorkoutChoiceCatalogStore.load(defaults: defaults).isEmpty)
    }

    @Test func immediateWatchStartReplyRoundTrips() throws {
        let expected = WatchImmediateStartResult.chooseWorkout(
            message: "Choose a workout."
        )
        let data = try #require(WatchWire.encode(expected))
        #expect(WatchWire.decode(WatchImmediateStartResult.self, from: data) == expected)
    }

    @Test func intentDeepLinksBecomeValidatedInProcessDestinations() throws {
        let routineID = try #require(
            UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")
        )
        let choiceID = WorkoutChoiceTarget.routine(routineID).identifier
        let startURL = try #require(
            ForgeFitIntentDeepLink.startWorkout(choiceID: choiceID)
        )

        #expect(
            ForgeFitIntentDestination(internalDeepLink: startURL)
                == .startWorkout(choiceID: choiceID)
        )
        #expect(
            ForgeFitIntentDestination(
                internalDeepLink: ForgeFitIntentDeepLink.startNextWorkout
            ) == .startNextWorkout
        )
        #expect(
            ForgeFitIntentDestination(
                internalDeepLink: ForgeFitIntentDeepLink.resumeWorkout
            ) == .resumeWorkout
        )
        #expect(
            ForgeFitIntentDestination(
                internalDeepLink: ForgeFitIntentDeepLink.routine(routineID)
            ) == .routine(routineID)
        )
    }

    @Test func malformedIntentDeepLinksFailClosed() throws {
        let malformedChoice = try #require(
            URL(string: "forgefit://start-choice?id=routine%3Anot-a-uuid")
        )
        let unsupportedScheme = try #require(
            URL(string: "https://example.com/start-next")
        )

        #expect(ForgeFitIntentDestination(internalDeepLink: malformedChoice) == nil)
        #expect(ForgeFitIntentDestination(internalDeepLink: unsupportedScheme) == nil)
    }

    @Test @MainActor func navigatorRetainsAColdLaunchRequestUntilTheShellConsumesIt() {
        let navigator = ForgeFitIntentNavigator()
        navigator.navigate(to: .startNextWorkout)

        #expect(navigator.pendingRequest?.destination == .startNextWorkout)
        #expect(navigator.takePendingRequest()?.destination == .startNextWorkout)
        #expect(navigator.pendingRequest == nil)
    }
}
