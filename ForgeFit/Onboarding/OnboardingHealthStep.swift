import SwiftUI

struct OnboardingHealthStep: View {
    @Environment(\.theme) private var theme
    let authorizationState: HealthAuthorizationState
    let onConnect: () -> Void
    let onOpenSettings: () -> Void
    let onContinueWithoutHealth: () -> Void

    private var connecting: Bool { authorizationState.isRequesting }

    var body: some View {
        ZStack {
            ScreenBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Step 2 of 2")
                            .font(.label)
                            .foregroundStyle(theme.accent)
                        Image(systemName: "heart.fill")
                            .font(.screenTitle)
                            .foregroundStyle(theme.success)
                            .frame(width: 64, height: 64)
                            .background(theme.success.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                            .accessibilityHidden(true)
                        Text("Make readiness and Watch metrics work")
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Apple Health lets ForgeFit use heart rate, sleep, HRV, and workouts for readiness and live metrics.")
                            .font(.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: Space.lg) {
                        OnboardingFeatureRow(
                            systemImage: "gauge.with.dots.needle.50percent",
                            tint: theme.accent,
                            title: "Readiness in context",
                            detail: "See recovery signals beside your recent training load."
                        )
                        OnboardingFeatureRow(
                            systemImage: "applewatch.radiowaves.left.and.right",
                            tint: theme.secondaryAccent,
                            title: "Live workout metrics",
                            detail: "Keep heart rate and workout state in sync with Apple Watch."
                        )
                    }

                    Card {
                        HStack(alignment: .top, spacing: Space.md) {
                            Image(systemName: "lock.shield.fill")
                                .font(.cardTitle)
                                .foregroundStyle(theme.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text("Health data is processed on this device")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                                Text("It is excluded from ForgeFit’s iCloud sync and backups. You choose access in Apple’s permission screen.")
                                    .font(.label)
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }

                    if let issue = authorizationState.issueMessage {
                        Card {
                            HStack(alignment: .top, spacing: Space.md) {
                                Image(systemName: authorizationState.requiresPermissionReview
                                    ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(theme.danger)
                                    .accessibilityHidden(true)
                                Text(issue)
                                    .font(.body)
                                    .foregroundStyle(theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityIdentifier("onboarding-health-authorization-issue")
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.xxl)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.sm) {
                if authorizationState.requiresPermissionReview {
                    PrimaryButton(
                        title: "Open Settings",
                        systemImage: "gearshape.fill",
                        action: onOpenSettings
                    )
                    .accessibilityIdentifier("onboarding-open-health-settings")
                } else {
                    PrimaryButton(
                        title: connecting ? "Connecting…" : authorizationState == .notDetermined
                            ? "Connect Apple Health" : "Try Apple Health Again",
                        systemImage: "heart.fill",
                        action: onConnect
                    )
                    .disabled(connecting || authorizationState == .unavailable)
                    .accessibilityIdentifier("onboarding-connect-health")
                }

                SecondaryButton(title: "Continue without Health", action: onContinueWithoutHealth)
                    .disabled(connecting)
                    .accessibilityIdentifier("onboarding-continue-without-health")
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.md)
            .padding(.bottom, Space.sm)
            .background(theme.background)
            .overlay(alignment: .top) {
                Divider().overlay(theme.separator)
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
