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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var featuresRevealed = false
    @Binding var isPresented: Bool
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]
    @AppStorage("weightUnitRaw") private var weightUnitRaw = WeightUnit.lb.rawValue
    @State private var unit: WeightUnit = .lb
    @State private var connecting = false
    @State private var selectedProgramID: String?
    @State private var showHistoryImporter = false
    @State private var hasCloudBackup = false
    @AppStorage("trainingFocusRaw") private var trainingFocusRaw = TrainingFocus.mixed.rawValue
    @State private var focus: TrainingFocus = .mixed
    /// Once the user manually toggles a program row, focus changes stop
    /// steering the selection — their explicit choice (or deselection) wins.
    @State private var userAdjustedProgram = false

    private var validTemplates: [RoutineTemplate] {
        RoutineTemplateCatalog.validTemplates(from: RoutineTemplateCatalog.load(), exercises: exercises)
    }

    private var starterPrograms: [RoutineProgramTemplate] {
        var ordered = RoutineTemplateCatalog.validPrograms(
            from: RoutineTemplateCatalog.loadPrograms(),
            templates: validTemplates,
            exercises: exercises
        )
        // The focus's default program leads the list so the pre-selection is
        // always visible, not hidden behind the prefix cut.
        if let defaultID = focus.defaultProgramID,
           let index = ordered.firstIndex(where: { $0.id == defaultID }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        return Array(ordered.prefix(3))
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
                        .font(.screenTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text("The training OS for hybrid athletes.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.textSecondary)

                    VStack(alignment: .leading, spacing: Space.lg) {
                        feature(0, "dumbbell.fill", theme.accent, "Log strength & cardio", "Advanced set types, Strava-style cardio, smart rest timers.")
                        feature(1, "applewatch", theme.secondaryAccent, "Live Apple Watch sync", "Start anywhere, log from the wrist, live heart rate.")
                        feature(2, "waveform.path.ecg", theme.success, "Readiness scoring", "HRV, sleep & training load tell you when to push or back off.")
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

                    VStack(alignment: .leading, spacing: Space.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("What do you train?")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text("Sets up your home screen quick starts — change anytime.")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        HStack(spacing: Space.sm) {
                            ForEach(TrainingFocus.allCases) { option in
                                focusChip(option)
                            }
                        }
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

                    // Returning users with an iCloud backup skip straight to
                    // their training log (the importer screen leads with the
                    // restore card when a backup exists).
                    if hasCloudBackup {
                        Button {
                            showHistoryImporter = true
                        } label: {
                            HStack(spacing: Space.md) {
                                Image(systemName: "icloud.and.arrow.down.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(theme.secondaryAccent)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Restore from iCloud Backup")
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    Text("Your ForgeFit training log from a previous iPhone.")
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
                    }

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
        .onAppear {
            featuresRevealed = true
            focus = TrainingFocus.stored
            // Pre-select the focus's starter program so doing nothing still
            // gets you a plan; the row stays deselectable and a deliberate
            // deselection is respected (no silent seeding behind it).
            if !userAdjustedProgram {
                selectedProgramID = focus.defaultProgramID
            }
        }
        .task {
            hasCloudBackup = !(await BackupRestoreService.availableBackups().isEmpty)
        }
    }

    private func focusChip(_ option: TrainingFocus) -> some View {
        let isSelected = focus == option
        return Button {
            focus = option
            trainingFocusRaw = option.rawValue
            if !userAdjustedProgram {
                selectedProgramID = option.defaultProgramID
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(option.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? theme.accent.opacity(0.14) : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .animation(Motion.tap, value: isSelected)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(option.title)\(isSelected ? ", selected" : "")")
    }

    private func feature(_ index: Int, _ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
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
        // First-run-only cascade; Reduce Motion keeps a single quick fade.
        .opacity(featuresRevealed ? 1 : 0)
        .offset(y: featuresRevealed || reduceMotion ? 0 : 10)
        .animation(
            reduceMotion ? Motion.reduced : Motion.entrance.delay(Double(index) * 0.08),
            value: featuresRevealed
        )
    }

    private func starterProgramButton(_ program: RoutineProgramTemplate) -> some View {
        let isSelected = selectedProgramID == program.id
        return Button {
            // Tap toggles: picking a program is entirely optional, so a second
            // tap deselects instead of locking the user into a choice.
            selectedProgramID = isSelected ? nil : program.id
            userAdjustedProgram = true
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(isSelected ? theme.success : theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: reduceMotion ? false : isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text("\(program.level.capitalized) · \(program.structureSummary)")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    if let letters = program.scheduleLetters, Set(program.routineIDs).count < letters.count {
                        Text("Week: \(letters.joined(separator: " · "))")
                            .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                    }
                }
                Spacer()
            }
            .padding(Space.md)
            .background(isSelected ? theme.accent.opacity(0.14) : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .animation(Motion.tap, value: isSelected)
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
        var importedFolder: RoutineFolderModel?
        if let selectedProgramID,
           let program = starterPrograms.first(where: { $0.id == selectedProgramID }) {
            importedFolder = RoutineTemplateCatalog.importProgram(program, templates: validTemplates, in: modelContext)
        }
        seedQuickStarts(folder: importedFolder)
        UserDefaults.standard.set(true, forKey: "didOnboard")
        isPresented = false
    }

    /// Seeds the Home quick-start tiles to match the chosen focus (a lifter
    /// gets their program days, not four cardio tiles). Never overwrites an
    /// existing configuration. Format matches `HomeQuickStartAction.encode`.
    private func seedQuickStarts(folder: RoutineFolderModel?) {
        let key = "homeQuickStartActions.v1"
        guard (UserDefaults.standard.string(forKey: key) ?? "").isEmpty else { return }
        var routineIDs: [UUID] = []
        if let folder {
            let all = (try? modelContext.fetch(FetchDescriptor<RoutineModel>())) ?? []
            routineIDs = all
                .filter { $0.folderID == folder.id && $0.deletedAt == nil }
                .sorted { $0.position < $1.position }
                .map(\.id)
        }
        let ids = focus.quickStartIDs(routineIDs: routineIDs)
        if let data = try? JSONEncoder().encode(ids), let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: key)
        }
    }
}
