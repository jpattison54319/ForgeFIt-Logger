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
    /// One position in the cycle. Usually a single routine; an alternating
    /// pair fills one slot with both of its members, the way the tracked
    /// microcycle treats a pair as one day rather than two.
    struct Slot: Identifiable {
        let id: UUID
        let routines: [RoutineModel]

        init(routines: [RoutineModel]) {
            self.id = routines.first?.id ?? UUID()
            self.routines = routines
        }

        var isAlternating: Bool { routines.count > 1 }
    }

    /// One block of the cycle: an optional microcycle heading and its slots.
    struct Section: Identifiable {
        let id = UUID()
        let title: String?
        let slots: [Slot]

        init(title: String?, slots: [Slot]) {
            self.title = title
            self.slots = slots
        }

        /// Convenience for cycles without alternating pairs — one slot per routine.
        init(title: String?, routines: [RoutineModel]) {
            self.init(title: title, slots: routines.map { Slot(routines: [$0]) })
        }
    }

    let name: String
    let isMesocycle: Bool
    let sections: [Section]
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme

    private var allRoutines: [RoutineModel] { sections.flatMap { $0.slots.flatMap(\.routines) } }
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
                                Image(systemName: "calendar").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.secondaryAccentForeground)
                                Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.textPrimary)
                                Spacer(minLength: 0)
                                Text(routineCountLabel(section))
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                            }
                            ForEach(section.slots) { slot in
                                slotBlock(slot)
                            }
                        }
                    } else {
                        ForEach(section.slots) { slot in
                            slotBlock(slot)
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

    private func routineCountLabel(_ section: Section) -> String {
        let count = section.slots.reduce(0) { $0 + $1.routines.count }
        return "\(count) routine\(count == 1 ? "" : "s")"
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

    /// A single routine renders on its own; an alternating pair renders as one
    /// tinted group so the image shows that the two routines swap in and out of
    /// the same slot instead of reading as two separate training days.
    @ViewBuilder
    private func slotBlock(_ slot: Slot) -> some View {
        if slot.isAlternating {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(theme.accentForeground)
                    // The two routine names sit directly below — repeating
                    // them in the header would just be noise.
                    Text("Alternating")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
                }
                ForEach(slot.routines) { routine in
                    routineBlock(routine)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if let routine = slot.routines.first {
            routineBlock(routine)
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
                Image(systemName: "list.bullet").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.accentForeground)
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
                            .foregroundStyle(theme.secondaryAccentForeground)
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
        let exportTheme = AppTheme.export(family: theme.family)
        return ShareRenderer.image(
            FolderShareCard(
                name: name,
                isMesocycle: isMesocycle,
                sections: sections,
                exercises: exercises,
                theme: exportTheme
            ),
            theme: exportTheme
        )
    }
}

/// Groups a cycle's routines into share-card slots, pairing routines that
/// alternate with each other. A partner that lives outside the shared cycle
/// still rides along in its owner's slot — the plan file already carries it,
/// so the image would otherwise hide half of the pair.
@MainActor
enum FolderShareSlotBuilder {
    struct Group {
        let title: String?
        let routines: [RoutineModel]
    }

    static func sections(
        _ groups: [Group],
        alternations: [RoutineAlternationModel],
        availableRoutines: [RoutineModel]
    ) -> [FolderShareCard.Section] {
        // The due member is history-derived and irrelevant to a static image —
        // only the pairing itself is being drawn.
        let states = RoutineAlternationService.states(
            alternations: alternations,
            routines: availableRoutines,
            workouts: []
        )
        var partnerByRoutineID: [UUID: RoutineModel] = [:]
        for state in states {
            partnerByRoutineID[state.owner.id] = state.partner
            partnerByRoutineID[state.partner.id] = state.owner
        }
        // A pair renders once, in the section where its first member appears,
        // so a partner in a sibling microcycle can't be drawn twice.
        var placedRoutineIDs: Set<UUID> = []
        return groups.map { group in
            var slots: [FolderShareCard.Slot] = []
            for routine in group.routines {
                guard placedRoutineIDs.insert(routine.id).inserted else { continue }
                if let partner = partnerByRoutineID[routine.id],
                   placedRoutineIDs.insert(partner.id).inserted {
                    slots.append(FolderShareCard.Slot(routines: [routine, partner]))
                } else {
                    slots.append(FolderShareCard.Slot(routines: [routine]))
                }
            }
            return FolderShareCard.Section(title: group.title, slots: slots)
        }
    }
}
