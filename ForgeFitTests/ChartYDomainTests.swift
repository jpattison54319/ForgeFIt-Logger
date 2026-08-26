import Testing
@testable import ForgeFit

struct ChartYDomainTests {
    @Test func heartRateRangeUsesRoundedObservedBoundsInsteadOfZero() {
        #expect(ChartYDomain.padded(values: [70, 180], lowerLimit: 0) == 50...200)
    }

    @Test func closeDurationValuesRemainReadable() {
        #expect(ChartYDomain.padded(values: [21, 28], lowerLimit: 0) == 20...30)
    }

    @Test func flatSeriesStillReceivesVisibleContext() {
        #expect(ChartYDomain.padded(values: [120, 120], lowerLimit: 0) == 100...140)
    }

    @Test func lowerLimitPreventsImpossibleNegativeMeasurementTicks() {
        #expect(ChartYDomain.padded(values: [0, 0], lowerLimit: 0).lowerBound == 0)
    }

    @Test func signedChangeMetricsRetainNegativeValues() {
        let domain = ChartYDomain.padded(values: [-12, -4])
        #expect(domain.lowerBound <= -12)
        #expect(domain.upperBound >= -4)
    }

    @Test func nonFiniteValuesDoNotCorruptTheDomain() {
        #expect(ChartYDomain.padded(values: [.nan, 70, 180, .infinity], lowerLimit: 0) == 50...200)
    }
}
