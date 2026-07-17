import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Sets a cardio effort's goal — four peer shapes rather than a single
/// "intervals" bucket: **Open** (just track), a **Target** (cover a
/// distance / last a duration / burn calories / climb, with an optional
/// pace band), a **Zone lock** (hold one HR zone the whole effort), or
/// **Intervals** (structured steps with auto-advancing cues — the classic
/// repeat shape, or a fully custom ordered step list). All four encode into
/// the same `IntervalPlan`. Closure-based so the routine editor (template)
/// and the live cardio card (this session) can both present it.
struct IntervalPlanBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    /// The goal shape being configured. Steady targets, zone locks, and
    /// intervals are distinct ways to aim an effort, so they're peers here,
    /// not nested inside each other.
    private enum GoalMode: String, CaseIterable, Identifiable {
        case open, goal, zone, intervals
        var id: String { rawValue }
        var title: String {
            switch self {
            case .open: "Open"
            case .goal: "Target"
            case .zone: "Zone lock"
            case .intervals: "Intervals"
            }
        }
        var blurb: String {
            switch self {
            case .open: "Just track time, distance, and heart rate — no target to hold."
            case .goal: "Chase one number — a distance, a duration, calories, or climb — with an optional pace band."
            case .zone: "Hold one heart-rate zone the whole effort. Audible + haptic cue when you drift out."
            case .intervals: "Structured steps with auto-advancing cues — classic rounds or a fully custom sequence."
            }
        }
    }

    /// How the intervals mode edits its steps: the classic repeat steppers,
    /// or the ordered custom list. Plans that no longer fit the repeat
    /// shape open (and stay) in custom — round-tripping them through the
    /// steppers would silently flatten them.
    private enum IntervalsLayout { case repeats, custom }

    /// User-saved presets (active only), newest first — rendered alongside the
    /// built-ins in the presets card.
    @Query(
        filter: #Predicate<IntervalPresetModel> { $0.deletedAt == nil },
        sort: \IntervalPresetModel.createdAt, order: .reverse
    ) private var userPresets: [IntervalPresetModel]

    private let onSave: (String?) -> Void

    @State private var warmup: Int
    @State private var repeats: Int
    @State private var work: Int
    @State private var recover: Int
    @State private var cooldown: Int
    @State private var mode: GoalMode
    /// 0 = no zone selected; 1...5 = target zone (used by the Zone lock mode
    /// and as the Target mode's optional zone).
    @State private var zoneTarget: Int
    /// Per-step zone targets for work/recover blocks (0 = none).
    @State private var workZone: Int
    @State private var recoverZone: Int
    /// Repeats mode: work reps measured by the clock or by distance.
    @State private var workByDistance: Bool
    @State private var workDistance: Double
    /// Optional pace band on the work reps (repeats mode) / the session
    /// (Target mode). Stored canonically in seconds per km.
    @State private var paceLow: Double?
    @State private var paceHigh: Double?

    // Target mode state.
    @State private var goalKind: IntervalPlan.SessionGoal.Kind
    @State private var goalDistance: Double?     // user's distance unit
    @State private var goalMinutes: Int?
    @State private var goalCalories: Int?
    @State private var goalClimbMeters: Double?  // entered in m (or ft when mi)

    // Custom-steps state.
    @State private var intervalsLayout: IntervalsLayout
    @State private var customSteps: [EditableStep]

    /// "Save as preset" name-prompt state.
    @State private var showSavePrompt = false
    @State private var presetName = ""
    /// Presents the soft-delete management list for user presets.
    @State private var showManageSheet = false

    init(planJSON: String?, onSave: @escaping (String?) -> Void) {
        self.onSave = onSave
        let existing = IntervalPlan.decode(from: planJSON)
        // Derive the mode from the stored shape: steps win (intervals), then
        // a session goal/band (target), then a plan-wide zone (lock).
        let initialMode: GoalMode = {
            if existing?.hasSteps == true { return .intervals }
            if existing?.goal?.isMeaningful == true || existing?.target?.isMeaningful == true { return .goal }
            if existing?.hrZoneTarget != nil { return .zone }
            return .open
        }()
        _mode = State(initialValue: initialMode)
        // Seed from the existing plan's shape, or sensible defaults.
        let workStep = existing?.steps.first { $0.kind == .work }
        let recoverStep = existing?.steps.first { $0.kind == .recover }
        _warmup = State(initialValue: existing?.steps.first { $0.kind == .warmup }?.seconds ?? 300)
        _repeats = State(initialValue: (existing?.steps.filter { $0.kind == .work }.count).flatMap { $0 > 0 ? $0 : nil } ?? 6)
        _work = State(initialValue: workStep.map { $0.isDistanceBased ? 60 : $0.seconds } ?? 60)
        _recover = State(initialValue: recoverStep?.seconds ?? 90)
        _cooldown = State(initialValue: existing?.steps.first { $0.kind == .cooldown }?.seconds ?? 300)
        _zoneTarget = State(initialValue: existing?.hrZoneTarget ?? 0)
        _workZone = State(initialValue: workStep?.hrZone ?? 0)
        _recoverZone = State(initialValue: recoverStep?.hrZone ?? 0)
        _workByDistance = State(initialValue: workStep?.isDistanceBased ?? false)
        _workDistance = State(initialValue: workStep?.distanceMeters ?? 400)
        let band = workStep?.target ?? existing?.target
        _paceLow = State(initialValue: band?.metric == .pace ? band?.low : nil)
        _paceHigh = State(initialValue: band?.metric == .pace ? band?.high : nil)

        let goal = existing?.goal
        _goalKind = State(initialValue: goal?.kind ?? .distance)
        _goalDistance = State(initialValue: goal?.kind == .distance ? goal.map { Fmt.distanceUnit.distance(fromMeters: $0.value) } : nil)
        _goalMinutes = State(initialValue: goal?.kind == .duration ? goal.map { Int($0.value) / 60 } : nil)
        _goalCalories = State(initialValue: goal?.kind == .calories ? goal.map { Int($0.value) } : nil)
        _goalClimbMeters = State(initialValue: goal?.kind == .elevation ? goal?.value : nil)

        // Custom plans open in the ordered-list editor; repeat shapes keep
        // the steppers until the user asks for more.
        let fitsRepeats = existing?.matchesRepeatBuilderShape ?? true
        _intervalsLayout = State(initialValue: fitsRepeats ? .repeats : .custom)
        _customSteps = State(initialValue: (existing?.steps ?? []).map(EditableStep.init))
    }

    /// Edit a routine exercise's stored template in place.
    init(routineExercise: RoutineExerciseModel) {
        self.init(planJSON: routineExercise.intervalPlanJSON) { json in
            routineExercise.intervalPlanJSON = json
            routineExercise.updatedAt = Date()
        }
    }

    private var workPaceBand: IntervalPlan.Target? {
        guard paceLow != nil || paceHigh != nil else { return nil }
        return IntervalPlan.Target(metric: .pace, low: paceLow, high: paceHigh)
    }

    private var sessionGoal: IntervalPlan.SessionGoal? {
        switch goalKind {
        case .distance:
            guard let value = goalDistance, value > 0 else { return nil }
            return .init(kind: .distance, value: Fmt.distanceUnit.meters(fromDistance: value))
        case .duration:
            guard let minutes = goalMinutes, minutes > 0 else { return nil }
            return .init(kind: .duration, value: Double(minutes * 60))
        case .calories:
            guard let kcal = goalCalories, kcal > 0 else { return nil }
            return .init(kind: .calories, value: Double(kcal))
        case .elevation:
            guard let meters = goalClimbMeters, meters > 0 else { return nil }
            return .init(kind: .elevation, value: meters)
        }
    }

    private var plan: IntervalPlan {
        switch mode {
        case .open:
            return IntervalPlan(steps: [])
        case .goal:
            // Steady chase: a session goal, an optional pace band, an
            // optional zone to sit in while chasing it.
            return IntervalPlan(
                steps: [],
                hrZoneTarget: zoneTarget == 0 ? nil : zoneTarget,
                goal: sessionGoal,
                target: workPaceBand
            )
        case .zone:
            // Steady-state: a plan-wide zone lock, no steps.
            return IntervalPlan(steps: [], hrZoneTarget: zoneTarget == 0 ? nil : zoneTarget)
        case .intervals:
            switch intervalsLayout {
            case .repeats:
                // Structured: steps carry their own per-step zones; the
                // plan-wide lock stays off so the goal shapes never blend.
                let built = IntervalPlan.build(
                    warmupSeconds: warmup, repeats: repeats,
                    workSeconds: workByDistance ? 0 : work,
                    recoverSeconds: recover, cooldownSeconds: cooldown,
                    workZone: workZone == 0 ? nil : workZone,
                    recoverZone: recoverZone == 0 ? nil : recoverZone,
                    workDistanceMeters: workByDistance ? workDistance : nil,
                    workTarget: workPaceBand)
                return IntervalPlan(steps: built.steps, hrZoneTarget: nil)
            case .custom:
                return IntervalPlan(steps: EditableStep.relabeled(customSteps), hrZoneTarget: nil)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    modeSelectorCard

                    switch mode {
                    case .open:
                        EmptyView()
                    case .goal:
                        goalCard
                    case .zone:
                        zoneLockCard
                    case .intervals:
                        presetsCard
                        if intervalsLayout == .repeats {
                            intervalStepsCard
                            customizeCard
                        } else {
                            customStepsCard
                        }
                        totalCard
                    }
                }
                .padding(Space.lg)
                .animation(.spring(duration: 0.25), value: mode)
                .animation(.spring(duration: 0.25), value: intervalsLayout == .custom)
            }
            .background(theme.background)
            .navigationTitle("Cardio goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.font(.bodyStrong)
                        .accessibilityIdentifier("cardio-goal-save")
                }
            }
            .alert("Save preset", isPresented: $showSavePrompt) {
                TextField("Preset name", text: $presetName)
                Button("Cancel", role: .cancel) { presetName = "" }
                Button("Save") { saveAsPreset() }
            } message: {
                Text("Save this interval structure to reuse it later.")
            }
            .sheet(isPresented: $showManageSheet) {
                IntervalPresetManagerView()
            }
            // Entering Zone lock with nothing chosen? Seed Zone 2 — the
            // canonical steady-state base — so the goal is immediately valid.
            .onChange(of: mode) { _, newMode in
                if newMode == .zone, zoneTarget == 0 { zoneTarget = 2 }
            }
        }
    }

    /// The four peer goal shapes, with a one-line explanation of the selection.
    private var modeSelectorCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Picker("Goal", selection: $mode) {
                    ForEach(GoalMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("cardio-goal-mode")
                Text(mode.blurb)
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Target mode

    /// One number to chase, an optional pace band, an optional zone to sit
    /// in. Elevation fills from Apple Health at completion — the card says
    /// so instead of pretending it tracks live.
    private var goalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Picker("Target", selection: $goalKind) {
                    Text("Distance").tag(IntervalPlan.SessionGoal.Kind.distance)
                    Text("Time").tag(IntervalPlan.SessionGoal.Kind.duration)
                    Text("Calories").tag(IntervalPlan.SessionGoal.Kind.calories)
                    Text("Climb").tag(IntervalPlan.SessionGoal.Kind.elevation)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("cardio-goal-kind")

                switch goalKind {
                case .distance:
                    goalValueRow {
                        OptionalDecimalField(placeholder: "5.0", value: $goalDistance)
                            .accessibilityIdentifier("cardio-goal-distance")
                    } unit: { Fmt.distanceUnit.abbreviation }
                case .duration:
                    goalValueRow {
                        OptionalIntField(placeholder: "45", value: $goalMinutes)
                            .accessibilityIdentifier("cardio-goal-minutes")
                    } unit: { "min" }
                case .calories:
                    goalValueRow {
                        OptionalIntField(placeholder: "400", value: $goalCalories)
                            .accessibilityIdentifier("cardio-goal-calories")
                    } unit: { "kcal" }
                case .elevation:
                    goalValueRow {
                        OptionalDecimalField(placeholder: "300", value: $goalClimbMeters)
                            .accessibilityIdentifier("cardio-goal-climb")
                    } unit: { "m" }
                }

                if goalKind == .elevation {
                    Text("Climb fills in from Apple Health when you complete — it doesn't tick live.")
                        .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if goalKind == .distance || goalKind == .duration {
                    Divider().overlay(theme.separator)
                    PaceBandRow(low: $paceLow, high: $paceHigh)
                }

                Divider().overlay(theme.separator)
                stepZoneRow("Zone lock while chasing it", selection: $zoneTarget)
            }
        }
    }

    private func goalValueRow(@ViewBuilder field: () -> some View, unit: () -> String) -> some View {
        HStack(spacing: 8) {
            Text("Target").font(.bodyStrong).foregroundStyle(theme.textPrimary)
            Spacer()
            field().frame(maxWidth: 120)
            Text(unit())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    /// Steady-state goal: pick one HR zone to hold for the whole effort.
    private var zoneLockCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Target zone").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                HStack(spacing: Space.sm) {
                    ForEach(1...5, id: \.self) { z in
                        let selected = zoneTarget == z
                        Button {
                            zoneTarget = z
                        } label: {
                            Text("Z\(z)")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(selected ? Color.white : theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(selected ? theme.zoneColor(z) : theme.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("zone-lock-\(z)")
                    }
                }
                if zoneTarget != 0 {
                    Text(HRZone.label(zoneTarget))
                        .font(.tag)
                        .foregroundStyle(theme.zoneColor(zoneTarget))
                }
            }
        }
    }

    // MARK: - Intervals mode (repeats)

    /// Structured-interval builder: warm-up → rounds of work/recover → cool-down.
    private var intervalStepsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                durationRow("Warm-up", seconds: $warmup, step: 30)
                Divider().overlay(theme.separator)
                Stepper(value: $repeats, in: 1...30) {
                    HStack {
                        Text("Rounds").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(repeats)×").font(.bodyStrong).foregroundStyle(theme.secondaryAccent)
                    }
                }
                Divider().overlay(theme.separator)
                workLengthRow
                stepZoneRow("Work target zone", selection: $workZone)
                PaceBandRow(low: $paceLow, high: $paceHigh, label: "Work pace band")
                durationRow("Recover", seconds: $recover, step: 15)
                stepZoneRow("Recover target zone", selection: $recoverZone)
                Divider().overlay(theme.separator)
                durationRow("Cool-down", seconds: $cooldown, step: 30)
            }
        }
    }

    /// Work reps count down a clock or count up a distance — the erg's
    /// 8 × 500 m and the track's 6 × 400 m are distance reps, not guesses
    /// at how long they take.
    private var workLengthRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Work").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Picker("Work rep length", selection: $workByDistance) {
                    Text("Time").tag(false)
                    Text("Distance").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .accessibilityIdentifier("work-length-type")
            }
            if workByDistance {
                Stepper(value: $workDistance, in: 50...5000, step: 50) {
                    HStack {
                        Text("Each rep").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text(IntervalPlan.metricDistance(workDistance))
                            .font(.bodyStrong).foregroundStyle(theme.secondaryAccent)
                    }
                }
            } else {
                Stepper(value: $work, in: 0...3600, step: 15) {
                    HStack {
                        Text("Each rep").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text(work == 0 ? "Off" : Fmt.durationShort(work))
                            .font(.bodyStrong).foregroundStyle(theme.secondaryAccent)
                    }
                }
            }
        }
    }

    /// The bridge from steppers to the ordered list: one tap expands the
    /// repeat structure into individually editable steps.
    private var customizeCard: some View {
        Card {
            NavigationLink {
                CustomStepsEditor(steps: $customSteps)
                    .onAppear {
                        // Expand the CURRENT stepper structure exactly once,
                        // at the repeats→custom transition — a stale custom
                        // list must never shadow fresh stepper edits.
                        if intervalsLayout == .repeats {
                            customSteps = plan.steps.map(EditableStep.init)
                            intervalsLayout = .custom
                        }
                    }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .bold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Customize steps").font(.system(size: 14, weight: .semibold))
                        Text("Mix time and distance reps with per-step targets.")
                            .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).opacity(0.6)
                }
                .foregroundStyle(theme.secondaryAccent)
            }
            .accessibilityIdentifier("customize-steps")
        }
    }

    // MARK: - Intervals mode (custom)

    private var customStepsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text("Custom steps").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("\(customSteps.count) steps")
                        .font(.tag).foregroundStyle(theme.textSecondary)
                }
                ForEach(EditableStep.relabeled(customSteps)) { step in
                    HStack(spacing: 8) {
                        Circle().fill(step.kind.tint(in: theme)).frame(width: 8, height: 8)
                        Text(step.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(step.isDistanceBased
                             ? IntervalPlan.metricDistance(step.distanceMeters ?? 0)
                             : Fmt.durationShort(step.seconds))
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(theme.secondaryAccent)
                        if let zone = step.hrZone {
                            Text("Z\(zone)").font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(theme.zoneColor(zone))
                        }
                    }
                }
                NavigationLink {
                    CustomStepsEditor(steps: $customSteps)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                        Text("Edit steps")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondaryAccent)
                }
                .accessibilityIdentifier("edit-custom-steps")
            }
        }
    }

    private var totalCard: some View {
        Card {
            HStack {
                Text("Total").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                let current = plan
                Text(totalText(for: current))
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.secondaryAccent)
            }
        }
    }

    private func totalText(for plan: IntervalPlan) -> String {
        var parts: [String] = []
        if plan.totalSeconds > 0 { parts.append(Fmt.durationShort(plan.totalSeconds)) }
        if plan.totalDistanceMeters > 0 { parts.append(IntervalPlan.metricDistance(plan.totalDistanceMeters)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    /// Quick-start templates: one tap fills the whole structure; the steppers
    /// stay editable after.
    private var presetsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text("Presets").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Button("Save current") {
                        presetName = ""
                        showSavePrompt = true
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(plan.isMeaningful ? theme.secondaryAccent : theme.textTertiary)
                    .disabled(!plan.isMeaningful)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.sm) {
                        ForEach(IntervalPresets.builtIn, id: \.name) { preset in
                            presetChip(name: preset.name, plan: preset.plan, isUser: false) {
                                apply(preset.plan)
                            }
                        }
                        ForEach(userPresets) { preset in
                            if let plan = IntervalPlan.decode(from: preset.planJSON) {
                                presetChip(name: preset.name, plan: plan, isUser: true) {
                                    apply(plan)
                                }
                            }
                        }
                    }
                }
                if !userPresets.isEmpty {
                    Button("Manage saved presets") { showManageSheet = true }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func presetChip(name: String, plan: IntervalPlan, isUser: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isUser {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.secondaryAccent)
                    }
                    Text(name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                }
                Text(plan.structureSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Seed the editor from a plan — repeat shapes load the steppers, custom
    /// shapes load the ordered list; the fields stay editable afterward.
    private func apply(_ plan: IntervalPlan) {
        if plan.matchesRepeatBuilderShape {
            intervalsLayout = .repeats
            let steps = plan.steps
            let workStep = steps.first { $0.kind == .work }
            let recoverStep = steps.first { $0.kind == .recover }
            warmup = steps.first { $0.kind == .warmup }?.seconds ?? 0
            repeats = max(1, steps.filter { $0.kind == .work }.count)
            work = workStep?.seconds ?? 60
            workByDistance = false
            recover = recoverStep?.seconds ?? 60
            cooldown = steps.first { $0.kind == .cooldown }?.seconds ?? 0
            workZone = workStep?.hrZone ?? 0
            recoverZone = recoverStep?.hrZone ?? 0
            customSteps = steps.map(EditableStep.init)
        } else {
            intervalsLayout = .custom
            customSteps = plan.steps.map(EditableStep.init)
        }
        if let zone = plan.hrZoneTarget { zoneTarget = zone }
    }

    private func saveAsPreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        presetName = ""
        guard !trimmed.isEmpty, plan.isMeaningful, let json = plan.encodedJSON() else { return }
        let preset = IntervalPresetModel(userID: ForgeFitDemo.userID, name: trimmed, planJSON: json)
        modelContext.insert(preset)
        try? modelContext.save()
    }

    private func stepZoneRow(_ label: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Spacer()
            Picker(label, selection: selection) {
                Text("None").tag(0)
                ForEach(1...5, id: \.self) { z in Text("Z\(z)").tag(z) }
            }
            .pickerStyle(.menu)
            .tint(selection.wrappedValue == 0 ? theme.textTertiary : theme.zoneColor(selection.wrappedValue))
        }
    }

    private func durationRow(_ label: String, seconds: Binding<Int>, step: Int, tint: Color? = nil) -> some View {
        Stepper(value: seconds, in: 0...3600, step: step) {
            HStack {
                Text(label).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Text(seconds.wrappedValue == 0 ? "Off" : Fmt.durationShort(seconds.wrappedValue))
                    .font(.bodyStrong).foregroundStyle(tint ?? theme.textPrimary)
            }
        }
    }

    private func save() {
        onSave(plan.isMeaningful ? plan.encodedJSON() : nil)
        dismiss()
    }
}

// MARK: - Pace band entry

/// Optional pace window, entered as m:ss in the user's distance unit
/// ("5:20" min/km) — the vocabulary runners actually think in. Empty fields
/// leave the bound open.
struct PaceBandRow: View {
    @Environment(\.theme) private var theme
    /// Bounds in canonical seconds per km; conversion happens here.
    @Binding var low: Double?
    @Binding var high: Double?
    var label: String = "Pace band"

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                Text("Live cue when you drift out")
                    .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
            }
            Spacer()
            PaceEntryField(placeholder: "5:20", secondsPerKm: $low)
                .accessibilityIdentifier("pace-band-fast")
            Text("–").foregroundStyle(theme.textTertiary)
            PaceEntryField(placeholder: "5:40", secondsPerKm: $high)
                .accessibilityIdentifier("pace-band-slow")
            Text(Fmt.distanceUnit.paceSuffix)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
    }
}

