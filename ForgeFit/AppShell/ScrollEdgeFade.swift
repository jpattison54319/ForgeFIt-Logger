import SwiftUI

/// Marks a horizontal row as continuing past the edge it is cut at.
///
/// The rows this is used on are bled out to the display edge so the next item
/// is sliced mid-shape — an item that stops short of the edge inside the
/// content gutter reads as a clipping bug rather than a row you can push. This
/// supplies the other half of that signal: a soft fade under the cut edge,
/// drawn only while content really does continue that way, so a row whose
/// items all fit looks untouched and a row scrolled to its end stops
/// advertising a direction that has nothing left in it.
private struct ScrollEdgeFade: ViewModifier {
    struct Overflow: Equatable {
        var leading = false
        var trailing = false
    }

    /// Width of the fade ramp. Wide enough to read as depth, narrow enough
    /// that the sliced item stays identifiable.
    let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var overflow = Overflow()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Overflow.self) { geometry in
                let offset = geometry.contentOffset.x + geometry.contentInsets.leading
                let scrollable = geometry.contentSize.width
                    + geometry.contentInsets.leading
                    + geometry.contentInsets.trailing
                    - geometry.containerSize.width
                // A point of slack absorbs the fractional offsets that bounce
                // and rubber-banding leave behind, so the fades don't flicker
                // at either end of the travel.
                return Overflow(leading: offset > 1, trailing: offset < scrollable - 1)
            } action: { _, updated in
                overflow = updated
            }
            .mask(alignment: .leading) {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflow.leading ? width : 0)
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflow.trailing ? width : 0)
                }
            }
            .animation(reduceMotion ? Motion.reduced : Motion.stateChange, value: overflow)
    }
}

extension View {
    /// See `ScrollEdgeFade`. Apply to a horizontal `ScrollView` that is
    /// intentionally scrollable — never to one that merely might overflow at
    /// large text sizes, where the fade would read as damage.
    func scrollEdgeFade(width: CGFloat = 28) -> some View {
        modifier(ScrollEdgeFade(width: width))
    }
}
