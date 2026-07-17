import SwiftUI

/// Home's same-day counterpart to morning recovery: recovery answers how the
/// day started; strain answers how much movement and training has accumulated.
struct DailyStrainCard: View {
    @Environment(\.theme) private var theme
    @State private var showingInfo = false

    let report: DailyStrainEngine.Report

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.secondaryAccent)
                    Text("Daily strain")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Button("About daily strain", systemImage: "info.circle") {
                        showingInfo = true
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("daily-strain-info")
                }
                .frame(height: 44)

                if let score = report.score {
                    scoreRow(score)
                    StrainTargetBar(
                        score: score,
                        target: report.targetRange,
                        color: strainColor
                    )
                    activityRow
                } else {
                    buildingState
                }
            }
        }
        .sheet(isPresented: $showingInfo) {
            DailyStrainInfoSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("daily-strain-card")
    }

    private func scoreRow(_ score: Double) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: Space.sm) {
            Text(score.formatted(.number.precision(.fractionLength(1))))
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(strainColor)
            Text("/ 10")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textTertiary)

            Spacer(minLength: Space.md)

            VStack(alignment: .trailing, spacing: 3) {
                if let target = report.targetRange {
                    Text("Target \(formatted(target.lowerBound))–\(formatted(target.upperBound))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                } else {
                    Text("Target building")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                }
                Text(statusText(score))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var activityRow: some View {
        HStack(spacing: Space.lg) {
            if let steps = report.steps {
                activityLabel("\(steps.formatted()) steps", systemImage: "shoeprints.fill")
            } else if let energy = report.activeEnergyKcal {
                activityLabel("\(energy) active kcal", systemImage: "bolt.fill")
            }

            if report.workoutMinutes > 0 {
                activityLabel("\(report.workoutMinutes) min training", systemImage: "figure.strengthtraining.traditional")
            } else if let minutes = report.exerciseMinutes {
                activityLabel("\(minutes) active min", systemImage: "figure.walk")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func activityLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
    }

    private var buildingState: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 48, height: 48)
                .background(theme.surfaceElevated)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Building your strain baseline")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text("Seven days of movement data unlocks a personal score and target.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var strainColor: Color {
        report.status == .aboveTarget ? theme.warmup : theme.secondaryAccent
    }

    private var statusColor: Color {
        switch report.status {
        case .inTarget: theme.success
        case .aboveTarget: theme.warmup
        default: theme.textSecondary
        }
    }

    private func statusText(_ score: Double) -> String {
        switch report.status {
        case .building: "Building baseline"
        case .targetBuilding: "Recovery target building"
        case .belowTarget:
            if let lower = report.targetRange?.lowerBound {
                "\(formatted(max(0, lower - score))) to target"
            } else {
                "Below target"
            }
        case .inTarget: "Target reached"
        case .aboveTarget: "Above today's range"
        }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