/// m:ss pace entry against the user's distance unit, stored as seconds per
/// km. Accepts "5:20" (or a bare "5.5" = 5m30s) on the draft-field pattern.
struct PaceEntryField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var secondsPerKm: Double?
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .keyboardType(.numbersAndPunctuation)
            .font(.bodyStrong)
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.textPrimary)
            .frame(width: 64, height: 40)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .focused($isFocused)
            .onAppear { draft = Self.text(for: secondsPerKm) }
            .onChange(of: draft) { _, newDraft in
                guard isFocused else { return }
                secondsPerKm = Self.parse(newDraft)
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { draft = Self.text(for: secondsPerKm) }
            }
    }

    /// Display: seconds/km → m:ss in the user's unit.
    private static func text(for secondsPerKm: Double?) -> String {
        guard let secondsPerKm, secondsPerKm > 0 else { return "" }
        let perUnit = secondsPerKm * (Fmt.distanceUnit.metersPerUnit / 1000)
        return String(format: "%d:%02d", Int(perUnit) / 60, Int(perUnit) % 60)
    }

    /// Parse: m:ss (or decimal minutes) in the user's unit → seconds/km.
    private static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let perUnitSeconds: Double?
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let minutes = Int(parts[0]),
                  let seconds = Int(parts[1]), (0..<60).contains(seconds) else { return nil }
            perUnitSeconds = Double(minutes * 60 + seconds)
        } else if let minutes = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
            perUnitSeconds = minutes * 60
        } else {
            perUnitSeconds = nil
        }
        guard let perUnitSeconds, perUnitSeconds > 0 else { return nil }
        return perUnitSeconds / (Fmt.distanceUnit.metersPerUnit / 1000)
    }
}

