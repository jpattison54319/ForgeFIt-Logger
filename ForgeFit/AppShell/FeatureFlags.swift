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
}
