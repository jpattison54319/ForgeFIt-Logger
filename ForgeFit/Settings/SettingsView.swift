import SwiftUI
import SwiftData

/// Settings: connect Apple Health & Fitness (read + write), Apple Watch live-sync
/// status, and units. The Health connection is what powers cardio auto-fill and
/// readiness — so it leads the screen.
struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @AppStorage("liveSyncEnabled") private var liveSyncEnabled = true
    @AppStorage("healthWriteEnabled") private var healthWriteEnabled = true
    @AppStorage("weightUnitRaw") private var weightUnitRaw = WeightUnit.lb.rawValue
    @AppStorage("showRPEInLogger") private var showRPEInLogger = false

    @State private var watch = WatchLink.shared
    @State private var connected = HealthService.shared.isConnected
    @State private var connecting = false
    @State private var unit: WeightUnit = Fmt.unit
    @State private var showHistoryImporter = false
    @State private var showResetSheet = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    healthCard
                    historyImportCard
                    watchCard
                    remindersCard
                    unitsCard
                    platesCard
                    dataResetCard
                    aboutCard
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.bodyStrong)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showHistoryImporter) {
            WorkoutHistoryImportView()
        }
        .sheet(isPresented: $showResetSheet) {
            ResetDataSheet {
                showResetSheet = false
                dismiss()
            }
        }
        .onAppear {
            watch.activate()
            connected = HealthService.shared.isConnected
        }
    }

    // MARK: - Apple Health

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Apple Health & Fitness")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(spacing: Space.md) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(LinearGradient(colors: [theme.danger, Color(hex: 0xFF2D55)], startPoint: .top, endPoint: .bottom))
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Health").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                            Text(connected ? "Connected" : (HealthService.shared.isAvailable ? "Not connected" : "Unavailable on this device"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(connected ? theme.success : theme.textSecondary)
                        }
                        Spacer()
                        if connected {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(theme.success)
                        }
                    }

                    Text("Reads workout metrics (heart rate, energy, distance, power) plus full-day recovery data — HRV, resting heart rate, sleep, respiratory rate, blood oxygen, VO₂max, heart-rate recovery, steps & body weight — to drive readiness scores and auto-fill. Writes finished workouts back to Health & Fitness.")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !connected {
                        PrimaryButton(title: connecting ? "Connecting…" : "Connect Apple Health", systemImage: "heart.fill") {
                            connect()
                        }
                        .disabled(connecting || !HealthService.shared.isAvailable)
                    } else {
                        Text("Manage exact permissions in the Health app → Sharing → Apps.")
                            .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    }
                }
            }

            Card {
                Toggle(isOn: $healthWriteEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write workouts to Health").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("Save each finished session as an Apple Health workout.")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                }
                .tint(theme.accent)
            }
        }
    }

    // MARK: - Historical import

    private var historyImportCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Workout History")
            Card {
                HStack(spacing: Space.md) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import from another app")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Hevy CSV, common CSV exports, or ForgeFit JSON.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Button("Import") { showHistoryImporter = true }
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accent)
                }
            }
        }
    }

    // MARK: - Apple Watch

    private var watchCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Apple Watch")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    statusRow("applewatch", "Paired", watch.isPaired ? "Yes" : "No", good: watch.isPaired)
                    Divider().overlay(theme.separator)
                    statusRow("apps.iphone", "ForgeFit on Watch", watch.isWatchAppInstalled ? "Installed" : "Not installed", good: watch.isWatchAppInstalled)
                    Divider().overlay(theme.separator)
                    statusRow("dot.radiowaves.left.and.right", "Reachable now", watch.isReachable ? "Yes" : "No", good: watch.isReachable)
                }
            }
            Card {
                Toggle(isOn: $liveSyncEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live sync with Apple Watch").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("Pull heart rate, distance & calories live from your Watch during a session.")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                }
                .tint(theme.accent)
            }
            if !watch.isPaired {
                Text("Pair an Apple Watch in the Watch app, then keep it on during workouts for automatic metrics.")
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func statusRow(_ icon: String, _ title: String, _ value: String, good: Bool) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textSecondary).frame(width: 24)
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.textPrimary)
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(good ? theme.success : theme.textTertiary)
        }
    }

    // MARK: - Units

    private var unitsCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Units")
            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack {
                        Text("Default weight unit").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Picker("Unit", selection: $unit) {
                            Text("lb").tag(WeightUnit.lb)
                            Text("kg").tag(WeightUnit.kg)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                        .onChange(of: unit) { _, newValue in
                            Fmt.unit = newValue
                            weightUnitRaw = newValue.rawValue
                        }
                    }
                    Text("Used for exercises without their own unit.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Divider().overlay(theme.separator)
                    Toggle(isOn: $showRPEInLogger) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show RPE in logger").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                            Text("Adds an optional effort column for strength sets.")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    .tint(theme.accent)
                }
            }
        }
    }

    // MARK: - Reminders

    private var remindersCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Reminders")
            ReminderSettingsCard()
        }
    }

    // MARK: - Plates & bars

    /// The plate calculator's inventory: bar weight plus which plates (and how
    /// many pairs) the gym has.
    private var platesCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Plates & Bars")
            PlateInventoryEditor(unit: unit)
                .id(unit) // rebuild when the app unit flips
        }
    }

    // MARK: - Data reset

    private var dataResetCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Data")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .top, spacing: Space.md) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(theme.danger)
                            .frame(width: 34, height: 34)
                            .background(theme.danger.opacity(0.12))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reset all app data")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text("Delete local workouts, routines, imports, notes, progress, reminders, and preferences from ForgeFit.")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(role: .destructive) {
                        showResetSheet = true
                    } label: {
                        Text("Reset all app data")
                            .font(.bodyStrong)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.danger)
                    .controlSize(.large)
                }
            }
        }
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("About")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack {
                        Text("Version").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(appVersion).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                    }
                    Divider().overlay(theme.separator)
                    // TODO(launch): point at the hosted policy URL once
                    // published — the same URL goes in App Store Connect.
                    Link(destination: URL(string: "https://github.com/yuhonas/free-exercise-db")!) {
                        HStack {
                            Text("Exercise illustrations: free-exercise-db")
                                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                        }
                    }
                    Divider().overlay(theme.separator)
                    Text("Your data stays on your device. Health data is read with permission, and ForgeFit only writes workouts or weigh-ins when you choose to.")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func connect() {
        connecting = true
        Task {
            _ = await HealthService.shared.requestAuthorization()
            await HealthWorkoutImporter.shared.importRecent(in: modelContext)
            await MainActor.run {
                connected = HealthService.shared.isConnected
                connecting = false
                // Pull the daily recovery series immediately so readiness
                // reflects real biometrics right after connecting.
                HealthMetricsStore.shared.refresh(force: true)
            }
        }
    }
}

