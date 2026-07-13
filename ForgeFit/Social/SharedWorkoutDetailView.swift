import ForgeData
import SwiftUI

/// Read-only view of a friend's shared workout, reconstructed from the
/// sanitized `SharedWorkoutDTO` payload. Includes the like control.
struct SharedWorkoutDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(SocialService.self) private var social
    let ref: SocialWorkoutRef
    var ownerName: String

    @State private var dto: SharedWorkoutDTO?
    @State private var likeCount = 0
    @State private var hasLiked = false
    @State private var loaded = false

    var body: some View {
        ScreenScaffold(ref.title ?? "Workout", trailing: { EmptyView() }) {
            summaryCard
            likeBar
            if let dto {
                ForEach(dto.exercises, id: \.id) { exercise in
                    exerciseCard(exercise)
                }
            } else if loaded {
                EmptyStateCard(title: "Couldn't load", message: "This workout is no longer available.", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Space.lg)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("\(ownerName) · \(ref.startedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                HStack(spacing: Space.lg) {
                    stat("Volume", Fmt.volume(ref.summary.volumeKg))
                    stat("Sets", "\(ref.summary.workingSets)")
                    stat("Reps", "\(ref.summary.reps)")
                    stat("Time", Fmt.durationShort(ref.summary.durationSeconds))
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
