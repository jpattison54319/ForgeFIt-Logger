import CoreGraphics
import Testing
@testable import ForgeFit

struct SwipeToDeleteDirectionTests {
    @Test func verticalScrollIsPermanentlyRejected() {
        #expect(SwipeToDeleteDirection.resolve(horizontal: 7, vertical: 24, isOpen: false) == .rejected)
    }

    @Test func ambiguousDiagonalWaitsForClearIntent() {
        #expect(SwipeToDeleteDirection.resolve(horizontal: -12, vertical: 10, isOpen: false) == nil)
    }

    @Test func strongLeftwardDragOpensDeleteIntent() {
        #expect(SwipeToDeleteDirection.resolve(horizontal: -24, vertical: 8, isOpen: false) == .horizontal)
    }

    @Test func closedRowRejectsRightwardDrag() {
        #expect(SwipeToDeleteDirection.resolve(horizontal: 24, vertical: 4, isOpen: false) == .rejected)
    }

    @Test func openRowAcceptsRightwardDragToClose() {
        #expect(SwipeToDeleteDirection.resolve(horizontal: 24, vertical: 4, isOpen: true) == .horizontal)
    }
}
