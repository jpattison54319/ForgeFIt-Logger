import ForgeCore
import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The three fixed-size social share cards. Each has one identity that holds
/// across every workout shape — Training Log is *the work you did*, Metrics is
/// *what your body did*, Minimal is *the brag* — and adapts its modules to the
/// shape rather than changing what it's about. All are rendered off-screen by
/// `ShareRenderer` at 3× (4:5 → 1080×1350, 1:1 → 1080×1080).

// MARK: - Training log (4:5)

struct WorkoutShareCardTrainingLog: View {
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme
    var routeMaps: [UUID: UIImage] = [:]

    static let size = CGSize(width: 360, height: 450)

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: [workout], exercises: exercises) }
    private var summary: TrainingAnalytics.Summary { analytics.summary(for: workout) }
    private var shape: WorkoutShareShape { .of(workout: workout, summary: summary) }
    private var chrome: ShareCardChrome { ShareCardChrome(theme: theme) }
    private var sessions: [CardioSessionModel] {
        workout.cardioSessions.filter { $0.deletedAt == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chrome.header(title: workout.title ?? "Workout", date: workout.startedAt, compact: true)
            ShareHeroRow(workout: workout, summary: summary, shape: shape, theme: theme)
            switch shape {
            case .strength, .hybrid: strengthWork
            case .cardio: cardioWork
            case .yoga: yogaWork
            }
            Spacer(minLength: 0)
            chrome.footer()
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
        .background(theme.background)
    }

    // MARK: Strength / hybrid

    private var strengthWork: some View {
        let plan = ShareTrainingLogPlan.make(
            workout: workout,
            exercises: exercises,
            // Hybrid gives up set lines to the cardio rows below.
            lineBudget: shape == .hybrid ? 12 - 2 * min(sessions.count, 2) : 14
        )
        return chrome.surfaceBlock {
            ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .strength(let block):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(block.name)
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 8) {
                                Text(line.label)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.textSecondary)
                                    .frame(width: 28, alignment: .leading)
                                Text(line.value)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                Spacer(minLength: 0)
                            }
                        }
                        if block.extraSets > 0 {
                            Text("+\(block.extraSets) more set\(block.extraSets == 1 ? "" : "s")")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                        }
                    }
                case .cardio(let session):
                    cardioLine(session)
                }
            }
            if plan.moreExercises > 0 {
                Text("+\(plan.moreExercises) more exercise\(plan.moreExercises == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textSecondary)
            }
        }
    }

    /// A cardio effort inside a hybrid session, as a single line in position.
    private func cardioLine(_ session: CardioSessionModel) -> some View {
        let kind = CardioKind.from(modality: session.modality)
        var parts: [String] = [Fmt.durationShort(session.durationSeconds)]
        if let d = session.distanceMeters, d > 0 { parts.append(Fmt.distance(d)) }
        if let hr = session.avgHR { parts.append("\(hr) bpm") }
        return HStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 12, weight: .bold)).foregroundStyle(theme.secondaryAccent)
            Text(exerciseName(for: session) ?? kind.title)
                .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(parts.joined(separator: " · "))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func exerciseName(for session: CardioSessionModel) -> String? {
        guard let weID = session.workoutExerciseID,
              let we = workout.exercises.first(where: { $0.id == weID }) else { return nil }
        return exercises.first { $0.id == we.exerciseID }?.name
    }

    // MARK: Cardio

    /// Splits are the cardio set list. One session gets the full treatment
    /// (map + splits); additional sessions compress to lines.
    private var cardioWork: some View {
        let primary = sessions.max { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
        return VStack(alignment: .leading, spacing: 10) {
            if let primary {
                chrome.surfaceBlock {
                    HStack(spacing: 8) {
                        let kind = CardioKind.from(modality: primary.modality)
                        Image(systemName: kind.systemImage)
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.secondaryAccent)
                        Text(exerciseName(for: primary) ?? kind.title)
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.textPrimary)
                        Spacer(minLength: 0)
                        if let hr = primary.avgHR {
                            Text("\(hr) bpm avg")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.danger)
                        }
                    }
                    if sessions.count == 1, let map = routeMaps[primary.id] {
                        Image(uiImage: map)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    splitsTable(primary)
                }
            }
            ForEach(sessions.filter { $0.id != primary?.id }) { session in
                chrome.surfaceBlock { cardioLine(session) }
            }
        }
    }

    @ViewBuilder
    private func splitsTable(_ session: CardioSessionModel) -> some View {
        let allSplits = session.splits.sorted { $0.index < $1.index }
        let splits = allSplits.prefix(routeMaps[session.id] != nil ? 5 : 8)
        if splits.isEmpty {
            // No laps recorded — the zone bar stands in as the effort story.
            if session.hrZoneSeconds.contains(where: { $0 > 0 }) {
                ZoneSecondsBar(zoneSeconds: session.hrZoneSeconds)
                    .environment(\.theme, theme)
            }
        } else {
            let slowest = splits.map(\.paceSecondsPerKm).max() ?? 1
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(splits.enumerated()), id: \.offset) { index, split in
                    HStack(spacing: 8) {
                        Text(split.label ?? "\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: split.label == nil ? 20 : 58, alignment: .leading)
                        Text(CardioMetrics.paceString(distanceMeters: split.distanceMeters, durationSeconds: split.durationSeconds))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            .frame(width: 70, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.surfaceHighlight)
                                Capsule().fill(theme.secondaryAccent)
                                    .frame(width: geo.size.width * CGFloat(min(1, (slowest > 0 ? split.paceSecondsPerKm / slowest : 0))))
                            }
                        }
                        .frame(height: 6)
                    }
                }
                if allSplits.count > splits.count {
                    Text("+\(allSplits.count - splits.count) more")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    // MARK: Yoga

    /// The yoga log: what you practiced and which regions got time under
    /// stretch — the pose-work analog of a set list.
    private var yogaWork: some View {
        let session = sessions.first { $0.isYogaSession }
        let exposure = FlexibilityAnalytics.decodeExposure(session?.flexibilityExposureJSON)
            .sorted { $0.value > $1.value }
            .prefix(5)
        let maxSeconds = exposure.map(\.value).max() ?? 1
        return chrome.surfaceBlock {
            HStack(spacing: 8) {
                Image(systemName: "figure.yoga")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.secondaryAccent)
                Text(session?.yogaStyleRaw?.capitalized ?? "Yoga")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                if let poses = session?.posesCompleted, poses > 0 {
                    Text("\(poses) poses")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
                }
            }
            if exposure.isEmpty {
                HStack(spacing: 10) {
                    chrome.chip("Time", Fmt.durationShort(session?.durationSeconds))
                    if let kcal = session?.activeEnergyKcal { chrome.chip("Energy", "\(Int(kcal)) kcal") }
                    if let hr = session?.avgHR { chrome.chip("Avg HR", "\(hr)") }
                }
            } else {
                Text("Time under stretch").font(.tag).foregroundStyle(theme.textSecondary)
                ForEach(Array(exposure.enumerated()), id: \.offset) { _, region in
                    HStack(spacing: 8) {
                        Text(region.key.capitalized)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            .frame(width: 96, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.surfaceHighlight)
                                Capsule().fill(theme.secondaryAccent)
                                    .frame(width: geo.size.width * CGFloat(Double(region.value) / Double(max(1, maxSeconds))))
                            }
                        }
                        .frame(height: 6)
                        Text(Fmt.durationShort(region.value))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Metrics (4:5)

struct WorkoutShareCardMetrics: View {
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme
    var hrSamples: [(date: Date, bpm: Int)] = []
    var recoveryPoints: [SetRecoveryPoint] = []

    static let size = CGSize(width: 360, height: 450)

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: [workout], exercises: exercises) }
    private var summary: TrainingAnalytics.Summary { analytics.summary(for: workout) }
    private var shape: WorkoutShareShape { .of(workout: workout, summary: summary) }
    private var chrome: ShareCardChrome { ShareCardChrome(theme: theme) }

    /// Workout-level zones, falling back to the sessions' own arrays for
    /// cardio-only workouts logged before workout-level zones existed.
    private var zoneSeconds: [Int] {
        if workout.hrZoneSeconds.contains(where: { $0 > 0 }) { return workout.hrZoneSeconds }
        let sessionZones = workout.cardioSessions.filter { $0.deletedAt == nil }.map(\.hrZoneSeconds)
        guard let first = sessionZones.first(where: { !$0.isEmpty }) else { return [] }
        return sessionZones.reduce(into: [Int](repeating: 0, count: first.count)) { total, zones in
            for (index, seconds) in zones.enumerated() where index < total.count {
                total[index] += seconds
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chrome.header(title: workout.title ?? "Workout", date: workout.startedAt, compact: true)
            ShareHeroRow(workout: workout, summary: summary, shape: shape, theme: theme)
            if !hrSamples.isEmpty {
                chrome.surfaceBlock {
                    chrome.blockTitle("Heart rate", systemImage: "waveform.path.ecg", color: theme.danger) {
                        if let peak = hrSamples.map(\.bpm).max() {
                            Text("peak \(peak) bpm")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.danger)
                        }
                    }
                    HeartRateTrendChart(
                        samples: hrSamples,
                        bands: HeartRateTrendChart.cardioBands(for: workout),
                        height: 118
                    )
                    .environment(\.theme, theme)
                }
            }
            if zoneSeconds.contains(where: { $0 > 0 }) {
                chrome.surfaceBlock {
                    ZoneSecondsBar(zoneSeconds: zoneSeconds, totalDurationSeconds: summary.durationSeconds)
                        .environment(\.theme, theme)
                }
            }
            chipsRow
            Spacer(minLength: 0)
            chrome.footer()
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
        .background(theme.background)
    }

    private var chipsRow: some View {
        chrome.surfaceBlock {
            HStack(spacing: 12) {
                if let readiness = workout.readinessAtStart {
                    chrome.miniStat("Readiness", "\(readiness)%")
                }
                if let kcal = workout.activeEnergyKcal {
                    chrome.miniStat("Energy", "\(Int(kcal)) kcal")
                }
                if let avg = workout.avgHR {
                    chrome.miniStat("Avg / Max HR", "\(avg) / \(workout.maxHR.map(String.init) ?? "—")")
                }
                if shape == .cardio {
                    if let session = workout.cardioSessions.first(where: { $0.deletedAt == nil }),
                       session.distanceMeters ?? 0 > 0 {
                        chrome.miniStat(
                            "Pace",
                            CardioMetrics.paceString(distanceMeters: session.distanceMeters, durationSeconds: session.durationSeconds)
                        )
                    }
                } else if let bestDrop = recoveryPoints.compactMap(\.recoveryBPM).max() {
                    chrome.miniStat("Best drop", "▼\(bestDrop) bpm")
                }
            }
        }
    }
}

// MARK: - Minimal (1:1)

struct WorkoutShareCardMinimal: View {
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme

    static let size = CGSize(width: 360, height: 360)

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: [workout], exercises: exercises) }
    private var summary: TrainingAnalytics.Summary { analytics.summary(for: workout) }
    private var shape: WorkoutShareShape { .of(workout: workout, summary: summary) }
    private var chrome: ShareCardChrome { ShareCardChrome(theme: theme) }

    /// Always four tiles — missing data falls through to the next best fact.
    private var stats: [(label: String, value: String)] {
        var tiles: [(String, String)] = [("Duration", Fmt.durationShort(summary.durationSeconds))]
        let kcal = workout.activeEnergyKcal.map { "\(Int($0)) kcal" }
        let sessions = workout.cardioSessions.filter { $0.deletedAt == nil }
        let distance = sessions.compactMap(\.distanceMeters).reduce(0, +)
        switch shape {
        case .strength:
            tiles.append(("Volume", Fmt.volume(summary.volume)))
            tiles.append(("Sets", "\(summary.sets)"))
            tiles.append(("Energy", kcal ?? topMuscle ?? "—"))
        case .hybrid:
            tiles.append(("Volume", Fmt.volume(summary.volume)))
            tiles.append(("Sets", "\(summary.sets)"))
            tiles.append(distance > 0 ? ("Distance", Fmt.distance(distance)) : ("Energy", kcal ?? "—"))
        case .cardio:
            let single = sessions.count == 1 ? sessions.first : nil
            tiles.append(("Distance", distance > 0 ? Fmt.distance(distance) : "—"))
            if let single, single.distanceMeters ?? 0 > 0 {
                tiles.append(("Pace", CardioMetrics.paceString(distanceMeters: single.distanceMeters, durationSeconds: single.durationSeconds)))
            } else {
                tiles.append(("Avg HR", workout.avgHR.map(String.init) ?? summary.avgHR.map(String.init) ?? "—"))
            }
            tiles.append(("Energy", kcal ?? "—"))
        case .yoga:
            let session = sessions.first { $0.isYogaSession }
            tiles.append(("Poses", session?.posesCompleted.map(String.init) ?? "—"))
            tiles.append(("Style", session?.yogaStyleRaw?.capitalized ?? "Yoga"))
            tiles.append(("Energy", kcal ?? "—"))
        }
        return tiles
    }

    private var topMuscle: String? {
        analytics.muscleVolume(for: workout).first?.muscle.capitalized
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: shape.systemImage)
                .font(.system(size: 150, weight: .bold))
                .foregroundStyle(theme.accent.opacity(0.06))
                .offset(x: 24, y: 24)
            VStack(alignment: .leading, spacing: 0) {
                chrome.header(title: workout.title ?? "Workout", date: workout.startedAt, compact: true)
                Spacer(minLength: 0)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 22) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, tile in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tile.value.uppercased())
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.5)
                            Text(tile.label.uppercased())
                                .font(.system(size: 10, weight: .heavy)).foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
                chrome.footer()
            }
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
        .background(theme.background)
    }
}

