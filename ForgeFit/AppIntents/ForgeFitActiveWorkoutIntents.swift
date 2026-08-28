import AppIntents
import ForgeCore
import Foundation

// MARK: - Active set entity

nonisolated struct ForgeFitActiveSetEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Workout Set",
        numericFormat: "\(placeholder: .int) workout sets"
    )
    static let defaultQuery = ForgeFitActiveSetQuery()

    let id: String
    let name: String
    let detail: String
    let isCompleted: Bool

    init(_ snapshot: ForgeFitActiveSetSnapshot) {
        id = snapshot.identifier
        name = snapshot.spokenName
        detail = "\(snapshot.workoutTitle) · \(snapshot.isCompleted ? "Complete" : "Incomplete")"
        isCompleted = snapshot.isCompleted
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(detail)",
            image: .init(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
        )
    }
}

struct ForgeFitActiveSetQuery: EntityStringQuery, EnumerableEntityQuery {
    @Dependency private var service: ForgeFitActiveWorkoutIntentService

    func entities(for identifiers: [String]) async throws -> [ForgeFitActiveSetEntity] {
        let requested = Set(identifiers)
        return await service.activeSetSnapshots()
            .filter { requested.contains($0.identifier) }
            .map(ForgeFitActiveSetEntity.init)
    }

    func entities(matching string: String) async throws -> [ForgeFitActiveSetEntity] {
        let snapshots = await service.activeSetSnapshots()
        let queryKeys = searchKeys(for: string)
        guard !queryKeys.isEmpty else { return snapshots.map(ForgeFitActiveSetEntity.init) }

        let exact = snapshots.filter { snapshot in
            let keys = searchKeys(for: snapshot.spokenName)
            return !queryKeys.isDisjoint(with: keys)
        }
        if !exact.isEmpty { return exact.map(ForgeFitActiveSetEntity.init) }

        let compactQuery = comparisonKey(string)
        return snapshots.filter { snapshot in
            let compactName = comparisonKey(snapshot.spokenName)
            return compactName.contains(compactQuery) || compactQuery.contains(compactName)
        }
        .map(ForgeFitActiveSetEntity.init)
    }

    func allEntities() async throws -> [ForgeFitActiveSetEntity] {
        await service.activeSetSnapshots().map(ForgeFitActiveSetEntity.init)
    }

    func suggestedEntities() async throws -> [ForgeFitActiveSetEntity] {
        let snapshots = await service.activeSetSnapshots()
        return (snapshots.filter { !$0.isCompleted } + Array(snapshots.filter(\.isCompleted).reversed()))
            .map(ForgeFitActiveSetEntity.init)
    }

    private func searchKeys(for value: String) -> Set<String> {
        Set(WorkoutChoiceNameMatcher.spokenAliases(for: value).map(comparisonKey))
    }

    private func comparisonKey(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US")
            )
            .replacing("&", with: " and ")
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}

// MARK: - Set commands

enum ForgeFitSetAction: String, AppEnum {
    case complete
    case update
    case reopen

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Set Action")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .complete: DisplayRepresentation(title: "Complete"),
        .update: DisplayRepresentation(title: "Update"),
        .reopen: DisplayRepresentation(title: "Reopen"),
    ]
}

enum ForgeFitSetField: String, AppEnum {
    case reps
    case load
    case rpe
    case rir
    case partialReps

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Set Field")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .reps: DisplayRepresentation(title: "Reps"),
        .load: DisplayRepresentation(title: "Load", synonyms: ["Weight"]),
        .rpe: DisplayRepresentation(title: "RPE", synonyms: ["Effort"]),
        .rir: DisplayRepresentation(title: "RIR", synonyms: ["Reps in reserve"]),
        .partialReps: DisplayRepresentation(
            title: "Lengthened partial reps",
            synonyms: ["Partial reps", "Partials"]
        ),
    ]
}

