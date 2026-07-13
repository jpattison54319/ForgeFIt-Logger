import SwiftUI

// MARK: - Concentric day rings

/// Two concentric recovery rings for a calendar day: the OUTER ring is that
/// day's daily readiness, the INNER ring its 7-day trend. Both are colour-coded
/// on the same recovery scale.
///
/// The hard part is the same-colour case — when both scores land in one band
/// (e.g. both green), two touching rings can read as a single thick line. A
/// dedicated dark **moat** ring is painted between them so there is always a
/// base-colour gap separating the two arcs, whatever colour they are and
/// whatever the cell background is.
struct RecoveryDayRings: View {
    /// Daily readiness, 0...1 (outer ring). Nil when that day's acute score
    /// wasn't captured.
    let daily: Double?
    /// 7-day trend, 0...1 (inner ring). Nil until enough history backs it.
    let trend: Double?
    var size: CGFloat = 34
    var lineWidth: CGFloat = 2.5
    /// Clear space between the two rings.
    var moat: CGFloat = 2

    @Environment(\.theme) private var theme

    private var innerSize: CGFloat { size - 2 * (lineWidth + moat) }
    private var bothPresent: Bool { daily != nil && trend != nil }

    var body: some View {
        ZStack {
            // Daily is the outer ring. A single available score always takes the
            // primary (outer) position, so a lone ring never looks like a stray
            // inner circle.
            if let daily {
                ring(progress: daily, diameter: size)
            }
            if bothPresent {
                // Guaranteed dark separator: a base-colour arc in the gap, so
                // two same-colour rings never fuse into one line — and it wins
                // even over a tinted (selected) cell behind it.
                Circle()
                    .stroke(theme.background, lineWidth: moat + 1)
                    .frame(width: (size + innerSize) / 2, height: (size + innerSize) / 2)
            }
            if let trend {
                ring(progress: trend, diameter: bothPresent ? innerSize : size)
            }
        }
        .frame(width: size, height: size)
    }

    private func ring(progress: Double, diameter: CGFloat) -> some View {
        ZStack {
            // Faint track so a low score still reads as a full ring, not a stub.
            Circle().stroke(theme.surfaceHighlight, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(theme.readinessColor(progress), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Selected-day recovery card

/// The card above a selected day's workouts: recovery and trend side by side,
/// with the day's strain spanning the row beneath them.
struct RecoveryDaySummaryCard: View {
    let snapshot: RecoverySnapshot?
    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            if let snapshot {
                VStack(spacing: Space.md) {
                    HStack(spacing: 0) {
                        scoreColumn(label: "Recovery", value: snapshot.daily,
                                    caption: "That day", id: "recovery")
                        Rectangle()
                            .fill(theme.separator)
                            .frame(width: 1, height: 52)
                            .padding(.horizontal, Space.md)
                        scoreColumn(label: "Trend", value: snapshot.trend,
                                    caption: "7-day", id: "trend")
                    }
                    .frame(maxWidth: .infinity)

                    if let strain = snapshot.strain {
                        Rectangle()
                            .fill(theme.separator)
                            .frame(height: 1)
                        RecoveryDayStrainRow(score: strain, target: snapshot.strainTargetRange)
                    }
                }
            } else {
                HStack(spacing: Space.md) {
                    Image(systemName: "heart.text.square")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No recovery recorded")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Recovery is captured each day going forward.")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func scoreColumn(label: String, value: Double?, caption: String, id: String) -> some View {
        HStack(spacing: Space.md) {
            ZStack {
                ProgressRing(
                    progress: value ?? 0,
                    lineWidth: 5,
                    color: value.map(theme.readinessColor) ?? theme.surfaceHighlight
                )
                .frame(width: 52, height: 52)
                Text(value.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(caption)")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) out of 100" } ?? "no data")
        .accessibilityIdentifier("recovery-summary-\(id)")
    }
}
