import ForgeData
import SwiftUI

/// Deep-link + share-link helpers for follow-by-link.
/// `forgefit://u/<handle>` opens a profile; the https form is human-shareable.
enum SocialLinks {
    static let scheme = "forgefit"
    static func appURL(handle: String) -> URL { URL(string: "\(scheme)://u/\(SocialHandle.normalize(handle))")! }
    static func shareText(handle: String) -> String {
        "Follow me on ForgeFit: \(appURL(handle: handle).absoluteString)"
    }
    /// Extracts a handle from an opened `forgefit://u/<handle>` URL.
    static func handle(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "u" else { return nil }
        let handle = url.pathComponents.last(where: { $0 != "/" })
        return handle.map(SocialHandle.normalize)
    }
}

func socialInitials(_ name: String) -> String {
    let parts = name.split(separator: " ")
    let initials = parts.prefix(2).compactMap(\.first).map(String.init).joined()
    return initials.isEmpty ? "?" : initials.uppercased()
}

/// The identity + XP + lifetime-stats card, driven by a published `SocialProfile`.
/// Renders identically to your own Profile header (shared `LevelBadge` /
/// `XPProgressBar`) so a friend's profile feels like yours.
struct SocialProfileHeaderView: View {
    @Environment(\.theme) private var theme
    let profile: SocialProfile

    private var progress: XPService.Progress { XPService.progress(forTotalXP: profile.totalXP) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.lg) {
                    ZStack {
                        Circle().stroke(theme.accent.opacity(0.28), lineWidth: 1.5).frame(width: 76, height: 76)
                        Circle().fill(theme.recoveryHigh.opacity(0.9)).frame(width: 64, height: 64)
                            .shadow(color: theme.accent.opacity(0.35), radius: 10)
                        Text(socialInitials(profile.displayName)).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack(spacing: Space.sm) {
                            Text(profile.displayName).font(.sectionTitle).foregroundStyle(theme.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            LevelBadge(level: progress.level)
                        }
                        Text("@\(profile.handle)").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary)
                        HStack(spacing: Space.sm) {
                            SocialStatTile(icon: "flame.fill", value: "\(profile.workoutCount)", label: "Logged")
                            SocialStatTile(icon: "clock.fill", value: "\(Int(profile.lifetimeHours))", label: "Hours")
                        }
                    }
                }
                XPProgressBar(progress: progress)
                lifetimeStrip
            }
        }
    }

    @ViewBuilder private var lifetimeStrip: some View {
        let chips = statChips
        if !chips.isEmpty {
            Divider().overlay(theme.separator)
            HStack(spacing: Space.md) {
                ForEach(chips, id: \.label) { chip in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chip.value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
                        Text(chip.label).font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var statChips: [(label: String, value: String)] {
        var chips: [(String, String)] = []
        if profile.stats.lifetimeVolumeKg > 0 { chips.append(("Volume", Fmt.volume(profile.stats.lifetimeVolumeKg))) }
        if profile.stats.bestE1RMKg > 0 { chips.append(("Best lift", Fmt.loadUnit(profile.stats.bestE1RMKg))) }
        if profile.stats.cardioDistanceMeters > 0 { chips.append(("Cardio", Fmt.distance(profile.stats.cardioDistanceMeters))) }
        if profile.stats.yogaMinutes > 0 { chips.append(("Yoga", "\(Int(profile.stats.yogaMinutes)) min")) }
        return Array(chips.prefix(3))
    }
}

struct SocialStatTile: View {
    @Environment(\.theme) private var theme
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: Space.xs) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent).accessibilityHidden(true)
                Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(label).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Space.sm).padding(.horizontal, Space.xs)
        .background(theme.surfaceElevated).clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .accessibilityElement(children: .combine)
    }
}

/// A recent-workout row on a profile, driven by the queryable `SocialWorkoutRef`
/// (no payload decode needed). Mirrors the local `WorkoutFeedRow`.
struct SocialWorkoutRow: View {
    @Environment(\.theme) private var theme
    let ref: SocialWorkoutRef

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Image(systemName: kindIcon).font(.system(size: 14, weight: .bold)).foregroundStyle(theme.accent)
                    Text(ref.title ?? "Workout").font(.bodyStrong).foregroundStyle(theme.textPrimary).lineLimit(1)
                    Spacer()
                    Text(ref.startedAt.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    // Rows open the workout detail (where likes live) —
                    // chevron is the app's tappable signal.
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textTertiary)
                }
                HStack(spacing: Space.lg) {
                    rowStat("Time", Fmt.durationShort(ref.summary.durationSeconds))
                    switch ref.summary.kind {
                    case "cardio":
                        if ref.summary.distanceMeters > 0 { rowStat("Distance", Fmt.distance(ref.summary.distanceMeters)) }
                    case "yoga":
                        rowStat("Style", "Yoga")
                    default:
                        rowStat("Volume", Fmt.volume(ref.summary.volumeKg))
                        rowStat("Sets", "\(ref.summary.workingSets)")
                    }
                }
            }
        }
    }

    private var kindIcon: String {
        switch ref.summary.kind {
        case "cardio": "figure.run"
        case "yoga": "figure.mind.and.body"
        default: "dumbbell.fill"
        }
    }

    private func rowStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
            Text(label).font(.system(size: 11)).foregroundStyle(theme.textTertiary)
        }
    }
}
