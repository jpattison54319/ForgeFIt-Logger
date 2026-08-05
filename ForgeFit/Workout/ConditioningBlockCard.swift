import ForgeCore
import ForgeData
import SwiftUI

struct ConditioningBlockCard: View {
    @Environment(\.theme) private var theme

    @Bindable var workout: WorkoutModel
    @Bindable var block: WorkoutBlockModel
    let exercises: [ExerciseLibraryModel]
    var allowsLiveControls = true
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onReorderDragChanged: (CGFloat) -> Void
    let onReorderDragEnded: () -> Void
    let onAccessibilityMoveBy: (Int) -> Void

    @State private var showRunner = false
    @State private var activeSegmentMessage: String?

    private var plan: ConditioningPlan? {
        ConditioningPlan.decode(from: block.planSnapshotJSON)
    }

    private var progress: ConditioningProgress {
        ConditioningProgress.decode(from: block.progressJSON) ?? ConditioningProgress()
    }

    private var session: CardioSessionModel? {
        workout.cardioSessions.first {
            $0.workoutBlockID == block.id && $0.workoutExerciseID == nil
        }
    }

    private var hasStarted: Bool {
        progress.status != .ready || session?.liveStartedAt != nil
    }

    private var isComplete: Bool {
        progress.status == .completed || session?.endedAt != nil
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                header
                planSummary
                actionArea
            }
        }
        .fullScreenCover(isPresented: $showRunner) {
            ConditioningWorkoutView(
                workout: workout,
                block: block,
                exercises: exercises,
                onMinimize: { showRunner = false },
                onCompleted: { showRunner = false }
            )
        }
        .alert("Another Segment Is Active", isPresented: Binding(
            get: { activeSegmentMessage != nil },
            set: { if !$0 { activeSegmentMessage = nil } }
        )) {
        } message: {
            Text(activeSegmentMessage ?? "Complete the current segment first.")
        }
        .accessibilityIdentifier("live-conditioning-block")
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "stopwatch")
                .font(.title3)
                .foregroundStyle(theme.warmup)
                .frame(width: 38, height: 38)
                .background(theme.surfaceElevated)
                .clipShape(.circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("Conditioning block")
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            ReorderHandle(
                onDragChanged: onReorderDragChanged,
                onDragEnded: onReorderDragEnded,
                onAccessibilityMoveBy: onAccessibilityMoveBy
            )
            ScrollSafeMenu(sections: blockMenuSections) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Conditioning block options")
            .accessibilityIdentifier("conditioning-block-options")
        }
    }

    private var blockMenuSections: [[ScrollSafeMenuItem]] {
        var sections: [[ScrollSafeMenuItem]] = []
        if !hasStarted {
            sections.append([ScrollSafeMenuItem(
                title: "Edit Block",
                systemImage: "slider.horizontal.3",
                action: onEdit
            )])
        }
        sections.append([ScrollSafeMenuItem(
            title: "Remove Block",
            systemImage: "trash",
            isDestructive: true,
            action: onRemove
        )])
        return sections
    }

    private var planSummary: some View {
        let sectionCount = plan?.sections.count ?? 0
        let movementCount = Set(plan?.sections.flatMap(\.movements).map(\.exerciseID) ?? []).count
        return HStack {
            StatColumn(label: "Sections", value: "\(sectionCount)", valueColor: theme.warmup)
            StatColumn(label: "Movements", value: "\(movementCount)")
            if let duration = session?.durationSeconds, isComplete {
                StatColumn(label: "Time", value: Fmt.durationShort(duration))
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if !allowsLiveControls || isComplete {
            HStack(spacing: Space.sm) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "lock.fill")
                    .foregroundStyle(isComplete ? theme.success : theme.textTertiary)
                Text(isComplete ? resultSummary : "No conditioning result logged")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
        } else {
            Button(action: startOrResume) {
                Label(hasStarted ? "Resume Conditioning" : "Start Conditioning", systemImage: "play.fill")
                    .font(.bodyStrong)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.md)
                    .background(theme.warmup)
                    .clipShape(.rect(cornerRadius: Radius.control))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(plan?.isEmpty != false)
            .accessibilityIdentifier("start-conditioning-block")
        }
    }

    private var title: String {
        guard plan?.sections.count == 1,
              let name = plan?.sections.first?.name,
              !name.isEmpty else { return "Conditioning" }
        return name
    }

    private var resultSummary: String {
        guard let result = ConditioningResult.decode(from: block.resultJSON),
              let first = result.sectionResults.first else { return "Conditioning complete" }
        let section = plan?.sections.first(where: { $0.id == first.id }) ?? plan?.sections.first
        let status = section.map {
            ConditioningSharePresentation.completionStatus(section: $0, result: first).label
        } ?? (first.completed ? "Completed" : "Incomplete")
        return "\(status) · \(ConditioningSharePresentation.score(first))"
    }

    private func startOrResume() {
        if let active = WorkoutTimedSegmentPolicy.activeSegment(in: workout, excludingBlockID: block.id) {
            activeSegmentMessage = "\(active) is already recording. Complete it before starting conditioning."
            return
        }
        showRunner = true
    }
}

enum WorkoutTimedSegmentPolicy {
    static func activeSegment(in workout: WorkoutModel, excludingBlockID: UUID? = nil) -> String? {
        guard let session = workout.cardioSessions.first(where: {
            $0.deletedAt == nil
                && $0.liveStartedAt != nil
                && $0.endedAt == nil
                && $0.workoutBlockID != excludingBlockID
        }) else { return nil }
        if session.isYogaSession { return "Yoga" }
        if session.isConditioningSession { return "Conditioning" }
        return "Cardio"
    }
}
