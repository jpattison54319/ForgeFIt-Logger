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
            snapshot: ForgeFitWidgetSnapshotStore.load(),
            themePreference: ForgeThemePreferenceStore.load()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ForgeFitComplicationEntry>) -> Void) {
        let snapshot = ForgeFitWidgetSnapshotStore.load()
        // Mid-workout state goes stale fast; idle readiness is good for an hour.
        let refresh: TimeInterval = snapshot?.mode == .activeWorkout ? 5 * 60 : 60 * 60
        completion(Timeline(
            entries: [ForgeFitComplicationEntry(
                date: Date(),
                snapshot: snapshot,
                themePreference: ForgeThemePreferenceStore.load()
            )],
            policy: .after(Date().addingTimeInterval(refresh))
        ))
    }
}

struct ForgeFitComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ForgeFitComplicationEntry

    private var snapshot: ForgeFitWidgetSnapshot? { entry.snapshot }
    private var isWorkout: Bool { snapshot?.mode == .activeWorkout }
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
                    Gauge(value: Double(score), in: 0...100) {
                        Image(systemName: "bolt.heart.fill")
                    } currentValueLabel: {
                        Text("\(score)").font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(accent)
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
                    } else if let score = snapshot?.readinessScore {
                        Text("\(score)% ready").font(.headline)
                        Text(snapshot?.readinessAction ?? "Today's readiness")
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
            } else if let score = snapshot?.readinessScore {
                Label("\(score)% ready", systemImage: "bolt.heart.fill")
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
                    } else if let score = snapshot?.readinessScore {
                        Text("\(score)% ready")
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
