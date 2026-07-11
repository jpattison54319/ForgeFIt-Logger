import ForgeCore
import SwiftUI

/// Manual heart-rate zone configuration: set max HR (which scales all five
/// zones), optionally a resting HR and custom zone boundaries, and auto-calibrate
/// from your Apple Health age or a live field test. Persists to the shared store
/// and pushes the updated model to the watch.
struct HRZoneSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var config = HRZoneConfigStore.load()
    @State private var showAdvanced = false
    @State private var showFieldTest = false
    @State private var manualAge = ""
    @State private var appleSyncProposal: AppleHealthZoneSync?
    @State private var appleSyncError: String?
    @State private var syncingAppleHealth = false
    @AppStorage("zoneVoiceCues") private var zoneVoiceCues = true

    private var healthAge: Int? { HealthService.shared.biologicalAge() }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                maxHRCard
                zonesPreview
                zoneLockCard
                calibrateCard
                advancedCard
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
        }
        .background(theme.background)
        .navigationTitle("Heart-rate zones")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: config) { _, _ in save() }
        .sheet(isPresented: $showFieldTest) {
            HRZoneFieldTestView { peak in
                config.maxHR = peak
            }
        }
        .alert(item: $appleSyncProposal) { proposal in
            Alert(
                title: Text("Sync from Apple Health?"),
                message: Text(proposal.message),
                primaryButton: .default(Text("Apply")) {
                    config.maxHR = proposal.maxHR
                    config.restingHR = proposal.restingHR
                },
                secondaryButton: .cancel()
            )
        }
        .alert("Apple Health unavailable", isPresented: appleSyncErrorPresented) {
            Button("OK", role: .cancel) { appleSyncError = nil }
        } message: {
            Text(appleSyncError ?? "No recent heart-rate data was available.")
        }
    }

    // MARK: - Max / resting HR

    private var maxHRCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Your maximums")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    Stepper(value: $config.maxHR, in: 120...220) {
                        HStack {
                            Text("Max heart rate").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text("\(config.maxHR) bpm").font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.secondaryAccent)
                        }
                    }
                    Text(config.restingHR == nil
                         ? "Zones are calculated as a percentage of this value."
                         : "Zones use heart-rate reserve: resting HR plus a percentage of the gap to max.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    Divider().overlay(theme.separator)
                    Toggle(isOn: restingEnabled) {
                        Text("Track resting HR").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    }
                    .tint(theme.accent)
                    if config.restingHR != nil {
                        Stepper(value: restingBinding, in: 30...90) {
                            HStack {
                                Text("Resting heart rate").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                                Spacer()
                                Text("\(config.restingHR ?? 60) bpm").font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Zone preview

    private var zonesPreview: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Your zones")
            Card {
                VStack(spacing: Space.sm) {
                    ForEach(Array(stride(from: 5, through: 1, by: -1)), id: \.self) { zone in
                        HStack(spacing: Space.md) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(theme.zoneColor(zone))
                                .frame(width: 6, height: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(HRZone.label(zone)).font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                Text(zonePercentText(zone)).font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                            Text(rangeText(zone)).font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Zone lock cues

    private var zoneLockCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Zone lock")
            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Toggle(isOn: $zoneVoiceCues) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spoken cues").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                            Text("Speak “above zone 2” / “back in zone” aloud on the phone. Haptics fire either way, on phone and Watch.")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(theme.accent)
                    Text("Set a target zone from any cardio exercise before you start it.")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    // MARK: - Calibrate

    private var calibrateCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Calibrate")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    // Age estimate (220 − age)
                    Text("Estimate from age").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    if let age = healthAge {
                        Text("Apple Health says you're \(age) — estimated max HR \(HRZoneConfig.maxHR(forAge: age)) bpm.")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        SecondaryButton(title: "Use age estimate (\(HRZoneConfig.maxHR(forAge: age)) bpm)", systemImage: "sparkles") {
                            config.maxHR = HRZoneConfig.maxHR(forAge: age)
                        }
                    } else {
                        HStack {
                            TextField("Your age", text: $manualAge)
                                .keyboardType(.numberPad)
                                .padding(.vertical, 8).padding(.horizontal, 10)
                                .background(theme.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            SecondaryButton(title: "Apply", systemImage: "sparkles") {
                                if let age = Int(manualAge), (10...100).contains(age) {
                                    config.maxHR = HRZoneConfig.maxHR(forAge: age)
                                }
                            }
                        }
                    }
                    Divider().overlay(theme.separator)
                    Text("Apple Health").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text("Pull your latest resting heart rate and recent workout peak, then preview the updated zones before applying them.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecondaryButton(
                        title: syncingAppleHealth ? "Syncing…" : "Sync from Apple Health",
                        systemImage: "heart.text.square.fill"
                    ) {
                        syncFromAppleHealth()
                    }
                    .disabled(syncingAppleHealth)
                    Divider().overlay(theme.separator)
                    // Field test
                    Text("Field test").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text("Run an all-out effort while wearing your Apple Watch and we'll capture your true peak heart rate for a more accurate max.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PrimaryButton(title: "Start zone test", systemImage: "bolt.heart.fill") {
                        showFieldTest = true
                    }
                }
            }
        }
    }

    // MARK: - Advanced boundaries

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Button {
                withAnimation { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced: zone boundaries").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textTertiary)
                }
            }
            if showAdvanced {
                Card {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Edit each split as either percent or exact BPM. Both controls stay in sync.")
                            .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(0..<4, id: \.self) { index in
                            boundaryRow(index)
                        }
                        SecondaryButton(title: "Reset to standard (60·70·80·90)", systemImage: "arrow.counterclockwise") {
                            config.zoneUpperBounds = HRZoneConfig.defaultBounds
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bindings & helpers

    private var restingEnabled: Binding<Bool> {
        Binding(get: { config.restingHR != nil },
                set: { config.restingHR = $0 ? (config.restingHR ?? 60) : nil })
    }

    private var restingBinding: Binding<Int> {
        Binding(get: { config.restingHR ?? 60 }, set: { config.restingHR = $0 })
    }

    private var appleSyncErrorPresented: Binding<Bool> {
        Binding(get: { appleSyncError != nil }, set: { if !$0 { appleSyncError = nil } })
    }

    private func boundaryBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { Int((config.zoneUpperBounds[index] * 100).rounded()) },
            set: { newValue in
                var bounds = config.zoneUpperBounds
                bounds[index] = Double(newValue) / 100
                config.zoneUpperBounds = bounds
            }
        )
    }

    private func boundaryBPMBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { config.bpm(forFraction: config.zoneUpperBounds[index]) },
            set: { newValue in
                let range = boundaryBPMRange(index)
                let bpm = min(max(newValue, range.lowerBound), range.upperBound)
                var bounds = config.zoneUpperBounds
                bounds[index] = max(0, min(1, config.fraction(forBPM: bpm)))
                config.zoneUpperBounds = bounds
            }
        )
    }

    /// Keep each boundary strictly between its neighbours.
    private func boundaryRange(_ index: Int) -> ClosedRange<Int> {
        let lower = index == 0 ? 40 : Int((config.zoneUpperBounds[index - 1] * 100).rounded()) + 1
        let upper = index == 3 ? 99 : Int((config.zoneUpperBounds[index + 1] * 100).rounded()) - 1
        return lower...max(lower, upper)
    }

    private func boundaryBPMRange(_ index: Int) -> ClosedRange<Int> {
        let minBPM = config.restingHR ?? 40
        let lower = index == 0 ? minBPM : config.bpm(forFraction: config.zoneUpperBounds[index - 1]) + 1
        let upper = index == 3 ? config.maxHR - 1 : config.bpm(forFraction: config.zoneUpperBounds[index + 1]) - 1
        return lower...max(lower, upper)
    }

    private func boundaryRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: boundaryBinding(index), in: boundaryRange(index), step: 1) {
                HStack {
                    Text("Z\(index + 1)/Z\(index + 2) split")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                    Spacer()
                    Text("\(Int((config.zoneUpperBounds[index] * 100).rounded()))%")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                }
            }
            HStack(spacing: 8) {
                Text("BPM")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                TextField("BPM", value: boundaryBPMBinding(index), format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("bpm")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func rangeText(_ zone: Int) -> String {
        let range = config.rangeBPM(forZone: zone)
        return zone == 5 ? "\(range.lowerBound)+ bpm" : "\(range.lowerBound)–\(range.upperBound) bpm"
    }

    private func zonePercentText(_ zone: Int) -> String {
        let lower = zone == 1 ? 0 : Int((config.zoneUpperBounds[zone - 2] * 100).rounded())
        let upper = zone == 5 ? 100 : Int((config.zoneUpperBounds[zone - 1] * 100).rounded())
        return "\(lower)–\(upper)% of \(config.usesHeartRateReserve ? "HR reserve" : "max")"
    }

    private func save() {
        HRZoneConfigStore.save(config)
        WatchLink.shared.publishState()
        LiveMetricsHub.shared.reloadZoneConfig()
    }

    private func syncFromAppleHealth() {
        guard !syncingAppleHealth else { return }
        syncingAppleHealth = true
        Task {
            _ = await HealthService.shared.requestAuthorization()
            async let resting = HealthService.shared.latestRestingHR()
            async let walking = HealthService.shared.latestWalkingAverageHR()
            async let peak = HealthService.shared.recentPeakHeartRate(days: 90)
            let healthResting = await resting
            let walkingFallback = await walking
            let recentPeak = await peak
            await MainActor.run {
                syncingAppleHealth = false
                let resolvedResting = healthResting ?? walkingFallback ?? config.restingHR
                let resolvedMax = recentPeak ?? healthAge.map(HRZoneConfig.maxHR(forAge:)) ?? config.maxHR
                guard resolvedResting != nil || recentPeak != nil else {
                    appleSyncError = "ForgeFit could not find recent resting HR, walking HR, or workout peak HR in Apple Health."
                    return
                }
                appleSyncProposal = AppleHealthZoneSync(
                    maxHR: resolvedMax,
                    restingHR: resolvedResting,
                    maxSource: recentPeak == nil ? "fallback" : "peak from last 90 days",
                    restingSource: healthResting != nil ? "latest resting HR" : (walkingFallback != nil ? "walking HR fallback" : "existing value")
                )
            }
        }
    }
}

private struct AppleHealthZoneSync: Identifiable {
    let id = UUID()
    let maxHR: Int
    let restingHR: Int?
    let maxSource: String
    let restingSource: String

    var message: String {
        let restingText = restingHR.map { "\($0) bpm (\(restingSource))" } ?? "unchanged"
        return "Max HR: \(maxHR) bpm (\(maxSource)). Resting HR: \(restingText). Your zones will use heart-rate reserve when resting HR is set."
    }
}

// MARK: - Field test

/// A guided all-out effort that captures the highest heart rate streamed from
/// the Apple Watch, then offers to set it as the user's max HR.
struct HRZoneFieldTestView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let onCapture: (Int) -> Void

    /// A max-effort test needs actual pacing, not a bare "tell us when
    /// you're done" — warmup and cooldown are now real guided countdowns
    /// (previously just prose in the intro), and the effort phase advances
    /// itself so the only thing the user needs to do at max HR is run, not
    /// aim a thumb at a button.
    private enum Phase { case intro, warmup, effort, cooldown, done }
    /// Fixed at 3 minutes to match the pacing instructions ("~3 minutes,
    /// building to a sprint in the final 30 seconds") — this is the
    /// calibration protocol, not a user preference.
    private let effortSeconds = 180
    /// Below this, an "observed peak" almost certainly reflects a sensor
    /// glitch or a watch that wasn't actually worn, not a real max HR.
    private let plausibleRange = 100...230

    @State private var phase: Phase = .intro
    @State private var live = LiveMetricsHub.shared
    @State private var peakHR = 0
    @State private var phaseEndsAt: Date?
    @State private var warmupMinutes = 10
    @State private var cooldownMinutes = 3
    @State private var autoAdvanceTask: Task<Void, Never>?
    @State private var showCloseConfirm = false
    @State private var showLowPeakConfirm = false

    private var isMidTest: Bool {
        phase == .warmup || phase == .effort || phase == .cooldown
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    switch phase {
                    case .intro: intro
                    case .warmup: timedPhase(
                        title: "Warm up",
                        detail: "Easy effort — jog, spin, or row to raise your heart rate gradually.",
                        tint: theme.secondaryAccent,
                        skipTitle: "Skip warmup"
                    )
                    case .effort: effortPhase
                    case .cooldown: timedPhase(
                        title: "Cool down",
                        detail: "Easy effort until your heart rate settles.",
                        tint: theme.secondaryAccent,
                        skipTitle: "Skip cooldown"
                    )
                    case .done: done
                    }
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Zone test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if isMidTest { showCloseConfirm = true } else { finishAndDismiss() }
                    }
                }
            }
            .confirmationDialog("End this test?", isPresented: $showCloseConfirm, titleVisibility: .visible) {
                Button("End Test", role: .destructive) { finishAndDismiss() }
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text("Your progress and observed peak heart rate will be lost.")
            }
        }
        .onChange(of: live.liveMetrics?.heartRate) { _, hr in trackPeak(hr) }
        .onChange(of: live.liveMetrics?.maxHR) { _, hr in trackPeak(hr) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label("Wear your Apple Watch", systemImage: "applewatch")
                .font(.bodyStrong).foregroundStyle(theme.textPrimary)
            Text("We'll guide you through a warmup, a ~3 minute max effort — building to an absolute sprint in the final 30 seconds — and a cooldown. Peak heart rate is captured automatically.")
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Card(fill: theme.danger.opacity(0.12)) {
                HStack(alignment: .top, spacing: Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger)
                    Text("A max-effort test is strenuous. Only do this if you're healthy and cleared for vigorous exercise. Stop if you feel dizzy, short of breath, or chest pain. This is an estimate, not a medical test.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Warmup length").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                SegmentedPills(options: [5, 10, 15], title: { "\($0) min" }, selection: $warmupMinutes)
            }
            PrimaryButton(title: "Start test", systemImage: "bolt.heart.fill", tint: theme.danger) {
                start()
            }
        }
    }

    /// Shared layout for the warmup and cooldown phases: a countdown, a live
    /// HR readout, and a way to move on early. Effort has its own view since
    /// it also tracks and shows the peak.
    private func timedPhase(title: String, detail: String, tint: Color, skipTitle: String) -> some View {
        VStack(spacing: Space.lg) {
            Text(title.uppercased()).font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
            // Purely cosmetic — the phase actually ends via the Task scheduled
            // in beginPhase(), not by this view noticing zero (avoids a
            // double-advance race between the two).
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Fmt.restTimer(remainingSeconds(at: ctx.date)))
                    .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill").foregroundStyle(theme.danger).font(.system(size: 13))
                Text(live.liveMetrics?.heartRate.map(String.init) ?? "—")
                    .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                Text("bpm").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            }
            Text(detail)
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: skipTitle, systemImage: "forward.end.fill") { advance() }
        }
        .frame(maxWidth: .infinity)
    }

    private var effortPhase: some View {
        VStack(spacing: Space.lg) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let remaining = remainingSeconds(at: ctx.date)
                let finalSprint = remaining <= 30
                VStack(spacing: Space.lg) {
                    Text(finalSprint ? "FINAL SPRINT!" : "MAX EFFORT")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(finalSprint ? theme.danger : theme.textSecondary)
                        .contentTransition(.numericText())
                    // Purely cosmetic — see the note in timedPhase(): the
                    // Task in beginPhase() owns the actual transition.
                    Text(Fmt.restTimer(remaining))
                        .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(finalSprint ? theme.danger : theme.textPrimary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "heart.fill").foregroundStyle(theme.danger)
                            .symbolEffect(.pulse, isActive: true)
                        Text(live.liveMetrics?.heartRate.map(String.init) ?? "—")
                            .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                        Text("bpm").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    }
                }
            }
            StatColumn(label: "Peak so far", value: peakHR > 0 ? "\(peakHR) bpm" : "—", valueColor: theme.secondaryAccent)
            if live.liveMetrics?.heartRate == nil {
                Text("Waiting for heart rate… make sure the ForgeFit watch app opened into a workout, or that your heart rate monitor is connected and broadcasting.")
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            SecondaryButton(title: "End effort now", systemImage: "forward.end.fill") { advance() }
        }
        .frame(maxWidth: .infinity)
    }

    private var done: some View {
        VStack(spacing: Space.lg) {
            if peakHR > 0 {
                Text("Observed peak").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                Text("\(peakHR)").font(.system(size: 64, weight: .bold, design: .rounded)).foregroundStyle(theme.secondaryAccent)
                Text("bpm").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                if !plausibleRange.contains(peakHR) {
                    Card(fill: theme.danger.opacity(0.12)) {
                        HStack(alignment: .top, spacing: Space.sm) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger)
                            Text("This is unusual for a max heart rate — make sure your Watch was worn snugly and tracking. Using it anyway will skew every training zone.")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                PrimaryButton(title: "Use \(peakHR) bpm as my max HR", systemImage: "checkmark.seal.fill") {
                    if plausibleRange.contains(peakHR) {
                        onCapture(peakHR)
                        finishAndDismiss()
                    } else {
                        showLowPeakConfirm = true
                    }
                }
                SecondaryButton(title: "Discard") { finishAndDismiss() }
            } else {
                Image(systemName: "heart.slash").font(.system(size: 40)).foregroundStyle(theme.textTertiary)
                Text("No heart rate was recorded. Make sure your Apple Watch is on your wrist with the ForgeFit watch app in a workout — or that your heart rate monitor is connected and broadcasting — then try again.")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                SecondaryButton(title: "Done") { finishAndDismiss() }
            }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("Use \(peakHR) bpm anyway?", isPresented: $showLowPeakConfirm, titleVisibility: .visible) {
            Button("Use \(peakHR) bpm anyway", role: .destructive) {
                onCapture(peakHR)
                finishAndDismiss()
            }
            Button("Discard instead", role: .cancel) {}
        } message: {
            Text("This value is outside the normal range for a max heart rate and will skew every training zone.")
        }
    }

    private func remainingSeconds(at date: Date) -> Int {
        guard let phaseEndsAt else { return 0 }
        return max(0, Int(phaseEndsAt.timeIntervalSince(date).rounded(.up)))
    }

    private func start() {
        peakHR = 0
        // Nudge the watch into a live run so it starts streaming heart rate.
        HealthService.shared.startWatchApp(cardioKind: .run)
        beginPhase(.warmup, seconds: warmupMinutes * 60)
    }

    private func beginPhase(_ next: Phase, seconds: Int) {
        autoAdvanceTask?.cancel()
        phase = next
        phaseEndsAt = Date().addingTimeInterval(TimeInterval(seconds))
        autoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            advance()
        }
    }

    /// Moves to the next phase — used both by the countdown reaching zero and
    /// by the manual Skip/End-now escape hatches, since both mean the same
    /// thing: this phase is over.
    private func advance() {
        switch phase {
        case .intro: break
        case .warmup: beginPhase(.effort, seconds: effortSeconds)
        case .effort: beginPhase(.cooldown, seconds: cooldownMinutes * 60)
        case .cooldown:
            autoAdvanceTask?.cancel()
            phaseEndsAt = nil
            phase = .done
        case .done: break
        }
    }

    private func trackPeak(_ hr: Int?) {
        // Only the effort phase's HR counts toward peak — a warmup or
        // cooldown spike (dropped signal, moving the watch) shouldn't be
        // mistaken for max effort.
        guard phase == .effort, let hr, hr > peakHR, hr < 240 else { return }
        peakHR = hr
    }

    private func finishAndDismiss() {
        autoAdvanceTask?.cancel()
        live.clearLiveMetrics()
        dismiss()
    }
}
