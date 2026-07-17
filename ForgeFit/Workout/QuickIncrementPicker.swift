import SwiftUI
import UIKit

/// Hold-and-drag quick increments for weight/reps fields in the live logger:
/// touch-and-hold a field and ±1/2/3-step options fan out above (+) and
/// below (−); drag to one and release to apply — one continuous touch.
/// Applying goes through the same draft/commit path as typing, so a ghost
/// suggestion the user increments materializes as an entered value.
///
/// A UIKit continuous long-press recognizer owns the interaction. Quick taps
/// still reach the TextField, movement before the hold threshold fails in
/// favor of scrolling, and every terminal state (ended or cancelled) closes
/// the fan. The fan itself renders in a root-level overlay because rows live
/// inside clipped cards.
@Observable
final class QuickIncrementController {
    struct Option: Equatable {
        /// Reps: whole reps. Weight: display-unit delta (already
        /// step-multiplied, e.g. +5 for the second band of a 2.5 lb step).
        let delta: Double
        let label: String
    }

    struct Fan {
        let fieldFrame: CGRect          // in `spaceName` coordinates
        let options: [Option]           // +max first … −max last
        let apply: (Double) -> Void
        var hoveredIndex: Int?
    }

    static let spaceName = "quick-increment-space"
    /// Forty-four points leaves an eight-point visual gap between the 36-point
    /// capsules while preserving full-width drag targets.
    static let bandHeight: CGFloat = 44
    static let bandWidth: CGFloat = 92
    static let fieldGap: CGFloat = 6

    private(set) var fan: Fan?
    /// The overlay reports its bounds (same named space) so hover mapping and
    /// drawing share one clamped layout.
    var overlayBounds: CGRect = .zero
    private(set) var hoverTick = 0
    private(set) var openTick = 0

    var isActive: Bool { fan != nil }

    func begin(fieldFrame: CGRect, options: [Option], apply: @escaping (Double) -> Void) {
        fan = Fan(fieldFrame: fieldFrame, options: options, apply: apply, hoveredIndex: nil)
        openTick += 1
    }

    func updateHover(at location: CGPoint) {
        guard fan != nil else { return }
        let currentLayout = layout()
        let hit = currentLayout?.firstIndex { slot in
            // Generous horizontal slop: vertical position picks the option,
            // the finger shouldn't have to stay inside a narrow column.
            slot.rect.insetBy(dx: -44, dy: 0).contains(location)
        }
        if hit != fan?.hoveredIndex {
            fan?.hoveredIndex = hit
            if hit != nil { hoverTick += 1 }
        }
    }

    /// Applies the hovered option (release on/near the field = cancel).
    func finish() {
        if let fan, let index = fan.hoveredIndex, fan.options.indices.contains(index) {
            fan.apply(fan.options[index].delta)
        }
        self.fan = nil
    }

    func cancel() {
        fan = nil
    }

    struct Slot: Equatable {
        let option: Option
        let rect: CGRect
        let isPositive: Bool
    }

    /// One layout for drawing and hover mapping: positive bands stack upward
    /// from the field, negative bands downward, the whole fan slides (never
    /// shrinks) to stay inside the overlay bounds.
    func layout() -> [Slot]? {
        guard let fan, overlayBounds != .zero else { return nil }
        let half = fan.options.count / 2
        let width = Self.bandWidth
        let x = min(max(fan.fieldFrame.midX, overlayBounds.minX + width / 2 + 8),
                    overlayBounds.maxX - width / 2 - 8)

        var slots: [Slot] = []
        for (index, option) in fan.options.enumerated() {
            let rect: CGRect
            if index < half {
                // Positives: index 0 is the largest (+3), sitting furthest up.
                let stepsAbove = CGFloat(half - index)
                let top = fan.fieldFrame.minY - Self.fieldGap - stepsAbove * Self.bandHeight
                rect = CGRect(x: x - width / 2, y: top, width: width, height: Self.bandHeight)
            } else {
                let stepsBelow = CGFloat(index - half)
                let top = fan.fieldFrame.maxY + Self.fieldGap + stepsBelow * Self.bandHeight
                rect = CGRect(x: x - width / 2, y: top, width: width, height: Self.bandHeight)
            }
            slots.append(Slot(option: option, rect: rect, isPositive: index < half))
        }

        // Slide the whole fan back into bounds if a screen edge cuts it off.
        let minY: CGFloat = slots.map(\.rect.minY).min() ?? 0
        let maxY: CGFloat = slots.map(\.rect.maxY).max() ?? 0
        let topLimit: CGFloat = overlayBounds.minY + 4
        let bottomLimit: CGFloat = overlayBounds.maxY - 4
        var shift: CGFloat = 0
        if minY < topLimit { shift = topLimit - minY }
        if maxY + shift > bottomLimit { shift -= (maxY + shift) - bottomLimit }
        guard shift != 0 else { return slots }
        return slots.map { Slot(option: $0.option, rect: $0.rect.offsetBy(dx: 0, dy: shift), isPositive: $0.isPositive) }
    }