struct ManageForgeFitSetIntent: AppIntent {
    static let title: LocalizedStringResource = "Manage Active Workout Set"
    static let description = IntentDescription(
        "Completes, updates, or reopens an identity-bound set in the active ForgeFit workout."
    )
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Action", default: .complete)
    var action: ForgeFitSetAction

    @Parameter(title: "Set")
    var targetSet: ForgeFitActiveSetEntity?

    @Parameter(title: "Reps")
    var reps: Int?

    @Parameter(
        title: "Load",
        defaultUnit: .pounds,
        defaultUnitAdjustForLocale: true,
        supportsNegativeNumbers: false
    )
    var load: Measurement<UnitMass>?

    @Parameter(title: "RPE")
    var rpe: Double?

    @Parameter(title: "RIR")
    var rir: Int?

    @Parameter(title: "Lengthened partial reps")
    var partialReps: Int?

    @Parameter(title: "Field to update")
    var updateField: ForgeFitSetField?

    @Dependency private var service: ForgeFitActiveWorkoutIntentService
    @Dependency private var navigator: ForgeFitIntentNavigator

    static var parameterSummary: some ParameterSummary {
        Switch(\.$action) {
            Case(.complete) {
                Summary("Complete \(\.$targetSet) with \(\.$reps) reps, \(\.$load), RPE \(\.$rpe), RIR \(\.$rir), and \(\.$partialReps) partial reps")
            }
            Case(.update) {
                Summary("Update \(\.$targetSet) \(\.$updateField) with \(\.$reps) reps, \(\.$load), RPE \(\.$rpe), RIR \(\.$rir), and \(\.$partialReps) partial reps")
            }
            DefaultCase() {
                Summary("Reopen \(\.$targetSet)")
            }
        }
    }

    init() {
        action = .complete
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog: String = switch action {
        case .complete:
            try await completeSetDialog()
        case .update:
            try await updateSetDialog()
        case .reopen:
            try await reopenSetDialog()
        }
        return .result(dialog: "\(dialog)")
    }

    @MainActor
    private func completeSetDialog() async throws -> String {
        guard let snapshot = selectedSnapshot(defaultingTo: service.nextPendingSet()) else {
            return "No incomplete set is available in an active ForgeFit workout."
        }
        if snapshot.needsSpecializedUI {
            try await openSpecializedControls(for: snapshot)
            return "Opening \(snapshot.spokenName) in ForgeFit for its dedicated live controls."
        }

        let values: ForgeFitSetCommandValues
        do {
            values = try await completionValues(for: snapshot)
            try validate(values, for: snapshot)
        } catch let error as ForgeFitActiveWorkoutCommandError {
            return error.message
        }

        try await requestConfirmation(
            conditions: [],
            actionName: .custom(
                acceptLabel: "Complete Set",
                acceptAlternatives: ["Complete", "Log Set"],
                denyLabel: "Cancel",
                denyAlternatives: ["Keep Logging"]
            ),
            dialog: "Mark \(snapshot.spokenName) complete with \(valuesText(values, snapshot: snapshot))?"
        )

        do {
            let completed = try service.completeSet(expected: snapshot, values: values)
            let next = service.nextPendingSet()
            let nextText = next.map { " Next is \($0.spokenName)." } ?? " All sets are complete."
            return "Completed \(completed.spokenName).\(nextText)"
        } catch let error as ForgeFitActiveWorkoutCommandError {
            return error.message
        }
    }

