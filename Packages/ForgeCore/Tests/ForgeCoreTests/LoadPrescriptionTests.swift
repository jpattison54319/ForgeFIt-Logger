import Testing
@testable import ForgeCore

struct LoadPrescriptionTests {
    @Test func parsesExactDecimalPercentage() throws {
        let value = try #require(EstimatedOneRepMaxPrescription.parse("82.5%"))
        #expect(value.lowPercent == 82.5)
        #expect(value.highPercent == nil)
    }

    @Test func parsesAndNormalizesPercentageRange() throws {
        let value = try #require(EstimatedOneRepMaxPrescription.parse("67–72"))
        #expect(value.lowPercent == 67)
        #expect(value.highPercent == 72)
    }

    @Test func rejectsInvalidAndReversedPercentages() {
        #expect(EstimatedOneRepMaxPrescription.parse("0") == nil)
        #expect(EstimatedOneRepMaxPrescription.parse("101") == nil)
        #expect(EstimatedOneRepMaxPrescription.parse("72-67") == nil)
        #expect(EstimatedOneRepMaxPrescription.parse("67-") == nil)
    }

    @Test func resolvesAgainstEstimatedOneRepMax() throws {
        let exact = try #require(EstimatedOneRepMaxPrescription.parse("82.5"))
        let exactLoad = try #require(exact.resolving(estimatedOneRepMaxKg: 100))
        #expect(exactLoad.lowKg == 82.5)
        #expect(exactLoad.highKg == 82.5)

        let range = try #require(EstimatedOneRepMaxPrescription.parse("67-72"))
        let rangedLoad = try #require(range.resolving(estimatedOneRepMaxKg: 100))
        #expect(rangedLoad.lowKg == 67)
        #expect(rangedLoad.highKg == 72)
    }
}
