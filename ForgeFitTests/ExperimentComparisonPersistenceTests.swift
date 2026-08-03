import Foundation
import Testing
@testable import ForgeFit

struct ExperimentComparisonPersistenceTests {
    @Test
    func savedComparisonRoundTripsReferenceAndExplicitTrackerPairs() throws {
        let currentTrackerID = UUID()
        let referenceTrackerID = UUID()
        let referenceExperimentID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = ExperimentSavedComparison(
            reference: .experiment(
                id: referenceExperimentID,
                start: start,
                end: start.addingTimeInterval(3_600),
                timeZoneIdentifier: "UTC"
            ),
            customTrackerPairs: [currentTrackerID: referenceTrackerID]
        )
        let data = try JSONEncoder().encode(saved)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try #require(ExperimentSavedComparison.decode(json))

        #expect(decoded.reference == saved.reference)
        #expect(decoded.customTrackerPairs[currentTrackerID] == referenceTrackerID)
    }

    @Test
    func legacyReferenceOnlyJSONStillLoads() throws {
        let legacy = ExperimentReferenceSelection.previousEqualPeriod
        let data = try JSONEncoder().encode(legacy)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try #require(ExperimentSavedComparison.decode(json))

        #expect(decoded.reference == legacy)
        #expect(decoded.customTrackerPairs.isEmpty)
    }
}
