import SwiftUI
import UIKit

/// A single Wrapped page rendered as a social-friendly 9:16 card: the page
/// exactly as it appears in the story, plus ForgeFit branding and the period
/// label. Pinned to `.sageDark` like every other share export so a shared
/// card looks the same regardless of the sharer's in-app appearance.
struct WrappedShareCard: View {
    @Environment(\.theme) private var theme
    let page: WrappedPage
    let periodLabel: String

    var body: some View {
        VStack(spacing: 0) {
            WrappedPageView(page: page, periodLabel: periodLabel)
                .frame(width: 390, height: 600)
                .clipped()
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text("ForgeFit")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                }
                Spacer()
                Text(periodLabel)
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
            .background(theme.surface)
        }
        .frame(width: 390)
        .background(theme.background)
    }
}

@MainActor
enum WrappedShareRenderer {
    static func image(page: WrappedPage, periodLabel: String, theme: AppTheme) -> UIImage? {
        ShareRenderer.image(WrappedShareCard(page: page, periodLabel: periodLabel), theme: theme)
    }
}