    @MainActor
    private func updateSetDialog() async throws -> String {
        guard let snapshot = selectedSnapshot(
            defaultingTo: service.mostRecentlyCompletedSet() ?? service.nextPendingSet()
        ) else {
            return "No set is available in an active ForgeFit workout."
        }
        if snapshot.needsSpecializedUI {
            try await openSpecializedControls(for: snapshot)
            return "Opening \(snapshot.spokenName) in ForgeFit for its dedicated live controls."
        }

        let values: ForgeFitSetCommandValues
        do {
            values = try await updateValues(for: snapshot)
            try validate(values, for: snapshot)
        } catch let error as ForgeFitActiveWorkoutCommandError {
            return error.message
        }

        try await requestConfirmation(
            conditions: [],
            actionName: .custom(
                acceptLabel: "Update Set",
                acceptAlternatives: ["Update", "Save Changes"],
                denyLabel: "Cancel",
                denyAlternatives: ["Keep Current Values"]
            ),
            dialog: "Update \(snapshot.spokenName) to \(valuesText(values, snapshot: snapshot))?"
        )

        do {
            let updated = try service.updateSet(expected: snapshot, values: values)
            return "Updated \(updated.spokenName)."
        } catch let error as ForgeFitActiveWorkoutCommandError {
            return error.message
        }
    }

    @MainActor
    private func reopenSetDialog() async throws -> String {
        guard let snapshot = selectedSnapshot(
            defaultingTo: service.mostRecentlyCompletedSet()
        ) else {
            return "No completed set is available in the active ForgeFit workout."
        }
        if snapshot.needsSpecializedUI {
            try await openSpecializedControls(for: snapshot)
            return "Opening \(snapshot.spokenName) in ForgeFit for its dedicated live controls."
        }

        try await requestConfirmation(
            conditions: [],
            actionName: .custom(
                acceptLabel: "Reopen Set",
                acceptAlternatives: ["Reopen"],
                denyLabel: "Cancel",
                denyAlternatives: ["Leave Complete"]
            ),
            dialog: "Reopen \(snapshot.spokenName) and mark it incomplete? Its logged values will stay in place."
        )

        do {
            let reopened = try service.reopenSet(expected: snapshot)
            return "Reopened \(reopened.spokenName). Its values are unchanged."
        } catch let error as ForgeFitActiveWorkoutCommandError {
            return error.message
        }
    }

    @MainActor
    private func completionValues(
        for snapshot: ForgeFitActiveSetSnapshot
    ) async throws -> ForgeFitSetCommandValues {
        var values = explicitValues()
        if values.rpe != nil, values.rir != nil {
            throw ForgeFitActiveWorkoutCommandError(message: "Give either RPE or RIR for one set, not both.")
        }

        if values.reps == nil {
            if let suggestedReps = snapshot.reps {
                values.reps = suggestedReps
            } else {
                values.reps = try await $reps.requestValue(
                    "How many reps did you complete for \(snapshot.exerciseName)?"
                )
            }
        }
        if snapshot.weightMode == .bodyweight {
            if values.loadKilograms != nil {
                throw ForgeFitActiveWorkoutCommandError(
                    message: "Pure bodyweight sets don't have a separate load value."
                )
            }
        } else if values.loadKilograms == nil {
            if let suggested = snapshot.loadKilograms {
                values.loadKilograms = suggested
            } else {
                let requested: Measurement<UnitMass> = try await $load.requestValue(
                    "What load did you use for \(snapshot.exerciseName)? Include pounds or kilograms."
                )
                values.loadKilograms = requested.converted(to: .kilograms).value
            }
        }

        if snapshot.logsEffort {
            if values.rpe == nil, values.rir == nil {
                if let suggested = snapshot.rpe {
                    values.rpe = suggested
                } else if preferredEffortScale == .rir {
                    values.rir = try await $rir.requestValue(
                        "How many reps in reserve did you have, from 0 to 10?"
                    )
                } else {
                    values.rpe = try await $rpe.requestValue(
                        "What was the set RPE, from 0 to 10?"
                    )
                }
            }
        } else if values.rpe != nil || values.rir != nil {
            throw ForgeFitActiveWorkoutCommandError(
                message: "Per-set effort logging is off in ForgeFit Settings, so I didn't save an RPE or RIR."
            )
        }

        if snapshot.setType.tracksTrailingPartials, values.partialReps == nil {
            if let suggestedPartialReps = snapshot.partialReps {
                values.partialReps = suggestedPartialReps
            } else {
                values.partialReps = try await $partialReps.requestValue(
                    "How many lengthened partial reps followed the full-range reps?"
                )
            }
        }
        return values
    }

