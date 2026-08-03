import Foundation
import SwiftData
import Testing
@testable import ForgeData

@Suite struct ExperimentModelTests {
    private func modelNames(_ models: [any PersistentModel.Type]) -> Set<String> {
        Set(models.map { String(describing: $0) })
    }

    @Test func experimentModelsAreLogOnlyAndRelationshipFree() {
        let expected: Set<String> = [
            "ExperimentModel",
            "ExperimentTrackerModel",
            "ExperimentEntryModel",
        ]
        let logNames = modelNames(ForgeDataSchema.logModels)
        let planNames = modelNames(ForgeDataSchema.planModels)

        #expect(expected.isSubset(of: logNames))
        #expect(expected.intersection(planNames).isEmpty)

        let schema = Schema(ForgeDataSchema.models)
        for entity in schema.entities where expected.contains(entity.name) {
            #expect(entity.relationships.isEmpty, "\(entity.name) must use UUID scalar references only")
        }
    }

    @Test func initializerDefaultsAndWindowHelpersAreDeterministic() {
        let userID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 7 * 86_400)
        let experiment = ExperimentModel(
            userID: userID,
            name: "Creatine block",
            startedAt: start,
            plannedEndAt: end,
            timeZoneIdentifier: "America/New_York"
        )

        #expect(experiment.state == .active)
        #expect(experiment.isActive)
        #expect(experiment.headlineMetricSelectionsJSON == "[]")
        #expect(experiment.savedComparisonJSON == nil)
        #expect(!experiment.reminderEnabled)
        #expect(experiment.reminderTimeMinutes == nil)
        #expect(experiment.resultsViewedAt == nil)
        #expect(experiment.schemaVersion == 1)
        #expect(experiment.deletedAt == nil)
        #expect(experiment.contains(start, asOf: end))
        #expect(experiment.contains(end.addingTimeInterval(-1), asOf: end))
        #expect(!experiment.contains(end, asOf: end))
        #expect(!experiment.contains(start.addingTimeInterval(-1), asOf: end))

        let earlyEnd = start.addingTimeInterval(14 * 86_400)
        experiment.endedAt = earlyEnd
        experiment.state = .completed
        #expect(!experiment.isActive)
        #expect(experiment.observationEnd(asOf: end) == earlyEnd)

        experiment.stateRaw = "future-state"
        #expect(experiment.state == .completed)
        #expect(!experiment.isActive)
    }

    @Test func trackerMetadataAndEntryValuesUseTypedFailSafeAccessors() {
        let experimentID = UUID()
        let tracker = ExperimentTrackerModel(
            userID: UUID(),
            experimentID: experimentID,
            label: "Dose",
            type: .number,
            unit: "mg",
            options: ["Low", "Standard"],
            cadence: .selectedWeekdays,
            selectedWeekdays: [2, 4, 6]
        )

        #expect(tracker.type == .number)
        #expect(tracker.cadence == .selectedWeekdays)
        #expect(tracker.options == ["Low", "Standard"])
        #expect(tracker.selectedWeekdays == [2, 4, 6])
        #expect(!tracker.isArchived)

        tracker.typeRaw = "future-type"
        tracker.cadenceRaw = "future-cadence"
        tracker.optionsJSON = "{malformed"
        tracker.selectedWeekdaysJSON = "{malformed"
        #expect(tracker.type == .note)
        #expect(tracker.cadence == .anytime)
        #expect(tracker.options.isEmpty)
        #expect(tracker.selectedWeekdays.isEmpty)

        let entry = ExperimentEntryModel(
            userID: tracker.userID,
            experimentID: experimentID,
            trackerID: tracker.id,
            value: .number(5)
        )
        #expect(entry.value == .number(5))
        #expect(entry.numericValue == 5)
        #expect(entry.booleanValue == nil)

        entry.value = .boolean(false)
        #expect(entry.value == .boolean(false))
        #expect(entry.numericValue == nil)
        #expect(entry.booleanValue == false)
        #expect(entry.ratingValue == nil)
        #expect(entry.choiceValue == nil)
        #expect(entry.textValue == nil)

        entry.value = nil
        #expect(entry.value == nil)
        #expect(entry.valueTypeRaw.isEmpty)
        #expect(entry.booleanValue == nil)
    }

    @MainActor
    @Test func experimentGraphRoundTripsThroughSwiftDataUsingUUIDReferences() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let userID = UUID()
        let experimentID = UUID()
        let trackerID = UUID()
        let workoutID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let experiment = ExperimentModel(
            id: experimentID,
            userID: userID,
            name: "Eight week protocol",
            protocolDescription: "Take after breakfast",
            question: "Does training volume improve?",
            startedAt: start,
            plannedEndAt: start.addingTimeInterval(8 * 7 * 86_400),
            timeZoneIdentifier: "America/New_York",
            headlineMetricSelectionsJSON: #"[{"metricID":"strength.volume"}]"#,
            savedComparisonJSON: #"{"kind":"previousEqualPeriod"}"#,
            reminderEnabled: true,
            reminderTimeMinutes: 8 * 60
        )
        let tracker = ExperimentTrackerModel(
            id: trackerID,
            userID: userID,
            experimentID: experimentID,
            label: "Session energy",
            type: .rating,
            scaleMinimumLabel: "Drained",
            scaleMaximumLabel: "Excellent",
            cadence: .perWorkout,
            position: 2
        )
        let entry = ExperimentEntryModel(
            userID: userID,
            experimentID: experimentID,
            trackerID: trackerID,
            workoutID: workoutID,
            observedAt: start.addingTimeInterval(3_600),
            value: .rating(4),
            definitionSnapshotJSON: #"{"label":"Session energy","type":"rating"}"#
        )

        context.insert(experiment)
        context.insert(tracker)
        context.insert(entry)
        try context.save()

        let reloadContext = ModelContext(container)
        let reloadedExperiment = try #require(
            try reloadContext.fetch(FetchDescriptor<ExperimentModel>()).first
        )
        let reloadedTracker = try #require(
            try reloadContext.fetch(FetchDescriptor<ExperimentTrackerModel>()).first
        )
        let reloadedEntry = try #require(
            try reloadContext.fetch(FetchDescriptor<ExperimentEntryModel>()).first
        )

        #expect(reloadedExperiment.id == experimentID)
        #expect(reloadedExperiment.protocolDescription == "Take after breakfast")
        #expect(reloadedExperiment.question == "Does training volume improve?")
        #expect(reloadedExperiment.headlineMetricSelectionsJSON == #"[{"metricID":"strength.volume"}]"#)
        #expect(reloadedExperiment.reminderTimeMinutes == 480)
        #expect(reloadedTracker.experimentID == experimentID)
        #expect(reloadedTracker.type == .rating)
        #expect(reloadedTracker.cadence == .perWorkout)
        #expect(reloadedEntry.experimentID == experimentID)
        #expect(reloadedEntry.trackerID == trackerID)
        #expect(reloadedEntry.workoutID == workoutID)
        #expect(reloadedEntry.value == .rating(4))
        #expect(reloadedEntry.definitionSnapshotJSON.contains("Session energy"))
    }
}
