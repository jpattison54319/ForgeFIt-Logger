import Foundation

/// Rule engine for the Wrapped coaching pages: "What improved", "What held
/// you back", and the closing "Next Month Focus". Pure — takes precomputed
/// ingredient numbers, emits copy with SPECIFIC values and actions (the
/// request's bar: "Add 2 easy Zone 2 cardio sessions per week", never "try
/// to be more balanced").
enum WrappedInsights {
    struct Ingredients {
        var workouts = 0
        var workoutsDelta: Int?
        var volumeKg: Double = 0
        var volumeDeltaKg: Double?
        var activeDays = 0
        var strengthCount = 0
        var cardioCount = 0
        var cardioMinutes = 0
        /// Seconds in HR zones 1–5.
        var zoneSeconds: [Int] = [0, 0, 0, 0, 0]
        var pushSets: Double = 0
        var pullSets: Double = 0
        var recordsSet = 0
        var bestE1RMGainKg: Double?
        var bestLiftName: String?
        var avgRPEFirstHalf: Double?
        var avgRPESecondHalf: Double?
        /// Mean readiness-at-start for the first/second halves of the period.
        var readinessFirstHalf: Double?
        var readinessSecondHalf: Double?
    }

    struct Insight: Equatable {
        let headline: String
        let detail: String
    }

    struct Outcome: Equatable {
        var improved: Insight?
        var heldBack: Insight?
        var focus: WrappedPage.Focus
    }

    private struct Candidate {
        let priority: Int           // higher wins
        let insight: Insight
        /// Actionable next-month instruction (negatives only).
        var action: String?
        /// "Maintain" phrasing (positives only).
        var maintain: String?
    }