// MARK: - Custom ordered steps

/// Editor-friendly mirror of `IntervalPlan.Step`: labels regenerate on save,
/// so the editor only tracks the structural fields.
struct EditableStep: Identifiable, Equatable {
    let id: UUID
    var kind: IntervalPlan.Step.Kind
    var seconds: Int
    var distanceMeters: Double?
    var hrZone: Int?
    var targetMetric: IntervalPlan.Target.Metric?
    var targetLow: Double?
    var targetHigh: Double?

    var isDistanceBased: Bool { (distanceMeters ?? 0) > 0 }

    init(kind: IntervalPlan.Step.Kind, seconds: Int = 60, distanceMeters: Double? = nil) {
        self.id = UUID()
        self.kind = kind
        self.seconds = seconds
        self.distanceMeters = distanceMeters
    }

    init(_ step: IntervalPlan.Step) {
        id = step.id
        kind = step.kind
        seconds = step.seconds
        distanceMeters = step.distanceMeters
        hrZone = step.hrZone
        targetMetric = step.target?.metric
        targetLow = step.target?.low
        targetHigh = step.target?.high
    }

    var target: IntervalPlan.Target? {
        guard let targetMetric, targetLow != nil || targetHigh != nil else { return nil }
        return IntervalPlan.Target(metric: targetMetric, low: targetLow, high: targetHigh)
    }

