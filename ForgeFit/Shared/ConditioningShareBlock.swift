import ForgeCore
import ForgeData
import SwiftUI

enum ConditioningSharePresentation {
    struct Context {
        let plan: ConditioningPlan
        let result: ConditioningResult?
    }

    struct Fact: Equatable {
        let label: String
        let value: String
    }

    enum CompletionStatus: Equatable {
        case completed
        case timeCap
        case incomplete
        case notLogged

        var label: String {
            switch self {
            case .completed: "Completed"
            case .timeCap: "Time cap"
            case .incomplete: "Incomplete"
            case .notLogged: "Skipped"
            }
        }
    }

    static func contexts(for workout: WorkoutModel) -> [Context] {
        let blocks = workout.blocks
            .filter { $0.kind == .conditioning }
            .sorted { $0.position < $1.position }
            .compactMap { block -> Context? in
                guard let plan = ConditioningPlan.decode(from: block.planSnapshotJSON) else { return nil }
                return Context(plan: plan, result: ConditioningResult.decode(from: block.resultJSON))
            }
        if !blocks.isEmpty { return blocks }
        guard let plan = ConditioningPlan.decode(from: workout.conditioningPlanSnapshotJSON) else { return [] }
        return [Context(plan: plan, result: ConditioningResult.decode(from: workout.conditioningResultJSON))]
    }

    static func primaryContext(for workout: WorkoutModel) -> Context? {
        contexts(for: workout).first
    }

