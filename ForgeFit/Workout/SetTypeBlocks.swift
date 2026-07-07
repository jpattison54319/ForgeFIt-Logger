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
/// of tap-to-confirm mini-set pills, and an inline micro-rest countdown that
/// never takes the lifter off the screen.
struct SetBlockView: View {
    @Bindable var set: SetModel
    @Bindable var workoutExercise: WorkoutExerciseModel
    let blockNumber: Int
    let previous: SetModel?
    let showWeight: Bool
    let displayUnit: WeightUnit
    /// Unilateral exercises run the whole block once per limb: the flow
    /// renders twice ("Side 1" → "Side 2"), same weight and micro-rests,
    /// and only the single complete checkbox finishes the set.
    var isUnilateral: Bool = false
    let onChange: () -> Void
    let onSetType: (SetType) -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @Environment(SetInputRouter.self) private var inputRouter: SetInputRouter?

    /// Inline pill entry: `newEntryIndex` = typing a new mini-set, >= 0 =
    /// retyping an existing one. `editingSide` scopes it for per-side flows.
    @State private var editingIndex: Int?
    @State private var editingSide = 1
    @State private var entryText = ""
    @FocusState private var entryFocused: Bool

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
            MicroRestBar(tint: style.color, ownerID: set.id)
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
            Menu {
                ForEach(SetType.allCases, id: \.self) { type in
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

            completeButton
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

    /// Checks off the WHOLE block (all segments done) and starts the full rest.
    private var completeButton: some View {
        Button {
            if isDone {
                set.completedAt = nil
            } else {
                // Side 1's segment sum only — side 2 is added to volume by
                // recomputeDerivedMetrics from its own fields.
                if isCluster { set.reps = set.miniReps.reduce(0, +) }
                set.completedAt = Date()
                HealthMetricsStore.shared.fillBodyweight(set)
                timer.skip()
                if let rest = workoutExercise.restSeconds ?? set.setType.defaultRestSeconds {
                    timer.start(seconds: rest, label: style.label)
                }
            }
            set.recomputeDerivedMetrics()
            onChange()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isDone ? .white : theme.textTertiary)
                .frame(width: 34, height: 30)
                .background(isDone ? theme.success : theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
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
                blockField(
                    text: Binding(
                        get: { set.weight.map { Fmt.load($0, unit: displayUnit) } ?? "" },
                        set: { set.weight = Fmt.loadKilograms(from: $0, unit: displayUnit); onChange() }
                    ),
                    placeholder: previous?.weight.map { Fmt.load($0, unit: displayUnit) } ?? displayUnit.suffix
                )
            }
            blockField(
                text: Binding(
                    get: { sideReps(side).map(String.init) ?? "" },
                    set: { setSideReps(side, Int($0)); onChange() }
                ),
                placeholder: activationPlaceholder(side: side)
            )
            // Log the activation → the first micro-rest starts immediately.
            Button {
                guard sideReps(side) != nil else { return }
                timer.start(seconds: microRest, label: miniRestLabel(side: side, count: 1), micro: true, ownerID: set.id)
                onChange()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(sideReps(side) == nil ? theme.textTertiary : style.color)
                    .frame(width: 34, height: 30)
                    .background(style.color.opacity(sideReps(side) == nil ? 0.08 : 0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(sideReps(side) == nil)
        }
    }

    /// Side 2 suggests matching side 1's activation; side 1 suggests history.
    private func activationPlaceholder(side: Int) -> String {
        if side == 2 {
            return set.reps.map(String.init) ?? "reps"
        }
        return previous?.reps.map(String.init) ?? "reps"
    }

    // MARK: - Mini-set pill strip

    private func miniSetStrip(side: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCluster && showWeight && side == 1 {
                HStack(spacing: Space.sm) {
                    Text("Weight")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    blockField(
                        text: Binding(
                            get: { set.weight.map { Fmt.load($0, unit: displayUnit) } ?? "" },
                            set: { set.weight = Fmt.loadKilograms(from: $0, unit: displayUnit); onChange() }
                        ),
                        placeholder: previous?.weight.map { Fmt.load($0, unit: displayUnit) } ?? displayUnit.suffix
                    )
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
                if editingIndex == Self.newEntryIndex && editingSide == side {
                    entryPill(side: side)
                } else {
                    addMiniPill(side: side)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// A confirmed mini-set. Tap-and-hold to adjust when you fell short or
    /// pushed past the target — or retype it entirely.
    private func miniPill(side: Int, index: Int, reps: Int) -> some View {
        Menu {
            Button("+1 rep", systemImage: "plus") { adjustMini(side: side, index: index, by: 1) }
            Button("−1 rep", systemImage: "minus") { adjustMini(side: side, index: index, by: -1) }
            Button("Enter manually", systemImage: "keyboard") { beginEntry(side: side, editing: index) }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) {
                var minis = sideMinis(side)
                minis.remove(at: index)
                setSideMinis(side, minis)
                syncClusterReps()
                onChange()
            }
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
    }

    /// The "next mini-set" pill. First mini-set: opens keyboard entry so the
    /// user logs what they actually got (no forced target). After that, one
    /// tap repeats the last mini — long-press to type a different number.
    private func addMiniPill(side: Int) -> some View {
        Menu {
            Button("Enter manually", systemImage: "keyboard") { beginEntry(side: side, editing: Self.newEntryIndex) }
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
        } primaryAction: {
            if let target = nextMiniTarget(side: side) {
                appendMini(side: side, target)
            } else {
                beginEntry(side: side, editing: Self.newEntryIndex)
            }
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

    /// nil = no target to repeat yet — the first mini must be typed. Side 2
    /// falls back to side 1's pattern before history: same limb pair, same
    /// plan.
    private func nextMiniTarget(side: Int) -> Int? {
        if let last = sideMinis(side).last { return last }
        if side == 2, let mirror = set.miniReps.first { return mirror }
        return previous?.miniReps.first
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

    private func blockField(text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 15, weight: .semibold))
            .multilineTextAlignment(.center)
            .keyboardType(.decimalPad)
            .foregroundStyle(theme.textPrimary)
            .frame(width: 58, height: 30)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
