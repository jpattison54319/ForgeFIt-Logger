import ForgeCore
import ForgeData
import SwiftUI

/// Completed conditioning as one scored modality block. Persistence may hold
/// a set row for every movement/round, but those rows are deliberately absent
/// here: the prescription already guarantees the repeated work.
struct ConditioningHistoryCard: View {
    let plan: ConditioningPlan?
    let result: ConditioningResult?
    let session: CardioSessionModel?
    let exercises: [ExerciseLibraryModel]
    let hrSamples: [(date: Date, bpm: Int)]
    let collapsible: Bool

    @Environment(\.theme) private var theme
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
        if let avgHR = session.avgHR { parts.append("\(avgHR) bpm") }
        if let energy = session.activeEnergyKcal { parts.append("\(Int(energy)) kcal") }
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
            }
        }

        if collapsible, let session, session.endedAt != nil {
            HStack {
                StatColumn(label: "Avg HR", value: session.avgHR.map(String.init) ?? "—", valueColor: theme.danger)
                StatColumn(label: "Max HR", value: session.maxHR.map(String.init) ?? "—", valueColor: theme.danger)
                StatColumn(label: "Energy", value: session.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "—")
            }
            if let avgHR = session.avgHR {
                HRZoneBar(
                    avgHR: avgHR,
                    maxHR: session.maxHR,
                    durationSeconds: session.durationSeconds,
                    zoneSeconds: session.hrZoneSeconds.contains(where: { $0 > 0 }) ? session.hrZoneSeconds : nil,
                    source: session.hrZoneSeconds.contains(where: { $0 > 0 }) ? .measured : .estimated
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
}
