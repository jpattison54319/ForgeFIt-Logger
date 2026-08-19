import SwiftUI

/// Packs compact Home markers into rows of up to ten, scaling each marker to
/// the available width before starting another row.
struct MicrocycleCompactDayLayout: Layout {
    static let maximumColumns = 10

    var rowHeight: CGFloat = TouchTarget.minimum

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = resolvedWidth(proposal: proposal, itemCount: subviews.count)
        let rows = Self.rowCount(itemCount: subviews.count)
        return CGSize(width: availableWidth, height: CGFloat(rows) * rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        let columns = Self.columnCount(itemCount: subviews.count)
        let itemWidth = bounds.width / CGFloat(columns)

        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            let row = index / columns
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * itemWidth,
                    y: bounds.minY + CGFloat(row) * rowHeight
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: itemWidth, height: rowHeight)
            )
        }
    }

    static func columnCount(itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return min(itemCount, maximumColumns)
    }

    static func rowCount(itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let columns = columnCount(itemCount: itemCount)
        return Int(ceil(Double(itemCount) / Double(columns)))
    }

    private func resolvedWidth(proposal: ProposedViewSize, itemCount: Int) -> CGFloat {
        proposal.width ?? CGFloat(min(itemCount, Self.maximumColumns)) * TouchTarget.minimum
    }
}
