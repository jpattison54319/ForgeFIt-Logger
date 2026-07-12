import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// First-launch welcome: what the app does, pick units, and prime the Apple
/// Health permission — the single step that lights up readiness scoring and
/// live watch metrics.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Binding var isPresented: Bool
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]
    @AppStorage("weightUnitRaw") private var weightUnitRaw = WeightUnit.lb.rawValue
    @State private var unit: WeightUnit = .lb
    @State private var connecting = false
    @State private var selectedProgramID: String?
    @State private var showHistoryImporter = false

    private var validTemplates: [RoutineTemplate] {
        RoutineTemplateCatalog.validTemplates(from: RoutineTemplateCatalog.load(), exercises: exercises)
    }

    private var starterPrograms: [RoutineProgramTemplate] {
        Array(RoutineTemplateCatalog.validPrograms(
            from: RoutineTemplateCatalog.loadPrograms(),
            templates: validTemplates,
            exercises: exercises
        ).prefix(3))
    }

    var body: some View {
        ZStack {
            ScreenBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text("Welcome to ForgeFit")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("The training OS for hybrid athletes.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.textSecondary)

                    VStack(alignment: .leading, spacing: Space.lg) {
                        feature("dumbbell.fill", theme.accent, "Log strength & cardio", "Advanced set types, Strava-style cardio, smart rest timers.")
                        feature("applewatch", theme.secondaryAccent, "Live Apple Watch sync", "Start anywhere, log from the wrist, live heart rate.")
                        feature("waveform.path.ecg", theme.success, "Readiness scoring", "HRV, sleep & training load tell you when to push or back off.")
                    }

                    HStack {
                        Text("Weight unit").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Picker("Unit", selection: $unit) {
                            Text("lb").tag(WeightUnit.lb)
                            Text("kg").tag(WeightUnit.kg)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                    }

                    if !starterPrograms.isEmpty {
                        VStack(alignment: .leading, spacing: Space.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Start with a training program")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                                Text("Optional — adds a folder of routines you can explore or change anytime.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            ForEach(starterPrograms) { program in
                                starterProgramButton(program)
                            }
                        }
                    }

                    Button {
                        showHistoryImporter = true
                    } label: {
                        HStack(spacing: Space.md) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(theme.accent)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import workout history")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                                Text("Bring in Hevy CSV or another workout export.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(Space.md)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())

                    PrimaryButton(title: connecting ? "Connecting…" : "Connect Apple Health & Start", systemImage: "heart.fill") {
                        connect()
                    }
                    .disabled(connecting)
                    Button("Skip for now") { finish() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.xxl)
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showHistoryImporter) {
            WorkoutHistoryImportView()
        }
    }

    private func feature(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Text(detail).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func starterProgramButton(_ program: RoutineProgramTemplate) -> some View {
        let isSelected = selectedProgramID == program.id
        let routineCount = program.routines(from: validTemplates).count
        return Button {
            // Tap toggles: picking a program is entirely optional, so a second
            // tap deselects instead of locking the user into a choice.
            selectedProgramID = isSelected ? nil : program.id
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(isSelected ? theme.success : theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text("\(program.level.capitalized) · \(program.daysPerWeek)x/week · \(routineCount) routine\(routineCount == 1 ? "" : "s")")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
            }
            .padding(Space.md)
            .background(isSelected ? theme.accent.opacity(0.14) : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func connect() {
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
        if let selectedProgramID,
           let program = starterPrograms.first(where: { $0.id == selectedProgramID }) {
            RoutineTemplateCatalog.importProgram(program, templates: validTemplates, in: modelContext)
        }
        UserDefaults.standard.set(true, forKey: "didOnboard")
        isPresented = false
    }
}
