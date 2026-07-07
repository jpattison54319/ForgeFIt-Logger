import ForgeCore
import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A branded, full-length snapshot of a completed workout, designed to be
/// rendered to a single tall image and shared / saved to Photos. Mirrors every
/// section the user sees on `WorkoutDetailView` — summary, session metrics, HR
/// graph, between-set recovery, muscles worked, and the full set log — so the
/// shared picture is a faithful capture of the workout, not a trimmed summary.
///
/// Takes an explicit `AppTheme` (and the already-loaded HealthKit-derived
/// `hrSamples` / `recoveryPoints`) so it renders correctly off-screen where the
/// environment and async loads aren't available.
struct WorkoutShareCard: View {
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme
    var hrSamples: [(date: Date, bpm: Int)] = []
    var recoveryPoints: [SetRecoveryPoint] = []
    /// Pre-rendered GPS route map per cardio session id (MapKit can't be
    /// rasterized off-screen, so the map is snapshotted before rendering).
    var routeMaps: [UUID: UIImage] = [:]

    /// Point size of the embedded route map — the cardio block's content width
    /// (card 430 − 28·2 padding − 16·2 block padding) at a 16:9-ish ratio.
    static let routeMapSize = CGSize(width: 342, height: 190)

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: [workout], exercises: exercises) }
    private var summary: TrainingAnalytics.Summary { analytics.summary(for: workout) }
    private var sortedExercises: [WorkoutExerciseModel] {
        workout.exercises.sorted { $0.position < $1.position }
    }
    private func library(_ we: WorkoutExerciseModel) -> ExerciseLibraryModel? {
        exercises.first { $0.id == we.exerciseID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statBlock
            if workout.avgHR != nil || workout.activeEnergyKcal != nil || workout.readinessAtStart != nil {
                sessionMetricsBlock
            }
            if !hrSamples.isEmpty {
                heartRateBlock
            }
            if recoveryPoints.contains(where: { $0.recoveryBPM != nil }) {
                recoveryBlock
            }
            if !summary.isCardio {
                let muscles = analytics.muscleVolume(for: workout)
                if !muscles.isEmpty { muscleBlock(muscles) }
            }
            Rectangle().fill(theme.separator).frame(height: 1)
            ForEach(sortedExercises) { we in
                if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == we.id }) {
                    cardioBlock(we, session)
                } else {
                    strengthBlock(we)
                }
            }
            // Legacy cardio sessions not linked to an exercise.
            ForEach(workout.cardioSessions.filter { $0.workoutExerciseID == nil }) { session in
                cardioBlock(nil, session)
            }
            footer
        }
        .padding(28)
        .frame(width: 430, alignment: .leading)
        .background(theme.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.accent)
                Image(systemName: "dumbbell.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.title ?? "Workout")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.label).foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Stat block

    private var statBlock: some View {
        HStack(spacing: 12) {
            stat("Duration", Fmt.durationShort(summary.durationSeconds), theme.textPrimary)
            if summary.isCardio {
                stat("Distance", Fmt.distance(workout.cardioSessions.first?.distanceMeters), theme.secondaryAccent)
                stat("Avg HR", summary.avgHR.map { "\($0)" } ?? "—", theme.danger)
            } else {
                stat("Volume", Fmt.volume(summary.volume), theme.secondaryAccent)
                stat("Sets", "\(summary.sets)", theme.textPrimary)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.uppercased()).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Session metrics

    private var sessionMetricsBlock: some View {
        surfaceBlock {
            blockTitle("Session metrics", systemImage: "heart.fill", color: theme.danger) {
                if let readiness = workout.readinessAtStart {
                    Text("Started \(readiness)% ready")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.readinessColor(Double(readiness) / 100))
                }
            }
            HStack(spacing: 12) {
                miniStat("Avg HR", Fmt.bpm(workout.avgHR))
                miniStat("Max HR", Fmt.bpm(workout.maxHR))
                miniStat("Energy", workout.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "—")
            }
            if workout.hrZoneSeconds.contains(where: { $0 > 0 }) {
                ZoneSecondsBar(zoneSeconds: workout.hrZoneSeconds)
            }
        }
    }

    // MARK: - Heart rate graph

    private var heartRateBlock: some View {
        surfaceBlock {
            blockTitle("Heart rate", systemImage: "waveform.path.ecg", color: theme.danger) {
                if let peak = hrSamples.map(\.bpm).max() {
                    Text("peak \(peak) bpm")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.danger)
                }
            }
            HeartRateTrendChart(samples: hrSamples)
        }
    }

    // MARK: - Between-set recovery

    private var recoveryBlock: some View {
        let dict = Dictionary(recoveryPoints.map { ($0.setID, $0) }, uniquingKeysWith: { first, _ in first })
        let drops = recoveryPoints.compactMap(\.recoveryBPM)
        let avg = drops.isEmpty ? 0 : Int((Double(drops.reduce(0, +)) / Double(drops.count)).rounded())
        let best = drops.max() ?? 0
        let maxDrop = max(1, best)
        return surfaceBlock {
            blockTitle("Between-set recovery", systemImage: "arrow.down.heart.fill", color: theme.danger) { EmptyView() }
            HStack(spacing: 12) {
                miniStat("Avg drop", "\(avg) bpm")
                miniStat("Best drop", "\(best) bpm")
                miniStat("Sets", "\(drops.count)")
            }
            ForEach(sortedExercises.filter { we in workout.cardioSessions.allSatisfy { $0.workoutExerciseID != we.id } }) { we in
                let sets = we.sets.sorted { $0.position < $1.position }
                let rows = Array(sets.enumerated()).compactMap { index, set -> (String, SetRecoveryPoint)? in
                    dict[set.id].map { (numberedLabel(for: set, index: index, sets: sets), $0) }
                }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(library(we)?.name ?? "Exercise")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                Text(row.0).font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.textSecondary).frame(width: 30, alignment: .leading)
                                Text("\(row.1.peakHR) bpm peak")
                                    .font(.tag).foregroundStyle(theme.textPrimary)
                                    .frame(width: 92, alignment: .leading)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(theme.surfaceHighlight)
                                        Capsule().fill(theme.success)
                                            .frame(width: geo.size.width * CGFloat(row.1.recoveryBPM ?? 0) / CGFloat(maxDrop))
                                    }
                                }
                                .frame(height: 7)
                                Text(row.1.recoveryBPM.map { "▼\($0)" } ?? "—")
                                    .font(.tag)
                                    .foregroundStyle(row.1.recoveryBPM != nil ? theme.success : theme.textTertiary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Muscles worked

    private func muscleBlock(_ rows: [(muscle: String, sets: Double)]) -> some View {
        let maxSets = rows.map(\.sets).max() ?? 1
        return surfaceBlock {
            blockTitle("Muscles worked", systemImage: "figure.strengthtraining.traditional", color: theme.accent) { EmptyView() }
            VStack(spacing: 7) {
                ForEach(rows, id: \.muscle) { row in
                    VStack(spacing: 4) {
                        HStack {
                            Text(row.muscle.capitalized).font(.label).foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text("\(row.sets.formatted(.number.precision(.fractionLength(0...1)))) sets")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.surfaceHighlight)
                                Capsule().fill(theme.accent)
                                    .frame(width: geo.size.width * (row.sets / max(1, maxSets)))
                            }
                        }
                        .frame(height: 7)
                    }
                }
            }
        }
    }

    // MARK: - Strength

    private func strengthBlock(_ we: WorkoutExerciseModel) -> some View {
        let unit = library(we)?.effectiveWeightUnit ?? Fmt.unit
        let sets = we.sets.sorted { $0.position < $1.position }
        return VStack(alignment: .leading, spacing: 8) {
            Text(library(we)?.name ?? "Exercise")
                .font(.system(size: 17, weight: .bold)).foregroundStyle(theme.textPrimary)
            if let notes = we.notes, !notes.isEmpty {
                Text(notes).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            // Deterministic per-set numbering (no mutable counter) — ImageRenderer
            // evaluates the body more than once, so a running `var` double-counts.
            ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                let style = SetTypeStyle.of(set.setType)
                let label = numberedLabel(for: set, index: index, sets: sets)
                HStack(spacing: 8) {
                    Text(label).font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(set.setType == .working ? theme.textSecondary : style.color)
                        .frame(width: 34, alignment: .leading)
                    Text(setValue(set, unit: unit)).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    if set.setType != .working {
                        Text(style.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.color)
                    }
                    Spacer(minLength: 0)
                    if let rpe = set.rpe {
                        Text("RPE \(rpe.formatted(.number.precision(.fractionLength(0...1))))")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    } else if let rir = set.rir {
                        Text("\(rir) RIR")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    }
                    if set.completedAt != nil {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(theme.success)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func setValue(_ set: SetModel, unit: WeightUnit) -> String {
        if !set.miniReps.isEmpty {
            let activation = set.reps.map(String.init)
            let minis = set.miniReps.map(String.init).joined(separator: "+")
            let reps = [activation, minis].compactMap(\.self).joined(separator: "+")
            guard let weight = set.weight, weight > 0 else { return "\(reps) reps" }
            return "\(Fmt.load(weight, unit: unit)) \(unit.suffix) × \(reps)"
        }
        if let seconds = set.durationSeconds, seconds > 0 {
            return Fmt.durationShort(seconds)
        }
        let reps = set.reps.map { "\($0)" } ?? "—"
        guard let weight = set.weight, weight > 0 else { return "\(reps) reps" }
        return "\(Fmt.load(weight, unit: unit)) \(unit.suffix) × \(reps)"
    }

    // MARK: - Cardio

    private func cardioBlock(_ we: WorkoutExerciseModel?, _ session: CardioSessionModel) -> some View {
        let kind = CardioKind.from(modality: session.modality)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kind.systemImage).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.secondaryAccent)
                Text(we.flatMap { library($0)?.name } ?? kind.title)
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(theme.textPrimary)
            }
            HStack(spacing: 10) {
                if let d = session.distanceMeters, d > 0 { chip("Distance", Fmt.distance(d)) }
                chip("Time", Fmt.durationShort(session.durationSeconds))
                if session.distanceMeters ?? 0 > 0 {
                    chip(kind.usesPace ? "Pace" : "Speed",
                         kind.usesPace
                            ? CardioMetrics.paceString(distanceMeters: session.distanceMeters, durationSeconds: session.durationSeconds, kind: kind)
                            : CardioMetrics.speedString(distanceMeters: session.distanceMeters, durationSeconds: session.durationSeconds))
                }
                if let hr = session.avgHR { chip("Avg HR", "\(hr)") }
            }
            if let map = routeMaps[session.id] {
                Image(uiImage: map)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.separator, lineWidth: 1)
                    )
            }
            let zones = session.hrZoneSeconds
            if zones.reduce(0, +) > 0 {
                zoneBar(zones)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func chip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
            Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(theme.textTertiary)
        }
    }

    private func zoneBar(_ zones: [Int]) -> some View {
        let total = max(1, zones.reduce(0, +))
        return HStack(spacing: 2) {
            ForEach(Array(zones.enumerated()), id: \.offset) { index, seconds in
                if seconds > 0 {
                    theme.zoneColor(index + 1)
                        .frame(width: max(3, 360 * (Double(seconds) / Double(total))), height: 8)
                }
            }
        }
        .clipShape(Capsule())
    }

    // MARK: - Shared building blocks

    @ViewBuilder
    private func surfaceBlock<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func blockTitle<Trailing: View>(_ title: String, systemImage: String, color: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.textPrimary)
            Spacer(minLength: 0)
            trailing()
        }
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberedLabel(for set: SetModel, index: Int, sets: [SetModel]) -> String {
        let style = SetTypeStyle.of(set.setType)
        guard style.numbered else { return style.badge.isEmpty ? "•" : style.badge }
        let number = sets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
        return "\(number)\(style.badge)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "dumbbell.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.accent)
            Text("Tracked with ForgeFit").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(.top, 2)
    }
}

