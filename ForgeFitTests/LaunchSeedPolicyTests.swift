import Testing
@testable import ForgeFit

/// The launch-seed gate: getting this wrong either re-runs the full catalog
/// seed every cold launch (the perf bug it fixes) or skips seeding a store
/// that genuinely needs it (much worse).
struct LaunchSeedPolicyTests {

    @Test func freshInstallSeeds() {
        // Fresh defaults read 0; fresh store has no exercises.
        #expect(LaunchSeedPolicy.shouldSeed(storedVersion: 0, libraryCount: 0, forcedReset: false))
    }

    @Test func upToDateLaunchSkips() {
        #expect(!LaunchSeedPolicy.shouldSeed(
            storedVersion: LaunchSeedPolicy.currentVersion,
            libraryCount: 900,
            forcedReset: false
        ))
    }

    @Test func catalogBumpReseeds() {
        #expect(LaunchSeedPolicy.shouldSeed(
            storedVersion: 1, currentVersion: 2,
            libraryCount: 900, forcedReset: false
        ))
    }

    /// Store recreated behind UserDefaults' back (migration-failure reset in
    /// ForgeFitApp, manual store deletion): the stamp says seeded, the store
    /// is empty — count wins.
    @Test func emptyStoreReseedsDespiteCurrentStamp() {
        #expect(LaunchSeedPolicy.shouldSeed(
            storedVersion: LaunchSeedPolicy.currentVersion,
            libraryCount: 0,
            forcedReset: false
        ))
    }

    /// `--reset-store` (UI-test automation) wipes the store in the same
    /// launch — must always reseed regardless of the stamp.
    @Test func forcedResetAlwaysReseeds() {
        #expect(LaunchSeedPolicy.shouldSeed(
            storedVersion: LaunchSeedPolicy.currentVersion,
            libraryCount: 900,
            forcedReset: true
        ))
    }

    /// A downgraded stamp never blocks (defensive: stored > current happens
    /// after a TestFlight downgrade — still skip, the library exists).
    @Test func newerStampThanBundledSkips() {
        #expect(!LaunchSeedPolicy.shouldSeed(
            storedVersion: 99,
            libraryCount: 900,
            forcedReset: false
        ))
    }
}
