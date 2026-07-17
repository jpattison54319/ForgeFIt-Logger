import XCTest

/// The exercise-header ⋯ menu was the last SwiftUI `Menu` on the logger's
/// scroll surface (a scroll starting on it dead-stopped) and is now a
/// UIKit-backed `ScrollSafeMenu`. This drives the converted menu end-to-end:
/// open ⋯ → "Add Warm-up Set" → a new set row appears.
final class LoggerOverflowMenuUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        element.tap()
    }

    @MainActor
    func testOverflowMenuAddsWarmupSet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--auto-start-routine", "-didOnboard", "YES", "-weightUnitRaw", "lb"]
        app.launch()

        // The starter routine's logger, recovered via the mini bar if the
        // auto-presentation race loses (same recovery as ForgeFitUITests).
        let firstSet = app.buttons["complete-set-1"].firstMatch
        if !firstSet.waitForExistence(timeout: 10) {
            let expand = app.descendants(matching: .any)["expand-active-workout"].firstMatch
            XCTAssertTrue(expand.waitForExistence(timeout: 5), "Expected the logger or the minimized bar.")
            tapWhenReady(expand)
        }
        XCTAssertTrue(firstSet.waitForExistence(timeout: 10), "Expected the live logger with a set row.")

        let setCountBefore = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'complete-set-'")
        ).count

        // The UIKit-backed menu opens from a tap and lists its actions.
        let overflow = app.descendants(matching: .any)["exercise-overflow-menu"].firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 5), "Expected the ⋯ overflow control on the exercise header.")
        tapWhenReady(overflow)

        let addWarmup = app.buttons["Add Warm-up Set"].firstMatch
        XCTAssertTrue(addWarmup.waitForExistence(timeout: 5), "The converted menu should present its actions.")
        tapWhenReady(addWarmup)

        // One more completable row than before proves the action fired.
        let grew = NSPredicate { _, _ in
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'complete-set-'")
            ).count == setCountBefore + 1
        }
        let expectation = XCTNSPredicateExpectation(predicate: grew, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 8), .completed,
                       "Adding a warm-up from the converted menu should append a set row.")
    }
}
