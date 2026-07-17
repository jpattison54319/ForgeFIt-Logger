import ForgeCore
import SwiftUI
import Testing
@testable import ForgeFit

/// Regression guard for the light-mode contrast bug: `Action.tint`,
/// `ReasonTone.foreground/background` and `Step.Kind.tint` once hardcoded
/// `AppTheme.sage`, drawing dark-tuned signal hues (~1.8:1 contrast) on
/// light-mode's white cards. Injection is proven by every case resolving to a
/// DIFFERENT color per theme (`sageLight` deepens all signal hues).
@MainActor
struct ThemeTintInjectionTests {

    @Test func recoveryActionTintFollowsTheme() {
        for action in [RecoveryEngine.Action.push, .trainAsPlanned, .reduceVolume, .deloadRecover] {
            #expect(action.tint(in: .sage) != action.tint(in: .sageLight), "\(action) ignores the active theme")
        }
    }

    @Test func reasonToneColorsFollowTheme() {
        for tone in [RecoveryEngine.ReasonTone.positive, .caution, .neutral] {
            #expect(tone.foreground(in: .sage) != tone.foreground(in: .sageLight), "\(tone) foreground ignores the active theme")
            #expect(tone.background(in: .sage) != tone.background(in: .sageLight), "\(tone) background ignores the active theme")
        }
    }

    @Test func intervalStepTintFollowsTheme() {
        for kind in [IntervalPlan.Step.Kind.warmup, .work, .recover, .cooldown] {
            #expect(kind.tint(in: .sage) != kind.tint(in: .sageLight), "\(kind) ignores the active theme")
        }
    }
}