    static func evaluate(_ i: Ingredients) -> Outcome {
        var positives: [Candidate] = []
        var negatives: [Candidate] = []

        // MARK: Positives

        if i.recordsSet >= 2 {
            positives.append(Candidate(
                priority: 90,
                insight: Insight(
                    headline: "\(i.recordsSet) records fell",
                    detail: "You set \(i.recordsSet) all-time bests this period — strength is trending exactly the right way."
                ),
                maintain: "the progressive overload that produced \(i.recordsSet) records"
            ))
        }
        if let delta = i.workoutsDelta, delta >= 3 {
            positives.append(Candidate(
                priority: 80,
                insight: Insight(
                    headline: "Consistency climbed",
                    detail: "You trained \(delta) more times than last month — showing up is the hardest part, and you did."
                ),
                maintain: "your \(i.workouts)-session pace"
            ))
        }
        if let gain = i.bestE1RMGainKg, gain > 0, let lift = i.bestLiftName {
            positives.append(Candidate(
                priority: 70,
                insight: Insight(
                    headline: "\(lift) got stronger",
                    detail: "Your estimated 1RM on \(lift) climbed \(Fmt.loadUnit(gain)) — the biggest jump of the period."
                ),
                maintain: "weekly heavy work on \(lift)"
            ))
        }
        let cardioSeconds = max(1, i.zoneSeconds.reduce(0, +))
        let easyShare = Double(i.zoneSeconds[0] + i.zoneSeconds[1]) / Double(cardioSeconds)
        let hardShare = Double(i.zoneSeconds[3] + i.zoneSeconds[4]) / Double(cardioSeconds)
        if i.cardioMinutes >= 60, easyShare >= 0.6 {
            positives.append(Candidate(
                priority: 60,
                insight: Insight(
                    headline: "Aerobic base, built right",
                    detail: "\(Int((easyShare * 100).rounded()))% of your cardio stayed in Zones 1–2 — the polarized mix endurance research favors."
                ),
                maintain: "the easy-pace cardio base"
            ))
        }
        if positives.isEmpty, i.activeDays >= 4 {
            positives.append(Candidate(
                priority: 10,
                insight: Insight(
                    headline: "\(i.activeDays) active days",
                    detail: "Every one of them is a deposit. The trend is what matters."
                ),
                maintain: "your \(i.activeDays)-day rhythm"
            ))
        }

        // MARK: Negatives (each carries a specific next-month action)

        if let volumeDelta = i.volumeDeltaKg, volumeDelta > 0,
           let first = i.readinessFirstHalf, let second = i.readinessSecondHalf,
           volumeDelta >= max(1, i.volumeKg - volumeDelta) * 0.25,
           second <= first - 5 {
            negatives.append(Candidate(
                priority: 95,
                insight: Insight(
                    headline: "Load outran recovery",
                    detail: "Volume jumped \(Fmt.volume(volumeDelta)) while your readiness slid from \(Int(first.rounded())) to \(Int(second.rounded())) — the classic overreach pattern."
                ),
                action: "Hold total volume at this month's level (no increases) and protect one full rest day per week."
            ))
        }
        if i.cardioMinutes >= 60, hardShare > 0.5 {
            negatives.append(Candidate(
                priority: 85,
                insight: Insight(
                    headline: "Cardio ran hot",
                    detail: "\(Int((hardShare * 100).rounded()))% of your cardio time sat in Zones 4–5 — hard sessions crowd out the easy volume that builds your base."
                ),
                action: "Add 2 easy Zone 2 sessions (25–35 min) per week and cap hard intervals at 1."
            ))
        }
        if i.pullSets >= 1, i.pushSets >= i.pullSets * 1.75 {
            let ratio = (i.pushSets / max(0.5, i.pullSets)).formatted(.number.precision(.fractionLength(1)))
            negatives.append(Candidate(
                priority: 75,
                insight: Insight(
                    headline: "Push outpaced pull",
                    detail: "Pressing volume ran \(ratio)× your pulling volume — that gap is how shoulders start complaining."
                ),
                action: "Add 2 pulling exercises (rows, pull-ups) per week until pull volume roughly matches push."
            ))
        } else if i.pushSets >= 1, i.pullSets >= i.pushSets * 1.75 {
            let ratio = (i.pullSets / max(0.5, i.pushSets)).formatted(.number.precision(.fractionLength(1)))
            negatives.append(Candidate(
                priority: 70,
                insight: Insight(
                    headline: "Pull outpaced push",
                    detail: "Pulling volume ran \(ratio)× your pressing volume."
                ),
                action: "Add 1–2 pressing movements per week to rebalance."
            ))
        }
        if let first = i.avgRPEFirstHalf, let second = i.avgRPESecondHalf,
           second - first >= 0.5, (i.bestE1RMGainKg ?? 0) <= 0 {
            negatives.append(Candidate(
                priority: 80,
                insight: Insight(
                    headline: "Effort rose, output didn't",
                    detail: "Average RPE climbed from \(first.formatted(.number.precision(.fractionLength(1)))) to \(second.formatted(.number.precision(.fractionLength(1)))) while estimated strength stayed flat — fatigue is masking fitness."
                ),
                action: "Take one lighter week: cut sets per exercise by about a third, keep the weights."
            ))
        }
        if i.activeDays < 8, i.workouts >= 1 {
            negatives.append(Candidate(
                priority: 65,
                insight: Insight(
                    headline: "Consistency was the bottleneck",
                    detail: "\(i.activeDays) active days this period — results follow frequency more than any single session."
                ),
                action: "Anchor 3 fixed training days per week (say Mon/Wed/Fri) and treat them as appointments."
            ))
        }
        if i.cardioCount == 0, i.strengthCount >= 4 {
            negatives.append(Candidate(
                priority: 55,
                insight: Insight(
                    headline: "No cardio on the books",
                    detail: "\(i.strengthCount) strength sessions and zero cardio — your engine deserves a slot too."
                ),
                action: "Add 2 easy Zone 2 sessions (25–35 min) per week alongside your \(i.strengthCount / 4)-plus strength days."
            ))
        } else if i.strengthCount == 0, i.cardioCount >= 4 {
            negatives.append(Candidate(
                priority: 55,
                insight: Insight(
                    headline: "All engine, no armor",
                    detail: "\(i.cardioCount) cardio sessions and zero strength work — lifting is what keeps the chassis strong."
                ),
                action: "Add 2 full-body strength sessions per week; 45 minutes each is plenty."
            ))
        }

        let improved = positives.max { $0.priority < $1.priority }
        let heldBack = negatives.max { $0.priority < $1.priority }
        let secondary = negatives
            .filter { $0.insight != heldBack?.insight }
            .max { $0.priority < $1.priority }

        let focus = WrappedPage.Focus(
            primary: heldBack?.action
                ?? "Repeat this month's structure — the mix is working. Nudge one lift's load up each week.",
            secondary: secondary?.action,
            maintain: improved?.maintain.map { "Maintain \($0)." }
        )
        return Outcome(improved: improved?.insight, heldBack: heldBack?.insight, focus: focus)
    }
}
