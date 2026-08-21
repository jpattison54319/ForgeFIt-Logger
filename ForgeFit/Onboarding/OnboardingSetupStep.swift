import ForgeCore
import SwiftUI

struct OnboardingSetupStep: View {
    @Environment(\.theme) private var theme
    @Binding var unit: WeightUnit
    @Binding var focus: TrainingFocus
    let onContinue: () -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ZStack {
            ScreenBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Step 1 of 2")
                            .font(.label)
                            .foregroundStyle(theme.accentForeground)
                        Text("Set up ForgeFit")
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Choose your training mix and preferred weight unit.")
                            .font(.body)
                            .foregroundStyle(theme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: Space.md) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Your training mix")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text("This sets up your first Home shortcuts. You can edit them anytime.")
                                .font(.label)
                                .foregroundStyle(theme.textSecondary)
                        }
                        LazyVGrid(columns: columns, spacing: Space.sm) {
                            ForEach(TrainingFocus.allCases) { option in
                                OnboardingFocusButton(
                                    option: option,
                                    isSelected: focus == option,
                                    action: { focus = option }
                                )
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            Text("Weight unit")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Picker("Weight unit", selection: $unit) {
                                Text("lb").tag(WeightUnit.lb)
                                Text("kg").tag(WeightUnit.kg)
                            }
                            .pickerStyle(.segmented)
                            .frame(minHeight: TouchTarget.minimum)
                        }
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.xxl)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack {
                PrimaryButton(title: "Continue", systemImage: "arrow.right", action: onContinue)
                    .accessibilityIdentifier("onboarding-setup-continue")
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.md)
            .padding(.bottom, Space.sm)
            .background(theme.background)
            .overlay(alignment: .top) {
                Divider().overlay(theme.separator)
            }
        }
        .navigationTitle("Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
