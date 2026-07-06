import ForgeCore
import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A branded, full-length snapshot of a completed workout, designed to be
/// rendered to an image and shared ("save a full-length screenshot"). Takes an
/// explicit `AppTheme` so it renders correctly off-screen where the environment
/// isn't injected.
struct WorkoutShareCard: View {
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let theme: AppTheme

    private var summary: TrainingAnalytics.Summary {
        TrainingAnalytics(workouts: [workout], exercises: exercises).summary(for: workout)
    }
    private var sortedExercises: [WorkoutExerciseModel] {
        workout.exercises.sorted { $0.position < $1.position }
    }
    private func library(_ we: WorkoutExerciseModel) -> ExerciseLibraryModel? {
        exercises.first { $0.id == we.exerciseID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            statBlock
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
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary)
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

    // MARK: - Strength

    private func strengthBlock(_ we: WorkoutExerciseModel) -> some View {
        let unit = library(we)?.effectiveWeightUnit ?? Fmt.unit
        let sets = we.sets.sorted { $0.position < $1.position }
        var working = 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(library(we)?.name ?? "Exercise")
                .font(.system(size: 17, weight: .bold)).foregroundStyle(theme.textPrimary)
            ForEach(sets) { set in
                let style = SetTypeStyle.of(set.setType)
                let label: String = {
                    if style.numbered { working += 1; return "\(working)\(style.badge)" }
                    return style.badge
                }()
                HStack {
                    Text(label).font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textSecondary).frame(width: 34, alignment: .leading)
                    Text(setValue(set, unit: unit)).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
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
        let reps = set.reps.map { "\($0) reps" } ?? "—"
        guard let weight = set.weight, weight > 0 else { return reps }
        return "\(Fmt.load(weight, unit: unit)) \(unit.suffix) × \(set.reps ?? 0)"
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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "dumbbell.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.accent)
            Text("Tracked with ForgeFit").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textSecondary)
            Spacer()
            if let readiness = workout.readinessAtStart {
                Text("Readiness \(readiness)%").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Rendering & sharing

@MainActor
enum WorkoutShareRenderer {
    /// Render the full-length share card to an image at retina scale.
    static func image(for workout: WorkoutModel, exercises: [ExerciseLibraryModel], theme: AppTheme) -> UIImage? {
        let renderer = ImageRenderer(content: WorkoutShareCard(workout: workout, exercises: exercises, theme: theme))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// A plain-text summary for share targets that prefer text (Messages, etc.).
    static func text(for workout: WorkoutModel, exercises: [ExerciseLibraryModel]) -> String {
        let summary = TrainingAnalytics(workouts: [workout], exercises: exercises).summary(for: workout)
        var lines = [workout.title ?? "Workout", workout.startedAt.formatted(date: .abbreviated, time: .shortened)]
        lines.append("⏱ \(Fmt.durationShort(summary.durationSeconds))")
        if summary.isCardio {
            if let d = workout.cardioSessions.first?.distanceMeters, d > 0 { lines.append("📍 \(Fmt.distance(d))") }
            if let hr = summary.avgHR { lines.append("❤️ \(hr) bpm avg") }
        } else {
            lines.append("🏋️ \(Fmt.volume(summary.volume)) · \(summary.sets) sets")
        }
        lines.append("— Tracked with ForgeFit")
        return lines.joined(separator: "\n")
    }
}

#if canImport(UIKit)
/// Standard iOS share sheet — lets the user save the workout image to Photos or
/// send it anywhere.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
