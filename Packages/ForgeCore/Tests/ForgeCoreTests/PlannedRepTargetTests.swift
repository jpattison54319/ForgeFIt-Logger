import Testing
@testable import ForgeCore

struct PlannedRepTargetTests {
    @Test func exactAndRangeTargetsRemainDistinct() throws {
        let exact = try #require(PlannedRepTarget(low: 5, high: 5))
        #expect(exact.displayText == "5")
        #expect(exact.exactValue == 5)
        #expect(exact.lowerBound == 5)

        let range = try #require(PlannedRepTarget(low: 8, high: 5))
        #expect(range.displayText == "5–8")
        #expect(range.exactValue == nil)
        #expect(range.lowerBound == 5)
        #expect(range.upperBound == 8)
    }

    @Test func oneBoundIsAnExactTargetAndNoBoundsStayAbsent() {
        #expect(PlannedRepTarget(low: 5, high: nil)?.exactValue == 5)
        #expect(PlannedRepTarget(low: nil, high: 7)?.exactValue == 7)
        #expect(PlannedRepTarget(low: nil, high: nil) == nil)
    }
}
