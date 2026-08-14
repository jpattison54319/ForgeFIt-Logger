import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Completed conditioning as one scored modality block. Persistence may hold
/// a set row for every movement/round, but those rows are deliberately absent
/// here: the prescription already guarantees the repeated work.
struct ConditioningHistoryCard: View {
    let plan: ConditioningPlan?
    let result: ConditioningResult?
    let session: CardioSessionModel?
    let exercises: [ExerciseLibraryModel]
    let workouts: [WorkoutModel]
    let hrSamples: [(date: Date, bpm: Int)]
    var heartRateMetrics: WorkoutHeartRateResolution.Metrics? = nil
    let collapsible: Bool

    @Environment(\.theme) private var theme
    @Query(sort: \IntervalPresetModel.updatedAt, order: .reverse)
    private var presetRecords: [IntervalPresetModel]
    @State private var isExpanded = false

    private var hasRecordedWork: Bool {
        result != nil || (plan == nil && session?.endedAt != nil)
    }

    private var completionStatus: ConditioningSharePresentation.CompletionStatus {
        if let plan {
            return ConditioningSharePresentation.completionStatus(for: .init(plan: plan, result: result))
        }
        return session?.endedAt == nil ? .notLogged : .completed
    }

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

    private var subtitle: String {
        guard collapsible else { return completionStatus.label }
        if let section = plan?.sections.first {
            let score: String?
            if let sectionResult = result?.sectionResults.first {
                score = ConditioningSharePresentation.score(sectionResult)
            } else {
                score = nil
            }
            let status = completionStatus == .completed ? nil : completionStatus.label
            return [status, score, ConditioningSharePresentation.prescription(section)]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        guard let session else { return "No work recorded" }
        var parts = [Fmt.durationShort(session.durationSeconds)]
        if let avgHR = displayAverageHR { parts.append("\(avgHR) bpm") }
        if let energy = displayEnergyKcal { parts.append("\(Int(energy)) kcal") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                header
                if hasRecordedWork, !collapsible || isExpanded {
                    details
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if collapsible, hasRecordedWork {
            Button {
                withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                headerContent(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Conditioning block")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")
            .accessibilityIdentifier("conditioning-block-header")
        } else {
            headerContent(showsChevron: false)
        }
    }

    private func headerContent(showsChevron: Bool) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "figure.cross.training")
                .foregroundStyle(theme.warmup)
                .frame(width: 34, height: 34)
                .background(theme.surfaceElevated)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Conditioning")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.warmup)
                Text(hasRecordedWork ? subtitle : "Skipped")
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
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: 44)
    }

    private var statusIcon: String {
        switch completionStatus {
        case .completed: "checkmark.circle.fill"
        case .timeCap, .incomplete: "exclamationmark.triangle.fill"
        case .notLogged: "minus.circle"
        }
    }

    private var statusColor: Color {
        switch completionStatus {
        case .completed: theme.success
        case .timeCap, .incomplete: theme.warmup
        case .notLogged: theme.textTertiary
        }
    }

    @ViewBuilder
    private var details: some View {
        if let plan {
            ConditioningShareBlock(
                plan: plan,
                result: result,
                exercises: exercises,
                theme: theme,
                showsResult: false,
                showsPerformance: false,
                showsSectionName: false
            )

            ForEach(plan.sections) { section in
                if let sectionResult = result?.sectionResults.first(where: { $0.id == section.id }),
                   !ConditioningSharePresentation.performanceFacts(
                       section: section,
                       result: sectionResult
                   ).isEmpty {
                    ConditioningPerformanceView(
                        section: section,
                        result: sectionResult,
                        sectionName: plan.sections.count > 1
                            ? (section.name.isEmpty ? section.format.title : section.name)
                            : nil
                    )
                }

                performanceHistoryLink(
                    section,
                    showsSectionName: plan.sections.count > 1
                )
            }
        }

        if collapsible, let session, session.endedAt != nil {
            HStack {
                StatColumn(label: "Avg HR", value: displayAverageHR.map(String.init) ?? "—", valueColor: theme.danger)
                StatColumn(label: "Max HR", value: displayMaximumHR.map(String.init) ?? "—", valueColor: theme.danger)
                StatColumn(label: "Energy", value: displayEnergyKcal.map { "\(Int($0)) kcal" } ?? "—")
            }
            if let avgHR = displayAverageHR {
                HRZoneBar(
                    avgHR: avgHR,
                    maxHR: displayMaximumHR,
                    durationSeconds: session.durationSeconds,
                    zoneSeconds: displayZoneSeconds,
                    source: displayZoneSeconds == nil ? .estimated : .measured
                )
            }
            if let window = CardioBlockSupport.blockWindow(
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
        }
    }

    private func performanceHistoryLink(
        _ section: ConditioningSection,
        showsSectionName: Bool
    ) -> some View {
        let sectionTitle = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = sectionTitle.isEmpty ? section.format.title : sectionTitle
        let preset = ConditioningPresetResolver.selection(
            for: section,
            records: presetRecords,
            exercises: exercises
        )
        return NavigationLink {
            if let preset {
                ConditioningPresetDetailDestination(
                    selection: preset,
                    workouts: workouts,
                    exercises: exercises
                )
            } else {
                ConditioningPresetDetailView(
                    title: resolvedTitle,
                    section: section,
                    workouts: workouts,
                    exercises: exercises
                )
            }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 28, height: 28)
                    .background(theme.accent.opacity(0.12))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset?.title ?? "Performance over time")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    if preset != nil {
                        Text("Preset · Performance over time")
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                    } else if showsSectionName {
                        Text(resolvedTitle)
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Space.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.sm)
            .frame(minHeight: 50)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View \(preset?.title ?? resolvedTitle) preset performance")
        .accessibilityHint("Opens performance history and preset details")
        .accessibilityIdentifier("conditioning-preset-history-link")
    }
}
