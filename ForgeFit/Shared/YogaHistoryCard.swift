import ForgeCore
import ForgeData
import SwiftUI

/// Yoga history uses practice vocabulary and folds left/right timing rows back
/// into one pose. In mixed workouts it becomes the same visible disclosure
/// pattern as cardio and conditioning; a yoga-only workout stays open.
struct YogaHistoryCard: View {
    let plan: YogaFlowPlan?
    let session: CardioSessionModel?
    let workoutExercise: WorkoutExerciseModel?
    let exercise: ExerciseLibraryModel?
    let hrSamples: [(date: Date, bpm: Int)]
    var heartRateMetrics: WorkoutHeartRateResolution.Metrics? = nil
    let collapsible: Bool

    @Environment(\.theme) private var theme
    @State private var isExpanded = false

    private var style: YogaStyle { session?.resolvedYogaStyle ?? plan?.style ?? .hatha }
    private var poses: [YogaHistoryPresentation.Pose] {
        YogaHistoryPresentation.poses(session: session, plan: plan)
    }
    private var title: String {
        if let session {
            return YogaHistoryPresentation.title(session: session, plan: plan, exercise: exercise)
        }
        if plan?.steps.count == 1 { return plan?.steps.first?.name ?? "Yoga" }
        return "\(style.title) Yoga"
    }
    private var durationSeconds: Int { session?.durationSeconds ?? plan?.totalSeconds ?? 0 }
    private var heartRateSummary: CardioBlockSupport.HeartRateSummary? {
        guard let session,
              let window = CardioBlockSupport.blockWindow(
                  startedAt: session.startedAt,
                  liveStartedAt: session.liveStartedAt,
                  endedAt: session.endedAt,
                  durationSeconds: session.durationSeconds
              ) else { return nil }
        return CardioBlockSupport.heartRateSummary(samples: hrSamples, window: window)
    }
    private var displayAverageHR: Int? {
        heartRateMetrics?.averageBPM ?? heartRateSummary?.averageBPM ?? session?.avgHR
    }
    private var displayMaximumHR: Int? {
        heartRateMetrics?.maximumBPM ?? heartRateSummary?.maximumBPM ?? session?.maxHR
    }
    private var displayEnergyKcal: Double? {
        heartRateMetrics?.activeEnergyKcal ?? session?.activeEnergyKcal
    }
    private var displayZoneSeconds: [Int]? {
        if let zones = heartRateMetrics?.zoneSeconds {
            return zones
        }
        guard let zones = session?.hrZoneSeconds,
              zones.contains(where: { $0 > 0 }) else { return nil }
        return zones
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                header
                if session != nil, !collapsible || isExpanded {
                    details
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if collapsible, session != nil {
            Button {
                withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                headerContent(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) yoga block")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")
            .accessibilityIdentifier("yoga-block-header")
        } else {
            headerContent(showsChevron: false)
        }
    }

    private func headerContent(showsChevron: Bool) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: style.systemImage)
                .foregroundStyle(theme.accentForeground)
                .frame(width: 34, height: 34)
                .background(theme.surfaceElevated)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bodyStrong).foregroundStyle(theme.accentForeground)
                Text(session.map {
                    collapsible
                        ? YogaHistoryPresentation.compactSummary(
                            session: $0,
                            plan: plan,
                            averageHeartRate: displayAverageHR
                        )
                        : "Completed"
                } ?? "Skipped")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            } else {
                if title == "\(style.title) Yoga" {
                    Image(systemName: session == nil ? "minus.circle" : "checkmark.circle.fill")
                        .foregroundStyle(session == nil ? theme.textTertiary : theme.success)
                } else {
                    Tag(text: "\(style.title) Yoga", color: theme.accent, background: theme.accentSoft)
                }
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var details: some View {
        if let note = nonemptyNote(workoutExercise?.notes) {
            LoggedNoteView(title: "Exercise note", text: note)
        }

        if collapsible {
            HStack {
                StatColumn(label: "Duration", value: Fmt.durationShort(durationSeconds), valueColor: theme.accent)
                StatColumn(label: "Poses", value: poses.isEmpty ? "—" : "\(poses.count)")
                StatColumn(label: "Avg HR", value: displayAverageHR.map(String.init) ?? "—", valueColor: theme.danger)
                StatColumn(label: "Energy", value: displayEnergyKcal.map { "\(Int($0)) kcal" } ?? "—")
            }
        }

        if !poses.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Poses").font(.tag).foregroundStyle(theme.textSecondary)
                ForEach(poses) { pose in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pose.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                            if let detail = pose.sideDetail {
                                Text(detail).font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(Fmt.durationShort(pose.durationSeconds))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.accentForeground)
                    }
                }
            }
        }

        let exposure = FlexibilityAnalytics.decodeExposure(session?.flexibilityExposureJSON)
            .sorted { $0.value > $1.value }
        if !exposure.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Time under stretch").font(.tag).foregroundStyle(theme.textSecondary)
                ForEach(exposure, id: \.key) { region, seconds in
                    HStack {
                        Text(region.capitalized)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(Fmt.durationShort(seconds))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }

        if collapsible, let session, let avgHR = displayAverageHR {
            HRZoneBar(
                avgHR: avgHR,
                maxHR: displayMaximumHR,
                durationSeconds: session.durationSeconds,
                zoneSeconds: displayZoneSeconds,
                source: displayZoneSeconds == nil ? .estimated : .measured
            )
        }
        if collapsible,
           let session,
           let window = CardioBlockSupport.blockWindow(
               startedAt: session.startedAt,
               liveStartedAt: session.liveStartedAt,
               endedAt: session.endedAt,
               durationSeconds: session.durationSeconds
           ) {
            let slice = CardioBlockSupport.hrSlice(samples: hrSamples, window: window)
            if slice.count >= 2 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Heart rate").font(.tag).foregroundStyle(theme.textSecondary)
                    HeartRateTrendChart(samples: slice)
                }
            }
        }

        if let exercise {
            NavigationLink(value: exercise.id) {
                HStack(spacing: 4) {
                    Text("View \(exercise.name) history")
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accentForeground)
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func nonemptyNote(_ note: String?) -> String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        return note
    }
}
