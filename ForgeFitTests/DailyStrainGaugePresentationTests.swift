import Testing
@testable import ForgeFit

struct DailyStrainGaugePresentationTests {
    private let usualRange = 4.0...6.0

    @Test func usualIsARangeCenteredOnTheGauge() throws {
        let low = DailyStrainGaugePresentation(score: 4, usualRange: usualRange)
        let middle = DailyStrainGaugePresentation(score: 5, usualRange: usualRange)
        let high = DailyStrainGaugePresentation(score: 6, usualRange: usualRange)

        #expect(low.band == .usual)
        #expect(middle.band == .usual)
        #expect(high.band == .usual)
        #expect(try #require(low.position) == 0.4)
        #expect(try #require(middle.position) == 0.5)
        #expect(try #require(high.position) == 0.6)
    }

    @Test func lowerAndHigherScoresFillAwayFromTheCenter() throws {
        let lower = DailyStrainGaugePresentation(score: 3, usualRange: usualRange)
        let higher = DailyStrainGaugePresentation(score: 7, usualRange: usualRange)

        #expect(lower.band == .belowUsual)
        #expect(higher.band == .aboveUsual)
        #expect(try #require(lower.position) < 0.5)
        #expect(try #require(higher.position) > 0.5)
    }

    @Test func outerRangesDescribeLargerDeviations() {
        #expect(DailyStrainGaugePresentation(score: 1, usualRange: usualRange).band == .muchLower)
        #expect(DailyStrainGaugePresentation(score: 9, usualRange: usualRange).band == .muchHigher)
    }

    @Test func missingPersonalRangeDoesNotClaimDirection() {
        let presentation = DailyStrainGaugePresentation(score: 5, usualRange: nil)

        #expect(presentation.band == .rangePending)
        #expect(presentation.position == nil)
    }

    @Test func labelsDistinguishEveryGaugeState() {
        #expect(DailyStrainGaugePresentation(score: nil, usualRange: nil).band.title == "Collecting baseline")
        #expect(DailyStrainGaugePresentation(score: 5, usualRange: nil).band.title == "More history needed")
        #expect(DailyStrainGaugePresentation(score: 1, usualRange: usualRange).band.title == "Far below usual")
        #expect(DailyStrainGaugePresentation(score: 3, usualRange: usualRange).band.title == "Below usual")
        #expect(DailyStrainGaugePresentation(score: 5, usualRange: usualRange).band.title == "In your usual range")
        #expect(DailyStrainGaugePresentation(score: 7, usualRange: usualRange).band.title == "Above usual")
        #expect(DailyStrainGaugePresentation(score: 9, usualRange: usualRange).band.title == "Far above usual")
    }
}