    // MARK: Option builders

    static func repsOptions() -> [Option] {
        let positives = [3, 2, 1].map { (count: Int) in Option(delta: Double(count), label: "+\(count)") }
        let negatives = [1, 2, 3].map { (count: Int) in Option(delta: -Double(count), label: "−\(count)") }
        return positives + negatives
    }

    /// Weight bands are multiples of the exercise's logical jump (2.5 lb
    /// small / 5 lb barbell-class; 1.25 / 2.5 kg) in display units.
    static func weightOptions(step: Double, suffix: String) -> [Option] {
        func label(_ multiple: Int, sign: String) -> String {
            let value = step * Double(multiple)
            let text = value.formatted(.number.precision(.fractionLength(0...2)))
            return "\(sign)\(text)"
        }
        return [3, 2, 1].map { Option(delta: step * Double($0), label: label($0, sign: "+")) }
            + [1, 2, 3].map { Option(delta: -step * Double($0), label: label($0, sign: "−")) }
    }

    // MARK: Paired reveal order

    /// Options are stored top-to-bottom (`+3 … +1, −1 … −3`). Their reveal
    /// stage instead runs outward from the field, pairing equal distances:
    /// `+1/−1`, then `+2/−2`, then `+3/−3`.
    static func revealStage(for index: Int, count: Int) -> Int {
        guard count > 0, count.isMultiple(of: 2), (0..<count).contains(index) else { return 0 }
        let half = count / 2
        return index < half ? half - index - 1 : index - half
    }

    /// The neighboring option each later stage buds from. `nil` means the
    /// first pair originates in the input field itself.
    static func revealParentIndex(for index: Int, count: Int) -> Int? {
        guard revealStage(for: index, count: count) > 0 else { return nil }
        let half = count / 2
        return index < half ? index + 1 : index - 1
    }
}

// MARK: - Field modifier

/// Latest field frame in the shared coordinate space, held in a plain class
/// so per-frame geometry updates never invalidate the row.
private final class FrameBox {
    var rect: CGRect = .zero
}

/// UIKit's continuous recognizer is deliberate here. SwiftUI only calls a
/// gesture's `onEnded` when that gesture succeeds, so a sequenced long-press
/// cancelled by the surrounding ScrollView could leave the fan open forever.
/// UILongPressGestureRecognizer reports both `.ended` and `.cancelled`, and
/// its touch-cancellation behavior prevents a successful hold from also
/// focusing the TextField on release.
private struct QuickIncrementPressGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.45
        recognizer.allowableMovement = 8
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        let location = context.converter.location(in: .named(QuickIncrementController.spaceName))
        switch recognizer.state {
        case .began:
            onBegan(location)
        case .changed:
            onChanged(location)
        case .ended:
            onEnded(location)
        case .cancelled, .failed:
            onCancelled()
        case .possible:
            break
        @unknown default:
            onCancelled()
        }
    }
}

private struct QuickIncrementable: ViewModifier {
    @Environment(QuickIncrementController.self) private var controller: QuickIncrementController?
    let options: [QuickIncrementController.Option]
    let isEnabled: Bool
    /// Clears any existing TextField focus only after the hold recognizes.
    /// A quick tap or scroll never invokes this closure.
    let onBegin: () -> Void
    /// Resolved at apply time: entered value if present, else the ghost the
    /// user is looking at, else 0.
    let base: () -> Double
    /// Receives the new value (base + chosen delta, floored at 0).
    let apply: (Double) -> Void

