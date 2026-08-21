import SwiftUI

struct OnboardingWelcomeStep: View {
    @Environment(\.theme) private var theme
    let onGetStarted: () -> Void
    let onImportOrRestore: () -> Void

    var body: some View {
        ZStack {
            ScreenBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Image("AnvilFMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 78, height: 68)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("ForgeFit")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.accentForeground)
                        Text("All your training.\nOne clear log.")
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Plan, log, and understand your strength, cardio, conditioning, and yoga in one place.")
                            .font(.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: Space.lg) {
                        OnboardingFeatureRow(
                            systemImage: "bolt.fill",
                            tint: theme.accent,
                            title: "Fast workout logging",
                            detail: "Track sets, intervals, and rest from one focused workout screen."
                        )
                        OnboardingFeatureRow(
                            systemImage: "applewatch",
                            tint: theme.secondaryAccent,
                            title: "Built for Apple Watch",
                            detail: "Start on iPhone or Apple Watch and follow the same live workout."
                        )
                        OnboardingFeatureRow(
                            systemImage: "waveform.path.ecg",
                            tint: theme.success,
                            title: "Recovery with context",
                            detail: "See sleep and HRV alongside the training that shaped them."
                        )
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.xxl)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.sm) {
                PrimaryButton(title: "Get started", systemImage: "arrow.right", action: onGetStarted)
                    .accessibilityIdentifier("onboarding-get-started")
                SecondaryButton(
                    title: "Import or restore data",
                    systemImage: "tray.and.arrow.down.fill",
                    action: onImportOrRestore
                )
                .accessibilityIdentifier("onboarding-import-or-restore")
                Text("You can import a workout CSV anytime from Settings.")
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.md)
            .padding(.bottom, Space.sm)
            .background(theme.background)
            .overlay(alignment: .top) {
                Divider().overlay(theme.separator)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
