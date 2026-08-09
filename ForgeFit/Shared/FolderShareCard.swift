import ForgeCore
import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A branded, full-length snapshot of a training cycle folder. Adapts its layout
/// to the folder's structure:
///  - a **microcycle** (leaf folder) lists each routine with its exercises,
///  - a **mesocycle** (folder of microcycle subfolders) groups routines under
///    each microcycle heading.
/// Renders to a single tall image for sharing.
struct FolderShareCard: View {
    /// One block of the cycle: an optional microcycle heading and its routines.
    struct Section: Identifiable {
        let id = UUID()
        let title: String?
        let routines: [RoutineModel]
    }

    let name: String
    let isMesocycle: Bool
    let sections: [Section]
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme

    private var allRoutines: [RoutineModel] { sections.flatMap(\.routines) }
    private var totalItems: Int { allRoutines.reduce(0) { $0 + $1.exercises.count + $1.blocks.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoutineShareHeader(
                title: name,
                kicker: isMesocycle ? "Mesocycle" : "Microcycle",
                systemImage: isMesocycle ? "square.stack.3d.up.fill" : "calendar",
                theme: theme
            )
            statBlock
            Rectangle().fill(theme.separator).frame(height: 1)
            if allRoutines.isEmpty {
                Text("No routines in this cycle yet")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textSecondary)
            } else {
                ForEach(sections) { section in
                    if let title = section.title {
                        // Mesocycle: a microcycle heading with its routines.
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.secondaryAccent)
                                Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.textPrimary)
                                Spacer(minLength: 0)
                                Text("\(section.routines.count) routine\(section.routines.count == 1 ? "" : "s")")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                            }
                            ForEach(section.routines) { routine in
                                routineBlock(routine)
                            }
                        }
                    } else {
                        ForEach(section.routines) { routine in
                            routineBlock(routine)
                        }
                    }
                }
            }
            ShareCardFooter(theme: theme)
        }
        .padding(28)
        .frame(width: 430, alignment: .leading)
        .background(theme.background)
    }

    private var statBlock: some View {
        HStack(spacing: 12) {
            if isMesocycle {
                RoutineShareStat(value: "\(sections.count)", label: "Microcycles", color: theme.accent, theme: theme)
            }
            RoutineShareStat(value: "\(allRoutines.count)", label: "Routines", color: theme.secondaryAccent, theme: theme)
            RoutineShareStat(value: "\(totalItems)", label: "Items", color: theme.textPrimary, theme: theme)
        }
    }

    /// Compact preview of a routine: name, size, and its exercise list with
    /// target set summaries — enough to read the plan without the full set table.
    private func routineBlock(_ routine: RoutineModel) -> some View {
        let sortedExercises = routine.exercises.sorted { $0.position < $1.position }
        let orderedItems = OrderedRoutineItem.ordered(in: routine)
        let setCount = sortedExercises.reduce(0) { $0 + $1.sets.count }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.accent)
                Text(routine.name).font(.system(size: 16, weight: .bold)).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                Text("\(orderedItems.count) items · \(setCount) sets")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            if orderedItems.isEmpty {
                Text("Nothing added").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            } else {
                ForEach(Array(orderedItems.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textTertiary).frame(width: 22, alignment: .leading)
                        Text(itemName(item))
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        Spacer(minLength: 8)
                        Text(itemSummary(item))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryAccent)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func itemName(_ item: OrderedRoutineItem) -> String {
        switch item {
        case .exercise(let exercise):
            exercises.first { $0.id == exercise.exerciseID }?.name ?? "Exercise"
        case .block(let block):
            block.kind.title
        }
    }

    private func itemSummary(_ item: OrderedRoutineItem) -> String {
        switch item {
        case .exercise(let exercise): return targetSummary(exercise)
        case .block(let block):
            if block.kind == .conditioning,
               let plan = ConditioningPlan.decode(from: block.planJSON) {
                return "\(plan.sections.count) section\(plan.sections.count == 1 ? "" : "s")"
            }
            if let plan = YogaFlowPlan.decode(from: block.planJSON) {
                return plan.structureSummary
            }
            return "—"
        }
    }

    /// e.g. "3 × 8–12" for strength, "3 × 30s" for timed/cardio work.
    private func targetSummary(_ re: RoutineExerciseModel) -> String {
        let sets = re.sets.sorted { $0.position < $1.position }
        guard !sets.isEmpty else { return "—" }
        let count = sets.count
        // Prefer the first working set as representative of the target.
        let rep = sets.first { $0.setType == .working } ?? sets[0]
        if let seconds = rep.targetDurationSeconds, seconds > 0 {
            return "\(count) × \(Fmt.durationShort(seconds))"
        }
        let reps: String
        switch (rep.targetRepsLow, rep.targetRepsHigh) {
        case let (lo?, hi?) where lo != hi: reps = "\(lo)–\(hi)"
        case let (lo?, _): reps = "\(lo)"
        case let (_, hi?): reps = "\(hi)"
        default: reps = "—"
        }
        return "\(count) × \(reps)"
    }
}

@MainActor
enum FolderShareRenderer {
    static func image(
        name: String,
        isMesocycle: Bool,
        sections: [FolderShareCard.Section],
        exercises: [ExerciseLibraryModel],
        theme: AppTheme
    ) -> UIImage? {
        ShareRenderer.image(
            FolderShareCard(name: name, isMesocycle: isMesocycle, sections: sections, exercises: exercises, theme: theme),
            theme: theme
        )
    }
}
