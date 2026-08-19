import ForgeCore
import SwiftData
import SwiftUI

/// First-launch flow. Each screen has one job: establish ForgeFit's value,
/// collect the two preferences needed to personalize logging, then explain
/// the Apple Health boundary before handing off to the system permission
/// sheet, which owns the allow/decline decision.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool
    @AppStorage("weightUnitRaw") private var weightUnitRaw = WeightUnit.lb.rawValue
    @AppStorage("trainingFocusRaw") private var trainingFocusRaw = TrainingFocus.mixed.rawValue
    @State private var path: [OnboardingStep] = []
    @State private var unit: WeightUnit = .lb
    @State private var focus: TrainingFocus = .mixed
    @State private var healthAuthorization = HealthAuthorizationStore.shared
    @State private var showHistoryImporter = false
    @State private var loadedPreferences = false

    var body: some View {
        NavigationStack(path: $path) {
            OnboardingWelcomeStep(
                onGetStarted: showSetup,
                onImportOrRestore: showImportOrRestore
            )
            .navigationDestination(for: OnboardingStep.self) { step in
                switch step {
                case .setup:
                    OnboardingSetupStep(unit: $unit, focus: $focus, onContinue: showHealth)
                case .health:
                    OnboardingHealthStep(
                        authorizationState: healthAuthorization.state,
                        onContinue: requestHealthThenFinish
                    )
                }
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showHistoryImporter) {
            WorkoutHistoryImportView(completionTitle: "Continue setup") {
                showHistoryImporter = false
                path = [.setup]
            }
        }
        .onAppear(perform: loadPreferences)
    }

    private func loadPreferences() {
        guard !loadedPreferences else { return }
        loadedPreferences = true
        unit = WeightUnit(rawValue: weightUnitRaw) ?? .lb
        focus = TrainingFocus(rawValue: trainingFocusRaw) ?? .mixed
    }

    private func showSetup() {
        path.append(.setup)
    }

    private func showHealth() {
        path.append(.health)
    }

    private func showImportOrRestore() {
        showHistoryImporter = true
    }

    /// Guideline 5.1.1(iv) requires the explainer screen to always lead to
    /// Apple's permission sheet, so this is onboarding's only exit — and it
    /// therefore has to survive every outcome. Granted, denied, HealthKit
    /// unavailable, or an infrastructure failure all finish: Home and Settings
    /// both carry a reconnect affordance, whereas holding someone on the last
    /// onboarding screen after a failed request leaves them no way into the app.
    ///
    /// Leaving early also keeps first launch honest. The 60-day catch-up scan
    /// that follows can take a while on a phone with years of Health workouts,
    /// and waiting it out under a spinner reads as a hang. The scan finishes in
    /// the background and Home fills in as it lands.
    private func requestHealthThenFinish() {
        guard !healthAuthorization.state.isRequesting else { return }
        let container = modelContext.container
        Task {
            _ = await healthAuthorization.connect()
            finish()
            await HealthWorkoutImporter.shared.importRecent(in: container)
            HealthMetricsStore.shared.refresh(force: true)
        }
    }

    private func finish() {
        Fmt.unit = unit
        weightUnitRaw = unit.rawValue
        trainingFocusRaw = focus.rawValue
        seedQuickStarts()
        UserDefaults.standard.set(true, forKey: "didOnboard")
        isPresented = false
    }

    /// Seeds focus-relevant Home actions without silently installing a training
    /// program. Home's permanent Empty tile remains the direct strength entry.
    private func seedQuickStarts() {
        let key = HomeQuickStartAction.preferenceKey
        guard (UserDefaults.standard.string(forKey: key) ?? "").isEmpty else { return }
        let ids = focus.quickStartIDs(routineIDs: [])
        if let data = try? JSONEncoder().encode(ids),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: key)
        }
    }
}
