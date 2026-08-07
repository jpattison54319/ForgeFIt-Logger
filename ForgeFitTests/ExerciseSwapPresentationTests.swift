import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

struct ExerciseSwapPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func usageCaptionExplainsFrequencyAndRecency() {
        let caption = ExerciseSwapPresentation.caption(
            for: [
                .sharedMuscles(["chest"]),
                .sameMovementFamily(.push),
                .usage(recentSessionCount: 5, lastUsedAt: now.addingTimeInterval(-6 * 86_400))
            ],
            referenceDate: now
        )

        #expect(caption == "Chest · 5 sessions in 90d · Last used 6d ago · Same push movement")
    }

    @Test func exactPatternAvoidsRedundantMovementFamilyCopy() {
        let caption = ExerciseSwapPresentation.caption(
            for: [.samePattern, .sameMovementFamily(.pull)],
            referenceDate: now
        )

        #expect(caption == "Same movement pattern")
    }

    @Test func todayAndOlderHistoryStayPlainLanguage() {
        #expect(
            ExerciseSwapPresentation.caption(
                for: [.usage(recentSessionCount: 1, lastUsedAt: now)],
                referenceDate: now
            ) == "1 session in 90d · Last used today"
        )
        #expect(
            ExerciseSwapPresentation.caption(
                for: [.usage(recentSessionCount: 0, lastUsedAt: now.addingTimeInterval(-120 * 86_400))],
                referenceDate: now
            ) == "Last used 120d ago"
        )
    }
}
