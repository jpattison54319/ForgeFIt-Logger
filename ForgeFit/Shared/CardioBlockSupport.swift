import Foundation

/// Pure helpers behind the cardio disclosure cards in mixed-workout detail:
/// deciding when a workout is mixed, composing the compact collapsed-card
/// text, and slicing whole-workout HR samples down to one cardio block.
enum CardioBlockSupport {
    /// A workout is "mixed" when it has both strength work and cardio blocks —
    /// only then do cardio cards collapse behind a disclosure. Strength
    /// exercises are the ones no cardio session is linked to.
    static func isMixedWorkout(
        exerciseIDs: [UUID],
        cardioLinkedExerciseIDs: Set<UUID>,
        cardioSessionCount: Int
    ) -> Bool {
        guard cardioSessionCount > 0 else { return false }
        return exerciseIDs.contains { !cardioLinkedExerciseIDs.contains($0) }
    }

    /// "18min Run" / "1h 5min Run" — just the name when there's no duration.
    static func compactTitle(durationSeconds: Int?, name: String) -> String {
        guard let durationSeconds, durationSeconds > 0 else { return name }
        return "\(Fmt.durationShort(durationSeconds)) \(name)"
    }

    /// "5.2 km · 152 bpm · 240 kcal · 7/10" — each part only when available;
    /// nil when nothing is. Distance arrives pre-formatted so the helper stays
    /// free of unit-preference lookups.
    static func compactSubtitle(
        distance: String?,
        avgHR: Int?,
        calories: Double?,
        effort: Int?
    ) -> String? {
        var parts: [String] = []
        if let distance { parts.append(distance) }
        if let avgHR { parts.append("\(avgHR) bpm") }
        if let calories { parts.append("\(Int(calories)) kcal") }
        if let effort { parts.append("\(effort)/10") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The time window one cardio block occupied within the workout — what its
    /// slice of the whole-workout HR series is keyed on. `liveStartedAt` is
    /// the HealthKit-accurate start when the block was run live; falls back to
    /// `startedAt` + duration when there's no recorded end.
    static func blockWindow(
        startedAt: Date,
        liveStartedAt: Date?,
        endedAt: Date?,
        durationSeconds: Int?
    ) -> ClosedRange<Date>? {
        let start = liveStartedAt ?? startedAt
        let end: Date
        if let endedAt {
            end = endedAt
        } else if let durationSeconds, durationSeconds > 0 {
            end = start.addingTimeInterval(TimeInterval(durationSeconds))
        } else {
            return nil
        }
        guard end > start else { return nil }
        return start...end
    }

    /// Whole-workout HR samples restricted to one block's window.
    static func hrSlice(
        samples: [(date: Date, bpm: Int)],
        window: ClosedRange<Date>
    ) -> [(date: Date, bpm: Int)] {
        samples.filter { window.contains($0.date) }
    }
}
