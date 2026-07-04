import SwiftUI

enum SupersetUI {
    static func label(for group: Int) -> String {
        "Superset \(letter(for: group))"
    }

    static func letter(for group: Int) -> String {
        guard group >= 0, group < 26 else { return "\(group + 1)" }
        let scalar = UnicodeScalar(65 + group)!
        return String(Character(scalar))
    }

    static func color(for group: Int) -> Color {
        let t = AppTheme.sage
        let palette: [Color] = [
            t.secondaryAccent,
            t.accent,
            t.success,
            t.warmup,
            t.danger
        ]
        return palette[abs(group) % palette.count]
    }
}

struct SupersetChip: View {
    @Environment(\.theme) private var theme
    let group: Int

    var body: some View {
        Text(SupersetUI.label(for: group))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(SupersetUI.color(for: group))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SupersetUI.color(for: group).opacity(0.16))
            .clipShape(Capsule())
    }
}

struct SupersetMenuItems: View {
    @Environment(\.theme) private var theme
    let currentGroup: Int?
    let availableGroups: [Int]
    let onAssign: (Int?) -> Void
    let onCreate: () -> Void
    let onUngroup: (Int) -> Void

    var body: some View {
        Button("Create Superset", systemImage: "link.badge.plus") { onCreate() }

        if !availableGroups.isEmpty {
            Menu("Add to Superset", systemImage: "link") {
                ForEach(availableGroups, id: \.self) { group in
                    Button {
                        onAssign(group)
                    } label: {
                        Label(SupersetUI.label(for: group), systemImage: currentGroup == group ? "checkmark" : "")
                    }
                }
            }
        }

        if let currentGroup {
            Button("Remove from \(SupersetUI.label(for: currentGroup))", systemImage: "link.badge.minus") {
                onAssign(nil)
            }
            Button("Ungroup \(SupersetUI.label(for: currentGroup))", systemImage: "rectangle.split.3x1") {
                onUngroup(currentGroup)
            }
        }
    }
}
