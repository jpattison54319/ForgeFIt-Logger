import ForgeCore
import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A branded, full-length snapshot of a training cycle folder. Adapts its layout
/// to the folder's structure:
///  - a **mesocycle** (folder of routines) lists each routine with its exercises,
///  - a **macrocycle** (folder of mesocycle subfolders) groups routines under
///    each mesocycle heading.
/// Renders to a single tall image for sharing.
struct FolderShareCard: View {
    /// One block of the cycle: an optional heading (a mesocycle name, for a
    /// macrocycle) and the routines under it.
    struct Section: Identifiable {
        let id = UUID()
        let title: String?
        let routines: [RoutineModel]
    }

    let name: String
    let isMacro: Bool
    let sections: [Section]
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme

    private var allRoutines: [RoutineModel] { sections.flatMap(\.routines) }
    private var totalExercises: Int { allRoutines.reduce(0) { $0 + $1.exercises.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoutineShareHeader(
                title: name,
                kicker: isMacro ? "Macrocycle" : "Mesocycle",
                systemImage: isMacro ? "square.stack.3d.up.fill" : "calendar",
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
                        // Macrocycle: a mesocycle heading with its routines.
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
            if isMacro {
                RoutineShareStat(value: "\(sections.count)", label: "Mesocycles", color: theme.accent, theme: theme)
            }
            RoutineShareStat(value: "\(allRoutines.count)", label: "Routines", color: theme.secondaryAccent, theme: theme)
            RoutineShareStat(value: "\(totalExercises)", label: "Exercises", color: theme.textPrimary, theme: theme)
        }
    }

    /// Compact preview of a routine: name, size, and its exercise list with
    /// target set summaries — enough to read the plan without the full set table.
    private func routineBlock(_ routine: RoutineModel) -> some View {
        let sortedExercises = routine.exercises.sorted { $0.position < $1.position }
        let setCount = sortedExercises.reduce(0) { $0 + $1.sets.count }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.accent)
                Text(routine.name).font(.system(size: 16, weight: .bold)).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                Text("\(sortedExercises.count) ex · \(setCount) sets")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            if sortedExercises.isEmpty {
                Text("No exercises").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            } else {
                ForEach(Array(sortedExercises.enumerated()), id: \.element.id) { index, re in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textTertiary).frame(width: 22, alignment: .leading)
                        Text(exercises.first { $0.id == re.exerciseID }?.name ?? "Exercise")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        Spacer(minLength: 8)
                        Text(targetSummary(re))
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
        isMacro: Bool,
        sections: [FolderShareCard.Section],
        exercises: [ExerciseLibraryModel],
        theme: AppTheme
    ) -> UIImage? {
        ShareRenderer.image(
            FolderShareCard(name: name, isMacro: isMacro, sections: sections, exercises: exercises, theme: theme),
            theme: theme
        )
    }
}