    /// Rebuild the flat step list with fresh sequential labels ("Work 2/3").
    static func relabeled(_ steps: [EditableStep]) -> [IntervalPlan.Step] {
        let workTotal = steps.count { $0.kind == .work }
        let recoverTotal = steps.count { $0.kind == .recover }
        var workSeen = 0, recoverSeen = 0
        return steps.map { editable in
            let label: String
            switch editable.kind {
            case .warmup: label = "Warm-up"
            case .cooldown: label = "Cool-down"
            case .work:
                workSeen += 1
                label = workTotal > 1 ? "Work \(workSeen)/\(workTotal)" : "Work"
            case .recover:
                recoverSeen += 1
                label = recoverTotal > 1 ? "Recover \(recoverSeen)/\(recoverTotal)" : "Recover"
            }
            return IntervalPlan.Step(
                id: editable.id,
                kind: editable.kind,
                seconds: editable.isDistanceBased ? 0 : editable.seconds,
                label: label,
                hrZone: editable.hrZone,
                distanceMeters: editable.isDistanceBased ? editable.distanceMeters : nil,
                target: editable.target
            )
        }
    }
}

/// Ordered step list: drag to reorder, swipe to delete, tap to edit — the
/// always-active edit-mode List pattern (rows stay tappable).
struct CustomStepsEditor: View {
    @Environment(\.theme) private var theme
    @Binding var steps: [EditableStep]