// MARK: - Shared hero row

/// The three-tile hero row all compact cards open with, adapted to shape.
private struct ShareHeroRow: View {
    let workout: WorkoutModel
    let summary: TrainingAnalytics.Summary
    let shape: WorkoutShareShape
    let theme: AppTheme

    private var chrome: ShareCardChrome { ShareCardChrome(theme: theme) }

    var body: some View {
        HStack(spacing: 10) {
            chrome.stat("Duration", Fmt.durationShort(summary.durationSeconds), theme.textPrimary)
            switch shape {
            case .strength, .hybrid:
                chrome.stat("Volume", Fmt.volume(summary.volume), theme.secondaryAccent)
                chrome.stat("Sets", "\(summary.sets)", theme.textPrimary)
            case .cardio:
                let sessions = workout.cardioSessions.filter { $0.deletedAt == nil }
                let distance = sessions.compactMap(\.distanceMeters).reduce(0, +)
                chrome.stat("Distance", distance > 0 ? Fmt.distance(distance) : "—", theme.secondaryAccent)
                if sessions.count == 1, let session = sessions.first, session.distanceMeters ?? 0 > 0 {
                    chrome.stat(
                        "Pace",
                        CardioMetrics.paceString(distanceMeters: session.distanceMeters, durationSeconds: session.durationSeconds),
                        theme.textPrimary
                    )
                } else {
                    chrome.stat("Avg HR", workout.avgHR.map(String.init) ?? summary.avgHR.map(String.init) ?? "—", theme.danger)
                }
            case .yoga:
                let session = workout.cardioSessions.first { $0.deletedAt == nil && $0.isYogaSession }
                chrome.stat("Poses", session?.posesCompleted.map(String.init) ?? "—", theme.secondaryAccent)
                chrome.stat("Style", session?.yogaStyleRaw?.capitalized ?? "Yoga", theme.textPrimary)
            }
        }
    }
}

