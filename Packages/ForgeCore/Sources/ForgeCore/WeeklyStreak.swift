import Foundation

/// Weekly-goal streak with automatic freezes — the evidence-backed
/// replacement for a raw consecutive-day chain (daily chains punish the rest
/// days training requires; Duolingo's freeze data shows forgiveness *adds*
/// retention). The streak counts consecutive weeks meeting a user-set
/// "N workouts/week" goal, and a missed week is absorbed by a freeze token
/// when one is banked.
///
/// Everything is derived deterministically from workout history, so there is
/// no streak state to persist, migrate, or sync: tokens start at 1, one more
/// is earned every 4 consecutive goal-met weeks (banked cap 2), and a missed
/// week either spends a token (streak survives, week marked frozen) or ends
/// the run.
public enum WeeklyStreak {

    public struct Result: Equatable, Sendable {
        /// Consecutive goal-met weeks, counting the current week only once
        /// it has met the goal.
        public let weeks: Int
        /// The longest run ever achieved (trophy math), current run included.
        public let longestWeeks: Int
        /// Completed workouts inside the current calendar week.
        public let thisWeekCount: Int
        public let goalPerWeek: Int
        /// Freeze tokens currently banked.
        public let freezesBanked: Int
        /// Start-of-week dates the streak survived on a freeze.
        public let frozenWeeks: [Date]
        /// True when the goal can still be met this week only by training on
        /// every remaining day (including today) — the honest nudge moment.
        public let mustTrainToday: Bool

        public var thisWeekMet: Bool { thisWeekCount >= goalPerWeek }
    }

    private static let startingTokens = 1
    private static let tokenEveryMetWeeks = 4
    private static let tokenCap = 2

    /// - Parameter workoutDates: start dates of COMPLETED workouts, any order.
    public static func compute(
        workoutDates: [Date],
        goalPerWeek: Int,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Result {
        let goal = max(1, goalPerWeek)
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return Result(weeks: 0, longestWeeks: 0, thisWeekCount: 0, goalPerWeek: goal,
                          freezesBanked: startingTokens, frozenWeeks: [], mustTrainToday: false)
        }

        // Bucket workouts by start-of-week.
        var countByWeek: [Date: Int] = [:]
        for date in workoutDates where date <= now {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { continue }
            countByWeek[week, default: 0] += 1
        }
        let thisWeekCount = countByWeek[thisWeekStart] ?? 0

        // Walk every week from the first workout up to (not including) the
        // current one, simulating the token economy in order.
        var streak = 0
        var longest = 0
        var tokens = startingTokens
        var metSinceToken = 0
        var frozen: [Date] = []
        if let firstWeek = countByWeek.keys.min(), firstWeek < thisWeekStart {
            var week = firstWeek
            while week < thisWeekStart {
                if (countByWeek[week] ?? 0) >= goal {
                    streak += 1
                    longest = max(longest, streak)
                    metSinceToken += 1
                    if metSinceToken >= tokenEveryMetWeeks {
                        metSinceToken = 0
                        tokens = min(tokenCap, tokens + 1)
                    }
                } else if streak > 0, tokens > 0 {
                    tokens -= 1
                    frozen.append(week)
                } else {
                    streak = 0
                    tokens = startingTokens
                    metSinceToken = 0
                    frozen.removeAll()
                }
                guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: week) else { break }
                week = next
            }
        }
        if thisWeekCount >= goal { streak += 1 }
        longest = max(longest, streak)

        // "Must train today": the remaining days this week (today included)
        // exactly match the workouts still needed. Trained today already →
        // today's box is ticked, no alarm.
        let trainedToday = workoutDates.contains { calendar.isDate($0, inSameDayAs: now) }
        let needed = max(0, goal - thisWeekCount)
        let daysLeft: Int = {
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return 0 }
            let today = calendar.startOfDay(for: now)
            return max(0, calendar.dateComponents([.day], from: today, to: interval.end).day ?? 0)
        }()
        let mustTrainToday = needed > 0 && needed >= daysLeft && !trainedToday && streak > 0

        return Result(
            weeks: streak,
            longestWeeks: longest,
            thisWeekCount: thisWeekCount,
            goalPerWeek: goal,
            freezesBanked: tokens,
            frozenWeeks: frozen,
            mustTrainToday: mustTrainToday
        )
    }
}
