import ForgeCore
import SwiftData
import SwiftUI

/// First-launch flow. Each screen has one job: establish ForgeFit's value,
/// collect the two preferences needed to personalize logging, then explain
/// the optional Apple Health boundary before the system permission sheet.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool
    @AppStorage("weightUnitRaw") private var weightUnitRaw = WeightUnit.lb.rawValue
    @AppStorage("trainingFocusRaw") private var trainingFocusRaw = TrainingFocus.mixed.rawValue
    @State private var path: [OnboardingStep] = []
    @State private var unit: WeightUnit = .lb
    @State private var focus: TrainingFocus = .mixed
    @State private var connecting = false
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
                        connecting: connecting,
                        onConnect: connectHealth,
                        onContinueWithoutHealth: finish
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

    private func connectHealth() {
        guard !connecting else { return }
        connecting = true
        Task {
            _ = await HealthService.shared.requestAuthorization()
            await HealthWorkoutImporter.shared.importRecent(in: modelContext)
            HealthMetricsStore.shared.refresh(force: true)
            finish()
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
        let key = "homeQuickStartActions.v1"
        guard (UserDefaults.standard.string(forKey: key) ?? "").isEmpty else { return }
        let ids = focus.quickStartIDs(routineIDs: [])
        if let data = try? JSONEncoder().encode(ids),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: key)
        }
    }
}