    @MainActor
    private func updateValues(
        for snapshot: ForgeFitActiveSetSnapshot
    ) async throws -> ForgeFitSetCommandValues {
        var values = explicitValues()
        if values.rpe != nil, values.rir != nil {
            throw ForgeFitActiveWorkoutCommandError(message: "Give either RPE or RIR for one set, not both.")
        }
        guard !values.hasAnyValue else { return values }

        let field: ForgeFitSetField
        if let updateField {
            field = updateField
        } else {
            field = try await $updateField.requestValue(
                "Which value should I update: reps, load, RPE, RIR, or lengthened partial reps?"
            )
        }
        switch field {
        case .reps:
            values.reps = try await $reps.requestValue("What should the reps be?")
        case .load:
            guard snapshot.weightMode != .bodyweight else {
                throw ForgeFitActiveWorkoutCommandError(
                    message: "Pure bodyweight sets don't have a separate load value."
                )
            }
            let requested: Measurement<UnitMass> = try await $load.requestValue(
                "What should the load be? Include pounds or kilograms."
            )
            values.loadKilograms = requested.converted(to: .kilograms).value
        case .rpe:
            guard snapshot.logsEffort else {
                throw ForgeFitActiveWorkoutCommandError(
                    message: "Per-set effort logging is off in ForgeFit Settings."
                )
            }
            values.rpe = try await $rpe.requestValue("What should the RPE be, from 0 to 10?")
        case .rir:
            guard snapshot.logsEffort else {
                throw ForgeFitActiveWorkoutCommandError(
                    message: "Per-set effort logging is off in ForgeFit Settings."
                )
            }
            values.rir = try await $rir.requestValue("What should the RIR be, from 0 to 10?")
        case .partialReps:
            guard snapshot.setType.tracksTrailingPartials else {
                throw ForgeFitActiveWorkoutCommandError(
                    message: "\(snapshot.spokenName) doesn't have a lengthened-partials field."
                )
            }
            values.partialReps = try await $partialReps.requestValue(
                "What should the lengthened partial reps be?"
            )
        }
        return values
    }

    private func explicitValues() -> ForgeFitSetCommandValues {
        ForgeFitSetCommandValues(
            reps: reps,
            loadKilograms: load?.converted(to: .kilograms).value,
            rpe: rpe,
            rir: rir,
            partialReps: partialReps
        )
    }

    private func validate(
        _ values: ForgeFitSetCommandValues,
        for snapshot: ForgeFitActiveSetSnapshot
    ) throws {
        if let reps = values.reps, !(0...1000).contains(reps) {
            throw ForgeFitActiveWorkoutCommandError(message: "Reps must be between 0 and 1,000.")
        }
        if let partialReps = values.partialReps, !(0...1000).contains(partialReps) {
            throw ForgeFitActiveWorkoutCommandError(
                message: "Lengthened partial reps must be between 0 and 1,000."
            )
        }
        if let load = values.loadKilograms,
           !load.isFinite || !(0...2000).contains(load) {
            throw ForgeFitActiveWorkoutCommandError(
                message: "The load must be between 0 and 2,000 kilograms."
            )
        }
        if let rpe = values.rpe, !rpe.isFinite || !(0...10).contains(rpe) {
            throw ForgeFitActiveWorkoutCommandError(message: "RPE must be between 0 and 10.")
        }
        if let rir = values.rir, !(0...10).contains(rir) {
            throw ForgeFitActiveWorkoutCommandError(message: "RIR must be between 0 and 10.")
        }
        if values.rpe != nil, values.rir != nil {
            throw ForgeFitActiveWorkoutCommandError(message: "Give either RPE or RIR for one set, not both.")
        }
        if !snapshot.logsEffort, values.rpe != nil || values.rir != nil {
            throw ForgeFitActiveWorkoutCommandError(
                message: "Per-set effort logging is off in ForgeFit Settings, so I didn't save an RPE or RIR."
            )
        }
        if snapshot.weightMode == .bodyweight, values.loadKilograms != nil {
            throw ForgeFitActiveWorkoutCommandError(
                message: "Pure bodyweight sets don't have a separate load value."
            )
        }
        if values.partialReps != nil, !snapshot.setType.tracksTrailingPartials {
            throw ForgeFitActiveWorkoutCommandError(
                message: "\(snapshot.spokenName) doesn't have a lengthened-partials field."
            )
        }
    }