    var body: some View {
        List {
            Section {
                ForEach($steps) { $step in
                    NavigationLink {
                        StepDetailEditor(step: $step)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\((steps.firstIndex { $0.id == step.id } ?? 0) + 1)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 22, height: 22)
                                .background(theme.surface)
                                .clipShape(Circle())
                            Circle().fill(step.kind.tint(in: theme)).frame(width: 8, height: 8)
                            Text(title(for: step))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text(step.isDistanceBased
                                 ? IntervalPlan.metricDistance(step.distanceMeters ?? 0)
                                 : Fmt.durationShort(step.seconds))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.secondaryAccent)
                            if let zone = step.hrZone {
                                Text("Z\(zone)")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(theme.zoneColor(zone))
                            }
                        }
                    }
                    .listRowBackground(theme.surfaceElevated)
                }
                .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { steps.remove(atOffsets: $0) }
            }

            Section("Add step") {
                ForEach([IntervalPlan.Step.Kind.warmup, .work, .recover, .cooldown], id: \.self) { kind in
                    Button {
                        steps.append(EditableStep(kind: kind, seconds: defaultSeconds(for: kind)))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(kind.tint(in: theme))
                            Text(name(for: kind)).foregroundStyle(theme.textPrimary)
                        }
                    }
                    .accessibilityIdentifier("add-step-\(kind.rawValue)")
                    .listRowBackground(theme.surfaceElevated)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Custom steps")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func title(for step: EditableStep) -> String {
        name(for: step.kind)
    }

    private func name(for kind: IntervalPlan.Step.Kind) -> String {
        switch kind {
        case .warmup: "Warm-up"
        case .work: "Work"
        case .recover: "Recover"
        case .cooldown: "Cool-down"
        }
    }

    private func defaultSeconds(for kind: IntervalPlan.Step.Kind) -> Int {
        switch kind {
        case .warmup, .cooldown: 300
        case .work: 60
        case .recover: 90
        }
    }
}

