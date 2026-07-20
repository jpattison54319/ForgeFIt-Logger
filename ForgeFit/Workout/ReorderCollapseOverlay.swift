import Observation
import SwiftUI
import UIKit

struct ExerciseReorderRow: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// Gesture-local order. Keeping this separate from SwiftData means crossing a
/// slot never relocates the source row that owns the active recognizer. The
/// parent commits `rows` once, after the touch has ended.
@Observable
final class ExerciseReorderSession {
    let heldID: UUID
    var fingerGlobalY: CGFloat
    private(set) var rows: [ExerciseReorderRow]
    private(set) var didMove = false

    init(heldID: UUID, fingerGlobalY: CGFloat, rows: [ExerciseReorderRow]) {
        self.heldID = heldID
        self.fingerGlobalY = fingerGlobalY
        self.rows = rows
    }

    @discardableResult
    func moveHeld(to index: Int) -> Bool {
        guard let current = rows.firstIndex(where: { $0.id == heldID }) else { return false }
        let target = min(max(0, index), max(0, rows.count - 1))
        guard target != current else { return false }
        rows.move(
            fromOffsets: IndexSet(integer: current),
            toOffset: target > current ? target + 1 : target
        )
        didMove = true
        return true
    }
}

/// SwiftUI's sequenced gestures do not report cancellation reliably when a
/// surrounding scroll view wins or the source view changes. UIKit's continuous
/// recognizer begins while the finger is stationary and always reports its
/// terminal state, which are both invariants of this interaction.
private struct ReorderPressGesture: UIGestureRecognizerRepresentable {
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onFinished: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.4
        recognizer.allowableMovement = 12
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        let location = context.converter.location(in: .global)
        switch recognizer.state {
        case .began:
            onBegan(location)
        case .changed:
            onChanged(location)
        case .ended, .cancelled, .failed:
            onFinished()
        case .possible:
            break
        @unknown default:
            onFinished()
        }
    }
}

/// The shared hold-to-reorder handle every exercise card/row shows: holding
/// it and moving streams the finger's global Y to the parent, which presents
/// `ReorderCollapseOverlay` with this exercise already in hand. One
/// definition so the gesture can't drift between surfaces.
struct ReorderHandle: View {
    @Environment(\.theme) private var theme
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    var onAccessibilityMoveBy: (Int) -> Void = { _ in }

    @State private var pressed = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.bodyStrong)
            .foregroundStyle(theme.textTertiary)
            .frame(width: 44, height: 44)   // HIG minimum touch target
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.88 : 1)
            .gesture(
                ReorderPressGesture(
                    onBegan: { location in
                        withAnimation(.easeOut(duration: 0.12)) { pressed = true }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.75)
                        // `.began` fires as soon as the hold recognizes, even
                        // when the finger has not moved a point.
                        onDragChanged(location.y)
                    },
                    onChanged: { onDragChanged($0.y) },
                    onFinished: {
                        withAnimation(.easeOut(duration: 0.12)) { pressed = false }
                        onDragEnded()
                    }
                )
            )
            .accessibilityLabel("Reorder exercises")
            .accessibilityHint("Drag to move this exercise in the workout order")
            .accessibilityAddTraits(.isButton)
            .accessibilityActions {
                Button("Move up") { onAccessibilityMoveBy(-1) }
                Button("Move down") { onAccessibilityMoveBy(1) }
            }
            .accessibilityIdentifier("hold-to-reorder-exercises")
    }
}

/// The hold-to-reorder surface shared by the live logger and the routine
/// editor — one continuous gesture, no separate screen or Done button:
///
/// - Holding a card's reorder handle presents this overlay: every exercise
///   collapses to a name-only row, and the whole stack is laid out **around
///   the finger** — the held exercise's row sits directly under the touch
///   (scaled, lifted), neighbours above and below in current order.
/// - The held row tracks the finger exactly. The row whose slot the finger
///   is entering dims; once the finger crosses that slot's midpoint the row
///   snaps to its new place in gesture-local state.
/// - Releasing dismisses the overlay and the normal cards animate back in,
///   after the parent commits the final order once.
///
/// The parent owns the gesture (it starts on a card handle that must stay
/// mounted) and the final model commit; this view turns a finger Y into
/// layout, hover styling, and local row moves.
struct ReorderCollapseOverlay: View {
    typealias Row = ExerciseReorderRow

