import ForgeData
import SwiftUI

/// Read-only view of a friend's shared workout, reconstructed from the
/// sanitized `SharedWorkoutDTO` payload. Includes the like control.
struct SharedWorkoutDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(SocialService.self) private var social
    let ref: SocialWorkoutRef
    var ownerName: String

    @State private var dto: SharedWorkoutDTO?
    @State private var likeCount = 0
    @State private var hasLiked = false
    @State private var loaded = false

    var body: some View {
        DashboardScaffold(title: ref.title ?? "Workout", dismiss: dismiss) {
            summaryCard
            likeBar
            if let dto {
                // Strength exercises (those with sets); cardio/yoga wrappers are
                // empty shells whose data lives in the sessions below.
                ForEach(dto.exercises.filter { !$0.sets.isEmpty }, id: \.id) { exercise in
                    exerciseCard(exercise)
                }
                ForEach(dto.cardioSessions, id: \.id) { session in
                    cardioCard(session)
                }
            } else if loaded {
                EmptyStateCard(title: "Couldn't load", message: "This workout is no longer available.", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Space.lg)
            }
        }
        .task { await load() }
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("\(ownerName) · \(ref.startedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                HStack(spacing: Space.lg) {
                    switch ref.summary.kind {
                    case "cardio":
                        stat("Time", Fmt.durationShort(ref.summary.durationSeconds))
                        if ref.summary.distanceMeters > 0 { stat("Distance", Fmt.distance(ref.summary.distanceMeters)) }
                    case "yoga":
                        stat("Time", Fmt.durationShort(ref.summary.durationSeconds))
                        if let poses = dto?.cardioSessions.first(where: \.isYoga)?.posesCompleted { stat("Poses", "\(poses)") }
                    default:
                        stat("Volume", Fmt.volume(ref.summary.volumeKg))
                        stat("Sets", "\(ref.summary.workingSets)")
                        stat("Reps", "\(ref.summary.reps)")
                        stat("Time", Fmt.durationShort(ref.summary.durationSeconds))
                    }
                }
            }
        }
    }

    private func cardioCard(_ session: SharedCardioSessionDTO) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(session.isYoga ? (session.yogaStyleRaw?.capitalized ?? "Yoga") : session.modality.capitalized)
                    .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                HStack(spacing: Space.lg) {
                    if let d = session.durationSeconds { stat("Time", Fmt.durationShort(d)) }
                    if session.isYoga {
                        if let poses = session.posesCompleted { stat("Poses", "\(poses)") }
                    } else {
                        if let dist = session.distanceMeters, dist > 0 { stat("Distance", Fmt.distance(dist)) }
                        if let pace = session.avgPaceSecondsPerKm, pace > 0 { stat("Pace", "\(Fmt.restTimer(Int(pace)))/km") }
                        if let watts = session.avgPowerWatts, watts > 0 { stat("Power", "\(Int(watts))w") }
                    }
                    if let effort = session.effort { stat("Effort", "\(effort)/10") }
                }
            }
        }
    }

    private var likeBar: some View {
        Button {
            Task { await toggleLike() }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: hasLiked ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(hasLiked ? theme.danger : theme.textSecondary)
                Text(likeCount == 1 ? "1 like" : "\(likeCount) likes")
                    .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
            }
            .padding(Space.md)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasLiked ? "Unlike workout" : "Like workout")
    }

    private func exerciseCard(_ exercise: SharedExerciseDTO) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(exercise.name.isEmpty ? "Exercise" : exercise.name)
                    .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                    HStack(spacing: Space.md) {
                        Text(setLabel(set, index: index))
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textSecondary)
                            .frame(width: 34, alignment: .leading)
                        Text(loadText(set))
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(theme.textPrimary)
                        Spacer()
                    }
                }
            }
        }
    }

    private func setLabel(_ set: SharedSetDTO, index: Int) -> String {
        set.setType == "warmup" ? "W" : "\(index + 1)"
    }

    private func loadText(_ set: SharedSetDTO) -> String {
        let reps = set.reps.map(String.init) ?? "—"
        if let kg = set.weightKg { return "\(Fmt.load(kg)) \(Fmt.unit.shortSuffix) × \(reps)" }
        return "\(reps) reps"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
            Text(label).font(.system(size: 11)).foregroundStyle(theme.textTertiary)
        }
    }

    private func load() async {
        dto = await social.workoutDetail(id: ref.id)
        likeCount = await social.likeCount(workoutID: ref.id)
        hasLiked = await social.hasLiked(workoutID: ref.id)
        loaded = true
    }

    private func toggleLike() async {
        hasLiked.toggle()
        likeCount += hasLiked ? 1 : -1
        await social.setLike(hasLiked, workoutID: ref.id)
    }
}
