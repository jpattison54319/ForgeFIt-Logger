import Foundation
import Testing
@testable import ForgeFit

@Suite("Exercise reorder session")
struct ExerciseReorderSessionTests {
    @Test("A held row can cross multiple slots without mutating its source order")
    func movesAcrossMultipleSlotsLocally() {
        let ids = (0..<4).map { _ in UUID() }
        let source = zip(ids, ["A", "B", "C", "D"]).map {
            ExerciseReorderRow(id: $0.0, name: $0.1)
        }
        let session = ExerciseReorderSession(
            heldID: ids[0],
            fingerGlobalY: 100,
            rows: source
        )

        #expect(session.moveHeld(to: 2))
        #expect(session.rows.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
        #expect(source.map(\.id) == ids)
        #expect(session.didMove)
    }

    @Test("Repeated and out-of-range slot updates remain stable")
    func clampsAndIgnoresNoOpMoves() {
        let ids = (0..<3).map { _ in UUID() }
        let rows = zip(ids, ["A", "B", "C"]).map {
            ExerciseReorderRow(id: $0.0, name: $0.1)
        }
        let session = ExerciseReorderSession(
            heldID: ids[1],
            fingerGlobalY: 100,
            rows: rows
        )

        #expect(!session.moveHeld(to: 1))
        #expect(session.moveHeld(to: 99))
        #expect(session.rows.map(\.id) == [ids[0], ids[2], ids[1]])
        #expect(!session.moveHeld(to: 99))
        #expect(session.moveHeld(to: -99))
        #expect(session.rows.map(\.id) == [ids[1], ids[0], ids[2]])
    }
}
