import SwiftUI

/// The leading content of a themed settings row: an optional SF Symbol in a
/// colored rounded square, followed by a title and optional subtitle.
///
/// Designed to be used as the label of a `Toggle`, `NavigationLink`, or
/// `Button` inside a `List(.insetGrouped)` section — the control provides
/// its own trailing accessory (switch, chevron, etc.).
struct SettingsRowLabel: View {
    @Environment(\.theme) private var theme

    var icon: String?
    var iconTint: Color?
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: Space.md) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(iconTint ?? theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension SettingsRowLabel {
    init(icon: String? = nil, iconTint: Color? = nil, title: String) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = nil
    }
}

/// A complete settings row with custom trailing content (value text, button,
/// etc.). Use `SettingsRowLabel` directly when the trailing accessory is
/// provided by a `Toggle` or `NavigationLink`.
struct SettingsRow<Trailing: View>: View {
    var icon: String?
    var iconTint: Color?
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: Trailing

    init(
        icon: String? = nil,
        iconTint: Color? = nil,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Space.md) {
            SettingsRowLabel(icon: icon, iconTint: iconTint, title: title, subtitle: subtitle)
            Spacer(minLength: Space.sm)
            trailing
        }
    }
}

// MARK: - List row theming

/// Applies the Sage theme's surface color and separator tint to a list row.
/// Use on every row inside the settings `List(.insetGrouped)` so the grouped
/// sections match the custom dark/light Sage palette instead of the system
/// defaults.
private struct ThemedListRowModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .listRowBackground(theme.surface)
            .listRowSeparatorTint(theme.separator)
    }
}

extension View {
    /// Style a list row with Sage theme surface + separator colors.
    func themedListRow() -> some View {
        modifier(ThemedListRowModifier())
    }
}
