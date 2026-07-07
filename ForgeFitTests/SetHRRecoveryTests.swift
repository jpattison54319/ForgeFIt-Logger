import Foundation
import Testing
@testable import ForgeFit

struct SetHRRecoveryTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let setA = UUID(uuidString: "00000000-0000-7000-8000-0000000000A1")!
    private let setB = UUID(uuidString: "00000000-0000-7000-8000-0000000000B2")!

    private func sample(_ offset: TimeInterval, _ bpm: Int) -> (date: Date, bpm: Int) {
        (base.addingTimeInterval(offset), bpm)
    }

    @Test func peakUsesPostCompletionSpikeAndRecoveryToNextSet() {
        // Set A completes at t=100; HR peaks at 160 just after, falls to 120 during
        // rest, then rises again toward set B which completes at t=220.
        let samples: [(date: Date, bpm: Int)] = [
            sample(95, 150), sample(105, 160), sample(140, 120), sample(170, 130),
            sample(215, 165), sample(300, 118),
        ]
        let sets = [(id: setA, completedAt: base.addingTimeInterval(100)),
                    (id: setB, completedAt: base.addingTimeInterval(220))]

        let points = SetHRRecovery.analyze(samples: samples, sets: sets)

        #expect(points.count == 2)
        let a = points.first { $0.setID == setA }
        #expect(a?.peakHR == 160)
        // Trough between A's peak and B's completion is 120 → drop of 40.
        #expect(a?.recoveryBPM == 40)
    }

    @Test func lastSetUsesFixedWindow() {
        let samples: [(date: Date, bpm: Int)] = [
            sample(100, 158), sample(150, 122), sample(180, 110),
        ]
        let sets = [(id: setA, completedAt: base.addingTimeInterval(100))]

        let points = SetHRRecovery.analyze(samples: samples, sets: sets, lastSetWindow: 90)

        // Peak 158 at t=100; window runs to t=190, trough 110 → drop 48.
        #expect(points.first?.peakHR == 158)
        #expect(points.first?.recoveryBPM == 48)
    }

    @Test func setWithoutNearbyHRIsSkipped() {
        let samples: [(date: Date, bpm: Int)] = [sample(500, 140), sample(560, 120)]
        let sets = [(id: setA, completedAt: base.addingTimeInterval(100))]

        #expect(SetHRRecovery.analyze(samples: samples, sets: sets).isEmpty)
    }

    @Test func recoveryClampsToZeroWhenHRKeepsRising() {
        let samples: [(date: Date, bpm: Int)] = [
            sample(100, 150), sample(130, 158), sample(160, 165),
        ]
        let sets = [(id: setA, completedAt: base.addingTimeInterval(100))]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets, lastSetWindow: 90).first
        #expect(point?.recoveryBPM == 0)
    }

    @Test func emptyInputsProduceNoPoints() {
        #expect(SetHRRecovery.analyze(samples: [], sets: [(id: setA, completedAt: base)]).isEmpty)
        #expect(SetHRRecovery.analyze(samples: [sample(0, 120)], sets: []).isEmpty)
    }
}
