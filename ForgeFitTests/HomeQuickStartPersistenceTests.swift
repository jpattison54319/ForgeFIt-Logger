import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct HomeQuickStartPersistenceTests {
    @Test func absentPreferenceUsesDefaultsButExplicitEmptyStaysEmpty() {
        #expect(HomeQuickStartAction.resolvedList(from: "") == HomeQuickStartAction.defaults)

        let persistedEmpty = HomeQuickStartAction.encodeList([])
        #expect(persistedEmpty == "[]")
        #expect(HomeQuickStartAction.resolvedList(from: persistedEmpty).isEmpty)
    }

    @Test func configuredOrderRoundTripsWithoutInventingUnknownActions() {
        let configured: [HomeQuickStartAction] = [
            .cardio(.walk),
            .yoga("morning-flow"),
        ]
        #expect(
            HomeQuickStartAction.resolvedList(
                from: HomeQuickStartAction.encodeList(configured)
            ) == configured
        )

        let mixedVersionPayload = #"["cardio:walk","newer-app-action","cardio:walk"]"#
        #expect(
            HomeQuickStartAction.resolvedList(from: mixedVersionPayload) == [.cardio(.walk)]
        )
    }

    @Test func malformedPayloadFallsBackToSafeDefaults() {
        #expect(
            HomeQuickStartAction.resolvedList(from: "not-json") == HomeQuickStartAction.defaults
        )
    }

    @Test func failedRoutineCreationLeavesNoPhantomAndRetryCommitsFreshly() throws {
        enum ExpectedFailure: Error { case write }

        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let saveCenter = PersistentChangeSaveCenter()
        let attemptID = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        let pendingFolder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Unrelated pending folder"
        )
        context.insert(pendingFolder)
        let attempt = RoutineCreationAttempt(
            id: attemptID,
            name: "New Routine",
            folderID: nil,
            position: 3,
            in: context
        )

        let failed = attempt.commit(
            into: context,
            saveCenter: saveCenter,
            save: { _ in throw ExpectedFailure.write },
            onCommit: { _ in Issue.record("failed save must not complete") }
        )
        #expect(!failed)
        #expect(try context.fetch(FetchDescriptor<RoutineModel>()).isEmpty)

        var committedRoutine: RoutineModel?
        let succeeded = attempt.commit(
            into: context,
            saveCenter: saveCenter,
            onCommit: { committedRoutine = $0 }
        )
        #expect(succeeded)
        #expect(committedRoutine?.id == attemptID)

        let freshContext = ModelContext(container)
        let persisted = try #require(
            freshContext.fetch(FetchDescriptor<RoutineModel>()).first
        )
        #expect(persisted.id == attempt.id)
        #expect(persisted.name == "New Routine")
        #expect(persisted.position == 3)
        #expect(
            try freshContext.fetch(FetchDescriptor<RoutineFolderModel>()).isEmpty,
            "successful isolated creation must not commit another tab's pending edit"
        )

        try context.save()
        let afterSeparateSave = ModelContext(container)
        #expect(try afterSeparateSave.fetch(FetchDescriptor<RoutineFolderModel>()).count == 1)
    }
}