    @Environment(\.theme) private var theme

    let session: ExerciseReorderSession

    /// The stack's top edge in local space, captured on the first layout so
    /// the held row starts exactly under the finger and the frame stays put
    /// while rows swap inside it.
    @State private var stackTop: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let fingerY = session.fingerGlobalY - frame.minY
            // Compress rows rather than overflow when a long workout's stack
            // is taller than the screen.
            let rowHeight = min(56, max(40, (proxy.size.height - 24) / CGFloat(max(session.rows.count, 1))))
            let stackHeight = rowHeight * CGFloat(session.rows.count)
            let heldIndex = session.rows.firstIndex { $0.id == session.heldID } ?? 0
            let top = stackTop ?? clampedTop(fingerY: fingerY, heldIndex: heldIndex, rowHeight: rowHeight, stackHeight: stackHeight, usable: proxy.size.height)
            // The slot the finger is inside — its occupant dims ("about to be
            // displaced") until the midpoint crossing snaps the order.
            let hoverIndex = slot(for: fingerY, top: top, rowHeight: rowHeight)

            ZStack(alignment: .top) {
                // Opaque canvas: the normal cards stay mounted underneath
                // (removing them would kill the in-flight touch) but stay
                // invisible until release.
                theme.background.ignoresSafeArea()

                ForEach(Array(session.rows.enumerated()), id: \.element.id) { index, row in
                    let isHeld = row.id == session.heldID
                    rowView(row, held: isHeld, dimmed: !isHeld && index == hoverIndex)
                        .frame(height: rowHeight - 8)
                        .padding(.horizontal, Space.lg)
                        .offset(y: isHeld
                            ? min(max(top, fingerY - rowHeight / 2), top + stackHeight - rowHeight)
                            : top + CGFloat(index) * rowHeight + 4)
                        // Non-held rows glide to their slots; the held row
                        // must track the finger raw, so no animation on it.
                        .animation(isHeld ? nil : .snappy(duration: 0.22), value: index)
                        .zIndex(isHeld ? 1 : 0)
                }
            }
            .onAppear {
                stackTop = top
            }
            .onChange(of: session.fingerGlobalY) { _, fingerGlobalY in
                commitIfCrossed(fingerY: fingerGlobalY - frame.minY, top: top, rowHeight: rowHeight, heldIndex: heldIndex)
            }
        }
        .sensoryFeedback(.selection, trigger: session.rows)
    }

    // MARK: - Rows

    private func rowView(_ row: Row, held: Bool, dimmed: Bool) -> some View {
        HStack {
            Text(row.name)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(held ? theme.surfaceElevated : theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            if held {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1)
            }
        }
        .scaleEffect(held ? 1.05 : 1)
        .shadow(color: .black.opacity(held ? 0.4 : 0), radius: 12, y: 5)
        .opacity(dimmed ? 0.45 : 1)
        .animation(.easeOut(duration: 0.12), value: dimmed)
    }

    // MARK: - Geometry

    /// Stack top so the held slot starts centered under the finger, clamped
    /// on-screen.
    private func clampedTop(fingerY: CGFloat, heldIndex: Int, rowHeight: CGFloat, stackHeight: CGFloat, usable: CGFloat) -> CGFloat {
        let ideal = fingerY - (CGFloat(heldIndex) + 0.5) * rowHeight
        return min(max(12, ideal), max(12, usable - stackHeight - 12))
    }

    private func slot(for fingerY: CGFloat, top: CGFloat, rowHeight: CGFloat) -> Int {
        let raw = Int(((fingerY - top) / rowHeight).rounded(.down))
        return min(max(0, raw), max(0, session.rows.count - 1))
    }

    /// Snap once the finger crosses the midpoint of a neighbouring slot.
    private func commitIfCrossed(fingerY: CGFloat, top: CGFloat, rowHeight: CGFloat, heldIndex: Int) {
        let nearest = Int(((fingerY - top - rowHeight / 2) / rowHeight).rounded())
        let target = min(max(0, nearest), max(0, session.rows.count - 1))
        if target != heldIndex {
            session.moveHeld(to: target)
        }
    }
}
