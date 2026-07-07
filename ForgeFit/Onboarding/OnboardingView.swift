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
    @Query(sort: \RoutineModel.position) private var routines: [RoutineModel]
    @AppStorage("weightUnitRaw") private var weightUnitRaw = WeightUnit.lb.rawValue
    @State private var unit: WeightUnit = .lb
    @State private var connecting = false
    @State private var selectedTemplateID: String?
    @State private var showHistoryImporter = false

    private var starterTemplates: [RoutineTemplate] {
        Array(RoutineTemplateCatalog.validTemplates(from: RoutineTemplateCatalog.load(), exercises: exercises).prefix(3))
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

                    if !starterTemplates.isEmpty {
                        VStack(alignment: .leading, spacing: Space.md) {
                            Text("Pick a starter routine")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            ForEach(starterTemplates) { template in
                                starterTemplateButton(template)
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
        .onAppear {
            if selectedTemplateID == nil {
                selectedTemplateID = starterTemplates.first?.id
            }
        }
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

    private func starterTemplateButton(_ template: RoutineTemplate) -> some View {
        Button {
            selectedTemplateID = template.id
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: selectedTemplateID == template.id ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(selectedTemplateID == template.id ? theme.success : theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text("\(template.level.capitalized) · \(template.daysPerWeek)x/week · \(template.estimatedMinutes)m")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
            }
            .padding(Space.md)
            .background(selectedTemplateID == template.id ? theme.accent.opacity(0.14) : theme.surface)
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
        if let selectedTemplateID,
           let template = starterTemplates.first(where: { $0.id == selectedTemplateID }) {
            RoutineTemplateCatalog.importTemplate(template, folderID: nil, existingRoutines: routines, in: modelContext)
        }
        UserDefaults.standard.set(true, forKey: "didOnboard")
        isPresented = false
    }
}
