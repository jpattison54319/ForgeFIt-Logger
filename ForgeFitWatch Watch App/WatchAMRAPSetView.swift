import ForgeCore
import SwiftUI

/// AMRAP execution on the wrist: choose the fixed work window, run it with a
/// local countdown/haptic, log the reps, then explicitly complete the set.
struct WatchAMRAPSetView: View {
    let store: WatchStore
    let exerciseID: UUID
    let setID: UUID

    @State private var durationSeconds: Int
    @State private var showsSetEditor = false

    private static let durationOptions = [30, 45, 60, 90, 120, 180, 300]

    init(store: WatchStore, exercise: WatchExerciseSnapshot, set: WatchSetSnapshot) {
        self.store = store
        self.exerciseID = exercise.id
        self.setID = set.id
        _durationSeconds = State(initialValue: set.durationSeconds ?? 60)
    }

    private var exercise: WatchExerciseSnapshot? {
        store.activeWorkout?.exercises.first { $0.id == exerciseID }
    }

    private var set: WatchSetSnapshot? {
        exercise?.sets.first { $0.id == setID }
    }

    var body: some View {
        ScrollView {
            if let exercise, let set {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("AMRAP", systemImage: "stopwatch.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(WTheme.gold)
                        Spacer()
                        if set.completed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(WTheme.success)
                                .accessibilityLabel("Completed")
                        }
                    }

                    if timerIsRunning(for: set) {
                        activeTimer(set, exercise: exercise)
                    } else {
                        Picker("Work Window", selection: $durationSeconds) {
                            ForEach(Self.durationOptions, id: \.self) { seconds in
                                Text(WFmt.rest(seconds)).tag(seconds)
                            }
                        }
                        .disabled(set.completed)
                        .accessibilityIdentifier("amrap-duration")

                        Button {
                            store.startSetTimer(set, in: exercise, seconds: durationSeconds)
                        } label: {
                            Label("Start AMRAP", systemImage: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WTheme.gold)
                        .disabled(set.completed)
                        .accessibilityIdentifier("start-watch-amrap")
                    }

                    Button {
                        showsSetEditor = true
                    } label: {
                        HStack {
                            Text(set.reps.map { "\($0) reps" } ?? "Log reps")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Spacer()
                            Image(systemName: "pencil")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(set.completed)
                    .accessibilityIdentifier("edit-watch-amrap-reps")

                    Button {
                        store.toggleSet(set, in: exercise)
                    } label: {
                        Label(
                            set.completed ? "Reopen AMRAP" : "Complete AMRAP",
                            systemImage: set.completed ? "arrow.uturn.backward" : "checkmark"
                        )
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(set.completed ? WTheme.surface : WTheme.success)
                    .accessibilityIdentifier("complete-watch-amrap")
                }
                .padding(.horizontal, 5)
            }
        }
        .navigationTitle("AMRAP")
        .sheet(isPresented: $showsSetEditor) {
            if let exercise, let set {
                WatchSetEditView(store: store, exercise: exercise, set: set)
            }
        }
    }

    private func activeTimer(
        _ set: WatchSetSnapshot,
        exercise: WatchExerciseSnapshot
    ) -> some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let remaining = max(
                    0,
                    Int((store.activeWorkout?.restEndsAt ?? context.date).timeIntervalSince(context.date).rounded(.up))
                )
                VStack(spacing: 1) {
                    Text("WORK")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(WTheme.gold)
                    Text(WFmt.rest(remaining))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WTheme.gold)
                        .contentTransition(.numericText(countsDown: true))
                }
                .frame(maxWidth: .infinity)
            }

            Button("Stop Timer", systemImage: "stop.fill") {
                store.stopSetTimer(set, in: exercise)
            }
            .buttonStyle(.bordered)
            .tint(WTheme.gold)
            .accessibilityIdentifier("stop-watch-amrap")
        }
    }

    private func timerIsRunning(for set: WatchSetSnapshot) -> Bool {
        guard store.activeWorkout?.restOwnerID == set.id,
              store.activeWorkout?.restLabel == "AMRAP",
              let endsAt = store.activeWorkout?.restEndsAt else { return false }
        return endsAt > Date.now
    }
}