    @MainActor
    private func selectedSnapshot(
        defaultingTo fallback: ForgeFitActiveSetSnapshot?
    ) -> ForgeFitActiveSetSnapshot? {
        if let targetSet {
            return service.setSnapshot(identifier: targetSet.id)
        }
        return fallback
    }

    @MainActor
    private func openSpecializedControls(for snapshot: ForgeFitActiveSetSnapshot) async throws {
        try await continueInForeground(
            "\(snapshot.spokenName) uses dedicated live controls. Open ForgeFit?"
        )
        navigator.navigate(to: .resumeWorkout)
    }

    private var preferredEffortScale: EffortScale {
        EffortScale(
            rawValue: UserDefaults.standard.string(forKey: "effortScaleRaw") ?? "rpe"
        ) ?? .rpe
    }

    private func valuesText(
        _ values: ForgeFitSetCommandValues,
        snapshot: ForgeFitActiveSetSnapshot
    ) -> String {
        var parts: [String] = []
        if let reps = values.reps { parts.append("\(reps) reps") }
        switch snapshot.weightMode {
        case .bodyweight:
            parts.append("bodyweight")
        case .bodyweightAdded:
            if let load = values.loadKilograms {
                parts.append("bodyweight plus \(loadText(load, unit: snapshot.displayUnit))")
            }
        case .bodyweightAssisted:
            if let load = values.loadKilograms {
                parts.append("\(loadText(load, unit: snapshot.displayUnit)) assistance")
            }
        case .external:
            if let load = values.loadKilograms {
                parts.append(loadText(load, unit: snapshot.displayUnit))
            }
        }
        if let partials = values.partialReps {
            parts.append("\(partials) lengthened partial reps")
        }
        if let rpe = values.rpe {
            parts.append("RPE \(numberText(rpe))")
        } else if let rir = values.rir {
            parts.append("RIR \(rir)")
        }
        return parts.joined(separator: ", ")
    }

    private func loadText(_ kilograms: Double, unit: WeightUnit) -> String {
        let maximumFractionDigits = unit == .kg ? 2 : 1
        let value = unit.displayValue(fromKilograms: kilograms)
            .formatted(.number.precision(.fractionLength(0...maximumFractionDigits)))
        return "\(value) \(unit.shortSuffix)"
    }

    private func numberText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

// MARK: - Status and rest

struct GetForgeFitActiveWorkoutStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Active Workout Status"
    static let description = IntentDescription(
        "Reports active workout progress, rest time, and the exact next set target."
    )
    static var supportedModes: IntentModes { .background }

    @Dependency private var service: ForgeFitActiveWorkoutIntentService

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(service.statusText())")
    }
}

enum ForgeFitRestAction: String, AppEnum {
    case check
    case skip
    case addFifteenSeconds
    case subtractFifteenSeconds

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Rest Action")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .check: DisplayRepresentation(title: "Check"),
        .skip: DisplayRepresentation(title: "Skip", synonyms: ["End"]),
        .addFifteenSeconds: DisplayRepresentation(
            title: "Add 15 seconds",
            synonyms: ["Add time", "Increase"]
        ),
        .subtractFifteenSeconds: DisplayRepresentation(
            title: "Subtract 15 seconds",
            synonyms: ["Reduce", "Decrease"]
        ),
    ]
}

