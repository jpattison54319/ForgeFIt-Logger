import ForgeData
import SwiftData
import SwiftUI

/// Floating iOS 26 Liquid Glass app bar: a single clear-glass capsule with a
/// fluid "expanding pill" indicator. Unselected tabs are outline glyphs;
/// the selected tab grows to reveal its label inside an accent pill that morphs
/// between tabs.
struct ForgeTabBar: View {
    @Environment(\.theme) private var theme
    @Binding var selection: AppTab
    @Query(filter: #Predicate<ExerciseLibraryModel> { $0.needsReview == true })
    private var importedExercisesNeedingReview: [ExerciseLibraryModel]
    @Namespace private var pill

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(AppTab.allCases) { tab in
                    item(tab)
                }
            }
            .padding(5)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(.horizontal, Space.xl)
    }

    private func item(_ tab: AppTab) -> some View {
        let isSelected = tab == selection
        let badgeCount = tab == .profile ? reviewCount : 0
        return Button {
            withAnimation(.bouncy(duration: 0.42, extraBounce: 0.06)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: tab.systemImage)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolEffect(.bounce, value: isSelected)
                if isSelected {
                    Text(tab.title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize()
                        .transition(.opacity.combined(with: .blurReplace))
                }
            }
            .overlay(alignment: .topTrailing) {
                if badgeCount > 0 {
                    Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .padding(.horizontal, badgeCount > 9 ? 5 : 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(theme.danger, in: Capsule())
                        .offset(x: 8, y: -7)
                        .accessibilityLabel("\(badgeCount) imported exercises need review")
                }
            }
            .foregroundStyle(isSelected ? Color.white : theme.textSecondary)
            .padding(.vertical, 11)
            .padding(.horizontal, isSelected ? 17 : 15)
            .background {
                if isSelected {
                    ActiveTabGlassPill()
                        .matchedGeometryEffect(id: "tab-pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-\(tab.rawValue)")
    }

    private var reviewCount: Int {
        importedExercisesNeedingReview.count { $0.ownerID != nil && $0.deletedAt == nil }
    }
}

private struct ActiveTabGlassPill: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Capsule()
            .fill(theme.accent.opacity(0.08))
            .glassEffect(.regular.tint(theme.accent.opacity(0.22)).interactive(), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.32),
                                theme.accent.opacity(0.45),
                                Color.white.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: theme.accent.opacity(0.22), radius: 10, y: 3)
    }
}

/// Minimized active-workout bar shown above the tab bar (Hevy's "Workout 7s"
/// pill). Tapping it re-opens the full logger; the trash discards.
struct MiniWorkoutBar: View {
    @Environment(\.theme) private var theme
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let onExpand: () -> Void
    let onDiscard: () -> Void

    private var subtitle: String {
        let names = workout.exercises
            .sorted { $0.position < $1.position }
            .compactMap { ex in exercises.first { $0.id == ex.exerciseID }?.name }
        return names.first ?? (workout.title ?? "Workout")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(workout.startedAt)))
            GlassEffectContainer(spacing: Space.sm) {
                HStack(spacing: Space.md) {
                    Button(action: onExpand) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)

                    Button(action: onExpand) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Circle().fill(theme.success).frame(width: 8, height: 8)
                                Text("Workout")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(theme.textPrimary)
                                Text(Fmt.elapsed(elapsed))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(theme.textSecondary)
                                    .monospacedDigit()
                            }
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDiscard) {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.danger)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .tint(theme.danger)
                    .accessibilityIdentifier("discard-active-workout")
                }
                .padding(8)
                .glassEffect(.regular.tint(theme.accent.opacity(0.16)), in: Capsule())
                .overlay(Capsule().stroke(theme.accent.opacity(0.32), lineWidth: 1))
                .shadow(color: .black.opacity(0.42), radius: 14, y: 5)
            }
        }
    }
}
