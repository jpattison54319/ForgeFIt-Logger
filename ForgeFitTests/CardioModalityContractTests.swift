import Foundation
import Testing
import ForgeCore
@testable import ForgeFit

/// The per-modality metric contracts: which fields each machine surfaces and
/// which stat leads its headline. These pin the founder-approved contracts —
/// rower speaks /500 m, stairs speak floors, ropes speak jumps.
struct CardioModalityContractTests {

    @Test func rowingContractLeadsWithSplitStrokeAndWatts() {
        let row = CardioKind.row
        #expect(row.usesSplit500)
        #expect(row.usesStrokeRate)
        #expect(row.usesPower)
        #expect(row.usesDistance)
        #expect(!row.usesCadence)        // stroke rate IS the rower's cadence
        #expect(!row.usesResistance)     // damper isn't in the founder contract
        #expect(row.paceHeadline == "Split")
    }

    @Test func stairContractIsFloorsStepsRateAndLevel() {
        let stair = CardioKind.stair
        #expect(stair.usesFloors)
        #expect(stair.usesStepCount)
        #expect(stair.usesResistance)
        #expect(stair.usesIncline)
        #expect(!stair.usesDistance)     // consoles speak floors, not km
        #expect(!stair.usesCadence)
        #expect(stair.stepCountLabel == "Steps")
    }

    @Test func indoorBikeContractIsSpeedCadenceResistancePower() {
        let cycle = CardioKind.cycle
        #expect(cycle.usesCadence)
        #expect(cycle.cadenceUnit == "rpm")
        #expect(cycle.usesResistance)
        #expect(cycle.usesPower)
        #expect(!cycle.usesPace)         // riders think speed, not pace
        #expect(cycle.paceHeadline == "Speed")
    }

    @Test func runningContractAddsPowerAlongsidePaceCadenceElevation() {
        for kind in [CardioKind.run, .trailRun] {
            #expect(kind.usesPace)
            #expect(kind.usesCadence)
            #expect(kind.cadenceUnit == "spm")
            #expect(kind.usesElevation)
            #expect(kind.usesPower)
        }
    }

    @Test func ellipticalSpeaksStrides() {
        let elliptical = CardioKind.elliptical
        #expect(elliptical.usesStepCount)
        #expect(elliptical.stepCountLabel == "Strides")
        #expect(elliptical.usesCadence)
        #expect(elliptical.cadenceFieldLabel == "Strides/min")
        #expect(elliptical.usesResistance)
        #expect(elliptical.usesIncline)
    }

    @Test func jumpRopeSpeaksJumpsAndNothingElse() {
        let rope = CardioKind.jumpRope
        #expect(rope.usesStepCount)
        #expect(rope.stepCountLabel == "Jumps")
        #expect(rope.usesCadence)
        #expect(rope.cadenceFieldLabel == "Jumps/min")
        #expect(!rope.usesDistance)
        #expect(!rope.usesResistance)
        #expect(!rope.usesElevation)
    }

    @Test func swimCarriesThePoolContract() {
        let swim = CardioKind.swim
        #expect(swim.usesSwimContract)
        #expect(swim.usesFixedMeters)
        #expect(swim.usesPace)
        #expect(swim.metricLabels.contains("Pool length"))
        #expect(swim.metricLabels.contains("Lengths"))
        #expect(swim.metricLabels.contains("Strokes"))
    }

    @Test func rowingPaceFormatterSpeaksPer500() {
        // 2000 m in 8:00 → 2:00 /500 m.
        #expect(CardioMetrics.paceString(distanceMeters: 2000, durationSeconds: 480, kind: .row) == "2:00 /500m")
        // Swim branch unchanged: 1000 m in 20:00 → 2:00 /100 m.
        #expect(CardioMetrics.paceString(distanceMeters: 1000, durationSeconds: 1200, kind: .swim) == "2:00 /100m")
    }

    @Test func rowingSplitHeadlinePrefersDerivedOverStoredAndNeverGuesses() {
        // Derived from distance+time wins over a stale machine readout.
        #expect(CardioMetrics.rowingSplitString(distanceMeters: 2000, durationSeconds: 480, storedSplitSeconds: 135) == "2:00 /500m")
        // No distance yet → the erg's own readout carries the headline.
        #expect(CardioMetrics.rowingSplitString(distanceMeters: nil, durationSeconds: nil, storedSplitSeconds: 135) == "2:15 /500m")
        // Nothing at all → a dash, not a fabrication.
        #expect(CardioMetrics.rowingSplitString(distanceMeters: nil, durationSeconds: nil, storedSplitSeconds: nil) == "—")
    }

    @Test func everyModalityStillListsTheUniversalMetrics() {
        for kind in CardioKind.allCases {
            let labels = kind.metricLabels
            #expect(labels.contains("Time"))
            #expect(labels.contains("Heart rate"))
            #expect(labels.contains("Effort"))
        }
    }
}