    static func completionStatus(for context: Context) -> CompletionStatus {
        guard let result = context.result else { return .notLogged }
        let plannedIDs = Set(context.plan.sections.map(\.id))
        let resultByID = Dictionary(
            result.sectionResults.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if !plannedIDs.isEmpty,
           plannedIDs.allSatisfy({ resultByID[$0]?.completed == true }) {
            return .completed
        }
        if context.plan.sections.contains(where: { section in
            guard let sectionResult = resultByID[section.id] else { return false }
            return completionStatus(section: section, result: sectionResult) == .timeCap
        }) {
            return .timeCap
        }
        return .incomplete
    }

    static func completionStatus(
        section: ConditioningSection,
        result: ConditioningSectionResult
    ) -> CompletionStatus {
        if result.completed { return .completed }
        if let cap = section.timeCapSeconds,
           (result.elapsedSeconds ?? 0) >= cap {
            return .timeCap
        }
        return .incomplete
    }

    static func workoutFacts(
        for workout: WorkoutModel,
        durationSeconds: Int,
        avgHR: Int? = nil,
        activeEnergyKcal: Double? = nil,
        includePhysiology: Bool = false
    ) -> [Fact] {
        let contexts = contexts(for: workout)
        guard contexts.count > 1 else {
            guard let context = contexts.first else { return [] }
            return facts(
                for: context,
                durationSeconds: durationSeconds,
                avgHR: avgHR,
                activeEnergyKcal: activeEnergyKcal,
                includePhysiology: includePhysiology
            )
        }

        let totalReps = contexts
            .flatMap { $0.result?.sectionResults ?? [] }
            .compactMap(\.totalReps)
            .reduce(0, +)
        let statuses = contexts.map { completionStatus(for: $0) }
        let aggregateStatus: CompletionStatus = if statuses.allSatisfy({ $0 == .completed }) {
            .completed
        } else if statuses.contains(.timeCap) {
            .timeCap
        } else if statuses.allSatisfy({ $0 == .notLogged }) {
            .notLogged
        } else {
            .incomplete
        }
        var facts = [
            Fact(label: "Duration", value: Fmt.durationShort(durationSeconds)),
            Fact(label: "Blocks", value: "\(contexts.count)"),
            aggregateStatus == .completed
                ? (totalReps > 0
                    ? Fact(label: "Work", value: "\(totalReps) reps")
                    : Fact(label: "Sections", value: "\(contexts.flatMap { $0.plan.sections }.count)"))
                : Fact(label: "Status", value: aggregateStatus.label)
        ]
        if includePhysiology {
            appendPhysiology(
                to: &facts,
                avgHR: avgHR,
                activeEnergyKcal: activeEnergyKcal,
                movementCount: contexts.flatMap { $0.plan.sections }.flatMap(\.movements).count
            )
        }
        return facts
    }

    /// Three non-redundant headline facts for a conditioning share image. A
    /// for-time score already *is* elapsed time, so it replaces Duration rather
    /// than appearing beside an identical clock value.
    static func facts(
        for context: Context,
        durationSeconds: Int,
        avgHR: Int? = nil,
        activeEnergyKcal: Double? = nil,
        includePhysiology: Bool = false
    ) -> [Fact] {
        guard let section = primarySection(in: context) else {
            return [Fact(label: "Duration", value: Fmt.durationShort(durationSeconds))]
        }
        let result = context.result?.sectionResults.first { $0.id == section.id }
            ?? context.result?.sectionResults.first
        var facts: [Fact]
        if let result {
            let status = completionStatus(section: section, result: result)
            let performance = performanceFacts(section: section, result: result)
            let performanceFact: (String) -> Fact? = { label in
                performance.first { $0.label == label }
            }
            if status != .completed {
                facts = [
                    Fact(
                        label: result.scoreKind == .elapsedTime ? "Time" : "Score",
                        value: score(result)
                    ),
                    Fact(label: "Status", value: status.label),
                    performanceFact("Rounds")
                        ?? performanceFact("Intervals")
                        ?? performanceFact("Steps")
                        ?? performanceFact("Avg round")
                        ?? workFact(section: section, result: result)
                ]
            } else {
                switch result.scoreKind {
                case .elapsedTime:
                    if let average = performanceFact("Avg round") {
                        facts = [
                            Fact(label: "Time", value: score(result)),
                            average,
                            performanceFact("2nd half")
                                ?? performanceFact("Rep rate")
                                ?? workFact(section: section, result: result)
                        ]
                    } else {
                        facts = [
                            Fact(label: "Time", value: score(result)),
                            workFact(section: section, result: result),
                            performanceFact("Rep rate")
                                ?? Fact(label: "Format", value: formatName(section))
                        ]
                    }
                case .roundsAndReps:
                    facts = [
                        Fact(label: "Duration", value: Fmt.durationShort(durationSeconds)),
                        Fact(label: "Score", value: score(result)),
                        performanceFact("Avg round")
                            ?? performanceFact("Rep rate")
                            ?? workFact(section: section, result: result)
                    ]
                case .totalReps, .completedIntervals, .load:
                    facts = [
                        Fact(label: "Duration", value: Fmt.durationShort(durationSeconds)),
                        Fact(label: "Score", value: score(result)),
                        performance.first ?? workFact(section: section, result: result)
                    ]
                }
            }
        } else {
            facts = [
                Fact(label: "Duration", value: Fmt.durationShort(durationSeconds)),
                Fact(label: "Format", value: formatName(section)),
                Fact(label: "Plan", value: prescription(section))
            ]
        }

        if includePhysiology {
            appendPhysiology(
                to: &facts,
                avgHR: avgHR,
                activeEnergyKcal: activeEnergyKcal,
                movementCount: section.movements.count
            )
        }
        return facts
    }

    /// Metrics that describe conditioning execution rather than restating its
    /// score. Ordering reflects the most useful signals for the workout format
    /// and is shared by history plus every workout-image layout.
    static func performanceFacts(
        section: ConditioningSection,
        result: ConditioningSectionResult
    ) -> [Fact] {
        let analysis = ConditioningPerformanceAnalysis(section: section, result: result)
        var facts: [Fact] = []

        switch section.format {
        case .amrap, .forTime:
            if let average = analysis.averageRoundSeconds {
                facts.append(Fact(label: "Avg round", value: Fmt.elapsed(average)))
            }
            if let change = analysis.secondHalfPaceChangePercent {
                facts.append(Fact(label: "2nd half", value: paceChange(change)))
            }
            if analysis.roundSplits.count >= 2, let fastest = analysis.fastestRoundSeconds {
                facts.append(Fact(label: "Fastest", value: Fmt.elapsed(fastest)))
            }
            if let rate = analysis.repsPerMinute {
                facts.append(Fact(label: "Rep rate", value: "\(decimal(rate))/min"))
            }
            appendRoundProgress(to: &facts, section: section, analysis: analysis)
        case .emom:
            appendRoundProgress(to: &facts, section: section, analysis: analysis)
            if let missed = analysis.missedRounds, missed > 0 {
                facts.append(Fact(label: "Missed", value: "\(missed)"))
            }
            if let rate = analysis.repsPerMinute {
                facts.append(Fact(label: "Rep rate", value: "\(decimal(rate))/min"))
            }
        case .intervals:
            appendRoundProgress(to: &facts, section: section, analysis: analysis)
            if let reps = analysis.repsPerRound {
                facts.append(Fact(label: "Avg / interval", value: decimal(reps)))
            }
            if let rate = analysis.repsPerMinute {
                facts.append(Fact(label: "Rep rate", value: "\(decimal(rate))/min"))
            }
        case .ladder:
            if let rate = analysis.repsPerMinute {
                facts.append(Fact(label: "Rep rate", value: "\(decimal(rate))/min"))
            }
            appendRoundProgress(to: &facts, section: section, analysis: analysis)
        case .maxLoad:
            if analysis.completedRounds > 0 {
                facts.append(Fact(label: "Attempts", value: "\(analysis.completedRounds)"))
            }
            if let elapsed = result.elapsedSeconds, elapsed > 0 {
                facts.append(Fact(label: "Time", value: Fmt.elapsed(elapsed)))
            }
        }

        var seen: Set<String> = []
        return facts.filter { seen.insert($0.label).inserted }
    }

    static func score(_ result: ConditioningSectionResult?) -> String {
        guard let result else { return "—" }
        switch result.scoreKind {
        case .roundsAndReps:
            return "\(result.fullRounds ?? 0) rounds"
        case .elapsedTime:
            return Fmt.elapsed(result.elapsedSeconds ?? 0)
        case .totalReps:
            return "\(result.totalReps ?? 0) reps"
        case .completedIntervals:
            return "\(result.completedIntervals ?? 0) intervals"
        case .load:
            guard let load = result.load else { return "—" }
            return load.formatted(.number.precision(.fractionLength(0...1)))
        }
    }

    static func prescription(_ section: ConditioningSection) -> String {
        switch section.format {
        case .amrap:
            return "AMRAP · \(duration(section.durationSeconds))"
        case .forTime:
            let work = section.repScheme.isEmpty
                ? section.rounds.map { "\($0) rounds" } ?? "For time"
                : section.repScheme.map(String.init).joined(separator: "–")
            if let cap = section.timeCapSeconds { return "\(work) · \(duration(cap)) cap" }
            return work
        case .emom:
            let interval = section.intervalSeconds ?? 60
            return "Every \(duration(interval)) · \(section.rounds ?? 0) rounds"
        case .intervals:
            let work = duration(section.workSeconds)
            let rest = duration(section.restSeconds)
            return "\(section.rounds ?? 0) × \(work) / \(rest)"
        case .ladder:
            if !section.repScheme.isEmpty {
                let direction = zip(section.repScheme, section.repScheme.dropFirst()).allSatisfy { $0.0 > $0.1 }
                    ? "Descending ladder"
                    : "Ladder"
                return "\(direction) · \(section.repScheme.map(String.init).joined(separator: "–"))"
            }
            let step = section.ladderStep ?? 1
            return "Ladder · +\(step) each round"
        case .maxLoad:
            return section.rounds.map { "\($0) attempts" } ?? "For load"
        }
    }

    static func movement(
        _ movement: ConditioningMovement,
        section: ConditioningSection,
        exercise: ExerciseLibraryModel?
    ) -> String {
        let target: String
        if section.repScheme.isEmpty {
            target = value(movement.targetValue, unit: movement.targetUnit)
        } else {
            target = section.repScheme.map(String.init).joined(separator: "–") + " reps"
        }
        guard let load = movement.targetLoad else { return target }
        let unit = exercise?.effectiveWeightUnit ?? Fmt.unit
        let prefix = movement.weightMode == .bodyweightAssisted ? "assisted" : "at"
        return "\(target) · \(prefix) \(Fmt.load(load, unit: unit))"
    }

    private static func value(_ value: Double, unit: ConditioningTargetUnit) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        return "\(number) \(unit.shortLabel)"
    }

