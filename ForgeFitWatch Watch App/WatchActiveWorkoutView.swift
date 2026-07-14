import SwiftUI
import ForgeCore

/// The live workout on the wrist: vertical pages for metrics, set logging,
/// and session controls — mirroring the phone logger, sized for a watch.
struct WatchActiveWorkoutView: View {
    let store: WatchStore
    let workout: WatchWorkoutSnapshot

    @State private var selection = 1

    var body: some View {
        TabView(selection: $selection) {
            WatchMetricsPage(store: store, workout: workout)
                .tag(0)
            WatchExercisesPage(store: store, workout: workout)
                .tag(1)
            WatchControlsPage(store: store)
                .tag(2)
        }
        .tabViewStyle(.verticalPage)
        .overlay(alignment: .top) {
            // The rest countdown follows the athlete onto every page. The
            // metrics page (0) has its own big headline, so the compact banner
            // rides the logging + controls pages so you never have to swipe to
            // find it.
            if selection != 0 {
                WatchRestBanner(workout: workout)
            }
        }
        .task {
            store.ensureWorkoutSessionRunning()
        }
    }
}

/// A compact, always-on rest countdown shown over the logging/controls pages.
/// Display-only (never intercepts touches); the phone owns the timer.
private struct WatchRestBanner: View {
    let workout: WatchWorkoutSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            if let endsAt = workout.restEndsAt, endsAt > context.date {
                let remaining = max(0, Int(endsAt.timeIntervalSince(context.date).rounded(.up)))
                let isMicro = workout.restIsMicro == true
                let tint = isMicro ? WTheme.teal : WTheme.accent
                HStack(spacing: 5) {
                    Image(systemName: "timer").font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                    Text(isMicro ? "MINI" : "REST").font(.system(size: 11, weight: .heavy)).foregroundStyle(tint)
                    Spacer(minLength: 4)
                    Text(WFmt.rest(remaining))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .contentTransition(.numericText(countsDown: true))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                .padding(.horizontal, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Metrics page

struct WatchMetricsPage: View {
    let store: WatchStore
    let workout: WatchWorkoutSnapshot

    @State private var engine = WatchWorkoutEngine.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(alignment: .leading, spacing: 6) {
                // Interval step, then rest countdown, take over the headline —
                // whichever number the athlete needs right now.
                if let stepName = workout.intervalStepName,
                   let stepEndsAt = workout.intervalStepEndsAt, stepEndsAt > context.date {
                    intervalHeadline(
                        name: stepName, endsAt: stepEndsAt, now: context.date,
                        kind: workout.intervalStepKind,
                        round: workout.intervalRound,
                        next: workout.intervalNextName)
                } else if let restEndsAt = workout.restEndsAt, restEndsAt > context.date {
                    restHeadline(endsAt: restEndsAt, now: context.date, isMicro: workout.restIsMicro == true)
                } else {
                    Text(WFmt.elapsed(max(0, Int(context.date.timeIntervalSince(workout.startedAt)))))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WTheme.gold)
                }

                HStack(spacing: 5) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(WTheme.danger)
                        .symbolEffect(.pulse, isActive: engine.heartRate != nil)
                    Text(engine.heartRate.map(String.init) ?? "—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("bpm").font(.system(size: 13)).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    metric("kcal", engine.activeEnergyKcal.map { String(Int($0)) } ?? "—", WTheme.teal)
                    metric("avg", engine.avgHR.map(String.init) ?? "—", .secondary)
                    metric("max", engine.maxHR.map(String.init) ?? "—", .secondary)
                }

                if let distance = engine.distanceMeters, distance > 0 {
                    metric("dist",
                           WFmt.distance(distance, unit: store.context?.effectiveDistanceUnit ?? .km),
                           WTheme.accent)
                }

                Spacer(minLength: 0)

                Text("\(workout.completedSets)/\(workout.totalSets) sets")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WTheme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 4)
        }
        .navigationTitle("")
    }

    private func intervalHeadline(
        name: String, endsAt: Date, now: Date,
        kind: String? = nil, round: String? = nil, next: String? = nil
    ) -> some View {
        let remaining = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        // Work runs hot (teal), recovery cools down (sage), book-ends gold —
        // the wrist reads the state from color alone.
        let tint: Color = switch kind {
        case "work": WTheme.teal
        case "recover": WTheme.accent
        case "warmup", "cooldown": WTheme.gold
        case "pose": WTheme.accent   // yoga hold — calm sage, not work-teal
        default: WTheme.teal
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(name.uppercased())
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if let round {
                    Text("· \(round)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(WFmt.rest(remaining))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(countsDown: true))
            if let next {
                Text("Next: \(next)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func restHeadline(endsAt: Date, now: Date, isMicro: Bool) -> some View {
        let remaining = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        // Micro-rests (myo-rep / drop / cluster) read teal, matching the phone.
        let tint = isMicro ? WTheme.teal : WTheme.accent
        return VStack(alignment: .leading, spacing: 0) {
            Text(isMicro ? "MINI-REST" : "REST")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(tint)
            Text(WFmt.rest(remaining))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(countsDown: true))
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Exercises / set logging page

struct WatchExercisesPage: View {
    let store: WatchStore
    let workout: WatchWorkoutSnapshot

    @State private var engine = WatchWorkoutEngine.shared

    var body: some View {
        NavigationStack {
            List {
                heartRateRow

                ForEach(workout.exercises) { exercise in
                    if exercise.isCardio {
                        cardioRow(exercise)
                    } else {
                        NavigationLink {
                            WatchSetListView(store: store, exerciseID: exercise.id)
                        } label: {
                            exerciseRow(exercise)
                        }
                    }
                }
            }
            .navigationTitle("Exercises")
        }
    }

    private var heartRateRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(WTheme.danger)
                .symbolEffect(.pulse, isActive: engine.heartRate != nil)
            Text(engine.heartRate.map { "\($0) bpm" } ?? "Starting HR…")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(engine.heartRate == nil ? .secondary : WTheme.danger)
            Spacer()
            if let avg = engine.avgHR {
                Text("avg \(avg)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .listRowBackground(WTheme.surface)
    }

    private func exerciseRow(_ exercise: WatchExerciseSnapshot) -> some View {
        let done = exercise.sets.filter(\.completed).count
        return VStack(alignment: .leading, spacing: 2) {
            Text(exercise.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 5) {
                if let group = exercise.supersetGroup {
                    Text("Superset \(supersetLetter(group))")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(WTheme.teal)
                }
                Text("\(done)/\(exercise.sets.count) sets")
                    .font(.system(size: 12))
                    .foregroundStyle(done == exercise.sets.count && !exercise.sets.isEmpty ? WTheme.success : .secondary)
            }
        }
    }

    /// Cardio never shows sets — it's a Start/Complete segment, auto-filled
    /// from the session's health data.
    private func cardioRow(_ exercise: WatchExerciseSnapshot) -> some View {
        Button {
            switch exercise.cardioState {
            case .notStarted, nil: store.startCardio(exercise)
            case .running: store.completeCardio(exercise)
            case .completed: break
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        if let group = exercise.supersetGroup {
                            Text("Superset \(supersetLetter(group))")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(WTheme.teal)
                        }
                        Text(cardioSubtitle(exercise.cardioState))
                            .font(.system(size: 12))
                            .foregroundStyle(WTheme.teal)
                    }
                }
                Spacer()
                Image(systemName: cardioIcon(exercise.cardioState))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(exercise.cardioState == .completed ? WTheme.success : WTheme.teal)
            }
        }
    }

    private func cardioSubtitle(_ state: WatchExerciseSnapshot.CardioState?) -> String {
        switch state {
        case .running: "Recording…"
        case .completed: "Completed"
        default: "Tap to start"
        }
    }

    private func cardioIcon(_ state: WatchExerciseSnapshot.CardioState?) -> String {
        switch state {
        case .running: "stop.circle.fill"
        case .completed: "checkmark.circle.fill"
        default: "play.circle.fill"
        }
    }

    private func supersetLetter(_ group: Int) -> String {
        guard group >= 0, group < 26 else { return "\(group + 1)" }
        let scalar = UnicodeScalar(65 + group)!
        return String(Character(scalar))
    }
}

/// One exercise's sets: tap a row to check it off (mirrors to the phone
/// instantly). Weight × reps are shown as logged on the phone.
struct WatchSetListView: View {
    let store: WatchStore
    let exerciseID: UUID

    @State private var editingSet: WatchSetSnapshot?

    private var exercise: WatchExerciseSnapshot? {
        store.activeWorkout?.exercises.first { $0.id == exerciseID }
    }

    /// The set the double-tap gesture targets.
    private var firstUncompletedSetID: UUID? {
        exercise?.sets.first { !$0.completed }?.id
    }

    var body: some View {
        List {
            if let exercise {
                ForEach(exercise.sets) { set in
                    Button {
                        store.toggleSet(set, in: exercise)
                    } label: {
                        HStack(spacing: 8) {
                            Text(set.label.isEmpty ? "–" : set.label)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(set.completed ? WTheme.success : WTheme.accent)
                                .frame(width: 26, alignment: .leading)
                            Text(setDescription(set))
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                            Spacer()
                            Image(systemName: set.completed ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(set.completed ? WTheme.success : .secondary)
                        }
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            editingSet = set
                        }
                    )
                    // Double-tap (watch hand gesture) completes the NEXT
                    // uncompleted set — mid-set, hands on the bar, no screen
                    // touch needed (T3-5).
                    .handGestureShortcut(.primaryAction, isEnabled: set.id == firstUncompletedSetID)
                    .listRowBackground(
                        (set.completed ? WTheme.success.opacity(0.12) : WTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    )
                }
                Text("Long-press a set to edit weight & reps")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(exercise?.name ?? "Sets")
        .sheet(item: $editingSet) { set in
            if let exercise {
                WatchSetEditView(store: store, exercise: exercise, set: set)
            }
        }
    }

    private func setDescription(_ set: WatchSetSnapshot) -> String {
        let unit = set.unitSuffix ?? store.context?.unitSuffix ?? "lb"
        let weight = set.weight.map { "\(WFmt.weight($0))\(unit)" }
        let reps = set.reps.map { "× \($0)" }
        let parts = [weight, reps].compactMap { $0 }
        return parts.isEmpty ? "Tap to log" : parts.joined(separator: " ")
    }
}

// MARK: - Controls page

struct WatchControlsPage: View {
    let store: WatchStore
    @State private var confirmFinish = false
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 10) {
            Button {
                confirmFinish = true
            } label: {
                Label("Finish", systemImage: "checkmark")
                    .font(.system(size: 16, weight: .bold))
            }
            .tint(WTheme.success)
            .buttonStyle(.borderedProminent)

            Button {
                confirmDiscard = true
            } label: {
                Label("Discard", systemImage: "trash")
                    .font(.system(size: 15, weight: .semibold))
            }
            .tint(WTheme.danger)
        }
        .padding(.horizontal, 4)
        .confirmationDialog("Finish workout?", isPresented: $confirmFinish) {
            Button("Finish Workout") { store.finishWorkout() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Discard workout?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { store.discardWorkout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Same stakes-warning the phone shows — discard is irreversible.
            Text("All logged sets from this session will be lost.")
        }
    }
}

// MARK: - Summary

/// Post-workout reflection: what you did and how your body responded.
struct WatchSummaryView: View {
    let store: WatchStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Workout Complete", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(WTheme.success)

                if let summary = store.summary {
                    summaryRow("Duration", WFmt.elapsed(summary.durationSeconds), WTheme.gold)
                    summaryRow("Sets", "\(summary.completedSets)", WTheme.accent)
                    summaryRow("Avg HR", summary.metrics.avgHR.map { "\($0) bpm" } ?? "—", WTheme.danger)
                    summaryRow("Max HR", summary.metrics.maxHR.map { "\($0) bpm" } ?? "—", WTheme.danger)
                    summaryRow("Energy", summary.metrics.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "—", WTheme.teal)
                }

                Button("Done") { store.summary = nil }
                    .buttonStyle(.borderedProminent)
                    .tint(WTheme.accent)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