/// One step's full contract: kind, timed-or-distance length, optional HR
/// zone, optional metric band. Pace bands cue live; power/cadence bands
/// display as guidance (no live sensor — the app never fakes a monitor).
struct StepDetailEditor: View {
    @Environment(\.theme) private var theme
    @Binding var step: EditableStep

    var body: some View {
        List {
            Section {
                Picker("Type", selection: $step.kind) {
                    Text("Warm-up").tag(IntervalPlan.Step.Kind.warmup)
                    Text("Work").tag(IntervalPlan.Step.Kind.work)
                    Text("Recover").tag(IntervalPlan.Step.Kind.recover)
                    Text("Cool-down").tag(IntervalPlan.Step.Kind.cooldown)
                }
                .listRowBackground(theme.surfaceElevated)
            }

            Section("Length") {
                Picker("Measured by", selection: Binding(
                    get: { step.isDistanceBased },
                    set: { byDistance in
                        if byDistance {
                            if (step.distanceMeters ?? 0) <= 0 { step.distanceMeters = 400 }
                        } else {
                            step.distanceMeters = nil
                            if step.seconds <= 0 { step.seconds = 60 }
                        }
                    }
                )) {
                    Text("Time").tag(false)
                    Text("Distance").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(theme.surfaceElevated)
                .accessibilityIdentifier("step-length-type")

                if step.isDistanceBased {
                    Stepper(value: Binding(
                        get: { step.distanceMeters ?? 400 },
                        set: { step.distanceMeters = $0 }
                    ), in: 50...10_000, step: 50) {
                        HStack {
                            Text("Distance")
                            Spacer()
                            Text(IntervalPlan.metricDistance(step.distanceMeters ?? 400))
                                .foregroundStyle(theme.secondaryAccent).bold()
                        }
                    }
                    .listRowBackground(theme.surfaceElevated)
                } else {
                    Stepper(value: $step.seconds, in: 5...3600, step: 15) {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(Fmt.durationShort(step.seconds))
                                .foregroundStyle(theme.secondaryAccent).bold()
                        }
                    }
                    .listRowBackground(theme.surfaceElevated)
                }
            }

            Section("Heart-rate zone") {
                Picker("Zone", selection: Binding(get: { step.hrZone ?? 0 }, set: { step.hrZone = $0 == 0 ? nil : $0 })) {
                    Text("None").tag(0)
                    ForEach(1...5, id: \.self) { Text("Z\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(theme.surfaceElevated)
            }

            Section {
                Picker("Metric", selection: Binding(
                    get: { step.targetMetric },
                    set: { step.targetMetric = $0; if $0 == nil { step.targetLow = nil; step.targetHigh = nil } }
                )) {
                    Text("None").tag(IntervalPlan.Target.Metric?.none)
                    Text("Pace").tag(IntervalPlan.Target.Metric?.some(.pace))
                    Text("Power").tag(IntervalPlan.Target.Metric?.some(.power))
                    Text("Cadence").tag(IntervalPlan.Target.Metric?.some(.cadence))
                }
                .listRowBackground(theme.surfaceElevated)
                .accessibilityIdentifier("step-target-metric")

                switch step.targetMetric {
                case .pace:
                    PaceBandRow(low: $step.targetLow, high: $step.targetHigh, label: "Pace band")
                        .listRowBackground(theme.surfaceElevated)
                case .power:
                    boundsRow(unit: "W", low: $step.targetLow, high: $step.targetHigh)
                case .cadence:
                    boundsRow(unit: "/min", low: $step.targetLow, high: $step.targetHigh)
                case nil:
                    EmptyView()
                }
            } header: {
                Text("Target band")
            } footer: {
                switch step.targetMetric {
                case .pace:
                    Text("Pace cues live from GPS or Apple Watch distance.")
                case .power, .cadence:
                    Text("Shown as a target to hold against the console — ForgeFit has no live sensor for it.")
                case nil:
                    Text("")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .navigationTitle("Step")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func boundsRow(unit: String, low: Binding<Double?>, high: Binding<Double?>) -> some View {
        HStack(spacing: 8) {
            Text("Range").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Spacer()
            OptionalDecimalField(placeholder: "min", value: low)
                .frame(width: 72)
            Text("–").foregroundStyle(theme.textTertiary)
            OptionalDecimalField(placeholder: "max", value: high)
                .frame(width: 72)
            Text(unit)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surfaceElevated)
    }
}

/// Built-in interval templates — the classics, ready in one tap.
enum IntervalPresets {
    struct Preset {
        let name: String
        let plan: IntervalPlan
    }

    static let builtIn: [Preset] = [
        Preset(name: "Run / Walk 10×1:00", plan: .build(
            warmupSeconds: 300, repeats: 10, workSeconds: 60, recoverSeconds: 60, cooldownSeconds: 300)),
        Preset(name: "Norwegian 4×4", plan: .build(
            warmupSeconds: 600, repeats: 4, workSeconds: 240, recoverSeconds: 180, cooldownSeconds: 300,
            workZone: 4, recoverZone: 3)),
        Preset(name: "30/30 HIIT", plan: .build(
            warmupSeconds: 300, repeats: 10, workSeconds: 30, recoverSeconds: 30, cooldownSeconds: 180)),
        Preset(name: "Sprint 8×0:20", plan: .build(
            warmupSeconds: 300, repeats: 8, workSeconds: 20, recoverSeconds: 100, cooldownSeconds: 300,
            workZone: 5)),
        Preset(name: "Track 6×400m", plan: .build(
            warmupSeconds: 600, repeats: 6, workSeconds: 0, recoverSeconds: 90, cooldownSeconds: 300,
            workDistanceMeters: 400)),
        Preset(name: "Erg 8×500m", plan: .build(
            warmupSeconds: 300, repeats: 8, workSeconds: 0, recoverSeconds: 120, cooldownSeconds: 180,
            workDistanceMeters: 500)),
    ]
}

/// Soft-delete management list for the user's saved interval presets. Lives in
/// the builder sheet; removing a preset stamps `deletedAt` so it drops out of
/// the active query without a hard delete.
private struct IntervalPresetManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<IntervalPresetModel> { $0.deletedAt == nil },
        sort: \IntervalPresetModel.createdAt, order: .reverse
    ) private var presets: [IntervalPresetModel]

    var body: some View {
        NavigationStack {
            Group {
                if presets.isEmpty {
                    ContentUnavailableView {
                        Label("No saved presets", systemImage: "bookmark")
                    } description: {
                        Text("Saved interval structures appear here.")
                    } actions: {
                        Button("Create a preset", systemImage: "plus") {
                            dismiss()
                        }
                    }
                } else {
                    List {
                        ForEach(presets) { preset in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                if let plan = IntervalPlan.decode(from: preset.planJSON) {
                                    Text(plan.structureSummary)
                                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                }
                            }
                            .listRowBackground(theme.surfaceElevated)
                        }
                        .onDelete(perform: delete)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.background)
            .navigationTitle("Saved presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        let now = Date()
        for index in offsets {
            let preset = presets[index]
            preset.deletedAt = now
            preset.updatedAt = now
        }
        try? modelContext.save()
    }
}