// MARK: - Training-log layout plan

/// Pure layout math for the training-log card, kept out of the view so the
/// budget rules are testable: every completed set when the session is small,
/// top set + "+N" per exercise as it grows, "+N more exercises" past the cap.
enum ShareTrainingLogPlan {
    struct SetLine: Equatable {
        var label: String
        var value: String
    }

    struct StrengthBlock: Equatable {
        var name: String
        var lines: [SetLine]
        var extraSets: Int
    }

    enum Entry {
        case strength(StrengthBlock)
        case cardio(CardioSessionModel)
    }

    struct Plan {
        var entries: [Entry]
        var moreExercises: Int
    }

    static let maxExercises = 6

    static func make(
        workout: WorkoutModel,
        exercises: [ExerciseLibraryModel],
        lineBudget: Int
    ) -> Plan {
        let cardioByExercise = Dictionary(
            workout.cardioSessions.filter { $0.deletedAt == nil }.compactMap { session in
                session.workoutExerciseID.map { ($0, session) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let ordered = workout.exercises.sorted { $0.position < $1.position }
        let strengthExercises = ordered.filter { cardioByExercise[$0.id] == nil }
        let completedSetCount = strengthExercises
            .flatMap(\.sets)
            .filter { HistoricalSetPresentation.isCompleted($0) }
            .count
        let showAllSets = strengthExercises.count <= 5 && completedSetCount <= lineBudget

        var entries: [Entry] = []
        var shownExercises = 0
        var moreExercises = 0
        for we in ordered {
            if let session = cardioByExercise[we.id] {
                entries.append(.cardio(session))
                continue
            }
            guard shownExercises < maxExercises else {
                moreExercises += 1
                continue
            }
            shownExercises += 1
            entries.append(.strength(block(for: we, exercises: exercises, showAllSets: showAllSets)))
        }
        return Plan(entries: entries, moreExercises: moreExercises)
    }

    private static func block(
        for we: WorkoutExerciseModel,
        exercises: [ExerciseLibraryModel],
        showAllSets: Bool
    ) -> StrengthBlock {
        let library = exercises.first { $0.id == we.exerciseID }
        let unit = library?.effectiveWeightUnit ?? Fmt.unit
        let sets = we.sets.sorted { $0.position < $1.position }
        let completed = sets.enumerated().filter { HistoricalSetPresentation.isCompleted($0.element) }
        let name = library?.name ?? "Exercise"

        if showAllSets {
            let lines = completed.map { index, set in
                SetLine(
                    label: ShareSetLabels.numberedLabel(for: set, index: index, sets: sets),
                    value: HistoricalSetPresentation.shareValue(set, unit: unit)
                )
            }
            return StrengthBlock(name: name, lines: lines, extraSets: 0)
        }
        // Top set = the completed set moving the most weight; work sets
        // outrank warm-ups at equal volume by coming later in the list.
        let top = completed.max { a, b in
            (a.element.totalVolume ?? 0, a.offset) < (b.element.totalVolume ?? 0, b.offset)
        }
        guard let top else { return StrengthBlock(name: name, lines: [], extraSets: 0) }
        let line = SetLine(
            label: "Top",
            value: HistoricalSetPresentation.shareValue(top.element, unit: unit)
        )
        return StrengthBlock(name: name, lines: [line], extraSets: max(0, completed.count - 1))
    }
}
