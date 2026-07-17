import SwiftUI

/// The visual half of the hold-and-drag increment picker. Interaction remains
/// in `QuickIncrementController`; these six layers stay mounted so presenting
/// them cannot interrupt the field's continuous UIKit gesture.
struct QuickIncrementFanAppearance: View {
    let fieldFrame: CGRect
    let slots: [QuickIncrementController.Slot]
    let hoveredIndex: Int?
    let isPresented: Bool
    let presentationTick: Int

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// -1 is closed. Stages 0...2 reveal the nearest, middle, then outer pair.
    @State private var revealedStage = -1
    @State private var transitionGeneration = 0

    private let optionCount = 6
    private let relayBeat: Duration = .milliseconds(80)
    private let retractionBeat: Duration = .milliseconds(35)
    private var relaySpring: Animation { .spring(response: 0.18, dampingFraction: 0.84) }
    private var retractionSpring: Animation { .spring(response: 0.13, dampingFraction: 0.92) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<optionCount, id: \.self) { index in
                option(at: index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: presentationTick) { _, _ in
            revealOptions()
        }
        .onChange(of: isPresented) { _, presented in
            if !presented { retractOptions() }
        }
    }

    private func option(at index: Int) -> some View {
        let slot = slots.indices.contains(index) ? slots[index] : placeholderSlot
        let stage = QuickIncrementController.revealStage(for: index, count: slots.count)
        let source = birthSource(for: index)
        let isRevealed = reduceMotion ? isPresented : revealedStage >= stage
        let highlighted = hoveredIndex == index && isPresented

        return Text(slot.option.label)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(
                highlighted
                    ? Color.white
                    : (slot.isPositive ? theme.textPrimary : theme.textSecondary)
            )
            .frame(width: slot.rect.width, height: slot.rect.height - 8)
            .contentShape(Capsule())
            .background {
                Capsule()
                    .fill(.thinMaterial)
                    .overlay {
                        Capsule().fill(optionTint(for: slot, highlighted: highlighted))
                    }
                    .overlay {
                        Capsule().strokeBorder(
                            Color.white.opacity(highlighted ? 0.28 : 0.12),
                            lineWidth: 0.75
                        )
                    }
                    .shadow(color: Color.black.opacity(0.16), radius: 8, y: 3)
            }
            .compositingGroup()
            // At birth the capsule is a flat squeeze inside its real parent.
            // It never lives at an off-screen seed position.
            .scaleEffect(x: isRevealed ? 1 : 0.68, y: isRevealed ? 1 : 0.12)
            .position(
                x: isRevealed ? slot.rect.midX : source.midX,
                y: isRevealed ? slot.rect.midY : source.midY
            )
            .opacity(isRevealed ? 1 : 0)
            .scaleEffect(highlighted ? 1.06 : 1)
            .animation(.snappy(duration: 0.13), value: hoveredIndex)
            .accessibilityHidden(!isPresented)
            .accessibilityIdentifier(isPresented ? "quick-increment-option-\(index)" : "")
    }

    /// The first pair begins in the held field. Each subsequent pair begins
    /// in the already-revealed neighbor on its own side of the fan.
    private func birthSource(for index: Int) -> CGRect {
        guard let parent = QuickIncrementController.revealParentIndex(for: index, count: slots.count),
              slots.indices.contains(parent) else {
            return fieldFrame.isEmpty ? placeholderSlot.rect : fieldFrame
        }
        return slots[parent].rect
    }

    private var maximumStage: Int {
        max(0, slots.count / 2 - 1)
    }

    /// The closed layers are transparent and concentric with the source, not
    /// parked beyond an edge of the screen. They remain mounted only to keep
    /// the long-press recognizer stable.
    private var placeholderSlot: QuickIncrementController.Slot {
        let width = QuickIncrementController.bandWidth
        let height = QuickIncrementController.bandHeight
        let center = fieldFrame.isEmpty
            ? CGPoint(x: width / 2, y: height / 2)
            : CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        return QuickIncrementController.Slot(
            option: .init(delta: 0, label: ""),
            rect: CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            ),
            isPositive: true
        )
    }

    private func optionTint(
        for slot: QuickIncrementController.Slot,
        highlighted: Bool
    ) -> Color {
        if highlighted {
            return theme.accent.opacity(0.52)
        }
        if slot.isPositive {
            return theme.accent.opacity(0.18)
        }
        return theme.textSecondary.opacity(0.10)
    }

    private func revealOptions() {
        transitionGeneration &+= 1
        let generation = transitionGeneration

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            revealedStage = reduceMotion ? maximumStage : -1
        }
        guard !reduceMotion else { return }

        Task { @MainActor in
            // Give the hidden layers one frame at their real parent positions.
            await Task.yield()
            for stage in 0...maximumStage {
                guard transitionGeneration == generation else { return }
                withAnimation(relaySpring) {
                    revealedStage = stage
                }
                if stage < maximumStage {
                    try? await Task.sleep(for: relayBeat)
                }
            }
        }
    }

    private func retractOptions() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        guard !reduceMotion else {
            revealedStage = -1
            return
        }

        Task { @MainActor in
            for stage in stride(from: maximumStage, through: 0, by: -1) {
                guard transitionGeneration == generation else { return }
                withAnimation(retractionSpring) {
                    revealedStage = stage - 1
                }
                if stage > 0 {
                    try? await Task.sleep(for: retractionBeat)
                }
            }
        }
    }
}