    @State private var frameBox = FrameBox()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(QuickIncrementController.spaceName))
            } action: { frameBox.rect = $0 }
            .gesture(fanGesture)
            .accessibilityAdjustableAction { direction in
                guard let smallest = options.map(\.delta).filter({ $0 > 0 }).min() else { return }
                switch direction {
                case .increment: apply(max(0, base() + smallest))
                case .decrement: apply(max(0, base() - smallest))
                @unknown default: break
                }
            }
    }

    private var fanGesture: QuickIncrementPressGesture {
        QuickIncrementPressGesture(
            isEnabled: isEnabled && controller != nil,
            onBegan: { location in
                beginIfNeeded()
                controller?.updateHover(at: location)
            },
            onChanged: { location in
                controller?.updateHover(at: location)
            },
            onEnded: { location in
                controller?.updateHover(at: location)
                controller?.finish()
            },
            onCancelled: {
                controller?.cancel()
            }
        )
    }

    private func beginIfNeeded() {
        guard controller?.isActive != true else { return }
        onBegin()
        controller?.begin(fieldFrame: frameBox.rect, options: options) { [base, apply] delta in
            apply(max(0, base() + delta))
        }
    }
}

extension View {
    func quickIncrementable(
        options: [QuickIncrementController.Option],
        isEnabled: Bool = true,
        onBegin: @escaping () -> Void = {},
        base: @escaping () -> Double,
        apply: @escaping (Double) -> Void
    ) -> some View {
        modifier(
            QuickIncrementable(
                options: options,
                isEnabled: isEnabled,
                onBegin: onBegin,
                base: base,
                apply: apply
            )
        )
    }
}

// MARK: - Root overlay

/// Draws the active fan above everything (rows are clipped by their cards).
/// Hit-testing stays off: the field's continuous recognizer owns the touch.
struct QuickIncrementOverlay: View {
    @Environment(QuickIncrementController.self) private var controller: QuickIncrementController?

    /// Presentation is cached after touch-up just long enough for the six
    /// capsules to retract into their real neighbors. The layers themselves
    /// stay mounted before a hold begins; inserting a GlassEffectContainer
    /// during an active UIKit touch cancels the recognizer that owns the drag.
    @State private var presentedFieldFrame: CGRect = .zero
    @State private var presentedSlots: [QuickIncrementController.Slot] = []
    @State private var presentedHover: Int?
    @State private var presentationTick = 0
    @State private var fanPresented = false

    var body: some View {
        GeometryReader { proxy in
            QuickIncrementFanAppearance(
                fieldFrame: presentedFieldFrame,
                slots: presentedSlots,
                hoveredIndex: presentedHover,
                isPresented: fanPresented,
                presentationTick: presentationTick
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                updateOverlayBounds(proxy.frame(in: .named(QuickIncrementController.spaceName)))
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(QuickIncrementController.spaceName))
            } action: { updateOverlayBounds($0) }
            .onChange(of: controller?.openTick, initial: true) { _, _ in
                capturePresentation()
            }
            .onChange(of: controller?.fan?.hoveredIndex) { _, hoveredIndex in
                presentedHover = hoveredIndex
            }
            .onChange(of: controller?.isActive) { _, isActive in
                if isActive != true { fanPresented = false }
            }
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(weight: .light), trigger: controller?.openTick ?? 0)
        .sensoryFeedback(.selection, trigger: controller?.hoverTick ?? 0)
        .animation(.snappy(duration: 0.15), value: controller?.fan?.hoveredIndex)
    }

    /// Keyboard presentation can transiently report a zero-sized overlay.
    /// Keep the last real bounds so a hold immediately after keyboard dismiss
    /// still has option rectangles to hover and select.
    private func updateOverlayBounds(_ bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        controller?.overlayBounds = bounds
    }

    private func capturePresentation() {
        guard let controller, let fan = controller.fan, let slots = controller.layout() else { return }
        presentedFieldFrame = fan.fieldFrame
        presentedSlots = slots
        presentedHover = fan.hoveredIndex
        presentationTick &+= 1
        fanPresented = true
    }
}
