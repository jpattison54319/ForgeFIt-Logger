import Foundation

/// App-level feature flags. Each reads a `UserDefaults` key so a build can be
/// flipped without a rebuild (launch argument `-<key> YES`, or a debug toggle);
/// an unset key resolves to the shipping default (`bool(forKey:)` → `false`).
enum FeatureFlags {
    /// Coach's Corner — the full readiness + progression + weekly-review
    /// surface. Held OFF while the periodization / weekly-review layer is still
    /// being fleshed out: with it off, Home surfaces a direct "Ask your Coach"
    /// AI chat instead of the Corner sheet. Flip the `coach_corner` default on
    /// (or set the key) once the weekly-review flow is complete.
    nonisolated static var coachCorner: Bool {
        UserDefaults.standard.bool(forKey: "coach_corner")
    }

    /// Community — public profiles, follows, shared workouts, likes,
    /// leaderboards. Held OFF for 1.0.
    ///
    /// Two things have to land before it can ship. The opt-in screen offers an
    /// "Approve followers" mode that nothing enforces: the chosen visibility is
    /// stored on the profile record and never read again, and the public
    /// database grants world read on profiles and shared workouts, so no client
    /// gate could enforce it anyway. And user-generated content — handles,
    /// display names, shared workouts — needs reporting, blocking, and a terms
    /// gate before it can go in front of App Review (Guideline 1.2).
    ///
    /// With this off, `SocialService` never contacts CloudKit and
    /// `isOptedIn` is always false, which is the single gate every publish,
    /// reconcile, and hearts path already checks.
    nonisolated static var social: Bool {
        UserDefaults.standard.bool(forKey: "social")
    }

    /// Launching a coach-adjusted version of a routine from Home — the
    /// "Review coach's version" button under Up next, and the welcome-back
    /// card's "Ease back in". Held OFF: ForgeFit shows you your training and
    /// gets out of the way; it doesn't prescribe a modified dose.
    ///
    /// The machinery stays intact (`CoachAdjustments`, `RoutineDoseContext`,
    /// `CoachAdjustmentReviewView`) — this only removes Home's entry points, so
    /// turning it back on is a one-key change. `CoachCornerView` has its own
    /// review entry and is gated separately by `coachCorner`.
    nonisolated static var coachDoseReview: Bool {
        UserDefaults.standard.bool(forKey: "coach_dose_review")
    }

    /// Home's expandable daily recommendation. Held OFF while ForgeFit moves
    /// away from recommendation-led presentation. Recovery data and the
    /// recommendation engine remain intact for the metric tiles, detail views,
    /// notifications, widgets, and a possible future return of this card.
    nonisolated static var homeDailyRecommendation: Bool {
        UserDefaults.standard.bool(forKey: "home_daily_recommendation")
    }

    /// The large suggested-routine card above Home's quick-launch tiles. Held
    /// OFF so the workout entry point is the neutral "Quick start" collection.
    /// The suggestion and launch path remain intact behind this one gate.
    nonisolated static var homeSuggestedWorkout: Bool {
        UserDefaults.standard.bool(forKey: "home_suggested_workout")
    }

    /// The explanatory sentence beneath the green action on Recovery Today.
    /// The action remains visible; only the supporting recommendation copy is
    /// held back.
    nonisolated static var recoveryActionDetail: Bool {
        UserDefaults.standard.bool(forKey: "recovery_action_detail")
    }

    /// The CR10 methodology line under a ready weekly-load comparison. Empty
    /// and building states keep their explanations because those communicate
    /// why a comparison is unavailable.
    nonisolated static var trainingLoadMethodDetail: Bool {
        UserDefaults.standard.bool(forKey: "training_load_method_detail")
    }
}
