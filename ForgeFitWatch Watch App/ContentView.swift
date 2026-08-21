import SwiftUI
import ForgeCore

/// Root router: summary after a workout ends, the live workout while one is
/// running, otherwise the start screen.
struct ContentView: View {
    @State private var store = WatchStore.shared

    var body: some View {
        Group {
            if store.summary != nil {
                WatchSummaryView(store: store)
            } else if let workout = store.activeWorkout {
                WatchActiveWorkoutView(store: store, workout: workout)
            } else {
                WatchHomeView(store: store)
            }
        }
        .animation(.snappy, value: store.activeWorkout != nil)
    }
}

// MARK: - Home / start screen

struct WatchHomeView: View {
    let store: WatchStore

    private var context: WatchAppContext? { store.context }

    var body: some View {
        let readinessBasis = context?.currentReadinessBasis()
        NavigationStack {
            List {
                // Day-gated: the retained context can be yesterday's, and a
                // stale score here is worse than no score.
                if let readiness = context?.currentReadiness() {
                    HStack(spacing: 10) {
                        if readinessBasis == .daily {
                            Gauge(value: Double(readiness), in: 0...100) {
                                EmptyView()
                            } currentValueLabel: {
                                Text("\(readiness)")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            .gaugeStyle(.accessoryCircularCapacity)
                            .tint(WTheme.readinessColor(readiness))
                            .scaleEffect(0.82)
                        } else {
                            Text("\(readiness)")
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 50)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(readinessBasis == .trend ? "7-day trend" : "Readiness score")
                                .font(.system(size: 14, weight: .semibold))
                            Text(context?.currentReadinessAction() ?? (readinessBasis == .trend ? "Today's index is building" : "Open ForgeFit for today's guidance"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Button {
                        store.startEmpty()
                    } label: {
                        Label("Empty Workout", systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .listItemTint(WTheme.accent)
                } header: {
                    Text("Start")
                }

                if let routines = context?.routines, !routines.isEmpty {
                    Section {
                        ForEach(routines) { routine in
                            Button {
                                store.startRoutine(routine)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routine.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .lineLimit(1)
                                    if let partner = routine.alternatingPartnerName {
                                        Label(
                                            routine.isNextInAlternation == true
                                                ? "Next · alternates with \(partner)"
                                                : "Alternates with \(partner)",
                                            systemImage: "arrow.triangle.2.circlepath"
                                        )
                                        .font(.system(size: 11))
                                        .foregroundStyle(routine.isNextInAlternation == true ? WTheme.accent : .secondary)
                                    } else {
                                        Text("\(routine.exerciseCount) exercise\(routine.exerciseCount == 1 ? "" : "s")")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Routines")
                    }
                }

                if context == nil {
                    Text("Open ForgeFit on your iPhone to sync routines.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("ForgeFit")
        }
    }
}

#Preview {
    ContentView()
}
