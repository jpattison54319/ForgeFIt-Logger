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

    /// Bluetooth heart-rate monitors — the Settings pairing row, the pairing
    /// sheet, the HRM column in the connection hero, and the reconnect that
    /// runs when a workout starts. Held OFF for 1.0.
    ///
    /// App Review cited the `bluetooth-central` background mode under
    /// Guideline 2.5.4 and asked for a physical-device recording of Bluetooth
    /// in use. With no strap on hand to film, the background mode came out of
    /// `AppInfo.plist` and the entry points came out with it — a feature a
    /// reviewer can see but cannot exercise is worse than no feature at all.
    ///
    /// `BLEHeartRateService` and everything downstream of it are untouched;
    /// this gate only hides the ways in. Because `CBCentralManager` is built
    /// lazily on first use, gating the reconnect call means it is never
    /// constructed and iOS never asks for Bluetooth permission.
    ///
    /// Turning this back on also needs `bluetooth-central` restored to
    /// `AppInfo.plist`, or a paired strap will drop as soon as the app leaves
    /// the foreground. `NSBluetoothAlwaysUsageDescription` was deliberately
    /// left in place so flipping this key alone can never crash on launch.
    nonisolated static var bluetoothHeartRate: Bool {
        UserDefaults.standard.bool(forKey: "bluetooth_heart_rate")
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
