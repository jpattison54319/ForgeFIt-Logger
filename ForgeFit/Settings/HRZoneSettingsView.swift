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
                    Text("Zones are calculated as a percentage of this value.")
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
                        ForEach(0..<4, id: \.self) { index in
                            Stepper(value: boundaryBinding(index), in: boundaryRange(index), step: 1) {
                                HStack {
                                    Text("Z\(index + 1)/Z\(index + 2) split").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                                    Spacer()
                                    Text("\(Int((config.zoneUpperBounds[index] * 100).rounded()))%")
                                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                                }
                            }
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

    /// Keep each boundary strictly between its neighbours.
    private func boundaryRange(_ index: Int) -> ClosedRange<Int> {
        let lower = index == 0 ? 40 : Int((config.zoneUpperBounds[index - 1] * 100).rounded()) + 1
        let upper = index == 3 ? 99 : Int((config.zoneUpperBounds[index + 1] * 100).rounded()) - 1
        return lower...max(lower, upper)
    }

    private func rangeText(_ zone: Int) -> String {
        let range = config.rangeBPM(forZone: zone)
        return zone == 5 ? "\(range.lowerBound)+ bpm" : "\(range.lowerBound)–\(range.upperBound) bpm"
    }

    private func zonePercentText(_ zone: Int) -> String {
        let lower = zone == 1 ? 0 : Int((config.zoneUpperBounds[zone - 2] * 100).rounded())
        let upper = zone == 5 ? 100 : Int((config.zoneUpperBounds[zone - 1] * 100).rounded())
        return "\(lower)–\(upper)% of max"
    }

    private func save() {
        HRZoneConfigStore.save(config)
        WatchLink.shared.publishState()
    }
}

// MARK: - Field test

/// A guided all-out effort that captures the highest heart rate streamed from
/// the Apple Watch, then offers to set it as the user's max HR.
struct HRZoneFieldTestView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let onCapture: (Int) -> Void

    private enum Phase { case intro, running, done }
    @State private var phase: Phase = .intro
    @State private var watch = WatchLink.shared
    @State private var peakHR = 0
    @State private var startedAt = Date()

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    switch phase {
                    case .intro: intro
                    case .running: running
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
                    Button("Close") { finishAndDismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: watch.liveMetrics?.heartRate) { _, hr in trackPeak(hr) }
        .onChange(of: watch.liveMetrics?.maxHR) { _, hr in trackPeak(hr) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label("Wear your Apple Watch", systemImage: "applewatch")
                .font(.bodyStrong).foregroundStyle(theme.textPrimary)
            Text("Warm up for 10 minutes. Then run (or bike) as hard as you can sustain for ~3 minutes — ideally uphill — building to an absolute sprint in the final 30 seconds. We'll record your peak heart rate.")
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
            PrimaryButton(title: "Start test", systemImage: "bolt.heart.fill", tint: theme.danger) {
                start()
            }
        }
    }

    private var running: some View {
        VStack(spacing: Space.lg) {
            Text("Recording peak HR").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.danger)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill").foregroundStyle(theme.danger)
                    .symbolEffect(.pulse, isActive: true)
                Text(watch.liveMetrics?.heartRate.map(String.init) ?? "—")
                    .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                Text("bpm").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
            }
            HStack(spacing: Space.xl) {
                StatColumn(label: "Peak", value: peakHR > 0 ? "\(peakHR)" : "—", valueColor: theme.secondaryAccent)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    StatColumn(label: "Elapsed", value: Fmt.elapsed(max(0, Int(ctx.date.timeIntervalSince(startedAt)))))
                }
            }
            if watch.liveMetrics?.heartRate == nil {
                Text("Waiting for heart rate from your Watch… make sure the ForgeFit watch app opened into a workout.")
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            PrimaryButton(title: "Finish", systemImage: "checkmark", tint: theme.success) {
                phase = .done
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var done: some View {
        VStack(spacing: Space.lg) {
            if peakHR > 0 {
                Text("Observed peak").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                Text("\(peakHR)").font(.system(size: 64, weight: .bold, design: .rounded)).foregroundStyle(theme.secondaryAccent)
                Text("bpm").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                PrimaryButton(title: "Use \(peakHR) bpm as my max HR", systemImage: "checkmark.seal.fill") {
                    onCapture(peakHR)
                    finishAndDismiss()
                }
                SecondaryButton(title: "Discard") { finishAndDismiss() }
            } else {
                Image(systemName: "heart.slash").font(.system(size: 40)).foregroundStyle(theme.textTertiary)
                Text("No heart rate was recorded. Make sure your Apple Watch is on your wrist and the ForgeFit watch app started a workout, then try again.")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                SecondaryButton(title: "Done") { finishAndDismiss() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func start() {
        peakHR = 0
        startedAt = Date()
        phase = .running
        // Nudge the watch into a live run so it starts streaming heart rate.
        HealthService.shared.startWatchApp(cardioKind: .run)
    }

    private func trackPeak(_ hr: Int?) {
        guard phase == .running, let hr, hr > peakHR, hr < 240 else { return }
        peakHR = hr
    }

    private func finishAndDismiss() {
        watch.clearLiveMetrics()
        dismiss()
    }
}
