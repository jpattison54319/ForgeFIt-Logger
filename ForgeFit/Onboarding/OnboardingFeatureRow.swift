import SwiftUI

struct OnboardingFeatureRow: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: systemImage)
                .font(.bodyStrong)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
