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
                            .foregroundStyle(theme.accent)
                        Text("Train everything.\nLog it fast.")
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Strength, cardio, yoga, Apple Watch, and recovery in one place.")
                            .font(.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: Space.lg) {
                        OnboardingFeatureRow(
                            systemImage: "bolt.fill",
                            tint: theme.accent,
                            title: "Fast workout logging",
                            detail: "Log drop sets, intervals, and rest without leaving your workout."
                        )
                        OnboardingFeatureRow(
                            systemImage: "applewatch",
                            tint: theme.secondaryAccent,
                            title: "Built for Apple Watch",
                            detail: "Start on iPhone or Watch and keep your workout in sync."
                        )
                        OnboardingFeatureRow(
                            systemImage: "waveform.path.ecg",
                            tint: theme.success,
                            title: "Readiness in context",
                            detail: "See HRV, sleep, and recent training load together."
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
