import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Bundles a coach adjustment plan with the routine it applies to so it can
/// drive a single `.sheet(item:)` presentation from either Home or Coach's
/// Corner.
struct CoachReviewRequest: Identifiable {
    let id = UUID()
    let plan: CoachAdjustments.Plan
    let routine: RoutineModel
    /// Honest provenance for `plan` — `CoachAdjustments.weeklySourceLabel`
    /// when a Coach's Corner weekly deload override won out over today's
    /// readiness call, `CoachAdjustments.dailySourceLabel` otherwise. Shown
    /// on the review screen so the lifter knows WHY today is lighter.
    var sourceLabel: String = CoachAdjustments.dailySourceLabel
}

/// Full-control review of a coach-adjusted workout, presented before it
/// starts. Shows exactly what will change against the saved routine and lets
/// the lifter override every part of it — include/exclude any exercise, edit
/// how many sets come off, and (when the plan trims load) dial the weight cut
/// and RPE cap. The saved routine itself is never touched either way.
struct CoachAdjustmentReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let routine: RoutineModel
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]
    /// Plain-language reasons behind today's call (e.g. readiness reason
    /// chips) — shown under the plan header so "why" is never a mystery.
    let reasons: [String]
    /// Honest provenance for `plan` — see `CoachReviewRequest.sourceLabel`.
    let sourceLabel: String
    /// Called after the workout has been started (either adjusted or as
    /// planned) — lets a presenting parent (e.g. Coach's Corner) dismiss
    /// itself too, on top of this view's own dismissal.
    var onStarted: (() -> Void)?

    @State private var draft: CoachAdjustments.AdjustmentDraft

    init(
        plan: CoachAdjustments.Plan,
        routine: RoutineModel,
        exercises: [ExerciseLibraryModel],
        setupNotes: [UserExerciseNoteModel] = [],
        reasons: [String] = [],
        sourceLabel: String = CoachAdjustments.dailySourceLabel,
        onStarted: (() -> Void)? = nil
    ) {
        self.routine = routine
        self.exercises = exercises
        self.setupNotes = setupNotes
        self.reasons = reasons
        self.sourceLabel = sourceLabel
        self.onStarted = onStarted
        _draft = State(initialValue: CoachAdjustments.draft(for: plan, routine: routine, exercises: exercises))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    exerciseRows
                    if draft.plan.scalesWeight {
                        doseControls
                    }
                    reassurance
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
                // Extra clearance so the footer buttons never cover the last row.
                .padding(.bottom, 140)
            }
            .background(theme.background)
            .navigationTitle("Review Coach's Version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                footer
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)
                    .padding(.bottom, Space.sm)
                    .background(.regularMaterial)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.plan.action.title)
                    .font(.screenTitle)
                    .foregroundStyle(theme.textPrimary)
                Text(routine.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            Text(sourceLabel)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.accent)
                .textCase(.uppercase)
                .accessibilityIdentifier("coach-review-source-label")
            Text(draft.plan.summary)
                .font(.system(size: 14))
                .foregroundStyle(theme.textPrimary)
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(reasons, id: \.self) { reason in
                        HStack(alignment: .top, spacing: Space.sm) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                            Text(reason)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Per-exercise rows

    private var exerciseRows: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Exercises")
            VStack(spacing: Space.sm) {
                ForEach($draft.exercises) { $row in
                    exerciseRow($row)
                }
            }
        }
    }

    private func exerciseRow(_ row: Binding<CoachAdjustments.AdjustmentDraft.ExerciseDraft>) -> some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .top, spacing: Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.wrappedValue.exerciseName)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(changeDescription(row.wrappedValue))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Space.sm)
                    Toggle("", isOn: row.included)
                        .labelsHidden()
                        .tint(theme.accent)
                        .accessibilityLabel("\(row.wrappedValue.exerciseName) included in coach adjustment")
                }
                if row.wrappedValue.included, row.wrappedValue.maxSetsToDrop > 0 {
                    Stepper(
                        "Drop \(row.wrappedValue.setsToDrop) of \(row.wrappedValue.workingSetCount) sets",
                        value: row.setsToDrop,
                        in: 0...row.wrappedValue.maxSetsToDrop
                    )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                }
            }
        }
    }

    private func changeDescription(_ row: CoachAdjustments.AdjustmentDraft.ExerciseDraft) -> String {
        guard row.included else { return "Starts exactly as saved — \(row.workingSetCount) working sets" }
        var parts = ["\(row.workingSetCount) → \(row.workingSetCount - row.setsToDrop) working sets"]
        if draft.plan.scalesWeight, draft.weightCutPercent > 0 {
            parts.append("weight −\(Int(draft.weightCutPercent))%")
        }
        if draft.rpeCapEnabled {
            parts.append("cap RPE \(Int(draft.plan.rpeCapValue))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Dose controls (deload-style plans only — reduce-volume never scales weight)

    private var doseControls: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Dose")
            Card {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Weight cut").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        SegmentedPills(
                            options: [0.0, 5.0, 10.0, 15.0],
                            title: { "\(Int($0))%" },
                            selection: $draft.weightCutPercent
                        )
                    }
                    Toggle(isOn: $draft.rpeCapEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cap effort at RPE \(Int(draft.plan.rpeCapValue))")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text("Turning this off lets logged RPE/RIR go as high as you actually hit.")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .tint(theme.accent)
                }
            }
        }
    }

    private var reassurance: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text("Your saved routine is never changed — this only shapes today's session.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Space.sm) {
            PrimaryButton(title: "Start Workout", systemImage: "play.fill") {
                startWorkout()
            }
            .accessibilityIdentifier("coach-review-start-adjusted")
            SecondaryButton(title: "Start as Planned", systemImage: "list.bullet.clipboard") {
                startAsPlanned()
            }
            .accessibilityIdentifier("coach-review-start-planned")
        }
    }

    private func startWorkout() {
        let capturedDraft = draft
        dismiss()
        appState.requestStart {
            let workout = WorkoutFactory.start(routine: routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
            CoachAdjustments.apply(draft: capturedDraft, to: workout, in: modelContext)
            appState.showingLogger = true
        }
        onStarted?()
    }

    private func startAsPlanned() {
        dismiss()
        appState.requestStart {
            _ = WorkoutFactory.start(routine: routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
            appState.showingLogger = true
        }
        onStarted?()
    }
}

#Preview("Coach adjustment review") {
    let schema = Schema(ForgeDataSchema.models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [configuration])
    let context = container.mainContext

    let bench = ExerciseLibraryModel(name: "Bench Press", equipment: "Barbell")
    let squat = ExerciseLibraryModel(name: "Back Squat", equipment: "Barbell")
    context.insert(bench)
    context.insert(squat)

    let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Push Day")
    routine.exercises = [
        RoutineExerciseModel(
            userID: ForgeFitDemo.userID, exerciseID: bench.id, position: 0,
            sets: (0..<4).map { RoutineSetModel(userID: ForgeFitDemo.userID, position: $0, targetRepsLow: 8, targetWeight: 135) }
        ),
        RoutineExerciseModel(
            userID: ForgeFitDemo.userID, exerciseID: squat.id, position: 1,
            sets: (0..<3).map { RoutineSetModel(userID: ForgeFitDemo.userID, position: $0, targetRepsLow: 6, targetWeight: 185) }
        ),
    ]
    context.insert(routine)
    try? context.save()

    let plan = CoachAdjustments.plan(for: .deloadRecover)!

    return CoachAdjustmentReviewView(
        plan: plan,
        routine: routine,
        exercises: [bench, squat],
        reasons: ["HRV 18% below your baseline", "Sleep 5h40m — below your need"]
    )
    .modelContainer(container)
    .environment(AppState())
    .environment(\.theme, .sageDark)
}
