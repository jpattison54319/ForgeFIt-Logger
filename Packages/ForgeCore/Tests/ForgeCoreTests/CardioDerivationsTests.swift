import Testing
@testable import ForgeCore

/// Machine-modality math: every derivation returns nil on incomplete input
/// (dash over fabrication) and the classic reference numbers come out right.
struct CardioDerivationsTests {

    @Test func rowingSplitDerivesFromDistanceAndTime() {
        // A 2000 m piece in 8:00 is the canonical 2:00 /500 m.
        #expect(CardioDerivations.split500Seconds(distanceMeters: 2000, durationSeconds: 480) == 120)
        #expect(CardioDerivations.splitString(seconds: 120) == "2:00")
        // 5 km in 22:30 → 2:15.0 /500 m.
        #expect(CardioDerivations.splitString(seconds: CardioDerivations.split500Seconds(distanceMeters: 5000, durationSeconds: 1350)) == "2:15")
        #expect(CardioDerivations.split500Seconds(distanceMeters: nil, durationSeconds: 480) == nil)
        #expect(CardioDerivations.split500Seconds(distanceMeters: 2000, durationSeconds: 0) == nil)
    }

    @Test func splitStringRefusesJunk() {
        #expect(CardioDerivations.splitString(seconds: nil) == nil)
        #expect(CardioDerivations.splitString(seconds: 0) == nil)
        #expect(CardioDerivations.splitString(seconds: .infinity) == nil)
        #expect(CardioDerivations.splitString(seconds: 89.6) == "1:30")
    }

    @Test func stairRatesRoundSensibly() {
        #expect(CardioDerivations.floorsPerMinute(floors: 120, durationSeconds: 1800) == 4.0)
        #expect(CardioDerivations.floorsPerMinute(floors: 100, durationSeconds: 1800) == 3.3)
        #expect(CardioDerivations.floorsPerMinute(floors: nil, durationSeconds: 1800) == nil)
        #expect(CardioDerivations.stepsPerMinute(steps: 3000, durationSeconds: 1800) == 100)
        #expect(CardioDerivations.stepsPerMinute(steps: 0, durationSeconds: 1800) == nil)
    }

    @Test func swimContractRequiresPoolLengthAndLengths() {
        #expect(CardioDerivations.swimDistanceMeters(poolLengthMeters: 25, lengths: 40) == 1000)
        #expect(CardioDerivations.swimDistanceMeters(poolLengthMeters: nil, lengths: 40) == nil)
        #expect(CardioDerivations.swimDistanceMeters(poolLengthMeters: 25, lengths: 0) == nil)

        // 1000 m in 20:00 → 2:00 /100 m.
        #expect(CardioDerivations.pacePer100mSeconds(distanceMeters: 1000, durationSeconds: 1200) == 120)
    }

    @Test func swolfIsSecondsPlusStrokesPerLength() {
        // 40 lengths in 20:00 (30 s each) at 15 strokes/length → SWOLF 45.
        #expect(CardioDerivations.swolf(durationSeconds: 1200, lengths: 40, strokes: 600) == 45)
        // Missing any leg of the contract → no score, never a guess.
        #expect(CardioDerivations.swolf(durationSeconds: 1200, lengths: nil, strokes: 600) == nil)
        #expect(CardioDerivations.swolf(durationSeconds: nil, lengths: 40, strokes: 600) == nil)
        #expect(CardioDerivations.swolf(durationSeconds: 1200, lengths: 40, strokes: nil) == nil)
    }
}
