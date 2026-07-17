import Foundation
import Testing
@testable import ForgeCore

struct LiveHRAggregatorTests {
    // Max 190, no resting HR: zone bounds at 114/133/152/171 bpm.
    private let config = HRZoneConfig()
    private let start = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func ticked(_ readings: [(offset: TimeInterval, bpm: Int)]) -> LiveHRAggregator {
        var agg = LiveHRAggregator()
        for r in readings {
            agg.tick(bpm: r.bpm, at: start.addingTimeInterval(r.offset), config: config)
        }
        return agg
    }

    @Test func tracksLatestAvgAndMax() {
        let agg = ticked([(0, 100), (1, 120), (2, 110)])
        #expect(agg.latestHR == 110)
        #expect(agg.maxHR == 120)
        #expect(agg.avgHR == 110) // (100+120+110)/3
    }

    @Test func emptyAggregatorHasNilMetrics() {
        let agg = LiveHRAggregator()
        #expect(agg.latestHR == nil)
        #expect(agg.avgHR == nil)
        #expect(agg.maxHR == nil)
        #expect(agg.zoneSeconds == [0, 0, 0, 0, 0])
        let metrics = agg.liveMetrics(asOf: start)
        #expect(metrics.heartRate == nil)
        #expect(metrics.activeEnergyKcal == nil)
    }

    @Test func attributesElapsedSecondsToZoneOfNewestReading() {
        // Matches watch tickZone semantics: each tick credits the elapsed
        // whole seconds since the previous tick to the new reading's zone.
        let agg = ticked([(0, 100), (10, 100), (20, 140)])
        // 100 bpm -> zone 1 (fraction .526 < .60); 140 bpm -> zone 3.
        #expect(agg.zoneSeconds == [10, 0, 10, 0, 0])
    }

    @Test func discardsDropoutGapsOverTwoMinutes() {
        let agg = ticked([(0, 100), (150, 100)])
        #expect(agg.zoneSeconds == [0, 0, 0, 0, 0])
    }

    @Test func ignoresZeroAndOutOfOrderTicksSafely() {
        var agg = LiveHRAggregator()
        agg.tick(bpm: 0, at: start, config: config)
        #expect(agg.latestHR == nil)

        agg.tick(bpm: 100, at: start.addingTimeInterval(10), config: config)
        // Out-of-order reading: no negative zone time, tick clock not rewound.
        agg.tick(bpm: 105, at: start.addingTimeInterval(5), config: config)
        agg.tick(bpm: 110, at: start.addingTimeInterval(20), config: config)
        #expect(agg.zoneSeconds.reduce(0, +) == 10) // only the 10->20 span
        #expect(agg.avgHR == 105)
    }

    @Test func buffersSamplesForSeries() {
        let agg = ticked([(0, 100), (1, 101), (2, 102)])
        #expect(agg.samples.map(\.bpm) == [100, 101, 102])
        #expect(agg.samples.first?.date == start)
    }

    @Test func liveMetricsCarriesAggregatesAndTimestamp() {
        let agg = ticked([(0, 100), (10, 140)])
        let asOf = start.addingTimeInterval(11)
        let metrics = agg.liveMetrics(asOf: asOf)
        #expect(metrics.heartRate == 140)
        #expect(metrics.avgHR == 120)
        #expect(metrics.maxHR == 140)
        #expect(metrics.hrZoneSeconds == [0, 0, 10, 0, 0])
        #expect(metrics.asOf == asOf)
        #expect(metrics.activeEnergyKcal == nil)
        #expect(metrics.distanceMeters == nil)
    }

    @Test func zoneBoundariesUseConfig() {
        // With resting HR the zones use %HRR: same bpm lands differently.
        let hrrConfig = HRZoneConfig(maxHR: 190, restingHR: 60)
        var agg = LiveHRAggregator()
        agg.tick(bpm: 100, at: start, config: hrrConfig)
        agg.tick(bpm: 100, at: start.addingTimeInterval(10), config: hrrConfig)
        // fraction = (100-60)/130 = .307 -> zone 1
        #expect(agg.zoneSeconds == [10, 0, 0, 0, 0])
    }
}
