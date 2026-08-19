import ForgeData
import SwiftUI

// MARK: - Workout shape

/// The workout shapes the share cards adapt to. Computed once and passed
/// around so hero rows, module picks, and page availability can never drift
/// apart across the card styles.
enum WorkoutShareShape {
    case strength, cardio, conditioning, yoga, hybrid

    static func of(workout: WorkoutModel, summary: TrainingAnalytics.Summary) -> WorkoutShareShape {
        let modalities = WorkoutPresentationPlan.make(for: workout).modalities
        guard modalities.count == 1, let modality = modalities.first else {
            // Empty / notes-only workouts retain the strength log's graceful
            // empty state; two or more authored modalities are always hybrid.
            return modalities.isEmpty ? .strength : .hybrid
        }
        return switch modality {
        case .strength: .strength
        case .cardio: .cardio
        case .conditioning: .conditioning
        case .yoga: .yoga
        }
    }

    /// Watermark / accent icon for the minimal card.
    var systemImage: String {
        switch self {
        case .strength: "dumbbell.fill"
        case .cardio: "figure.run"
        case .conditioning: "figure.cross.training"
        case .yoga: "figure.yoga"
        case .hybrid: "figure.cross.training"
        }
    }

    /// Between-set recovery is derived from strength-set completion timestamps.
    /// Conditioning, cardio, and yoga have continuous modality-specific effort
    /// instead of discrete strength-set recovery windows.
    var supportsBetweenSetRecovery: Bool {
        self == .strength || self == .hybrid
    }
}

// MARK: - Card style

/// One share-card format the preview carousel offers. `full` is the existing
/// tall card; the rest are fixed-size social formats.
enum ShareCardStyle: String, CaseIterable, Identifiable {
    static let preferenceKey = "shareCardStyle.last"

    case trainingLog
    case metrics
    case minimal
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trainingLog: "Training Log"
        case .metrics: "Metrics"
        case .minimal: "Minimal"
        case .full: "Full Log"
        }
    }

    /// The pages the carousel offers for this workout — a page only exists
    /// when it has substance. Metrics needs heart-rate data; everything else
    /// adapts to whatever the workout holds.
    static func available(
        workout: WorkoutModel,
        summary: TrainingAnalytics.Summary,
        hasHRSamples: Bool
    ) -> [ShareCardStyle] {
        var styles: [ShareCardStyle] = [.trainingLog]
        if hasHRSamples || workout.hrZoneSeconds.contains(where: { $0 > 0 }) {
            styles.append(.metrics)
        }
        styles.append(.minimal)
        styles.append(.full)
        return styles
    }
}

// MARK: - Shared chrome

/// The visual vocabulary every share card is built from — one place for the
/// header, stat tiles, block containers, and brand footer so the compact
/// social cards and the full-length card can't drift apart.
struct ShareCardChrome {
    let theme: AppTheme

    func header(
        title: String,
        date: Date,
        compact: Bool = false,
        systemImage: String = "dumbbell.fill"
    ) -> some View {
        HStack(alignment: .center, spacing: compact ? 10 : 12) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous).fill(theme.accent)
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 16 : 20, weight: .bold)).foregroundStyle(theme.onAccent)
            }
            .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: compact ? 20 : 24, weight: .bold)).foregroundStyle(theme.textPrimary)
                    .lineLimit(compact ? 1 : 2)
                    .minimumScaleFactor(0.7)
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.label).foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.uppercased())
                .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(label.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Set counts are `Double` (half-sets exist for unilateral work), so raw
    /// interpolation renders "6.0" on a shared image. Drop the trailing
    /// zero, keep a genuine half.
    static func setCount(_ sets: Double) -> String {
        sets.formatted(.number.precision(.fractionLength(0...1)))
    }

    func chip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
            Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(theme.textTertiary)
        }
    }

    func blockTitle<Trailing: View>(
        _ title: String,
        systemImage: String,
        color: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.textPrimary)
            Spacer(minLength: 0)
            trailing()
        }
    }

    func surfaceBlock<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func footer() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "dumbbell.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.accentForeground)
            Text("Tracked with ForgeFit").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(.top, 2)
    }
}

// MARK: - Set labels

enum ShareSetLabels {
    /// Deterministic per-set numbering (no mutable counter) — ImageRenderer
    /// evaluates bodies more than once, so a running `var` double-counts.
    static func numberedLabel(for set: SetModel, index: Int, sets: [SetModel]) -> String {
        let style = SetTypeStyle.of(set.setType)
        guard style.numbered else { return style.badge.isEmpty ? "•" : style.badge }
        let number = sets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
        return "\(number)\(style.badge)"
    }
}
