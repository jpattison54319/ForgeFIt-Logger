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
                            .foregroundStyle(theme.accent)
                        Text("Set up ForgeFit")
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Choose what you train and how weights appear.")
                            .font(.body)
                            .foregroundStyle(theme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: Space.md) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("What do you train?")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text("This shapes your Home quick starts. You can change them later.")
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
