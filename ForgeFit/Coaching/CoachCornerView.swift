import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Coach's Corner: the one place that gathers everything the coach knows —
/// today's readiness call, what next session's progression will look like,
/// how the active plan's week is going, and a direct line to ask questions.
/// Ordered so the most time-sensitive thing (what to do *today*) leads.
struct CoachCornerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let workouts: [WorkoutModel]
    let routines: [RoutineModel]
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]
    let recovery: RecoveryEngine.Report
    let suggestion: (routine: RoutineModel, reason: String)?

    @Query private var coachedPrograms: [CoachedProgramModel]
    @Query private var allFolders: [RoutineFolderModel]
    @Query private var weekOverrides: [CoachingWeekOverrideModel]

    @State private var showSetup = false
    @State private var editPlanTarget: CoachedProgramModel?
    @State private var showStopCoachingConfirm = false
    @State private var attachFolderTarget: RoutineFolderModel?
    @State private var reviewRequest: CoachReviewRequest?
    @State private var showChat = false
    @State private var weeklyProposals: [CoachingWeekOverrideModel] = []
    @State private var weeklyActiveOverrides: [CoachingWeekOverrideModel] = []

    private var activeProgram: CoachedProgramModel? {
        coachedPrograms.first { $0.isActive && $0.deletedAt == nil }
    }

    private var topLevelFolders: [RoutineFolderModel] {
        allFolders.filter { $0.parentID == nil && $0.deletedAt == nil }.sorted { $0.position < $1.position }
    }

    private var doseContext: RoutineDoseContext? {
        guard let suggestion else { return nil }
        return RoutineDoseContext.make(routine: suggestion.routine, workouts: workouts, exercises: exercises, recovery: recovery)
    }

    private var currentWeekAnchor: Date { CoachWeeklyReview.weekAnchor(for: Date()) }

    /// Whether a weekly deload override is currently active — feeds
    /// `CoachAdjustments.effectivePlan`'s conservative-dose precedence so a
    /// weekly deload always wins over a plain daily volume reduction.
    private var weeklyDeloadActive: Bool {
        weekOverrides.contains {
            $0.statusRaw == CoachingOverrideStatus.active.rawValue
                && $0.kindRaw == CoachingOverrideKind.deloadWeek.rawValue
                && $0.weekStart == currentWeekAnchor
        }
    }

    /// Today's coach adjustment plus its honest provenance — the same
    /// global-vs-localized resolution Home's "Up next" card uses, run
    /// through `effectivePlan` so an active weekly deload always wins
    /// outright rather than stacking with a daily reduction.
    private var effectiveCoachPlan: (plan: CoachAdjustments.Plan, sourceLabel: String)? {
        guard suggestion != nil else { return nil }
        let global = CoachAdjustments.plan(for: recovery.action)
        let local = recovery.action == .trainAsPlanned ? doseContext.flatMap(CoachAdjustments.localizedPlan(for:)) : nil
        return CoachAdjustments.effectivePlan(daily: global ?? local, weeklyDeloadActive: weeklyDeloadActive)
    }

    private var coachPlan: CoachAdjustments.Plan? { effectiveCoachPlan?.plan }

    /// This week's active progression holds (Coach's Corner weekly review),
    /// keyed for `ProgressionPlanner`'s `heldExerciseIDs`/`holdReasons` —
    /// the identical overrides `WorkoutFactory.start` reads, so this preview
    /// always matches what starting the workout will actually do.
    private var activeHolds: (ids: Set<UUID>, reasons: [UUID: String]) {
        CoachWeeklyReview.activeProgressionHolds(in: modelContext)
    }

    /// Up to 3 next-session targets for the suggested routine — read-only,
    /// exactly what starting the workout will apply (`ProgressionPlanner.preview`
    /// and `.apply` share one planning step).
    private var progressionPreview: [PlannedProgression] {
        guard let suggestion else { return [] }
        let holds = activeHolds
        return Array(
            ProgressionPlanner.preview(
                routine: suggestion.routine, exercises: exercises, in: modelContext,
                heldExerciseIDs: holds.ids, holdReasons: holds.reasons
            ).prefix(3)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    todaysCallSection
                    if !progressionPreview.isEmpty {
                        progressionPreviewSection
                    }
                    thisWeekSection
                    askCoachSection
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
                .padding(.bottom, Space.xl)
            }
            .background(theme.background)
            .navigationTitle("Coach's Corner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.bodyStrong)
                }
            }
            .navigationDestination(isPresented: $showChat) { chatDestination }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(false)
        .task(id: activeProgram?.id) { refreshWeeklyReview() }
        .sheet(isPresented: $showSetup) {
            CoachingSetupView()
        }
        .sheet(item: $editPlanTarget) { program in
            EditCoachedPlanSheet(program: program, programName: programName(program))
        }
        .confirmationDialog(
            "Stop coaching this plan?",
            isPresented: $showStopCoachingConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Coaching", role: .destructive) {
                CoachPlanService.stopCoaching(in: modelContext)
                refreshWeeklyReview()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The coach stops tracking your weekly target. Your routines and history stay.")
        }
        .sheet(item: $attachFolderTarget) { folder in
            AttachPlanSheet(folder: folder) { sessionsPerWeek in
                CoachPlanService.attachPlan(folder: folder, sessionsPerWeek: sessionsPerWeek, in: modelContext)
            }
        }
        .sheet(item: $reviewRequest) { request in
            CoachAdjustmentReviewView(
                plan: request.plan,
                routine: request.routine,
                exercises: exercises,
                setupNotes: setupNotes,
                reasons: recovery.reasonChips.prefix(3).map(\.text),
                sourceLabel: request.sourceLabel,
                onStarted: { dismiss() }
            )
        }
    }

    // MARK: - Weekly review refresh

    /// Runs the weekly review (materializing any new proposals) when it's
    /// due for the active program, otherwise just re-reads this week's still
    /// -open proposals and active overrides. Safe to call repeatedly — see
    /// `CoachWeeklyReview.proposals(for:now:in:)`'s idempotency guarantee.
    private func refreshWeeklyReview() {
        guard let activeProgram else {
            weeklyProposals = []
            weeklyActiveOverrides = []
            return
        }
        let now = Date()
        let anchor = CoachWeeklyReview.weekAnchor(for: now)
        if CoachWeeklyReview.isReviewDue(program: activeProgram, now: now) {
            weeklyProposals = CoachWeeklyReview.proposals(for: activeProgram, now: now, in: modelContext)
        } else {
            weeklyProposals = CoachWeeklyReview.pendingProposals(for: activeProgram, weekAnchor: anchor, in: modelContext)
        }
        weeklyActiveOverrides = CoachWeeklyReview.activeOverrides(for: anchor, in: modelContext)
            .filter { $0.programID == activeProgram.id }
    }

    // MARK: - 1. Today's call

    private var todaysCallSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Today's call")
                .accessibilityIdentifier("coach-corner-section-todays-call")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: recovery.action.systemImage)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(recovery.action.tint(in: theme))
                        Text(recovery.action.title)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        // Below this confidence the engine is still building
                        // baselines (mirrors `RecoveryHeroCard.isBuilding`) —
                        // a precise number there would be false authority.
                        if recovery.confidence >= 0.75 {
                            Text("\(Int(recovery.displayScore * 100)) ready")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    Text(recovery.recommendation)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !recovery.reasonChips.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(recovery.reasonChips.prefix(4)) { chip in
                                HStack(alignment: .top, spacing: Space.sm) {
                                    Circle()
                                        .fill(chip.tone.foreground(in: theme))
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 5)
                                    Text(chip.text)
                                        .font(.system(size: 13))
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                        }
                    }

                    Divider().overlay(theme.separator)

                    if let suggestion {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Suggested session")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(theme.accent)
                                .textCase(.uppercase)
                            Text(suggestion.routine.name)
                                .font(.cardTitle)
                                .foregroundStyle(theme.textPrimary)
                            Text(suggestion.reason)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        HStack(spacing: Space.sm) {
                            PrimaryButton(title: "Start", systemImage: "play.fill") {
                                dismiss()
                                appState.requestStart {
                                    _ = WorkoutFactory.start(routine: suggestion.routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
                                    appState.showingLogger = true
                                }
                            }
                            .accessibilityIdentifier("coach-corner-start-\(suggestion.routine.name)")
                            if let effectiveCoachPlan {
                                SecondaryButton(title: "Review coach's version", systemImage: "wand.and.stars") {
                                    reviewRequest = CoachReviewRequest(
                                        plan: effectiveCoachPlan.plan, routine: suggestion.routine, sourceLabel: effectiveCoachPlan.sourceLabel
                                    )
                                }
                                .accessibilityIdentifier("coach-corner-review-\(suggestion.routine.name)")
                            }
                        }
                    } else {
                        EmptyStateCard(
                            title: "No suggested session yet",
                            message: "Add a routine or program and the coach will pick up from here.",
                            systemImage: "list.bullet.clipboard"
                        )
                    }
                }
            }
        }
    }

    // MARK: - 2. Progression preview

    private var progressionPreviewSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Next session's targets")
                .accessibilityIdentifier("coach-corner-section-next-session")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(Array(progressionPreview.enumerated()), id: \.element.routineExerciseID) { index, planned in
                        if index > 0 { Divider().overlay(theme.separator) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(planned.exerciseName)
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text(planned.suggestion.rationale)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    Text("Targets apply automatically once you start the workout — this is a preview, nothing is written yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    // MARK: - 3. This week

    private var thisWeekSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("This week")
                .accessibilityIdentifier("coach-corner-section-this-week")
            if let activeProgram {
                activeProgramCard(activeProgram)
                weeklyReviewCard(activeProgram)
            } else {
                noActiveProgramCard
            }
        }
    }

    private func activeProgramCard(_ program: CoachedProgramModel) -> some View {
        let week = TrainingAnalytics(workouts: workouts, exercises: exercises).thisWeek()
        let currentWeek = CoachPlanService.currentWeek(of: program)
        let isComplete = program.weeks > 0 && currentWeek > program.weeks
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(programName(program))
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text(blockWeekLabel(program))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Space.sm)
                    managePlanMenu(program)
                }
                if program.weeks > 0 {
                    ProgressView(value: Double(min(currentWeek, program.weeks)), total: Double(program.weeks))
                        .tint(isComplete ? theme.success : theme.accent)
                        .accessibilityLabel("Week \(min(currentWeek, program.weeks)) of \(program.weeks)")
                }
                if isComplete {
                    programCompleteBanner
                } else {
                    HStack(spacing: Space.md) {
                        StatColumn(label: "Sessions", value: "\(week.workoutCount)/\(program.weeklySessionTarget)")
                        if let suggestion {
                            StatColumn(label: "Next up", value: suggestion.routine.name)
                        }
                    }
                }
            }
        }
    }

    /// Post-plan affordances gathered under one control so the card stays
    /// calm: adjust the current plan in place, swap to a different program,
    /// or stop coaching altogether. Before this menu existed there was no
    /// route back into any of these once a plan was confirmed.
    private func managePlanMenu(_ program: CoachedProgramModel) -> some View {
        Menu {
            Button("Edit plan", systemImage: "slider.horizontal.3") {
                editPlanTarget = program
            }
            Button("Change program…", systemImage: "arrow.triangle.2.circlepath") {
                showSetup = true
            }
            Divider()
            Button("Stop coaching", systemImage: "stop.circle", role: .destructive) {
                showStopCoachingConfirm = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Manage plan")
        .accessibilityIdentifier("coach-corner-manage-plan")
    }

    /// Shown once the program's final week has passed — celebrates the
    /// finish and routes straight into planning the next block instead of
    /// leaving the card silently pinned to "Week N of N" forever.
    private var programCompleteBanner: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.success)
                Text("Program complete — nice work.")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
            }
            SecondaryButton(title: "Plan my next block", systemImage: "wand.and.stars") {
                showSetup = true
            }
            .accessibilityIdentifier("coach-corner-plan-next-block")
        }
    }

    /// Deterministic weekly review: the coach's holds/carry-forward/deload
    /// calls for the week ahead, each with full accept/dismiss control (no
    /// accept-all), plus whatever's currently active with a per-row cancel.
    /// A quiet "on track" line when nothing fired at all.
    private func weeklyReviewCard(_ program: CoachedProgramModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Weekly review")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                if weeklyProposals.isEmpty && weeklyActiveOverrides.isEmpty {
                    Text("On track — stay the course")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("coach-corner-weekly-on-track")
                } else {
                    if !weeklyProposals.isEmpty {
                        VStack(alignment: .leading, spacing: Space.md) {
                            ForEach(weeklyProposals) { proposal in
                                weeklyProposalRow(proposal)
                            }
                        }
                    }
                    if !weeklyActiveOverrides.isEmpty {
                        if !weeklyProposals.isEmpty { Divider().overlay(theme.separator) }
                        VStack(alignment: .leading, spacing: Space.md) {
                            Text("Active this week")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(theme.textTertiary)
                                .textCase(.uppercase)
                            ForEach(weeklyActiveOverrides) { override in
                                weeklyActiveOverrideRow(override)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("coach-corner-weekly-review-card")
    }

    private func weeklyProposalRow(_ override: CoachingWeekOverrideModel) -> some View {
        let title = weeklyOverrideTitle(override, verb: .proposed)
        return HStack(alignment: .top, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(override.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            HStack(spacing: Space.md) {
                Button {
                    CoachWeeklyReview.accept(override, in: modelContext)
                    refreshWeeklyReview()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.success)
                }
                .accessibilityLabel("Accept \(title)")
                .accessibilityIdentifier("coach-corner-weekly-accept-\(override.id)")

                Button {
                    CoachWeeklyReview.decline(override, in: modelContext)
                    refreshWeeklyReview()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.textTertiary)
                }
                .accessibilityLabel("Dismiss \(title)")
                .accessibilityIdentifier("coach-corner-weekly-dismiss-\(override.id)")
            }
            .buttonStyle(.plain)
        }
    }

    private func weeklyActiveOverrideRow(_ override: CoachingWeekOverrideModel) -> some View {
        let title = weeklyOverrideTitle(override, verb: .active)
        return HStack(alignment: .top, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(override.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            Button("Cancel") {
                CoachWeeklyReview.cancel(override, in: modelContext)
                refreshWeeklyReview()
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Cancel \(title)")
            .accessibilityIdentifier("coach-corner-weekly-cancel-\(override.id)")
        }
    }

    private enum OverrideVerb { case proposed, active }

    /// Short human title for a weekly override row — "Hold: Bench Press" for
    /// a proposal, "Holding: Bench Press" once accepted — so the same kind
    /// reads as an offer vs. a standing decision.
    private func weeklyOverrideTitle(_ override: CoachingWeekOverrideModel, verb: OverrideVerb) -> String {
        let exerciseName = override.exerciseID.flatMap { id in exercises.first { $0.id == id }?.name }
        switch CoachingOverrideKind(rawValue: override.kindRaw) {
        case .progressionHold:
            let name = exerciseName ?? "exercise"
            return verb == .proposed ? "Hold: \(name)" : "Holding: \(name)"
        case .carryForward:
            return verb == .proposed ? "Carry sessions forward" : "Carrying sessions forward"
        case .deloadWeek:
            return "Deload week"
        case nil:
            return "Coach adjustment"
        }
    }

    private func programName(_ program: CoachedProgramModel) -> String {
        if program.catalogProgramID == "yoga-flows" { return "Yoga" }
        if !program.catalogProgramID.isEmpty,
           let catalogProgram = RoutineTemplateCatalog.loadPrograms().first(where: { $0.id == program.catalogProgramID }) {
            return catalogProgram.name
        }
        if let folderID = program.folderID, let folder = allFolders.first(where: { $0.id == folderID }) {
            return folder.name
        }
        return "Your plan"
    }

    private func blockWeekLabel(_ program: CoachedProgramModel) -> String {
        let week = CoachPlanService.currentWeek(of: program)
        if program.weeks > 0 {
            if week > program.weeks {
                return "Completed · \(program.weeks) \(program.weeks == 1 ? "week" : "weeks")"
            }
            return "Week \(week) of \(program.weeks)"
        }
        return "Week \(week)"
    }

    private var noActiveProgramCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("No active plan")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text("Let the coach build you one, or hand over a folder you've already built by hand.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                PrimaryButton(title: "Build my plan", systemImage: "wand.and.stars") {
                    showSetup = true
                }
                .accessibilityIdentifier("coach-corner-build-plan")
                if !topLevelFolders.isEmpty {
                    Menu {
                        ForEach(topLevelFolders) { folder in
                            Button(folder.name) {
                                attachFolderTarget = folder
                            }
                        }
                    } label: {
                        HStack(spacing: Space.sm) {
                            Image(systemName: "folder.badge.gearshape")
                            Text("Coach this plan")
                        }
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .buttonBorderShape(.roundedRectangle(radius: Radius.control))
                    .accessibilityIdentifier("coach-corner-coach-this-plan")
                }
            }
        }
    }

    // MARK: - 4. Ask your Coach

    private var askCoachSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Ask your coach")
                .accessibilityIdentifier("coach-corner-section-ask-coach")
            Button {
                showChat = true
            } label: {
                Card {
                    HStack(spacing: Space.md) {
                        Image(systemName: "bubble.left.and.text.bubble.right.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 38, height: 38)
                            .background(theme.accentSoft)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ask your Coach")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text("Readiness, progression, and this week — explained in plain language.")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("coach-corner-ask-coach")
        }
    }

    private var chatDestination: some View {
        AICoachChatView(
            context: AICoachContext.build(workouts: workouts, routines: routines, exercises: exercises, recovery: recovery),
            coachPlan: coachPlan,
            suggestedRoutineName: suggestion?.routine.name,
            onApplyPlan: coachPlan != nil ? { plan in
                guard let suggestion else { return }
                // AICoachChatView already dismissed (popped) itself before
                // calling this closure — also close the Corner so the
                // logger isn't left with a sheet stacked behind it.
                dismiss()
                appState.requestStart {
                    let workout = WorkoutFactory.start(routine: suggestion.routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
                    CoachAdjustments.apply(plan, to: workout, in: modelContext)
                    appState.showingLogger = true
                }
            } : nil
        )
    }
}

/// The "Coach this plan" confirmation: picks a weekly session target for an
/// existing, hand-built folder before handing it to `CoachPlanService.attachPlan`.
/// The folder and its routines are never modified.
private struct AttachPlanSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let folder: RoutineFolderModel
    let onConfirm: (Int) -> Void

    @State private var sessionsPerWeek = 3

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coach \"\(folder.name)\"")
                        .font(.screenTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text("The coach tracks your sessions against a weekly target. The folder and its routines stay exactly as they are.")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Sessions per week")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    SegmentedPills(options: Array(2...6), title: { "\($0)x" }, selection: $sessionsPerWeek)
                }
                Spacer()
                PrimaryButton(title: "Start Coaching This Plan", systemImage: "checkmark.circle.fill") {
                    onConfirm(sessionsPerWeek)
                    dismiss()
                }
                .accessibilityIdentifier("coach-corner-attach-confirm")
            }
            .padding(Space.xl)
            .background(theme.background)
            .navigationTitle("Coach This Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
