import SwiftUI

// MARK: - Composed glyphs

/// A question mark fused with a sleep "z" — the "is this sleep real?" mark. SF
/// Symbols has no such glyph, so it's composed: a bold questionmark with a
/// small trailing `zzz` riding its shoulder.
private struct QuestionSleepGlyph: View {
    var size: CGFloat = 20
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "questionmark")
                .font(.system(size: size, weight: .heavy))
            Image(systemName: "zzz")
                .font(.system(size: size * 0.5, weight: .black))
                .offset(x: size * 0.42, y: -size * 0.30)
        }
        // Leave room for the offset `zzz` so it isn't clipped.
        .padding(.trailing, size * 0.42)
        .padding(.top, size * 0.20)
    }
}

/// A pencil fused with a sleep "z" — "edit this night's sleep." Composed the
/// same way so it reads as a sibling of the question mark glyph.
private struct EditSleepGlyph: View {
    var size: CGFloat = 20
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "pencil")
                .font(.system(size: size, weight: .heavy))
            Image(systemName: "zzz")
                .font(.system(size: size * 0.5, weight: .black))
                .offset(x: size * 0.44, y: -size * 0.34)
        }
        .padding(.trailing, size * 0.44)
        .padding(.top, size * 0.24)
    }
}

// MARK: - Card

/// Home affordance for a night flagged as probable partial-wear capture. A sage
/// Liquid Glass trigger; tapping it splits into Confirm / Edit / Delete via
/// `GlassDivisionMenu`'s cell-division morph. Choosing one confirms it and
/// swaps that bubble to an **Undo** — the other two stay, so the user can
/// switch choices or revert freely. Every success state is persisted
/// immediately so closing the app cannot lose it; Undo clears that saved choice.
/// Readiness recomputes and the card retires when the user dismisses with a
/// choice still active. Delete is deliberately different: the fan retracts
/// immediately and waits through a short grace period before refreshing the
/// score. All corrections remain on-device
/// (`SleepOverrideStore`).
struct SleepIntegrityCard: View {
    let alert: SleepIntegrityAlert
    /// Called after a saved correction is applied so Home can re-run readiness.
    var onResolved: () -> Void = {}

    @Environment(\.theme) private var theme

    /// The action the user has currently applied. It is already durable, but
    /// not reflected in the in-memory score until dismissal/grace expiry.
    /// Nil = nothing chosen; the fan shows all three options.
    private enum Choice: Equatable { case confirm, delete, edit(minutes: Int) }
    @State private var choice: Choice?
    @State private var menuExpanded = false
    @State private var editing = false
    @State private var draftHours = ""
    @State private var feedbackTick = 0
    @State private var pendingDeleteResolution: Task<Void, Never>?

    /// Long enough to recognize feedback and reverse a destructive tap, while
    /// short enough that readiness updates without another explicit action.
    private let deleteUndoWindow: Duration = .seconds(8)

