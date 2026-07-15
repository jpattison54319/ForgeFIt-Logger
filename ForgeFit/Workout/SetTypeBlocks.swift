import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Left-aligned flow layout: children lay out in rows and wrap to a new row
/// instead of overflowing horizontally.
struct WrapLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in computeRows(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            for index in row.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var range: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var start = 0
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if index > start, x + size.width > maxWidth {
                rows.append(Row(range: start..<index, width: x - spacing, height: rowHeight))
                start = index
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if start < subviews.count {
            rows.append(Row(range: start..<subviews.count, width: x - spacing, height: rowHeight))
        }
        return rows
    }
}

/// Intra-set block logger for myo-reps, rest-pause, and clusters.
///
/// These aren't rows of independent sets — they're ONE set broken up by
/// micro-rests, so the UI is a nested block: an activation/main input, a strip
/// of tap-to-confirm mini-set pills, and micro-rests in the logger's persistent
/// top timer.
struct SetBlockView: View {
    @Bindable var set: SetModel
    @Bindable var workoutExercise: WorkoutExerciseModel
    let blockNumber: Int
    let previous: SetModel?
    let showWeight: Bool
    let displayUnit: WeightUnit
    /// Display-unit jump for the hold-drag quick increment fan.
    var quickWeightStep: Double = 2.5
    /// Unilateral exercises run the whole block once per limb: the flow
    /// renders twice ("Side 1" → "Side 2"), same weight and micro-rests,
    /// and only the single complete checkbox finishes the set.
    var isUnilateral: Bool = false
    var completionDate: Date? = nil
    let onChange: () -> Void
    let onSetType: (SetType) -> Void
    let onCompleted: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    // Block input fields grow with Dynamic Type alongside the text they hold.
    @ScaledMetric(relativeTo: .body) private var blockFieldWidth: CGFloat = 58
    @ScaledMetric(relativeTo: .body) private var blockFieldHeight: CGFloat = 30
    @Environment(SetInputRouter.self) private var inputRouter: SetInputRouter?

    /// Inline pill entry: `newEntryIndex` = typing a new mini-set, >= 0 =
    /// retyping an existing one. `editingSide` scopes it for per-side flows.
    @State private var editingIndex: Int?
    @State private var editingSide = 1
    @State private var entryText = ""
    @FocusState private var entryFocused: Bool

    /// Raw weight text while the field has focus. Without this, the
    /// get-formats/set-parses binding erased a trailing decimal point the
    /// instant it was typed ("62." re-rendered as "62"), making fractional
    /// loads impossible to enter in blocks.
    @State private var weightDraft = ""
    @State private var weightDraftActive = false
    @FocusState private var weightFocused: Bool

    /// Which side's activation reps field has the keyboard, so the log
    /// button can hand focus to its field instead of sitting dead when no
    /// reps are typed yet (the retrofit-to-unilateral path made that
    /// disabled state read as a bug).
    @FocusState private var activationFocus: Int?

    private var timer: RestTimerController { RestTimerController.shared }

    private var isCluster: Bool { self.set.setType == .cluster }
    private var style: SetTypeStyle { SetTypeStyle.of(self.set.setType) }
    private var isDone: Bool { self.set.completedAt != nil }

    private var microRest: Int {
        workoutExercise.microRestSeconds ?? set.setType.defaultMicroRestSeconds ?? 15
    }

    /// Activation logged (myo/rest-pause) or at least one segment (cluster) —
    /// gates the mini-set strip.
    private var blockStarted: Bool {
        isCluster ? !set.miniReps.isEmpty : set.reps != nil
    }

    /// Same gate for the second side of a unilateral block.
    private var side2Started: Bool {
        isCluster ? !set.side2MiniReps.isEmpty : set.side2Reps != nil
    }

