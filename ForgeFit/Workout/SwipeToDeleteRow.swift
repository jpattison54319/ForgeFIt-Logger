import SwiftUI

/// Mail-style swipe-to-delete for set rows. These rows live in a plain
/// `LazyVStack`/`VStack`, not a `List`, so SwiftUI's `.swipeActions` isn't
/// available — this is the hand-rolled equivalent. Swipe left to reveal a red
/// trash tray (tap it to delete) or keep swiping past the commit threshold to
/// delete outright. Callers keep a menu "Delete Set" item as the accessible
/// path. Shared by the live logger and the routine editor so deleting a set
/// feels identical everywhere.
///
/// The drag is gated on horizontal-dominant movement with a non-trivial
/// `minimumDistance` so taps, typing, and vertical scrolling are left to the
/// row's controls and the enclosing scroll view.
struct SwipeToDeleteRow<Content: View>: View {
    @Environment(\.theme) private var theme
    let isOpen: Bool
    let onOpenChange: (Bool) -> Void
    let onDelete: () -> Void
    private let content: Content

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1

    init(
        isOpen: Bool,
        onOpenChange: @escaping (Bool) -> Void,
        onDelete: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isOpen = isOpen
        self.onOpenChange = onOpenChange
        self.onDelete = onDelete
        self.content = content()
    }

    /// Snap-open reveals ~⅓ of the row (min 88pt so the trash is a comfy tap).
    private var revealWidth: CGFloat { min(width, max(88, width / 3)) }
    /// Swiping past 60% of the row commits the delete outright.
    private var commitWidth: CGFloat { width * 0.6 }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: deleteWithAnimation) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: max(0, -offset))
                    .frame(maxHeight: .infinity)
                    .background(theme.danger)
                    .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete set")
            .allowsHitTesting(offset < -4)

            content
                .background(widthReader)
                .offset(x: offset)
                // Simultaneous, not exclusive: an exclusive DragGesture claims
                // the touch stream even for the vertical drags its onChanged
                // ignores, which starved ScrollView's pan whenever a scroll
                // began on a set row or one of its text fields. The
                // horizontal-dominant guard below still keeps casual scrolls
                // from opening the tray.
                .simultaneousGesture(swipe)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: isOpen) { _, open in
            if !open, offset != 0 {
                withAnimation(.snappy(duration: 0.22)) { offset = 0 }
            }
        }
    }

    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { width = max(geo.size.width, 1) }
                .onChange(of: geo.size.width) { _, w in width = max(w, 1) }
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Horizontal-dominant, leftward drags only — vertical stays with
                // the scroll view, taps stay with the row's controls.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = isOpen ? -revealWidth : 0
                offset = min(0, max(-width, base + value.translation.width))
            }
            .onEnded { value in
                let base: CGFloat = isOpen ? -revealWidth : 0
                let end = base + value.translation.width
                if -end > commitWidth {
                    deleteWithAnimation()
                } else if -end > revealWidth * 0.5 {
                    withAnimation(.snappy(duration: 0.22)) { offset = -revealWidth }
                    onOpenChange(true)
                } else {
                    withAnimation(.snappy(duration: 0.22)) { offset = 0 }
                    onOpenChange(false)
                }
            }
    }

    private func deleteWithAnimation() {
        withAnimation(.snappy(duration: 0.22)) {
            offset = -width
        } completion: {
            onDelete()
        }
    }
}
