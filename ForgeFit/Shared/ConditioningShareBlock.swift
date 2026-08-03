import ForgeCore
import ForgeData
import SwiftUI

enum ConditioningSharePresentation {
    static func score(_ result: ConditioningSectionResult?) -> String {
        guard let result else { return "—" }
        switch result.scoreKind {
        case .roundsAndReps:
            let rounds = result.fullRounds ?? 0
            if let partial = result.partialValue, partial > 0 {
                return "\(rounds) + \(Int(partial))"
            }
            return "\(rounds) rounds"
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
            if !section.repScheme.isEmpty { return section.repScheme.map(String.init).joined(separator: "–") }
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
}

struct ConditioningShareBlock: View {
    let plan: ConditioningPlan
    var result: ConditioningResult?
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme
    var compact = false

    private func exercise(_ id: UUID) -> ExerciseLibraryModel? {
        exercises.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            ForEach(Array(visibleSections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: compact ? 4 : 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.name.isEmpty ? section.format.title : section.name)
                                .font(.system(size: compact ? 14 : 16, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Text(ConditioningSharePresentation.prescription(section))
                                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer(minLength: 4)
                        if let sectionResult = result?.sectionResults.first(where: { $0.id == section.id }) {
                            Text(ConditioningSharePresentation.score(sectionResult))
                                .font(.system(size: compact ? 13 : 15, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.accent)
                                .lineLimit(1)
                        }
                    }
                    ForEach(Array(section.movements.prefix(compact ? 4 : section.movements.count))) { movement in
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
                    if compact, section.movements.count > 4 {
                        Text("+\(section.movements.count - 4) movements")
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
        compact ? Array(plan.sections.prefix(2)) : plan.sections
    }
}
