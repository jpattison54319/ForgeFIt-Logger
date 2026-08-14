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
    struct Metrics: Equatable {
        let bandHeight: CGFloat
        let bandWidth: CGFloat
        let fieldGap: CGFloat
        /// The capsule is this much shorter than its band. Because adjacent
        /// bands touch, this is also the visible gap between fan options.
        let visualHeightInset: CGFloat
        let labelFontSize: CGFloat
        let usesGlobalCoordinateSpace: Bool

        static let compact = Metrics(
            bandHeight: 44,
            bandWidth: 92,
            fieldGap: 6,
            visualHeightInset: 8,
            labelFontSize: 16,
            usesGlobalCoordinateSpace: false
        )

        static let guidedMyoRep = Metrics(
            bandHeight: 56,
            bandWidth: 120,
            fieldGap: 8,
            visualHeightInset: 8,
            labelFontSize: 20,
            usesGlobalCoordinateSpace: true
        )
    }

    struct Option: Equatable {
        /// Reps: whole reps. Weight: display-unit delta (already
        /// step-multiplied, e.g. +5 for the second band of a 2.5 lb step).
        let delta: Double
        let label: String
    }

    struct Fan {
        let transactionID: UUID
        /// In the controller's selected coordinate space: the named logger
        /// space for compact fields, or global space for guided Myo-Reps.
        let fieldFrame: CGRect
        let options: [Option]           // +max first … −max last
        /// Frozen when the hold recognizes. Keyboard dismissal, row updates,
        /// and unit changes must not move the hit map under an active finger.
        let slots: [Slot]
        /// Captured when the hold recognizes, before focus dismissal can
        /// commit/reformat the field or expose a different ghost value.
        let baseValue: Double
        let applyValue: (Double) -> Void
        var hoveredIndex: Int?
    }

    static let spaceName = "quick-increment-space"

    let metrics: Metrics

    private(set) var fan: Fan?
    /// The overlay reports its bounds in the controller's selected coordinate
    /// space so hover mapping and drawing share one clamped layout.
    var overlayBounds: CGRect = .zero
    private(set) var hoverTick = 0
    private(set) var openTick = 0

    var isActive: Bool { fan != nil }

    init(metrics: Metrics = .compact) {
        self.metrics = metrics
    }

    @discardableResult
    func begin(
        fieldFrame: CGRect,
        options: [Option],
        baseValue: Double,
        applyValue: @escaping (Double) -> Void
    ) -> UUID? {
        guard fan == nil,
              !fieldFrame.isEmpty,
              !fieldFrame.isNull,
              !fieldFrame.isInfinite,
              overlayBounds.width > 0,
              overlayBounds.height > 0,
              baseValue.isFinite,
              !options.isEmpty,
              options.count.isMultiple(of: 2),
              options.allSatisfy({ $0.delta.isFinite && $0.delta != 0 }),
              let slots = Self.makeLayout(
                fieldFrame: fieldFrame,
                options: options,
                overlayBounds: overlayBounds,
                metrics: metrics
              ) else { return nil }

        let transactionID = UUID()
        fan = Fan(
            transactionID: transactionID,
            fieldFrame: fieldFrame,
            options: options,
            slots: slots,
            baseValue: max(0, baseValue),
            applyValue: applyValue,
            hoveredIndex: nil
        )
        openTick += 1
        return transactionID
    }

    func updateHover(at location: CGPoint, transactionID: UUID) {
        guard fan?.transactionID == transactionID,
              location.x.isFinite,
              location.y.isFinite else { return }
        let hit = fan?.slots.firstIndex { slot in
            // Generous horizontal slop: vertical position picks the option,
            // the finger shouldn't have to stay inside a narrow column.
            slot.rect.insetBy(dx: -44, dy: 0).contains(location)
        }
        if hit != fan?.hoveredIndex {
            fan?.hoveredIndex = hit
            if hit != nil { hoverTick += 1 }
        }
    }

    /// Applies the last visibly-hovered option. A very fast drag can skip a
    /// `.changed` callback, so the terminal point is used only when no option
    /// was highlighted. It never replaces an option the user already saw.
    func finish(at location: CGPoint, transactionID: UUID) {
        guard fan?.transactionID == transactionID else { return }
        if fan?.hoveredIndex == nil {
            updateHover(at: location, transactionID: transactionID)
        }
        guard let completedFan = fan,
              completedFan.transactionID == transactionID else { return }
        // End the gesture transaction before its callback mutates SwiftData
        // and re-renders the row. A duplicate terminal callback can therefore
        // never apply the option twice.
        self.fan = nil
        guard let index = completedFan.hoveredIndex,
              completedFan.options.indices.contains(index) else { return }
        let delta = completedFan.options[index].delta
        let result = max(0, completedFan.baseValue + delta)
        guard result.isFinite else { return }
        completedFan.applyValue(result)
    }

    func cancel(transactionID: UUID) {
        guard fan?.transactionID == transactionID else { return }
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
        fan?.slots
    }

    /// Global rectangles need to be translated into the overlay's local space
    /// before SwiftUI can position them. The compact logger retains its named-
    /// space behavior unchanged.
    func overlayLocalRect(for rect: CGRect) -> CGRect {
        guard metrics.usesGlobalCoordinateSpace else { return rect }
        return rect.offsetBy(dx: -overlayBounds.minX, dy: -overlayBounds.minY)
    }

    private static func makeLayout(
        fieldFrame: CGRect,
        options: [Option],
        overlayBounds: CGRect,
        metrics: Metrics
    ) -> [Slot]? {
        guard overlayBounds.width > 0, overlayBounds.height > 0 else { return nil }
        let half = options.count / 2
        let width = metrics.bandWidth
        let x = min(max(fieldFrame.midX, overlayBounds.minX + width / 2 + 8),
                    overlayBounds.maxX - width / 2 - 8)

        var slots: [Slot] = []
        for (index, option) in options.enumerated() {
            let rect: CGRect
            if index < half {
                // Positives: index 0 is the largest (+3), sitting furthest up.
                let stepsAbove = CGFloat(half - index)
                let top = fieldFrame.minY - metrics.fieldGap - stepsAbove * metrics.bandHeight
                rect = CGRect(x: x - width / 2, y: top, width: width, height: metrics.bandHeight)
            } else {
                let stepsBelow = CGFloat(index - half)
                let top = fieldFrame.maxY + metrics.fieldGap + stepsBelow * metrics.bandHeight
                rect = CGRect(x: x - width / 2, y: top, width: width, height: metrics.bandHeight)
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

    /// Manual load nudges are native to the unit currently shown: quarter-
    /// plate jumps in kilograms and 2.5-pound jumps in pounds.
    static func weightOptions(unit: WeightUnit) -> [Option] {
        let step = unit == .kg ? 1.25 : 2.5
        func label(_ multiple: Int, sign: String) -> String {
            let value = step * Double(multiple)
            let text = value.formatted(.number.precision(.fractionLength(0...2)))
            return "\(sign)\(text)"
        }
        return [3, 2, 1].map { Option(delta: step * Double($0), label: label($0, sign: "+")) }
            + [1, 2, 3].map { Option(delta: -step * Double($0), label: label($0, sign: "−")) }
    }

    /// Resolves the number actually visible in a field. Suggestion-backed
    /// rows deliberately hide their routine value behind a previous-session
    /// ghost, so that hidden value must never become the quick-picker base.
    static func displayedBase(
        draftValue: Double?,
        isDraftEdited: Bool,
        enteredValue: Double?,
        suggestedValue: Double?,
        isShowingSuggestion: Bool
    ) -> Double? {
        if isDraftEdited { return draftValue }
        if isShowingSuggestion { return suggestedValue }
        return enteredValue ?? suggestedValue
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
    var transactionID: UUID?
}

/// UIKit's continuous recognizer is deliberate here. SwiftUI only calls a
/// gesture's `onEnded` when that gesture succeeds, so a sequenced long-press
/// cancelled by the surrounding ScrollView could leave the fan open forever.
/// UILongPressGestureRecognizer reports both `.ended` and `.cancelled`, and
/// its touch-cancellation behavior prevents a successful hold from also
/// focusing the TextField on release.
private struct QuickIncrementPressGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let usesGlobalCoordinateSpace: Bool
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    /// SwiftUI may reuse the underlying UIKit recognizer while replacing the
    /// row, value, or unit closures around it. Keeping the latest callbacks in
    /// the coordinator prevents a recycled recognizer from adjusting a field
    /// that is no longer on screen.
    final class Coordinator {
        var onBegan: (CGPoint) -> Void
        var onChanged: (CGPoint) -> Void
        var onEnded: (CGPoint) -> Void
        var onCancelled: () -> Void

        init(gesture: QuickIncrementPressGesture) {
            onBegan = gesture.onBegan
            onChanged = gesture.onChanged
            onEnded = gesture.onEnded
            onCancelled = gesture.onCancelled
        }

        func update(from gesture: QuickIncrementPressGesture) {
            onBegan = gesture.onBegan
            onChanged = gesture.onChanged
            onEnded = gesture.onEnded
            onCancelled = gesture.onCancelled
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(gesture: self)
    }

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
        context.coordinator.update(from: self)
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        let location = usesGlobalCoordinateSpace
            ? context.converter.location(in: .global)
            : context.converter.location(in: .named(QuickIncrementController.spaceName))
        switch recognizer.state {
        case .began:
            context.coordinator.onBegan(location)
        case .changed:
            context.coordinator.onChanged(location)
        case .ended:
            context.coordinator.onEnded(location)
        case .cancelled, .failed:
            context.coordinator.onCancelled()
        case .possible:
            break
        @unknown default:
            context.coordinator.onCancelled()
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
    /// Resolved once when the hold recognizes: entered value if present, else
    /// the ghost the user is looking at, else 0.
    let base: () -> Double?
    /// Receives the new value (base + chosen delta, floored at 0).
    let apply: (Double) -> Void

    @State private var frameBox = FrameBox()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                controller?.metrics.usesGlobalCoordinateSpace == true
                    ? proxy.frame(in: .global)
                    : proxy.frame(in: .named(QuickIncrementController.spaceName))
            } action: { frameBox.rect = $0 }
            .gesture(fanGesture)
            .accessibilityAdjustableAction { direction in
                guard let smallest = options.map(\.delta).filter({ $0 > 0 }).min(),
                      let baseValue = base(),
                      baseValue.isFinite else { return }
                switch direction {
                case .increment: apply(max(0, baseValue + smallest))
                case .decrement: apply(max(0, baseValue - smallest))
                @unknown default: break
                }
            }
    }

    private var fanGesture: QuickIncrementPressGesture {
        QuickIncrementPressGesture(
            isEnabled: isEnabled && controller != nil,
            usesGlobalCoordinateSpace: controller?.metrics.usesGlobalCoordinateSpace == true,
            onBegan: { location in
                beginIfNeeded(at: location)
            },
            onChanged: { location in
                guard let transactionID = frameBox.transactionID else { return }
                controller?.updateHover(at: location, transactionID: transactionID)
            },
            onEnded: { location in
                guard let transactionID = frameBox.transactionID else { return }
                frameBox.transactionID = nil
                controller?.finish(at: location, transactionID: transactionID)
            },
            onCancelled: {
                guard let transactionID = frameBox.transactionID else { return }
                frameBox.transactionID = nil
                controller?.cancel(transactionID: transactionID)
            }
        )
    }

    private func beginIfNeeded(at location: CGPoint) {
        guard let controller, !controller.isActive else { return }
        // Snapshot what the user sees before clearing focus. Clearing focus
        // commits drafts and can synchronously change which fallback value a
        // field exposes; resolving `base()` on release made adjustments use
        // stale/ghost values instead of the held value.
        guard let baseValue = base(), baseValue.isFinite,
              let transactionID = controller.begin(
            fieldFrame: frameBox.rect,
            options: options,
            baseValue: baseValue,
            applyValue: apply
        ) else { return }
        frameBox.transactionID = transactionID
        onBegin()
        controller.updateHover(at: location, transactionID: transactionID)
    }
}

extension View {
    func quickIncrementable(
        options: [QuickIncrementController.Option],
        isEnabled: Bool = true,
        onBegin: @escaping () -> Void = {},
        base: @escaping () -> Double?,
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
                presentationTick: presentationTick,
                metrics: controller?.metrics ?? .compact
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                updateOverlayBounds(frame(for: proxy))
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                frame(for: proxy)
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

    private func frame(for proxy: GeometryProxy) -> CGRect {
        controller?.metrics.usesGlobalCoordinateSpace == true
            ? proxy.frame(in: .global)
            : proxy.frame(in: .named(QuickIncrementController.spaceName))
    }

    private func capturePresentation() {
        guard let controller, let fan = controller.fan, let slots = controller.layout() else { return }
        presentedFieldFrame = controller.overlayLocalRect(for: fan.fieldFrame)
        presentedSlots = slots.map {
            QuickIncrementController.Slot(
                option: $0.option,
                rect: controller.overlayLocalRect(for: $0.rect),
                isPositive: $0.isPositive
            )
        }
        presentedHover = fan.hoveredIndex
        presentationTick &+= 1
        fanPresented = true
    }
}