private struct ResetDataSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let onFinished: () -> Void

    @State private var isResetting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(theme.danger)
                        Text("Reset ForgeFit")
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("This deletes your local ForgeFit data and returns the app to onboarding.")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            resetBullet("Deleted", "Workouts, routines, imports, notes, custom data, XP, levels, reminders, and preferences.")
                            Divider().overlay(theme.separator)
                            resetBullet("Kept in Apple Health", "Health records and permission grants are managed by iOS. ForgeFit will not delete Health workouts.")
                            Divider().overlay(theme.separator)
                            resetBullet("After reset", "The bundled exercise library is restored so you can start clean immediately.")
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PrimaryButton(title: isResetting ? "Resetting..." : "Reset all app data", systemImage: "trash.fill", tint: theme.danger) {
                        reset()
                    }
                    .disabled(isResetting)
                    SecondaryButton(title: "Cancel") {
                        dismiss()
                    }
                    .disabled(isResetting)
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isResetting)
    }

    private func resetBullet(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reset() {
        isResetting = true
        errorMessage = nil
        do {
            try AccountResetService.resetAllAppData(in: modelContext)
            dismiss()
            onFinished()
        } catch {
            errorMessage = "Reset failed: \(error.localizedDescription)"
            isResetting = false
        }
    }
}
