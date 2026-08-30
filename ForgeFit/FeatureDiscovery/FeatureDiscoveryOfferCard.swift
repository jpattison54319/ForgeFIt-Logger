import SwiftUI

struct FeatureDiscoveryOfferCard: View {
    @Environment(\.theme) private var theme

    let offer: FeatureDiscoveryOffer
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                header
                Text(offer.whyNow)
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                Text(offer.benefit)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                Button("Set day target", systemImage: "calendar.badge.plus", action: onAccept)
                    .font(.bodyStrong)
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
                    .controlSize(.large)
                    .buttonBorderShape(.roundedRectangle(radius: Radius.control))
                    .minimumTouchTarget()
                    .accessibilityIdentifier("feature-discovery-microcycle-accept")
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Label {
                Text(offer.title)
            } icon: {
                Image(systemName: "lightbulb.fill")
                    .accessibilityHidden(true)
            }
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("feature-discovery-microcycle-card")
            Spacer()
            Button("Dismiss microcycle suggestion", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(theme.textTertiary)
                .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityHint("This suggestion will not appear again.")
                .accessibilityIdentifier("feature-discovery-microcycle-dismiss")
        }
    }
}
