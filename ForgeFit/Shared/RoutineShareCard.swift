import ForgeCore
import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A branded, full-length snapshot of a routine (the microcycle) — its exercises
/// and target sets — designed to render to a single tall image and share.
/// Mirrors what the user sees on `RoutineDetailView`.
struct RoutineShareCard: View {
    let routine: RoutineModel
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme

    private var sortedExercises: [RoutineExerciseModel] {
        routine.exercises.sorted { $0.position < $1.position }
    }
    private var orderedItems: [OrderedRoutineItem] { OrderedRoutineItem.ordered(in: routine) }
    private func library(_ re: RoutineExerciseModel) -> ExerciseLibraryModel? {
        exercises.first { $0.id == re.exerciseID }
    }
    private var totalSets: Int { sortedExercises.reduce(0) { $0 + $1.sets.count } }
    private var conditioningPlan: ConditioningPlan? { ConditioningPlan.decode(from: routine.conditioningPlanJSON) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoutineShareHeader(
                title: routine.name,
                kicker: "Routine",
                systemImage: "list.bullet.clipboard.fill",
                theme: theme
            )
            statBlock
            if let conditioningPlan, routine.blocks.isEmpty {
                ConditioningShareBlock(plan: conditioningPlan, exercises: exercises, theme: theme)
            }
            if let notes = routine.notes, !notes.isEmpty {
                Text(notes).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            }
            if !orderedItems.isEmpty {
                Rectangle().fill(theme.separator).frame(height: 1)
                ForEach(orderedItems) { item in
                    switch item {
                    case .exercise(let exercise):
                        exerciseBlock(exercise)
                    case .block(let block):
                        routineBlockShare(block)
                    }
                }
            } else if conditioningPlan == nil {
                Rectangle().fill(theme.separator).frame(height: 1)
                Text("Nothing added yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textSecondary)
            }
            ShareCardFooter(theme: theme)
        }
        .padding(28)
        .frame(width: 430, alignment: .leading)
        .background(theme.background)
    }

    private var statBlock: some View {
        HStack(spacing: 12) {
            if let conditioningPlan, routine.blocks.isEmpty {
                RoutineShareStat(value: "\(conditioningPlan.sections.count)", label: "Sections", color: theme.accent, theme: theme)
                RoutineShareStat(
                    value: conditioningPlan.sections.first?.format.title ?? "Workout",
                    label: "Format",
                    color: theme.secondaryAccent,
                    theme: theme
                )
            } else {
                RoutineShareStat(value: "\(orderedItems.count)", label: "Items", color: theme.accent, theme: theme)
                RoutineShareStat(value: "\(totalSets)", label: "Sets", color: theme.secondaryAccent, theme: theme)
            }
        }
    }

    @ViewBuilder
    private func routineBlockShare(_ block: RoutineBlockModel) -> some View {
        if block.kind == .conditioning,
           let plan = ConditioningPlan.decode(from: block.planJSON) {
            ConditioningShareBlock(plan: plan, exercises: exercises, theme: theme)
        } else if block.kind == .yoga,
                  let plan = YogaFlowPlan.decode(from: block.planJSON) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Yoga", systemImage: "figure.yoga")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(theme.accent)
                Text("\(plan.structureSummary) · \(plan.style.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                ForEach(plan.steps) { step in
                    Text("• \(step.name) · \(Fmt.durationShort(step.holdSeconds))")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textPrimary)
                }
            }
        }
    }

    private func exerciseBlock(_ re: RoutineExerciseModel) -> some View {
        let exercise = library(re)
        let unit = exercise?.effectiveWeightUnit ?? Fmt.unit
        let isCardio = exercise?.isCardio == true
        let sets = re.sets.sorted { $0.position < $1.position }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isCardio ? "figure.run" : "dumbbell.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.accent)
                    .frame(width: 34, height: 34).background(theme.surfaceElevated).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise?.name ?? "Exercise").font(.system(size: 17, weight: .bold)).foregroundStyle(theme.textPrimary)
                    if let equipment = exercise?.equipment {
                        Text(equipment.capitalized).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let notes = re.notes, !notes.isEmpty {
                Text(notes).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            if !sets.isEmpty {
                // Column header
                HStack {
                    Text("SET").frame(width: 40, alignment: .leading)
                    Text(isCardio ? "TARGET" : unit.suffix.uppercased()).frame(maxWidth: .infinity, alignment: .leading)
                    if !isCardio { Text("REPS").frame(maxWidth: .infinity, alignment: .leading) }
                    Text("RPE").frame(width: 54, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .heavy)).foregroundStyle(theme.textTertiary)
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    let style = SetTypeStyle.of(set.setType)
                    HStack {
                        Text(style.numbered ? "\(numberedIndex(sets, upTo: index))" : (style.badge.isEmpty ? "•" : style.badge))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(set.setType == .working ? theme.textPrimary : style.color)
                            .frame(width: 40, alignment: .leading)
                        if isCardio {
                            Text(Fmt.durationShort(set.targetDurationSeconds))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(Fmt.load(set.targetWeight, unit: unit))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(repsText(set))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(rpeText(set))
                            .font(.tag).foregroundStyle(theme.textTertiary)
                            .frame(width: 54, alignment: .trailing)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func numberedIndex(_ sets: [RoutineSetModel], upTo index: Int) -> Int {
        sets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
    }

    private func repsText(_ set: RoutineSetModel) -> String {
        switch (set.targetRepsLow, set.targetRepsHigh) {
        case let (lo?, hi?) where lo != hi: "\(lo)–\(hi)"
        case let (lo?, _): "\(lo)"
        case let (_, hi?): "\(hi)"
        default: "—"
        }
    }

    private func rpeText(_ set: RoutineSetModel) -> String {
        if let rpe = set.targetRPE { return rpe.formatted(.number.precision(.fractionLength(0...1))) }
        if let rir = set.targetRIR { return "\(rir) RIR" }
        return "—"
    }
}

// MARK: - Shared share-card chrome (used by routine & folder cards)

struct RoutineShareHeader: View {
    let title: String
    let kicker: String
    let systemImage: String
    let theme: AppTheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.accent)
                Image(systemName: systemImage).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(kicker.uppercased()).font(.system(size: 11, weight: .heavy)).foregroundStyle(theme.accent)
                Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(theme.textPrimary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

struct RoutineShareStat: View {
    let value: String
    let label: String
    let color: Color
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ShareCardFooter: View {
    let theme: AppTheme
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "dumbbell.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.accent)
            Text("Built with ForgeFit").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(.top, 2)
    }
}

@MainActor
enum RoutineShareRenderer {
    static func image(for routine: RoutineModel, exercises: [ExerciseLibraryModel], theme: AppTheme) -> UIImage? {
        ShareRenderer.image(RoutineShareCard(routine: routine, exercises: exercises, theme: theme), theme: theme)
    }
}
