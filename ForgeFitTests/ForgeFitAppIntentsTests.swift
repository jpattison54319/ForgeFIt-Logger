import AppIntents
import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct ForgeFitAppIntentsTests {
    @Test func modernEntityQueryReceivesAndResolvesSpokenWorkoutNameText() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: WorkoutChoiceCatalogStore.suiteName)
        )
        let previousCatalog = defaults.data(forKey: WorkoutChoiceCatalogStore.key)
        let previousDiagnostic = defaults.data(forKey: WorkoutIntentDiagnosticStore.key)
        defer {
            restore(
                previousCatalog,
                key: WorkoutChoiceCatalogStore.key,
                defaults: defaults
            )
            restore(
                previousDiagnostic,
                key: WorkoutIntentDiagnosticStore.key,
                defaults: defaults
            )
        }

        let records = [
            WorkoutChoiceRecord(
                id: "routine:00000000-0000-7000-8000-000000000921",
                title: "AX400",
                subtitle: "Saved routine",
                systemImageName: "list.bullet.clipboard"
            ),
            WorkoutChoiceRecord(
                id: "routine:00000000-0000-7000-8000-000000000922",
                title: "Cindy",
                subtitle: "Saved routine",
                systemImageName: "list.bullet.clipboard"
            ),
        ]
        WorkoutChoiceCatalogStore.save(records, defaults: defaults)

        let entities = try await ForgeFitWorkoutChoiceQuery().entities(
            matching: "start my A X four hundred workout on ForgeFit"
        )

        #expect(entities.map(\.name) == ["AX400"])
        #expect(!entities.contains(where: { $0.name == "Cindy" }))
        requireModernWorkoutSystemIntent(StartForgeFitWorkoutIntent.self)
        let namedIntent = StartForgeFitWorkoutIntent(style: try #require(entities.first))
        #expect(namedIntent.workoutStyle.id == records[0].id)
        #expect(
            StartForgeFitWorkoutIntent.suggestedWorkouts.first?.workoutStyle.id
                == WorkoutChoiceTarget.next.identifier
        )
        #expect(
            StartForgeFitWorkoutIntent.suggestedWorkouts.contains {
                $0.workoutStyle.id == records[0].id
            }
        )
        let diagnostic = await WorkoutIntentDiagnosticStore.shared.snapshot()
        #expect(diagnostic?.queryText == "start my A X four hundred workout on ForgeFit")
        #expect(diagnostic?.selectedTitle == "AX400")
        #expect(diagnostic?.outcome == .queryMatched)
    }

    @Test func activeWorkoutControlsAreModernAppIntentsWithinTheShortcutLimit() {
        requireModernAppIntent(GetForgeFitActiveWorkoutStatusIntent.self)
        requireModernAppIntent(ManageForgeFitSetIntent.self)
        requireModernAppIntent(ControlForgeFitRestIntent.self)
        requireModernAppIntent(FinishForgeFitWorkoutIntent.self)
        #expect(ForgeFitShortcuts.appShortcuts.count == 10)
    }

    private func requireModernWorkoutSystemIntent<Intent: StartWorkoutIntent>(
        _: Intent.Type
    ) {}

    private func requireModernAppIntent<Intent: AppIntent>(_: Intent.Type) {}

    private func restore(
        _ data: Data?,
        key: String,
        defaults: UserDefaults
    ) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