// MARK: - Rendering & sharing

@MainActor
enum ShareRenderer {
    /// Render any share card to a retina-scale image. Injects the theme into the
    /// environment so environment-reading subviews (charts, zone bars) render
    /// correctly off-screen.
    static func image<V: View>(_ content: V, theme: AppTheme) -> UIImage? {
        let renderer = ImageRenderer(content: content.environment(\.theme, theme))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

@MainActor
enum WorkoutShareRenderer {
    /// Render the full-length share card to a single tall image at retina scale.
    static func image(
        for workout: WorkoutModel,
        exercises: [ExerciseLibraryModel],
        theme: AppTheme,
        hrSamples: [(date: Date, bpm: Int)] = [],
        recoveryPoints: [SetRecoveryPoint] = [],
        routeMaps: [UUID: UIImage] = [:]
    ) -> UIImage? {
        ShareRenderer.image(
            WorkoutShareCard(
                workout: workout,
                exercises: exercises,
                theme: theme,
                hrSamples: hrSamples,
                recoveryPoints: recoveryPoints,
                routeMaps: routeMaps
            ),
            theme: theme
        )
    }
}

#if canImport(UIKit)
/// Standard iOS share sheet — lets the user save the image to Photos or send it
/// anywhere. Sharing a single `UIImage` surfaces the "Save Image" action.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper so any rendered share image can drive `.sheet(item:)`.
struct ShareImagePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}
#endif
