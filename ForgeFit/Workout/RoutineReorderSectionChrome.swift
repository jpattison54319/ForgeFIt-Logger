import SwiftUI

/// Visual ownership for one destination in the compact reorder overlay. This
/// chrome animates around the fixed flat slots; it never becomes another drop
/// target or nested layout, so it preserves the continuous gesture's stability.
struct RoutineReorderSectionChrome: View {
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card)
            .fill(theme.surface.opacity(0.34))
    }
}