    private var totalReps: Int {
        (isCluster ? 0 : (set.reps ?? 0) + (set.side2Reps ?? 0))
            + set.miniReps.reduce(0, +)
            + set.side2MiniReps.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            headerRow
            if isUnilateral { sideLabel(1) }
            if !isCluster { activationRow(side: 1) }
            if blockStarted || isCluster {
                miniSetStrip(side: 1)
            }
            // Side 2 unlocks once side 1 is underway, so the flow reads
            // top-to-bottom the way it's actually performed. Completing side
            // 1 never completes the set — only the header checkbox does.
            if isUnilateral && blockStarted {
                sideLabel(2)
                if !isCluster { activationRow(side: 2) }
                if side2Started || isCluster {
                    miniSetStrip(side: 2)
                }
            }
            if let ghost = matchPreviousGhost {
                matchPreviousRow(ghost)
            }
        }
        .padding(Space.sm)
        .background(isDone ? theme.success.opacity(0.10) : style.color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder((isDone ? theme.success : style.color).opacity(0.25), lineWidth: 1)
        )
    }

    private func sideLabel(_ side: Int) -> some View {
        Text("Side \(side)")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(style.color.opacity(0.85))
            .textCase(.uppercase)
            .padding(.top, side == 2 ? 2 : 0)
    }

    // MARK: - Per-side data plumbing

    private func sideReps(_ side: Int) -> Int? {
        side == 2 ? set.side2Reps : set.reps
    }

    private func setSideReps(_ side: Int, _ value: Int?) {
        if side == 2 { set.side2Reps = value } else { set.reps = value }
    }

    private func sideMinis(_ side: Int) -> [Int] {
        side == 2 ? set.side2MiniReps : set.miniReps
    }

    private func setSideMinis(_ side: Int, _ value: [Int]) {
        if side == 2 { set.side2MiniReps = value } else { set.miniReps = value }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: Space.sm) {
            // Leading circle checkbox, identical to every other set row —
            // the block's old trailing rounded-rect checkmark read as a
            // different control, and lifters finished blocks without ever
            // completing them.
            completeButton

            Menu {
                ForEach(SetType.selectable, id: \.self) { type in
                    Button {
                        onSetType(type)
                    } label: {
                        Label(SetTypeStyle.of(type).label, systemImage: set.setType == type ? "checkmark" : "")
                    }
                }
                Divider()
                Button("Delete Set", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                HStack(spacing: 5) {
                    Text(style.badge)
                        .font(.system(size: 13, weight: .heavy))
                    Text(style.label)
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(style.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(style.color.opacity(0.15))
                .clipShape(Capsule())
            }

            Spacer()

            if totalReps > 0 {
                Text(repSummary)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            // Micro-rest chip — tap to change the intra-set rest (10s–60s).
            RestDurationMenu(
                options: [10, 15, 20, 30, 45, 60],
                allowsOff: false,
                selected: microRest,
                onPick: { picked in
                    workoutExercise.microRestSeconds = picked
                    onChange()
                }
            ) {
                HStack(spacing: 3) {
                    Image(systemName: "timer").font(.system(size: 11, weight: .bold))
                    Text("\(microRest)s").font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.surfaceElevated)
                .clipShape(Capsule())
            }
        }
    }

    private var repSummary: String {
        if isUnilateral, blockStarted {
            // Both sides at a glance; scale-down handles the width.
            return "\(totalReps) reps · both sides"
        }
        let minis = set.miniReps.map(String.init).joined(separator: "+")
        if isCluster {
            return "\(totalReps) reps · \(minis)"
        }
        let activation = set.reps.map(String.init) ?? "—"
        return minis.isEmpty ? "\(activation) reps" : "\(activation) + \(minis)"
    }

    /// Checks off the whole block, then lets the logger's shared completion
    /// coordinator apply the same rest and superset rules as every other set.
    /// Rendered exactly like `SetRow`'s leading circle checkbox — one
    /// completion control across every set type.
    private var completeButton: some View {
        Button {
            if isDone {
                set.completedAt = nil
            } else {
                // Side 1's segment sum only — side 2 is added to volume by
                // recomputeDerivedMetrics from its own fields.
                if isCluster { set.reps = set.miniReps.reduce(0, +) }
                set.completedAt = completionDate ?? Date()
                HealthMetricsStore.shared.fillBodyweight(set)
                if timer.microOwnerID == set.id { timer.skip() }
            }
            set.recomputeDerivedMetrics()
            onChange()
            if isDone { onCompleted() }
        } label: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.sectionTitle)
                .foregroundStyle(isDone ? theme.success : theme.textTertiary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("complete-set-\(blockNumber)")
        .accessibilityLabel(isDone ? "Completed, tap to un-complete" : "Complete set")
    }

    // MARK: - Activation set (myo-reps / rest-pause)

    private func activationRow(side: Int) -> some View {
        HStack(spacing: Space.sm) {
            Text("Activation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Weight is the implement's — shared across sides, entered once.
            if showWeight && side == 1 {
                weightField
            }
            blockField(
                text: Binding(
                    get: { sideReps(side).map(String.init) ?? "" },
                    set: { setSideReps(side, Int($0)); onChange() }
                ),
                placeholder: activationPlaceholder(side: side),
                keyboardType: .numberPad
            )
            .accessibilityIdentifier("activation-reps-\(side)")
            .focused($activationFocus, equals: side)
            .quickIncrementable(
                options: QuickIncrementController.repsOptions(),
                onBegin: { activationFocus = nil },
                base: {
                    // Mirrors the ghost the placeholder shows: side 2 leans
                    // on side 1, side 1 on last session.
                    Double(sideReps(side) ?? (side == 2 ? self.set.reps : previous?.reps) ?? 0)
                },
                apply: { setSideReps(side, Int($0.rounded())); onChange() }
            )
            // Log the activation → the first micro-rest starts immediately.
            // With nothing typed it adopts the ghost the placeholder shows —
            // the same "as planned" contract as the working-set checkbox —
            // so a lifter who hit the target logs the activation in one tap.
            // Never disabled: with no reps AND no ghost it hands focus to the
            // field instead — a dead-looking no-op here read as a bug when a
            // set was converted to unilateral mid-workout and side 2 started
            // empty.
            Button {
                if sideReps(side) == nil, let ghost = activationGhostReps(side: side) {
                    setSideReps(side, ghost)
                    if showWeight && side == 1 && set.weight == nil {
                        set.weight = previous?.weight
                    }
                    logActivation(side: side)
                } else if sideReps(side) == nil {
                    activationFocus = side
                } else {
                    logActivation(side: side)
                }
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(activationLoggable(side: side) ? style.color : theme.textSecondary)
                    .frame(width: 34, height: 30)
                    .background(style.color.opacity(activationLoggable(side: side) ? 0.18 : 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("log-activation-\(side)")
            .accessibilityLabel(activationAccessibilityLabel(side: side))
        }
    }

    /// Side 2 suggests matching side 1's activation; side 1 suggests history.
    private func activationPlaceholder(side: Int) -> String {
        activationGhostReps(side: side).map(String.init) ?? "reps"
    }

    /// The ghost the placeholder shows — what the log button adopts when
    /// nothing is typed. Side 2 mirrors side 1; side 1 leans on last session.
    private func activationGhostReps(side: Int) -> Int? {
        side == 2 ? set.reps : previous?.reps
    }

    /// Typed reps, or a ghost the log button can adopt.
    private func activationLoggable(side: Int) -> Bool {
        sideReps(side) != nil || activationGhostReps(side: side) != nil
    }

    private func activationAccessibilityLabel(side: Int) -> String {
        if sideReps(side) != nil { return "Log activation and start micro-rest" }
        if activationGhostReps(side: side) != nil { return "Log activation as planned and start micro-rest" }
        return "Enter activation reps"
    }

    private func logActivation(side: Int) {
        timer.start(seconds: microRest, label: miniRestLabel(side: side, count: 1), micro: true, ownerID: set.id)
        onChange()
    }

    // MARK: - Mini-set pill strip

    private func miniSetStrip(side: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCluster && showWeight && side == 1 {
                HStack(spacing: Space.sm) {
                    Text("Weight")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    weightField
                    Spacer()
                }
            }
            // Pills wrap onto new rows instead of running off screen.
            WrapLayout(spacing: 7) {
                ForEach(Array(sideMinis(side).enumerated()), id: \.offset) { index, reps in
                    if editingIndex == index && editingSide == side {
                        entryPill(side: side)
                    } else {
                        miniPill(side: side, index: index, reps: reps)
                    }
                }
                let ghosts = remainingPlannedGoals(side: side)
                if editingIndex == Self.newEntryIndex && editingSide == side {
                    entryPill(side: side)
                    ForEach(Array(ghosts.dropFirst().enumerated()), id: \.offset) { _, goal in
                        ghostPill(side: side, goal: goal, isNext: false)
                    }
                } else if ghosts.isEmpty {
                    addMiniPill(side: side)
                } else {
                    // The routine's plan renders as dashed targets: the first
                    // ghost is the live "log this mini" pill, the rest show
                    // what's still ahead. Goals are never prefilled as reps.
                    ForEach(Array(ghosts.enumerated()), id: \.offset) { index, goal in
                        ghostPill(side: side, goal: goal, isNext: index == 0)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// A confirmed mini-set. Tap the number to retype it; touch-and-hold for
    /// quick ±1 adjustments or removal. Button + context menu instead of a
    /// `Menu` label on purpose: Menu labels claim the touch on contact
    /// (press-and-slide selection), so a scroll that began on any pill never
    /// reached the ScrollView — and pills are most of a block's surface.
    private func miniPill(side: Int, index: Int, reps: Int) -> some View {
        Button {
            beginEntry(side: side, editing: index)
        } label: {
            Text("+\(reps)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(style.color)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(style.color.opacity(0.16))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(style.color.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("+1 rep", systemImage: "plus") { adjustMini(side: side, index: index, by: 1) }
            Button("−1 rep", systemImage: "minus") { adjustMini(side: side, index: index, by: -1) }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) {
                var minis = sideMinis(side)
                minis.remove(at: index)
                setSideMinis(side, minis)
                syncClusterReps()
                onChange()
            }
        }
    }

    /// The "next mini-set" pill. First mini-set: opens keyboard entry so the
    /// user logs what they actually got (no forced target). After that, one
    /// tap repeats the last mini — touch-and-hold to type a different number.
    /// Button + context menu (not a `Menu` label) so scrolls that start here
    /// reach the ScrollView.
    private func addMiniPill(side: Int) -> some View {
        Button {
            if let target = nextMiniTarget(side: side) {
                appendMini(side: side, target)
            } else {
                beginEntry(side: side, editing: Self.newEntryIndex)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                if let target = nextMiniTarget(side: side) {
                    Text("\(target)").font(.system(size: 14, weight: .bold, design: .rounded))
                } else {
                    Text("reps").font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .overlay(
                Capsule().strokeBorder(
                    theme.textTertiary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Enter manually", systemImage: "keyboard") { beginEntry(side: side, editing: Self.newEntryIndex) }
        }
        .disabled(isDone)
    }

    /// Inline numeric field standing in for the pill being entered/edited.
    private func entryPill(side: Int) -> some View {
        TextField(nextMiniTarget(side: side).map(String.init) ?? "reps", text: $entryText)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .focused($entryFocused)
            .foregroundStyle(style.color)
            .frame(width: 52, height: 31)
            .background(style.color.opacity(0.16))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(style.color, lineWidth: 1.5))
            .onChange(of: entryFocused) { _, focused in
                // The keyboard's Log/dismiss both just end focus — the commit
                // itself always rides the focus loss, so every exit path
                // (accessory, tap-away, scroll) lands the typed reps.
                if focused {
                    inputRouter?.register(
                        token: entryAccessoryToken,
                        completeTitle: "Log",
                        onComplete: { entryFocused = false },
                        onDismiss: { entryFocused = false }
                    )
                } else {
                    commitEntry()
                    inputRouter?.unregister(token: entryAccessoryToken)
                }
            }
    }

    private var entryAccessoryToken: String { "\(set.id.uuidString)-mini" }

    /// nil = no target to repeat yet — the first mini must be typed. A cluster
    /// plan's goal for the next segment wins; otherwise side 2 falls back to
    /// side 1's pattern before history: same limb pair, same plan.
    private func nextMiniTarget(side: Int) -> Int? {
        if isCluster {
            let plan = set.plannedMiniReps
            let next = sideMinis(side).count
            if plan.indices.contains(next) { return plan[next] }
        }
        if let last = sideMinis(side).last { return last }
        if side == 2, let mirror = set.miniReps.first { return mirror }
        return previous?.miniReps.first
    }

    /// Planned-but-unlogged mini targets for this side: cluster ghosts carry
    /// their goal reps, myo ghosts are open slots (Int? = nil) to fill live.
    /// Both sides of a unilateral block follow the same plan.
    private func remainingPlannedGoals(side: Int) -> [Int?] {
        let logged = sideMinis(side).count
        if isCluster {
            let plan = set.plannedMiniReps
            guard logged < plan.count else { return [] }
            return plan[logged...].map(Optional.init)
        }
        if set.setType == .myoRep, let planned = set.plannedMiniSetCount, logged < planned {
            return Array(repeating: nil, count: planned - logged)
        }
        return []
    }

    /// A dashed plan target. The first ghost is live — tap logs the goal
    /// (cluster) or repeats the usual target (myo); later ghosts just preview
    /// the remaining plan.
    private func ghostPill(side: Int, goal: Int?, isNext: Bool) -> some View {
        let label = goal.map { "+\($0)" }
            ?? (isNext ? nextMiniTarget(side: side).map { "+\($0)" } : nil)
            ?? "+ reps"
        return Button {
            if let goal {
                appendMini(side: side, goal)
            } else if let target = nextMiniTarget(side: side) {
                appendMini(side: side, target)
            } else {
                beginEntry(side: side, editing: Self.newEntryIndex)
            }
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(isNext ? style.color : theme.textTertiary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .overlay(
                    Capsule().strokeBorder(
                        (isNext ? style.color : theme.textTertiary).opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Enter manually", systemImage: "keyboard") { beginEntry(side: side, editing: Self.newEntryIndex) }
        }
        .disabled(isDone || !isNext)
        .accessibilityLabel(goal.map { "Planned mini-set: \($0) reps" } ?? "Planned mini-set")
    }

    private static let newEntryIndex = -1

    private func beginEntry(side: Int, editing index: Int) {
        editingSide = side
        editingIndex = index
        entryText = index >= 0 ? String(sideMinis(side)[index]) : ""
        entryFocused = true
    }

    private func commitEntry() {
        defer { editingIndex = nil; entryText = "" }
        guard let editingIndex else { return }
        guard let value = Int(entryText), value > 0 else { return }
        if editingIndex == Self.newEntryIndex {
            appendMini(side: editingSide, value)
        } else if editingIndex < sideMinis(editingSide).count {
            var minis = sideMinis(editingSide)
            minis[editingIndex] = value
            setSideMinis(editingSide, minis)
            syncClusterReps()
            onChange()
        }
    }

    private func appendMini(side: Int, _ value: Int) {
        var minis = sideMinis(side)
        minis.append(value)
        setSideMinis(side, minis)
        if !isDone {
            timer.start(seconds: microRest, label: miniRestLabel(side: side, count: minis.count + 1), micro: true, ownerID: set.id)
        }
        syncClusterReps()
        onChange()
    }

    private func miniRestLabel(side: Int, count: Int) -> String {
        isUnilateral ? "S\(side) mini-set \(count)" : "Mini-set \(count)"
    }

    /// Cluster `reps` mirrors SIDE 1's segment sum only — side 2's segments
    /// live in `side2MiniReps` and are added to volume by
    /// `recomputeDerivedMetrics`, so folding them into `reps` here would
    /// count them twice.
    private func syncClusterReps() {
        if isCluster {
            set.reps = set.miniReps.reduce(0, +)
            set.recomputeDerivedMetrics()
        }
    }

    private func adjustMini(side: Int, index: Int, by delta: Int) {
        var minis = sideMinis(side)
        minis[index] = max(1, minis[index] + delta)
        setSideMinis(side, minis)
        syncClusterReps()
        onChange()
    }

    // MARK: - Match previous (structural copy-forward)

    /// Ghost of the last session's structure — one tap fills the whole block.
    private var matchPreviousGhost: String? {
        guard !blockStarted, !isDone,
              let previous, previous.setType == set.setType,
              previous.reps != nil || !previous.miniReps.isEmpty else { return nil }
        let minis = previous.miniReps.map(String.init).joined(separator: "+")
        let activation = previous.reps.map(String.init) ?? ""
        let structure = isCluster ? minis : [activation, minis].filter { !$0.isEmpty }.joined(separator: " + ")
        let weight = previous.weight.map { " @ \(Fmt.load($0, unit: displayUnit))\(displayUnit.suffix)" } ?? ""
        return structure + weight
    }

    private func matchPreviousRow(_ ghost: String) -> some View {
        Button {
            guard let previous else { return }
            set.weight = previous.weight
            set.reps = previous.reps
            set.miniReps = previous.miniReps
            onChange()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                Text("Match previous · \(ghost)")
                    .font(.tag)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.textTertiary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Field

    /// The block's one weight entry (myo/rest-pause activation row, or the
    /// cluster strip header). Shows the raw draft while focused — the model
    /// still parses per keystroke so dependent UI stays live — and re-formats
    /// only on blur, so "62.5" survives being typed.
    private var weightField: some View {
        blockField(
            text: Binding(
                get: { weightFocused && weightDraftActive ? weightDraft : storedWeightText },
                set: { text in
                    weightDraft = text
                    weightDraftActive = true
                    set.weight = Fmt.loadKilograms(from: text, unit: displayUnit)
                    onChange()
                }
            ),
            placeholder: previous?.weight.map { Fmt.load($0, unit: displayUnit) } ?? displayUnit.suffix
        )
        .focused($weightFocused)
        .onChange(of: weightFocused) { _, focused in
            if !focused { weightDraftActive = false }
        }
        .quickIncrementable(
            options: QuickIncrementController.weightOptions(step: quickWeightStep, suffix: displayUnit.shortSuffix),
            onBegin: { weightFocused = false },
            base: {
                let kilograms = self.set.weight ?? previous?.weight
                return kilograms.map(displayUnit.displayValue(fromKilograms:)) ?? 0
            },
            apply: { newDisplay in
                weightDraftActive = false
                self.set.weight = displayUnit.kilograms(fromDisplayValue: newDisplay)
                onChange()
            }
        )
    }

    private var storedWeightText: String {
        // `self.` required: a computed-var body statement starting with `set`
        // parses as a setter declaration (the property is named `set`).
        self.set.weight.map { Fmt.load($0, unit: displayUnit) } ?? ""
    }

    /// Weight fields keep the decimal pad; rep fields must use `.numberPad` —
    /// their setters parse with `Int(...)`, so a stray "." (e.g. "12.")
    /// silently nils the reps out.
    private func blockField(text: Binding<String>, placeholder: String, keyboardType: UIKeyboardType = .decimalPad) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 15, weight: .semibold))
            .multilineTextAlignment(.center)
            .keyboardType(keyboardType)
            .foregroundStyle(theme.textPrimary)
            .frame(width: blockFieldWidth, height: blockFieldHeight)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
