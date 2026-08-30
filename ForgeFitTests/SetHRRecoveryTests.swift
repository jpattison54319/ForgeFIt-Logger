import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

struct SetHRRecoveryTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let exerciseA = UUID(uuidString: "00000000-0000-7000-8000-00000000EA01")!
    private let exerciseB = UUID(uuidString: "00000000-0000-7000-8000-00000000EB02")!
    private let setA = UUID(uuidString: "00000000-0000-7000-8000-0000000000A1")!
    private let setB = UUID(uuidString: "00000000-0000-7000-8000-0000000000B2")!
    private let setC = UUID(uuidString: "00000000-0000-7000-8000-0000000000C3")!
    private let setD = UUID(uuidString: "00000000-0000-7000-8000-0000000000D4")!
    private let uuidD = UUID(uuidString: "00000000-0000-7000-8000-0000000000E5")!
    private let exerciseC = UUID(uuidString: "00000000-0000-7000-8000-00000000EC03")!

    private func sample(_ offset: TimeInterval, _ bpm: Int) -> (date: Date, bpm: Int) {
        (base.addingTimeInterval(offset), bpm)
    }

    private func set(
        _ id: UUID,
        exercise: UUID,
        at offset: TimeInterval,
        position: Int = 0,
        type: SetType = .working,
        group: Int? = nil
    ) -> RecoverySetInput {
        RecoverySetInput(
            id: id,
            exerciseID: exercise,
            supersetGroup: group,
            setType: type,
            position: position,
            completedAt: base.addingTimeInterval(offset)
        )
    }

    // MARK: - Rest has to be proven by the heart-rate curve

    @Test func straightSetReportsTheDropAcrossAGenuineRest() {
        // A completes at t=100 and HR bottoms out at t=200 — 100 s of real rest.
        let samples = [sample(105, 160), sample(200, 122), sample(330, 150)]
        let sets = [set(setA, exercise: exerciseA, at: 100),
                    set(setB, exercise: exerciseB, at: 340)]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets).first

        #expect(point?.peakHR == 160)
        #expect(point?.recoveryBPM == 38)
        #expect(point?.restObservedSeconds == 100)
    }

    @Test func shortRestReportsNothingEvenWhenTheNextSetCompletesLater() {
        // The trap: B is marked complete 75 s after A, but performing B took most
        // of that. HR turned back up 20 s in, so only 20 s of rest happened —
        // elapsed clock time to the next completion is not evidence of rest.
        let samples = [sample(105, 160), sample(120, 140), sample(150, 155), sample(170, 168)]
        let sets = [set(setA, exercise: exerciseA, at: 100),
                    set(setB, exercise: exerciseB, at: 175)]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets).first

        #expect(point?.peakHR == 160)
        #expect(point?.recoveryBPM == nil)
        #expect(point?.restObservedSeconds == nil)
    }

    @Test func troughHuntStopsAtTheRestCeiling() {
        // A fifteen-minute break would otherwise report the fall to resting HR
        // as between-set recovery.
        let samples = [sample(105, 160), sample(200, 140), sample(500, 90), sample(990, 150)]
        let sets = [set(setA, exercise: exerciseA, at: 100),
                    set(setB, exercise: exerciseB, at: 1000)]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets).first

        #expect(point?.recoveryBPM == 20)
    }

    // MARK: - Rounds, not sets

    @Test func supersetRoundIsOneUnitMeasuredAfterItsLastLeg() {
        // A1 at t=100 flows straight into B1 at t=160; the rest follows B1.
        let samples = [
            sample(105, 150), sample(150, 158), sample(165, 168),
            sample(200, 150), sample(240, 140), sample(300, 152), sample(335, 160),
            sample(405, 172), sample(470, 145),
        ]
        let sets = [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseB, at: 160, position: 0, group: 1),
            set(setC, exercise: exerciseA, at: 340, position: 1, group: 1),
            set(setD, exercise: exerciseB, at: 400, position: 1, group: 1),
        ]

        let points = SetHRRecovery.analyze(samples: samples, sets: sets)

        #expect(points.count == 2)
        // Round one: peak is the round's peak (reached during B1), not A1's.
        #expect(points[0].setIDs == [setA, setB])
        #expect(points[0].peakHR == 168)
        #expect(points[0].recoveryBPM == 28)
        #expect(points[0].restObservedSeconds == 80)
        #expect(points[1].setIDs == [setC, setD])
    }

    @Test func interLegDipDoesNotVoidASupersetRoundsReading() {
        // The round peaks on its FIRST leg (rise 0) and HR dips between legs to
        // a level lower than the post-round trough. Hunting the trough from the
        // peak would find that inter-leg dip, place it before the round ended,
        // and report no reading at all.
        let samples = [
            sample(105, 165),   // peak, during the opening leg
            sample(150, 118),   // dip between legs — lowest point of the round
            sample(205, 160),   // second leg's effort
            sample(280, 130),   // the actual post-round trough
            sample(395, 155),   // climbing into the next round
        ]
        let sets = [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseB, at: 200, position: 0, group: 1),
            set(setC, exercise: exerciseA, at: 400, position: 1, group: 1),
        ]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets).first

        #expect(point?.setIDs == [setA, setB])
        #expect(point?.peakHR == 165)
        #expect(point?.withinUnitRise == 0)
        #expect(point?.recoveryBPM == 35)
        #expect(point?.restObservedSeconds == 80)
    }

    @Test func finalSupersetRoundMeasuresItsWindowFromTheLastLeg() {
        // The final round's window must start where the work ended, or a round
        // that peaked early loses most of its rest to the second leg.
        let samples = [sample(105, 168), sample(150, 130), sample(205, 158), sample(275, 120)]
        let sets = [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseB, at: 200, position: 0, group: 1),
        ]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets, lastSetWindow: 90).first

        #expect(point?.setIDs == [setA, setB])
        #expect(point?.recoveryBPM == 48)
    }

    @Test func withinUnitRiseReportsTheClimbAcrossAMultiSetRound() {
        let samples = [
            sample(105, 150), sample(150, 158), sample(165, 168),
            sample(240, 140), sample(335, 160), sample(405, 172), sample(470, 145),
        ]
        let sets = [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseB, at: 160, position: 0, group: 1),
            set(setC, exercise: exerciseA, at: 340, position: 1, group: 1),
            set(setD, exercise: exerciseB, at: 400, position: 1, group: 1),
        ]

        let points = SetHRRecovery.analyze(samples: samples, sets: sets)

        // Opened at 150 bpm, topped out at 168 during the second exercise.
        #expect(points[0].withinUnitRise == 18)
        #expect(points[1].withinUnitRise == 12)
    }

    @Test func singleSetUnitsHaveNoWithinUnitRise() {
        let samples = [sample(105, 160), sample(200, 122), sample(330, 150)]
        let sets = [set(setA, exercise: exerciseA, at: 100),
                    set(setB, exercise: exerciseB, at: 340)]

        #expect(SetHRRecovery.analyze(samples: samples, sets: sets).first?.withinUnitRise == nil)
    }

    @Test func dropChainIsOneUnit() {
        let samples = [sample(105, 150), sample(155, 166), sample(250, 128), sample(390, 150)]
        let sets = [
            set(setA, exercise: exerciseA, at: 100, position: 0),
            set(setB, exercise: exerciseA, at: 130, position: 1, type: .drop),
            set(setC, exercise: exerciseA, at: 150, position: 2, type: .drop),
            set(setD, exercise: exerciseB, at: 400),
        ]

        let points = SetHRRecovery.analyze(samples: samples, sets: sets)

        #expect(points.first?.setIDs == [setA, setB, setC])
        #expect(points.first?.peakHR == 166)
        #expect(points.first?.withinUnitRise == 16)
        #expect(points.first?.recoveryBPM == 38)
    }

    @Test func aLegTickedLongAfterTheRoundStillBelongsToThatRound() {
        // Round 2 of the superset: the second leg was performed back to back but
        // only checked off at the end of the session, after another exercise.
        // Tick order must not tear the round into two orphan sets.
        let units = SetHRRecovery.recoveryUnits(from: [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseB, at: 160, position: 0, group: 1),
            set(setC, exercise: exerciseA, at: 340, position: 1, group: 1),
            set(uuidD, exercise: exerciseC, at: 500),
            set(setD, exercise: exerciseB, at: 900, position: 1, group: 1),
        ])

        #expect(units.map { $0.map(\.id) } == [[setA, setB], [setC, setD], [uuidD]])
    }

    @Test func aLateTickedLegDoesNotStretchTheMeasuredSpan() {
        // The round is measured around the leg that was actually performed then;
        // the late tick must not drag the peak window across everything between.
        let samples = [
            sample(105, 158),   // the round, as performed
            sample(200, 120),   // recovery before the next exercise
            sample(505, 175),   // a much harder later exercise
            sample(905, 150),   // the late tick, long afterwards
        ]
        let sets = [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseB, at: 900, position: 0, group: 1),
            set(setC, exercise: exerciseC, at: 500),
        ]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets).first

        // Both legs are members of the round...
        #expect(point?.setIDs == [setA, setB])
        // ...but the peak is the round's own, not the 175 from the exercise
        // that happened in between.
        #expect(point?.peakHR == 158)
        #expect(point?.recoveryBPM == 38)
        // A span of one real leg carries no within-round rise.
        #expect(point?.withinUnitRise == nil)
    }

    // MARK: - Unit boundaries

    @Test func supersetLegsWithDropsFormOneUnit() {
        let units = SetHRRecovery.recoveryUnits(from: [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseA, at: 125, position: 1, type: .drop, group: 1),
            set(setC, exercise: exerciseB, at: 180, position: 0, group: 1),
        ])

        #expect(units.count == 1)
        #expect(units[0].map(\.id) == [setA, setB, setC])
    }

    @Test func separateRoundsOfOneGroupAreSeparateUnits() {
        let units = SetHRRecovery.recoveryUnits(from: [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseB, at: 140, position: 0, group: 1),
            set(setC, exercise: exerciseA, at: 320, position: 1, group: 1),
            set(setD, exercise: exerciseB, at: 360, position: 1, group: 1),
        ])

        #expect(units.map { $0.map(\.id) } == [[setA, setB], [setC, setD]])
    }

    @Test func consecutiveSetsOnOneExerciseAreSeparateUnits() {
        // Both legs logged back to back on the same exercise means the lifter
        // rested in between, superset group or not.
        let units = SetHRRecovery.recoveryUnits(from: [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseA, at: 260, position: 1, group: 1),
        ])

        #expect(units.count == 2)
    }

    @Test func unequalSupersetMembersLeaveATrailingSoloRound() {
        // A has three rounds, B only two — the last A set stands alone.
        let units = SetHRRecovery.recoveryUnits(from: [
            set(setA, exercise: exerciseA, at: 100, position: 0, group: 1),
            set(setB, exercise: exerciseB, at: 140, position: 0, group: 1),
            set(setC, exercise: exerciseA, at: 320, position: 1, group: 1),
            set(setD, exercise: exerciseA, at: 500, position: 2, group: 1),
        ])

        #expect(units.map { $0.map(\.id) } == [[setA, setB], [setC], [setD]])
    }

    // MARK: - Final-unit window (unchanged semantics)

    @Test func lastUnitUsesFixedWindow() {
        let samples = [sample(100, 158), sample(150, 122), sample(180, 110)]
        let sets = [set(setA, exercise: exerciseA, at: 100)]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets, lastSetWindow: 90).first

        #expect(point?.peakHR == 158)
        #expect(point?.recoveryBPM == 48)
    }

    @Test func finalUnitOmitsRecoveryWhenWorkoutEndsBeforeSixtySeconds() {
        let samples = [sample(100, 158), sample(105, 148)]
        let sets = [set(setA, exercise: exerciseA, at: 100)]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets).first

        #expect(point?.peakHR == 158)
        #expect(point?.recoveryBPM == nil)
    }

    @Test func finalUnitRequiresAHeartRateSampleAtSixtySeconds() {
        let sets = [set(setA, exercise: exerciseA, at: 100)]
        let justShort = SetHRRecovery.analyze(
            samples: [sample(100, 158), sample(159.999, 120)],
            sets: sets
        ).first
        let exactlySixty = SetHRRecovery.analyze(
            samples: [sample(100, 158), sample(160, 118)],
            sets: sets
        ).first

        #expect(justShort?.recoveryBPM == nil)
        #expect(exactlySixty?.recoveryBPM == 40)
    }

    @Test func finalUnitClampsToZeroWhenHRKeepsRising() {
        // The window was fully observed and HR never fell: a real zero, not a
        // missing reading. Only interior rounds need a trough to prove rest.
        let samples = [sample(100, 150), sample(130, 158), sample(160, 165)]
        let sets = [set(setA, exercise: exerciseA, at: 100)]

        let point = SetHRRecovery.analyze(samples: samples, sets: sets, lastSetWindow: 90).first
        #expect(point?.recoveryBPM == 0)
    }

    // MARK: - Degenerate input

    @Test func setWithoutNearbyHRIsSkipped() {
        let samples = [sample(500, 140), sample(560, 120)]
        let sets = [set(setA, exercise: exerciseA, at: 100)]

        #expect(SetHRRecovery.analyze(samples: samples, sets: sets).isEmpty)
    }

    @Test func emptyInputsProduceNoPoints() {
        #expect(SetHRRecovery.analyze(samples: [], sets: [set(setA, exercise: exerciseA, at: 0)]).isEmpty)
        #expect(SetHRRecovery.analyze(samples: [sample(0, 120)], sets: []).isEmpty)
    }
}