struct ControlForgeFitRestIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Rest Timer"
    static let description = IntentDescription(
        "Checks, skips, or adjusts the active ordinary rest timer."
    )
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Action", default: .check)
    var action: ForgeFitRestAction

    @Dependency private var service: ForgeFitActiveWorkoutIntentService
    @Dependency private var navigator: ForgeFitIntentNavigator

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) the active rest timer")
    }

    init() {
        action = .check
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let message: String = switch action {
            case .check:
                service.restStatusText()
            case .skip:
                try service.skipOrdinaryRest()
            case .addFifteenSeconds:
                try service.adjustOrdinaryRest(by: 15)
            case .subtractFifteenSeconds:
                try service.adjustOrdinaryRest(by: -15)
            }
            return .result(dialog: "\(message)")
        } catch let error as ForgeFitActiveWorkoutCommandError {
            if error.message.contains("dedicated controls") {
                try await continueInForeground("\(error.message) Open ForgeFit?")
                navigator.navigate(to: .resumeWorkout)
            }
            return .result(dialog: "\(error.message)")
        }
    }
}

// MARK: - Finish

struct FinishForgeFitWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Active Workout"
    static let description = IntentDescription(
        "Finishes the active ForgeFit workout after confirming its completed and incomplete work."
    )
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Whole-session exertion")
    var exertion: Int?

    @Dependency private var service: ForgeFitActiveWorkoutIntentService

    static var parameterSummary: some ParameterSummary {
        Summary("Finish the active workout with session exertion \(\.$exertion)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let preview: ForgeFitWorkoutFinishPreview
        do {
            preview = try service.finishPreview()
        } catch let error as ForgeFitActiveWorkoutCommandError {
            return .result(dialog: "\(error.message)")
        }

        if !preview.hasSubstance {
            try await requestConfirmation(
                conditions: [],
                actionName: .custom(
                    acceptLabel: "Discard Empty Workout",
                    acceptAlternatives: ["Discard"],
                    denyLabel: "Keep Workout",
                    denyAlternatives: ["Cancel"],
                    destructive: true
                ),
                dialog: "\(preview.title) is empty. Finishing will discard it, and it won't appear in history."
            )
            do {
                try service.finishWorkout(expected: preview, exertion: nil)
                return .result(dialog: "Discarded the empty workout.")
            } catch let error as ForgeFitActiveWorkoutCommandError {
                return .result(dialog: "\(error.message)")
            }
        }

        let resolvedExertion: Int
        if let exertion {
            resolvedExertion = exertion
        } else {
            resolvedExertion = try await $exertion.requestValue(
                "What was your overall session exertion from 0 to 10?"
            )
        }
        guard (0...10).contains(resolvedExertion) else {
            return .result(dialog: "Whole-session exertion must be from 0 to 10.")
        }
        let incomplete = preview.incompleteMessage.isEmpty
            ? "All planned sets are marked complete."
            : preview.incompleteMessage
        try await requestConfirmation(
            conditions: [],
            actionName: .custom(
                acceptLabel: "Finish Workout",
                acceptAlternatives: ["Finish", "Save Workout"],
                denyLabel: "Keep Logging",
                denyAlternatives: ["Cancel"]
            ),
            dialog: "Finish \(preview.title) with \(preview.completedSetCount) of \(preview.totalSetCount) sets complete and exertion \(resolvedExertion) of 10? \(incomplete) This saves today's workout without changing the reusable routine."
        )

        do {
            try service.finishWorkout(expected: preview, exertion: resolvedExertion)
            return .result(
                dialog: "Finished \(preview.title) at exertion \(resolvedExertion) of 10. Today's workout is saved; the reusable routine is unchanged."
            )
        } catch let error as ForgeFitActiveWorkoutCommandError {
            return .result(dialog: "\(error.message)")
        }
    }
}
