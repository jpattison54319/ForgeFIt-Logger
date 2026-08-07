import SwiftUI

enum SupersetUI {
    private struct PaletteEntry {
        let name: String
        let color: Color
    }

    /// Stable, high-contrast group identities in the order users create them.
    /// A starts purple and B red; later colors stay distinct from ForgeFit's
    /// green completion state.
    private static let palette: [PaletteEntry] = [
        PaletteEntry(name: "Purple", color: Color(hex: 0x7C3AED)),
        PaletteEntry(name: "Red", color: Color(hex: 0xDC2626)),
        PaletteEntry(name: "Blue", color: Color(hex: 0x2563EB)),
        PaletteEntry(name: "Orange", color: Color(hex: 0xC2410C)),
        PaletteEntry(name: "Teal", color: Color(hex: 0x0F766E)),
        PaletteEntry(name: "Pink", color: Color(hex: 0xBE185D)),
        PaletteEntry(name: "Indigo", color: Color(hex: 0x4338CA)),
        PaletteEntry(name: "Cyan", color: Color(hex: 0x0E7490))
    ]

    static func label(for group: Int) -> String {
        "Superset \(letter(for: group))"
    }

    static func letter(for group: Int) -> String {
        guard group >= 0, group < 26 else { return "\(group + 1)" }
        let scalar = UnicodeScalar(65 + group)!
        return String(Character(scalar))
    }

    static func color(for group: Int) -> Color {
        palette[paletteIndex(for: group)].color
    }

    static func colorName(for group: Int) -> String {
        palette[paletteIndex(for: group)].name
    }

    static func menuLabel(for group: Int) -> String {
        "\(label(for: group)) · \(colorName(for: group))"
    }

    static func nextGroup(excluding groups: [Int]) -> Int {
        let used = Set(groups)
        return (0...).first { !used.contains($0) } ?? 0
    }

    private static func paletteIndex(for group: Int) -> Int {
        max(0, group) % palette.count
    }

    /// The superset actions as `ScrollSafeMenu` items — the one definition
    /// shared by every card menu that lives on a scroll surface (live yoga
    /// and cardio cards, the routine editor's ⋯ menu). Create / add-to
    /// submenu with the current group checked / remove-from / ungroup,
    /// matching `SupersetMenuItems` item-for-item.
    static func scrollSafeMenuItems(
        currentGroup: Int?,
        availableGroups: [Int],
        onAssign: @escaping (Int?) -> Void,
        onCreate: @escaping () -> Void,
        onUngroup: @escaping (Int) -> Void
    ) -> [ScrollSafeMenuItem] {
        let nextGroup = nextGroup(excluding: availableGroups)
        var items: [ScrollSafeMenuItem] = [
            ScrollSafeMenuItem(
                title: "Create \(menuLabel(for: nextGroup))",
                systemImage: "circle.fill",
                iconColor: color(for: nextGroup),
                action: onCreate
            )
        ]
        if !availableGroups.isEmpty {
            items.append(ScrollSafeMenuItem(
                title: "Add to Superset",
                systemImage: "link",
                children: availableGroups.map { group in
                    ScrollSafeMenuItem(
                        title: menuLabel(for: group),
                        systemImage: "circle.fill",
                        iconColor: color(for: group),
                        isChecked: currentGroup == group
                    ) {
                        onAssign(group)
                    }
                }
            ))
        }
        if let currentGroup {
            items.append(ScrollSafeMenuItem(title: "Remove from \(label(for: currentGroup))", systemImage: "link.badge.minus") {
                onAssign(nil)
            })
            items.append(ScrollSafeMenuItem(title: "Ungroup \(label(for: currentGroup))", systemImage: "rectangle.split.3x1") {
                onUngroup(currentGroup)
            })
        }
        return items
    }
}

struct SupersetChip: View {
    let group: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(SupersetUI.color(for: group))
            Text(SupersetUI.letter(for: group))
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 20, height: 20)
        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SupersetUI.label(for: group))
        .accessibilityValue(SupersetUI.colorName(for: group))
    }
}

// SupersetMenuItems (the SwiftUI `Menu` flavor) is gone: every card menu on a
// scroll surface now goes through `scrollSafeMenuItems` above, because a
// SwiftUI Menu label claims the touch stream and dead-stops scrolls that
// start on it (see ScrollSafeMenu).
