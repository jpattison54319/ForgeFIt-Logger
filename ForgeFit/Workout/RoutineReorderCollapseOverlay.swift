import SwiftUI

/// A compact, stable routine-library reorder surface. The full Workout screen
/// remains mounted underneath so the handle's continuous gesture is never
/// cancelled by the source card disappearing. Only this gesture-local stack
/// changes while the finger moves; SwiftData is committed once on release.
struct RoutineReorderCollapseOverlay: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: RoutineReorderSession

    /// Captured once so crossing a folder boundary shifts rows within a stable
    /// frame instead of moving the entire stack under the finger.
    @State private var stackTop: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let entries = session.entries
            let frame = proxy.frame(in: .global)
            let fingerY = session.fingerGlobalY - frame.minY
            let usableHeight = max(0, proxy.size.height - Space.tabBarClearance)
            let rowHeight = min(
                54,
                max(32, (usableHeight - 24) / CGFloat(max(entries.count, 1)))
            )
            let stackHeight = rowHeight * CGFloat(entries.count)
            let heldIndex = entries.firstIndex { $0.id == .item(session.draggedItemID) } ?? 1
            let top = stackTop ?? clampedTop(
                fingerY: fingerY,
                heldIndex: heldIndex,
                rowHeight: rowHeight,
                stackHeight: stackHeight,
                usable: usableHeight
            )
            let hoverIndex = slot(
                for: fingerY,
                top: top,
                rowHeight: rowHeight,
                entryCount: entries.count
            )
            let destinations = entries.compactMap { entry -> RoutineReorderSession.Destination? in
                guard case .section(let destination, _) = entry else { return nil }
                return destination
            }

            ZStack(alignment: .top) {
                theme.background.ignoresSafeArea()

                // One container wraps each header and its routine slots. The
                // entries remain a single fixed stream for smooth snapping;
                // only this chrome communicates the nested folder structure.
                ForEach(destinations, id: \.self) { destination in
                    if destination != .ungrouped,
                       let headerIndex = entries.firstIndex(where: {
                        $0.id == .section(destination)
                    }) {
                        let endIndex = nextHeaderIndex(
                            after: headerIndex,
                            in: entries
                        )
                        let routineCount = endIndex - headerIndex - 1
                        RoutineReorderSectionChrome()
                        .frame(height: rowHeight * CGFloat(routineCount + 1) - 4)
                        .padding(.horizontal, Space.sm)
                        .offset(y: top + CGFloat(headerIndex) * rowHeight + 2)
                        .animation(
                            reduceMotion ? nil : .snappy(duration: 0.22),
                            value: headerIndex
                        )
                        .animation(
                            reduceMotion ? nil : .snappy(duration: 0.22),
                            value: routineCount
                        )
                    }
                }

                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let isHeld = entry.id == .item(session.draggedItemID)
                    let isSection = isSection(entry)
                    entryView(
                        entry,
                        held: isHeld,
                        highlighted: !isHeld && index == hoverIndex
                    )
                    .frame(height: rowHeight - 7)
                    .padding(.leading, isSection ? Space.lg : Space.xl + Space.xs)
                    .padding(.trailing, Space.lg)
                    .offset(y: isHeld
                        ? min(
                            max(top, fingerY - rowHeight / 2),
                            top + stackHeight - rowHeight
                        )
                        : top + CGFloat(index) * rowHeight + 3.5
                    )
                    .animation(
                        isHeld || reduceMotion ? nil : .snappy(duration: 0.22),
                        value: index
                    )
                    .zIndex(isHeld ? 1 : 0)
                }
            }
            .onAppear { stackTop = top }
            .onChange(of: session.fingerGlobalY) { _, fingerGlobalY in
                commitIfCrossed(
                    fingerY: fingerGlobalY - frame.minY,
                    top: top,
                    rowHeight: rowHeight,
                    heldIndex: heldIndex,
                    entries: entries
                )
            }
        }
        .sensoryFeedback(.selection, trigger: session.entries)
    }

    @ViewBuilder
    private func entryView(
        _ entry: RoutineReorderSession.Entry,
        held: Bool,
        highlighted: Bool
    ) -> some View {
        switch entry {
        case .section(let destination, let title):
            HStack(spacing: Space.sm) {
                Image(systemName: destination == .ungrouped ? "tray.fill" : "folder.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(highlighted ? theme.textPrimary : theme.textSecondary)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(highlighted ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if highlighted {
                    Text("FIRST")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(highlighted ? theme.surfaceElevated : theme.surface.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

        case .item(let item):
            HStack(spacing: Space.md) {
                Text(item.name)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
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
                        .strokeBorder(theme.separator, lineWidth: 1)
                }
            }
            .scaleEffect(held ? 1.05 : 1)
            .shadow(color: .black.opacity(held ? 0.4 : 0), radius: 12, y: 5)
            .opacity(highlighted ? 0.45 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
        }
    }

    private func isSection(_ entry: RoutineReorderSession.Entry) -> Bool {
        if case .section = entry { true } else { false }
    }

    private func nextHeaderIndex(
        after headerIndex: Int,
        in entries: [RoutineReorderSession.Entry]
    ) -> Int {
        entries.indices.dropFirst(headerIndex + 1).first(where: { index in
            if case .section = entries[index] { true } else { false }
        }) ?? entries.endIndex
    }

    private func clampedTop(
        fingerY: CGFloat,
        heldIndex: Int,
        rowHeight: CGFloat,
        stackHeight: CGFloat,
        usable: CGFloat
    ) -> CGFloat {
        let ideal = fingerY - (CGFloat(heldIndex) + 0.5) * rowHeight
        return min(max(12, ideal), max(12, usable - stackHeight - 12))
    }

    private func slot(
        for fingerY: CGFloat,
        top: CGFloat,
        rowHeight: CGFloat,
        entryCount: Int
    ) -> Int {
        let raw = Int(((fingerY - top) / rowHeight).rounded(.down))
        return min(max(0, raw), max(0, entryCount - 1))
    }

    /// Routine rows snap across routine midpoints. A folder header is its own
    /// explicit first-position slot, which also makes an empty folder usable.
    private func commitIfCrossed(
        fingerY: CGFloat,
        top: CGFloat,
        rowHeight: CGFloat,
        heldIndex: Int,
        entries: [RoutineReorderSession.Entry]
    ) {
        let nearest = Int(((fingerY - top - rowHeight / 2) / rowHeight).rounded())
        let target = min(max(0, nearest), max(0, entries.count - 1))
        guard target != heldIndex else { return }

        switch entries[target] {
        case .section(let destination, _):
            session.moveHeldToBeginning(of: destination)
        case .item:
            session.moveHeld(toFlatIndex: target)
        }
    }
}