    /// Bare captured duration, e.g. "2h 4m" / "38m".
    private var durationText: String { Self.hm(alert.capturedMinutes) }
    private static func hm(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    var body: some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                headline
                Spacer(minLength: Space.sm)
                menu
            }
            .frame(minHeight: 52)
        }
        .fullScreenCover(isPresented: $editing) { editingOverlay }
        .sensoryFeedback(.impact(weight: .light), trigger: menuExpanded)
        .sensoryFeedback(.success, trigger: feedbackTick)
    }

    // MARK: Headline

    @ViewBuilder private var headline: some View {
        if let feedback = choiceFeedback {
            HStack(spacing: Space.sm) {
                Image(systemName: feedback.icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(feedback.tint)
                Text(feedback.text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
            .accessibilityIdentifier("sleep-integrity-feedback")
        } else if !menuExpanded {
            headlineCopy
                .transition(.opacity)
        }
    }

    private var headlineCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Only \(durationText) of sleep was detected")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Is this accurate?")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// The confirmation shown beside the fan once a choice is active.
    private var choiceFeedback: (icon: String, text: String, tint: Color)? {
        switch choice {
        case .confirm: ("checkmark.circle.fill", "Kept as recorded", theme.success)
        case .delete: ("trash.circle.fill", "Sleep removed", theme.danger)
        case .edit(let m): ("pencil.circle.fill", "Set to \(Self.hm(m))", theme.accent)
        case nil: nil
        }
    }

    // MARK: Menu

    private var menu: some View {
        let awaitingDeleteUndo = choice == .delete
        let collapsedAction: (() -> Void)? = awaitingDeleteUndo ? { undo() } : nil
        let accessibilityLabel = awaitingDeleteUndo ? "Undo sleep deletion" : "Review last night's sleep"
        let accessibilityHint = awaitingDeleteUndo
            ? "Restores last night's sleep and its review card."
            : "Only \(durationText) of sleep detected. Opens options to confirm, edit, or delete it."
        return GlassDivisionMenu(
            items: [slot("confirm", confirmItem), slot("edit", editItem), slot("delete", deleteItem)],
            direction: .leading,
            showsLabels: true,
            triggerTint: awaitingDeleteUndo ? theme.warmup : theme.accent,
            triggerAccessibilityLabel: accessibilityLabel,
            triggerAccessibilityHint: accessibilityHint,
            triggerAccessibilityID: awaitingDeleteUndo ? "sleep-integrity-undo" : "sleep-integrity-trigger",
            dismissAccessibilityID: "sleep-integrity-dismiss",
            collapsedAction: collapsedAction,
            onExpandedChange: { expanded in
                withAnimation(.easeInOut(duration: 0.3)) { menuExpanded = expanded }
                // Confirm/Edit update readiness when the user dismisses. Delete
                // owns a timed collapsed Undo state and resolves after it.
                if !expanded, choice != nil, choice != .delete { resolveChoice() }
            }
        ) {
            if awaitingDeleteUndo {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                QuestionSleepGlyph(size: 19).foregroundStyle(.white)
            }
        }
    }

    private var chosenID: String? {
        switch choice {
        case .confirm: "confirm"
        case .edit: "edit"
        // Delete retracts immediately, so its in-fan bubble stays Delete during
        // the exit animation. The single collapsed trigger owns the Undo state.
        case .delete: nil
        case nil: nil
        }
    }

    /// The bubble for a slot: its normal option, or — when it's the chosen one —
    /// an Undo that reverts. Keeps the same `id` across the swap so the bubble
    /// morphs in place (`contentKey` drives the icon/label crossfade).
    private func slot(_ id: String, _ normal: GlassDivisionItem) -> GlassDivisionItem {
        guard chosenID == id else { return normal }
        return GlassDivisionItem(
            id: id, systemImage: "arrow.uturn.backward", label: "Undo",
            accessibilityLabel: "Undo this choice", tint: theme.warmup,
            accessibilityID: "sleep-integrity-undo", dismissesOnTap: false,
            contentKey: "undo", action: undo)
    }

    private var confirmItem: GlassDivisionItem {
        GlassDivisionItem(
            id: "confirm", systemImage: "checkmark", label: "Confirm",
            accessibilityLabel: "Confirm sleep is accurate",
            tint: theme.success, accessibilityID: "sleep-integrity-confirm",
            dismissesOnTap: false, contentKey: "confirm", action: confirm)
    }
    private var editItem: GlassDivisionItem {
        GlassDivisionItem(
            id: "edit", label: "Edit", accessibilityLabel: "Edit sleep duration",
            tint: theme.accent, accessibilityID: "sleep-integrity-edit",
            dismissesOnTap: false, contentKey: "edit",
            icon: { EditSleepGlyph(size: 17) }, action: beginEditing)
    }
    private var deleteItem: GlassDivisionItem {
        GlassDivisionItem(
            id: "delete", systemImage: "trash.fill", label: "Delete",
            accessibilityLabel: "Delete last night's sleep",
            tint: theme.danger, role: .destructive,
            accessibilityID: "sleep-integrity-delete", dismissesOnTap: true,
            contentKey: "delete", action: deleteSleep)
    }

    // MARK: Editing panel

    private var editingOverlay: some View {
        ZStack {
            Button(action: cancelEditing) {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close sleep editor")
            .accessibilityIdentifier("sleep-integrity-editor-background")

            editingPanel
        }
        .presentationBackground(.clear)
    }

    private var editingPanel: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.sm) {
                EditSleepGlyph(size: 20).foregroundStyle(theme.accent)
                Text("Edit last night's sleep")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
            }
            Text("How long did you actually sleep? We'll use this instead of the tracked fragment.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.sm) {
                TextField("7.5", text: $draftHours)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(width: 120, height: 64)
                    .background(theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityIdentifier("sleep-integrity-hours-field")
                    .accessibilityLabel("Hours slept")
                Text("hours")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }

            HStack(spacing: Space.sm) {
                Button("Cancel") { cancelEditing() }
                    .font(.bodyStrong)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                Spacer()
                Button {
                    saveManual()
                } label: {
                    Text("Save")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                .buttonBorderShape(.capsule)
                .disabled(parsedDraftMinutes == nil)
                .accessibilityIdentifier("sleep-integrity-save")
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: 340)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .padding(.horizontal, Space.lg)
        .transition(.scale(scale: 0.3, anchor: .center).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sleep-integrity-editor")
    }

    private var parsedDraftMinutes: Int? {
        let normalized = draftHours.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let hours = Double(normalized), hours > 0, hours <= 24 else { return nil }
        return Int((hours * 60).rounded())
    }

    // MARK: Actions

    private func beginEditing() {
        draftHours = ""
        editing = true
    }

    private func cancelEditing() { editing = false }

    private func confirm() {
        choose(.confirm)
        persist(.confirmed)
    }

    private func deleteSleep() {
        choose(.delete)
        persist(.untracked)
        scheduleDeleteResolution()
    }

    private func saveManual() {
        guard let minutes = parsedDraftMinutes else { return }
        editing = false
        choose(.edit(minutes: minutes))
        persist(.manual(minutes: minutes))
    }

    /// Shows success feedback and swaps the chosen bubble to Undo. The action
    /// method immediately following this call makes the choice durable.
    private func choose(_ new: Choice) {
        pendingDeleteResolution?.cancel()
        pendingDeleteResolution = nil
        feedbackTick += 1
        withAnimation(.easeInOut(duration: 0.28)) { choice = new }
    }

    private func persist(_ override: SleepNightOverride) {
        SleepOverrideStore.shared.set(override, for: alert.day)
    }

    /// Reverts to no choice — clears the stored override and shows all three
    /// options again.
    private func undo() {
        pendingDeleteResolution?.cancel()
        pendingDeleteResolution = nil
        SleepOverrideStore.shared.clear(for: alert.day)
        HealthMetricsStore.shared.reprocessSleep()
        feedbackTick += 1
        withAnimation(.easeInOut(duration: 0.28)) { choice = nil }
    }

    private func scheduleDeleteResolution() {
        pendingDeleteResolution?.cancel()
        pendingDeleteResolution = Task { @MainActor in
            try? await Task.sleep(for: deleteUndoWindow)
            guard !Task.isCancelled, choice == .delete else { return }
            resolveChoice()
        }
    }

    /// Applies the already-persisted choice to the in-memory recovery series
    /// and retires the review card.
    private func resolveChoice() {
        guard choice != nil else { return }
        pendingDeleteResolution?.cancel()
        pendingDeleteResolution = nil
        HealthMetricsStore.shared.reprocessSleep()
        onResolved()
    }
}