    private static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        if seconds >= 60, seconds % 60 == 0 { return "\(seconds / 60) min" }
        return Fmt.durationShort(seconds)
    }

    private static func primarySection(in context: Context) -> ConditioningSection? {
        guard let result = context.result?.sectionResults.first else { return context.plan.sections.first }
        return context.plan.sections.first { $0.id == result.id } ?? context.plan.sections.first
    }

    private static func formatName(_ section: ConditioningSection) -> String {
        if section.format == .ladder,
           !section.repScheme.isEmpty,
           zip(section.repScheme, section.repScheme.dropFirst()).allSatisfy({ $0.0 > $0.1 }) {
            return "Descending ladder"
        }
        return section.format.title
    }

    private static func workFact(
        section: ConditioningSection,
        result: ConditioningSectionResult
    ) -> Fact {
        if let total = result.totalReps {
            return Fact(label: "Work", value: "\(total) reps")
        }
        if section.movements.allSatisfy({ $0.targetUnit == .reps }),
           let rounds = section.prescribedRounds,
           rounds > 0 {
            let total = (1...rounds).reduce(0.0) { running, round in
                running + section.movements.reduce(0.0) {
                    $0 + section.target(for: $1, round: round)
                }
            }
            return Fact(label: "Work", value: "\(Int(total)) reps")
        }
        return Fact(label: "Movements", value: "\(section.movements.count)")
    }

    private static func appendPhysiology(
        to facts: inout [Fact],
        avgHR: Int?,
        activeEnergyKcal: Double?,
        movementCount: Int
    ) {
        if let avgHR {
            facts.append(Fact(label: "Avg HR", value: "\(avgHR)"))
        } else if let activeEnergyKcal {
            facts.append(Fact(label: "Energy", value: "\(Int(activeEnergyKcal)) kcal"))
        } else {
            facts.append(Fact(label: "Movements", value: "\(movementCount)"))
        }
    }

    private static func appendRoundProgress(
        to facts: inout [Fact],
        section: ConditioningSection,
        analysis: ConditioningPerformanceAnalysis
    ) {
        guard let prescribed = analysis.prescribedRounds else { return }
        let label: String = switch section.format {
        case .emom, .intervals: "Intervals"
        case .ladder: "Steps"
        case .amrap, .forTime, .maxLoad: "Rounds"
        }
        facts.append(Fact(label: label, value: "\(analysis.completedRounds) / \(prescribed)"))
    }

    private static func paceChange(_ percent: Double) -> String {
        guard abs(percent) >= 3 else { return "Even" }
        let value = abs(percent).formatted(.number.precision(.fractionLength(0)))
        return percent > 0 ? "\(value)% slower" : "\(value)% faster"
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

struct ConditioningShareBlock: View {
    let plan: ConditioningPlan
    var result: ConditioningResult?
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme
    var compact = false
    var showsResult = true
    var showsModalityHeader = false
    var showsPerformance = true
    var compactSectionLimit = 2
    var compactMovementLimit = 4
    /// Share-card headers already carry the routine or workout name. Section
    /// names come from the selected template, so sharing hides them by default.
    var showsSectionName = false

    private func exercise(_ id: UUID) -> ExerciseLibraryModel? {
        exercises.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if showsModalityHeader {
                HStack(spacing: 7) {
                    Image(systemName: "figure.cross.training")
                        .font(.system(size: compact ? 12 : 14, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text("Conditioning")
                        .font(.system(size: compact ? 14 : 16, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
                }
            }
            ForEach(Array(visibleSections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: compact ? 4 : 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            if showsSectionName {
                                Text(section.name.isEmpty ? section.format.title : section.name)
                                    .font(.system(size: compact ? 14 : 16, weight: .bold))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Text(ConditioningSharePresentation.prescription(section))
                                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                                    .foregroundStyle(theme.textSecondary)
                            } else {
                                Text(ConditioningSharePresentation.prescription(section))
                                    .font(.system(size: compact ? 14 : 16, weight: .bold))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if showsResult,
                           let sectionResult = result?.sectionResults.first(where: { $0.id == section.id }) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(ConditioningSharePresentation.score(sectionResult))
                                    .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.accent)
                                    .lineLimit(1)
                                let status = ConditioningSharePresentation.completionStatus(
                                    section: section,
                                    result: sectionResult
                                )
                                if status != .completed {
                                    Text(status.label.uppercased())
                                        .font(.system(size: compact ? 8 : 9, weight: .heavy))
                                        .foregroundStyle(theme.warmup)
                                }
                            }
                        }
                    }
                    if showsPerformance,
                       let sectionResult = result?.sectionResults.first(where: { $0.id == section.id }) {
                        let facts = ConditioningSharePresentation.performanceFacts(
                            section: section,
                            result: sectionResult
                        )
                        if !facts.isEmpty {
                            ConditioningShareMetricsRow(facts: facts, theme: theme, compact: compact)
                        }
                    }
                    ForEach(Array(section.movements.prefix(
                        compact ? compactMovementLimit : section.movements.count
                    ))) { movement in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(exercise(movement.exerciseID)?.name ?? "Exercise")
                                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ConditioningSharePresentation.movement(
                                movement,
                                section: section,
                                exercise: exercise(movement.exerciseID)
                            ))
                            .font(.system(size: compact ? 10 : 11, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        }
                    }
                    if compact, section.movements.count > compactMovementLimit {
                        Text("+\(section.movements.count - compactMovementLimit) movements")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                if index < visibleSections.count - 1 {
                    Rectangle().fill(theme.separator).frame(height: 1)
                }
            }
            if compact, plan.sections.count > visibleSections.count {
                Text("+\(plan.sections.count - visibleSections.count) more section\(plan.sections.count - visibleSections.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous))
    }

    private var visibleSections: [ConditioningSection] {
        compact ? Array(plan.sections.prefix(compactSectionLimit)) : plan.sections
    }
}
