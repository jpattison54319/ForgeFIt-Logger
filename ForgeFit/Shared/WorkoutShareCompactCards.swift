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
    private var presentationPlan: WorkoutPresentationPlan { .make(for: workout) }
    private var sessions: [CardioSessionModel] {
        workout.cardioSessions.filter { $0.deletedAt == nil }
    }
    private var conditioningContexts: [ConditioningSharePresentation.Context] {
        ConditioningSharePresentation.contexts(for: workout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chrome.header(
                title: workout.title ?? "Workout",
                date: workout.startedAt,
                compact: true,
                systemImage: shape.systemImage
            )
            ShareHeroRow(workout: workout, exercises: exercises, summary: summary, shape: shape, theme: theme)
            if shape == .conditioning,
               conditioningContexts.count == 1,
               let context = conditioningContexts.first,
               context.result != nil {
                ConditioningShareBlock(
                    plan: context.plan,
                    result: context.result,
                    exercises: exercises,
                    theme: theme,
                    compact: true,
                    showsResult: false,
                    showsModalityHeader: true
                )
            } else if shape == .conditioning,
                      conditioningContexts.isEmpty,
                      sessions.contains(where: { $0.isConditioningSession && $0.endedAt != nil }) {
                conditioningSessionWork
            } else if shape == .yoga,
                      sessions.count(where: { $0.isYogaSession && $0.endedAt != nil }) == 1 {
                yogaWork
            } else if presentationPlan.hasModalityBlocks
                        || (presentationPlan.isMixed
                            && (!presentationPlan.modalities.isDisjoint(with: [.conditioning, .yoga]))) {
                orderedBlockWork
            } else {
                switch shape {
                case .strength, .hybrid: strengthWork
                case .cardio: cardioWork
                case .conditioning: EmptyView()
                case .yoga: yogaWork
                }
            }
            Spacer(minLength: 0)
            chrome.footer()
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
        .background(theme.background)
    }

    private var conditioningSessionWork: some View {
        let completed = sessions.filter { $0.isConditioningSession && $0.endedAt != nil }
        return chrome.surfaceBlock {
            ForEach(Array(completed.enumerated()), id: \.element.id) { index, session in
                HStack(spacing: 8) {
                    Image(systemName: "figure.cross.training")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.warmup)
                    Text(completed.count == 1 ? "Conditioning" : "Conditioning \(index + 1)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 4)
                    Text(Fmt.durationShort(session.durationSeconds))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var orderedBlockWork: some View {
        let items = presentationPlan.items
        return chrome.surfaceBlock {
            ForEach(Array(items.prefix(7).enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 7) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 14, alignment: .leading)
                    Image(systemName: compactIcon(item))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(compactTint(item))
                        .frame(width: 16)
                    Text(compactName(item))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(compactSummary(item))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            if items.count > 7 {
                Text("+\(items.count - 7) more")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func compactName(_ item: WorkoutPresentationPlan.Item) -> String {
        switch item {
        case .exercise(let exercise):
            if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == exercise.id }),
               session.isYogaSession {
                return YogaHistoryPresentation.title(
                    session: session,
                    plan: YogaFlowPlan.decode(from: exercise.yogaFlowJSON),
                    exercise: exercises.first { $0.id == exercise.exerciseID }
                )
            }
            if let plan = YogaFlowPlan.decode(from: exercise.yogaFlowJSON) {
                return plan.steps.count == 1 ? plan.steps[0].name : "\(plan.style.title) Yoga"
            }
            return exercises.first { $0.id == exercise.exerciseID }?.name ?? "Exercise"
        case .block(let block): return block.kind.title
        case .legacyConditioning: return "Conditioning"
        case .session(let session, _):
            if session.isYogaSession { return "\(session.resolvedYogaStyle.title) Yoga" }
            if session.isConditioningSession { return "Conditioning" }
            return CardioKind.from(modality: session.modality).title
        }
    }

    private func compactIcon(_ item: WorkoutPresentationPlan.Item) -> String {
        switch item {
        case .exercise(let exercise):
            if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == exercise.id }) {
                if session.isYogaSession { return "figure.yoga" }
                if session.isConditioningSession { return "figure.cross.training" }
                return CardioKind.from(modality: session.modality).systemImage
            }
            if YogaFlowPlan.decode(from: exercise.yogaFlowJSON) != nil { return "figure.yoga" }
            return "dumbbell.fill"
        case .block(let block): return block.kind == .yoga ? "figure.yoga" : "stopwatch"
        case .legacyConditioning: return "figure.cross.training"
        case .session(let session, _):
            if session.isYogaSession { return "figure.yoga" }
            if session.isConditioningSession { return "figure.cross.training" }
            return CardioKind.from(modality: session.modality).systemImage
        }
    }

    private func compactTint(_ item: WorkoutPresentationPlan.Item) -> Color {
        switch item {
        case .block(let block) where block.kind == .conditioning: return theme.warmup
        case .block: return theme.accent
        case .legacyConditioning: return theme.warmup
        case .session(let session, _) where session.isConditioningSession: return theme.warmup
        case .session(let session, _) where session.isYogaSession: return theme.accent
        case .exercise(let exercise):
            if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == exercise.id }),
               session.isYogaSession {
                return theme.accent
            }
            if YogaFlowPlan.decode(from: exercise.yogaFlowJSON) != nil { return theme.accent }
            return theme.secondaryAccent
        case .session: return theme.secondaryAccent
        }
    }

    private func compactSummary(_ item: WorkoutPresentationPlan.Item) -> String {
        switch item {
        case .exercise(let exercise):
            if let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == exercise.id }) {
                if session.isYogaSession {
                    guard session.endedAt != nil else { return "Skipped" }
                    return YogaHistoryPresentation.compactSummary(
                        session: session,
                        plan: YogaFlowPlan.decode(from: exercise.yogaFlowJSON)
                    )
                }
                return Fmt.durationShort(session.durationSeconds)
            }
            if YogaFlowPlan.decode(from: exercise.yogaFlowJSON) != nil { return "Skipped" }
            return "\(exercise.sets.filter { $0.completedAt != nil }.count) sets"
        case .block(let block):
            if block.kind == .conditioning,
               let plan = ConditioningPlan.decode(from: block.planSnapshotJSON) {
                return compactConditioningSummary(
                    plan: plan,
                    result: ConditioningResult.decode(from: block.resultJSON),
                    session: workout.cardioSessions.first { $0.workoutBlockID == block.id }
                )
            }
            let session = workout.cardioSessions.first { $0.workoutBlockID == block.id }
            guard let session, session.endedAt != nil else { return "Skipped" }
            return YogaHistoryPresentation.compactSummary(
                session: session,
                plan: YogaFlowPlan.decode(from: block.planSnapshotJSON)
            )
        case .legacyConditioning(let conditioning):
            return compactConditioningSummary(
                plan: conditioning.plan,
                result: conditioning.result,
                session: workout.cardioSessions.first { $0.isConditioningSession && $0.workoutBlockID == nil }
            )
        case .session(let session, _):
            if session.isYogaSession {
                guard session.endedAt != nil else { return "Skipped" }
                return YogaHistoryPresentation.compactSummary(session: session, plan: nil)
            }
            return Fmt.durationShort(session.durationSeconds)
        }
    }

    private func compactConditioningSummary(
        plan: ConditioningPlan,
        result: ConditioningResult?,
        session: CardioSessionModel?
    ) -> String {
        guard result != nil else { return "Skipped" }
        guard let section = plan.sections.first else { return "No work recorded" }
        let score: String?
        if let sectionResult = result?.sectionResults.first {
            score = ConditioningSharePresentation.score(sectionResult)
        } else if let session {
            score = Fmt.durationShort(session.durationSeconds)
        } else {
            score = nil
        }
        let context = ConditioningSharePresentation.Context(plan: plan, result: result)
        let completion = ConditioningSharePresentation.completionStatus(for: context)
        let status = completion == .completed ? nil : completion.label
        return [status, score, ConditioningSharePresentation.prescription(section)]
            .compactMap { $0 }
            .joined(separator: " · ")
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
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(block.name)
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            if let group = block.supersetGroup {
                                Text(SupersetUI.label(for: group))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(SupersetUI.color(for: group))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(SupersetUI.color(for: group).opacity(0.16), in: Capsule())
                            }
                        }
                        ForEach(Array(block.lines.enumerated()), id: \.offset) { index, line in
                            let style = SetTypeStyle.of(line.type)
                            HStack(spacing: 8) {
                                Text(line.label)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(line.type == .working ? theme.textSecondary : style.color)
                                    .frame(width: 28, alignment: .leading)
                                Text(line.value)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                if line.type != .working {
                                    Text(style.label)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(style.color)
                                }
                                // Folded onto the top-set line: a row of its
                                // own spent the card's scarcest resource
                                // (height) on a footnote.
                                if index == block.lines.count - 1, block.extraSets > 0 {
                                    Text("+\(block.extraSets) more")
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                                }
                                Spacer(minLength: 0)
                            }
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
        let session = sessions.first { $0.isYogaSession && $0.endedAt != nil }
        let plan = session.flatMap(yogaPlan)
        let poses = YogaHistoryPresentation.poses(session: session, plan: plan)
        let exposure = FlexibilityAnalytics.decodeExposure(session?.flexibilityExposureJSON)
            .sorted { $0.value > $1.value }
            .prefix(5)
        let maxSeconds = exposure.map(\.value).max() ?? 1
        return chrome.surfaceBlock {
            HStack(spacing: 8) {
                Image(systemName: "figure.yoga")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.secondaryAccent)
                Text(session.map {
                    YogaHistoryPresentation.title(session: $0, plan: plan, exercise: nil)
                } ?? "Yoga")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
            }
            if !poses.isEmpty {
                ForEach(Array(poses.prefix(6))) { pose in
                    HStack(spacing: 8) {
                        Text(pose.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        if let detail = pose.sideDetail {
                            Text(detail)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Text(Fmt.durationShort(pose.durationSeconds))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                if poses.count > 6 {
                    Text("+\(poses.count - 6) more poses")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                }
            } else if exposure.isEmpty {
                HStack(spacing: 10) {
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

    private func yogaPlan(for session: CardioSessionModel) -> YogaFlowPlan? {
        if let blockID = session.workoutBlockID,
           let block = workout.blocks.first(where: { $0.id == blockID }) {
            return YogaFlowPlan.decode(from: block.planSnapshotJSON)
        }
        if let exerciseID = session.workoutExerciseID,
           let exercise = workout.exercises.first(where: { $0.id == exerciseID }) {
            return YogaFlowPlan.decode(from: exercise.yogaFlowJSON)
        }
        return nil
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
        VStack(alignment: .leading, spacing: 10) {
            chrome.header(
                title: workout.title ?? "Workout",
                date: workout.startedAt,
                compact: true,
                systemImage: shape.systemImage
            )
            // Compact stat strip, not the big tile hero — this card's identity
            // is physiology; the oversized duration/volume tiles belong to the
            // other cards, and the tiles pushed this one past its fixed height.
            ShareHeroRow(
                workout: workout,
                exercises: exercises,
                summary: summary,
                shape: shape,
                theme: theme,
                compact: true
            )
            chrome.surfaceBlock {
                if !hrSamples.isEmpty {
                    chrome.blockTitle("Heart rate", systemImage: "waveform.path.ecg", color: theme.danger) {
                        if let peak = hrSamples.map(\.bpm).max() {
                            Text("peak \(peak) bpm")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.danger)
                        }
                    }
                    HeartRateTrendChart(
                        samples: hrSamples,
                        bands: HeartRateTrendChart.cardioBands(for: workout),
                        height: 96
                    )
                    .environment(\.theme, theme)
                }
                if zoneSeconds.contains(where: { $0 > 0 }) {
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
            } else if shape.supportsBetweenSetRecovery,
                      let bestDrop = recoveryPoints.compactMap(\.recoveryBPM).max() {
                chrome.miniStat("Best drop", "▼\(bestDrop) bpm")
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
        var tiles = WorkoutOverviewPresentation.make(
            workout: workout,
            exercises: exercises,
            durationSeconds: summary.durationSeconds
        ).facts.map { ($0.label, $0.value) }
        if tiles.count < 4, let kcal = workout.activeEnergyKcal {
            tiles.append(("Energy", "\(Int(kcal)) kcal"))
        }
        if tiles.count < 4, let avgHR = workout.avgHR ?? summary.avgHR {
            tiles.append(("Avg HR", "\(avgHR)"))
        }
        if tiles.count < 4,
           WorkoutPresentationPlan.make(for: workout).modalities == [.strength],
           let topMuscle {
            tiles.append(("Focus", topMuscle))
        }
        while tiles.count < 4 { tiles.append(("Status", "Complete")) }
        return Array(tiles.prefix(4))
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
                chrome.header(
                    title: workout.title ?? "Workout",
                    date: workout.startedAt,
                    compact: true,
                    systemImage: shape.systemImage
                )
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

/// The hero row all compact cards open with, adapted to shape — big tiles by
/// default, a thin miniStat strip when `compact` (the metrics card trades the
/// tiles for chart room).
private struct ShareHeroRow: View {
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let summary: TrainingAnalytics.Summary
    let shape: WorkoutShareShape
    let theme: AppTheme
    var compact = false

    private var chrome: ShareCardChrome { ShareCardChrome(theme: theme) }

    private var entries: [(label: String, value: String, color: Color)] {
        WorkoutOverviewPresentation.make(
            workout: workout,
            exercises: exercises,
            durationSeconds: summary.durationSeconds
        ).facts.prefix(3).map { fact in
            let color: Color = switch fact.label {
            case "Time", "Score", "Conditioning": theme.accent
            case "Work", "Volume", "Distance", "Cardio": theme.secondaryAccent
            case "Avg HR": theme.danger
            default: theme.textPrimary
            }
            return (fact.label, fact.value, color)
        }
    }

    var body: some View {
        HStack(spacing: compact ? 12 : 10) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                if compact {
                    chrome.miniStat(entry.label, entry.value)
                } else {
                    chrome.stat(entry.label, entry.value, entry.color)
                }
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
        var type: SetType
    }

    struct StrengthBlock: Equatable {
        var name: String
        var supersetGroup: Int?
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

    /// Verified visually against the 4:5 canvas: five top-set entries plus a
    /// cardio line fill it; six overflow.
    static let maxExercises = 5

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
        let ordered = WorkoutPresentationPlan.make(for: workout).visibleExercises
        let strengthExercises = ordered.filter { cardioByExercise[$0.id] == nil }
        let completedSetCount = strengthExercises
            .flatMap(\.sets)
            .filter { HistoricalSetPresentation.isCompleted($0) }
            .count
        let showAllSets = strengthExercises.count <= 5 && completedSetCount <= lineBudget
        // Exactly `maxExercises` fits; a "+N more" line does not fit *below*
        // them — so an over-full list gives up one entry to make room for it.
        let cap = strengthExercises.count > maxExercises ? maxExercises - 1 : maxExercises

        var entries: [Entry] = []
        var shownExercises = 0
        var moreExercises = 0
        for we in ordered {
            if let session = cardioByExercise[we.id] {
                entries.append(.cardio(session))
                continue
            }
            guard shownExercises < cap else {
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
                    value: HistoricalSetPresentation.shareValue(set, unit: unit),
                    type: set.setType
                )
            }
            return StrengthBlock(name: name, supersetGroup: we.supersetGroup, lines: lines, extraSets: 0)
        }
        // Top set = the completed set moving the most weight; work sets
        // outrank warm-ups at equal volume by coming later in the list.
        let top = completed.max { a, b in
            (a.element.totalVolume ?? 0, a.offset) < (b.element.totalVolume ?? 0, b.offset)
        }
        guard let top else { return StrengthBlock(name: name, supersetGroup: we.supersetGroup, lines: [], extraSets: 0) }
        let line = SetLine(
            label: "Top",
            value: HistoricalSetPresentation.shareValue(top.element, unit: unit),
            type: top.element.setType
        )
        return StrengthBlock(name: name, supersetGroup: we.supersetGroup, lines: [line], extraSets: max(0, completed.count - 1))
    }
}
