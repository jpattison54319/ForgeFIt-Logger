import ForgeCore
import SwiftUI
import WidgetKit

// ForgeFit watch-face complication. Reads the shared snapshot the watch app
// writes into the group.org.xpetsllc.ForgeFit app group (see
// WatchStore.publishComplicationSnapshot) and shows readiness when idle, live
// set progress mid-workout. Tapping opens the watch app.
//
// Ships in the ForgeFitWatchComplication widget-extension target, embedded in
// the watch app. Three things have to stay true or it silently falls back to
// placeholder data: the target links ForgeCore (for the snapshot types), and
// BOTH it and the watch app carry the group.org.xpetsllc.ForgeFit app group —
// `UserDefaults(suiteName:)` fails soft to `.standard`, so a missing
// entitlement on either side loses the write with no error anywhere.

struct ForgeFitComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: ForgeFitWidgetSnapshot?
    let themePreference: ForgeThemePreference
}

struct ForgeFitComplicationProvider: TimelineProvider {
    private func currentSnapshot(at date: Date = .now) -> ForgeFitWidgetSnapshot? {
        ForgeFitWidgetSnapshotStore.load().flatMap { snapshot in
            snapshot.isCurrent(at: date) ? snapshot : nil
        }
    }

    func placeholder(in context: Context) -> ForgeFitComplicationEntry {
        ForgeFitComplicationEntry(
            date: Date(),
            snapshot: nil,
            themePreference: ForgeThemePreference()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ForgeFitComplicationEntry) -> Void) {
        completion(ForgeFitComplicationEntry(
            date: Date(),
            snapshot: currentSnapshot(),
            themePreference: ForgeThemePreferenceStore.load()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ForgeFitComplicationEntry>) -> Void) {
        let now = Date.now
        let snapshot = currentSnapshot(at: now)
        // Mid-workout state goes stale fast; idle readiness is good for an hour.
        let refresh: TimeInterval = snapshot?.mode == .activeWorkout ? 5 * 60 : 60 * 60
        let periodicRefresh = now.addingTimeInterval(refresh)
        let nextDay = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: now)
        ) ?? periodicRefresh
        var entries = [ForgeFitComplicationEntry(
            date: now,
            snapshot: snapshot,
            themePreference: ForgeThemePreferenceStore.load()
        )]
        if snapshot?.mode != .activeWorkout {
            // Carry the expiry in the timeline itself so yesterday's score is
            // cleared at midnight even when watchOS delays the next reload.
            entries.append(ForgeFitComplicationEntry(
                date: nextDay,
                snapshot: nil,
                themePreference: ForgeThemePreferenceStore.load()
            ))
        }
        completion(Timeline(
            entries: entries,
            policy: .after(min(periodicRefresh, nextDay))
        ))
    }
}

struct ForgeFitComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ForgeFitComplicationEntry

    private var snapshot: ForgeFitWidgetSnapshot? { entry.snapshot }
    private var isWorkout: Bool { snapshot?.mode == .activeWorkout }
    private var isDailyReadiness: Bool {
        snapshot?.readinessBasis == .daily
    }
    private var readinessText: String {
        guard let score = snapshot?.readinessScore else { return "Readiness" }
        switch snapshot?.readinessBasis {
        case .daily: return "\(score)% ready"
        case .trend: return "\(score)% trend"
        case nil: return "\(score)% readiness"
        }
    }
    private var readinessBasisText: String {
        switch snapshot?.readinessBasis {
        case .daily: return "Today's readiness"
        case .trend: return "7-day trend"
        case nil: return "Readiness score"
        }
    }
    private var palette: ForgeThemePalette {
        ForgeThemeCatalog.palette(
            for: entry.themePreference.family,
            appearance: .dark
        )
    }
    private var accent: Color { Color(themeHex: palette.accent) }
    private var accentForeground: Color { Color(themeHex: palette.accentForeground) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if isWorkout {
                    VStack(spacing: 0) {
                        Image(systemName: "dumbbell.fill").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accentForeground)
                        Text("\(snapshot?.completedSets ?? 0)/\(snapshot?.totalSets ?? 0)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                } else if let score = snapshot?.readinessScore {
                    if isDailyReadiness {
                        Gauge(value: Double(score), in: 0...100) {
                            Image(systemName: "bolt.heart.fill")
                        } currentValueLabel: {
                            Text("\(score)").font(.system(size: 15, weight: .bold, design: .rounded))
                        }
                        .gaugeStyle(.accessoryCircular)
                        .tint(accent)
                    } else {
                        VStack(spacing: 0) {
                            Text("\(score)")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                            Text(snapshot?.readinessBasis == .trend ? "trend" : "score")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "dumbbell.fill").font(.system(size: 18, weight: .bold))
                }
            }

        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: isWorkout ? "dumbbell.fill" : "bolt.heart.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(accentForeground)
                VStack(alignment: .leading, spacing: 1) {
                    if isWorkout {
                        Text(snapshot?.workoutTitle ?? "Workout").font(.headline).lineLimit(1)
                        Text("\(snapshot?.completedSets ?? 0) of \(snapshot?.totalSets ?? 0) sets")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if snapshot?.readinessScore != nil {
                        Text(readinessText).font(.headline)
                        Text(snapshot?.readinessAction ?? readinessBasisText)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("ForgeFit").font(.headline)
                        Text("Open").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

        case .accessoryInline:
            if isWorkout {
                Label("\(snapshot?.completedSets ?? 0)/\(snapshot?.totalSets ?? 0) sets", systemImage: "dumbbell.fill")
            } else if snapshot?.readinessScore != nil {
                Label(readinessText, systemImage: "bolt.heart.fill")
            } else {
                Label("ForgeFit", systemImage: "dumbbell.fill")
            }

        case .accessoryCorner:
            Image(systemName: isWorkout ? "dumbbell.fill" : "bolt.heart.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(accentForeground)
                .widgetLabel {
                    if isWorkout {
                        Text("\(snapshot?.completedSets ?? 0)/\(snapshot?.totalSets ?? 0)")
                    } else if snapshot?.readinessScore != nil {
                        Text(readinessText)
                    } else {
                        Text("ForgeFit")
                    }
                }

        default:
            Image(systemName: "dumbbell.fill")
        }
    }
}

private extension Color {
    init(themeHex: UInt32) {
        self.init(
            .sRGB,
            red: Double((themeHex >> 16) & 0xFF) / 255,
            green: Double((themeHex >> 8) & 0xFF) / 255,
            blue: Double(themeHex & 0xFF) / 255
        )
    }
}

@main
struct ForgeFitWatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ForgeFitWatchComplication", provider: ForgeFitComplicationProvider()) { entry in
            ForgeFitComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("ForgeFit")
        .description("Readiness and live workout progress.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
