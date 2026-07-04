import SwiftUI

/// Shared screen chrome: pure-black canvas, a large bold title header with an
/// optional trailing accessory, and a scroll view that keeps its content clear
/// of the floating tab bar.
struct ScreenScaffold<Trailing: View, Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var subtitle: String? = nil
    var trailing: Trailing
    @ViewBuilder var content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Space.xl) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 15))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer()
                    trailing
                }
                .padding(.top, Space.sm)

                content
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .scrollDismissesKeyboard(.interactively)
    }
}

extension ScreenScaffold where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}
