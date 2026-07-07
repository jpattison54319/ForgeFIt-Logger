import Foundation
import Testing
@testable import ForgeFit

/// The rest timer's control surface — start/adjust/skip — backs the logger's
/// countdown bar. These pin the behaviors the bar's −15/+15/skip buttons rely
/// on (a regression here reads as "the timer buttons don't work").
@MainActor
struct RestTimerControllerTests {
    @Test func startArmsTheCountdownWithLabelAndMicroState() {
        let timer = RestTimerController()
        let ownerID = UUID()
        timer.start(seconds: 90, label: "Working", micro: true, ownerID: ownerID)
        #expect(timer.isRunning)
        #expect(timer.totalSeconds == 90)
        #expect(timer.label == "Working")
        #expect(timer.isMicro)
        #expect(timer.microOwnerID == ownerID)
        #expect(abs(timer.remaining() - 90) <= 1)
    }

    @Test func startIgnoresNonPositiveDurations() {
        let timer = RestTimerController()
        timer.start(seconds: 0, label: "Rest")
        #expect(!timer.isRunning)
    }

    @Test func nonMicroStartClearsMicroOwner() {
        let timer = RestTimerController()
        timer.start(seconds: 15, label: "Mini", micro: true, ownerID: UUID())
        timer.start(seconds: 120, label: "Rest")
        #expect(!timer.isMicro)
        #expect(timer.microOwnerID == nil)
    }

    @Test func adjustExtendsBothRemainingAndTotal() {
        let timer = RestTimerController()
        timer.start(seconds: 60, label: "Rest")
        timer.adjust(by: 15)
        #expect(abs(timer.remaining() - 75) <= 1)
        #expect(timer.totalSeconds == 75)
    }

    @Test func adjustNeverDropsRemainingBelowOneSecond() {
        let timer = RestTimerController()
        timer.start(seconds: 10, label: "Rest")
        timer.adjust(by: -60)
        #expect(timer.isRunning)
        #expect(timer.remaining() >= 1)
        #expect(timer.remaining() <= 2)
    }

    @Test func adjustWithoutARunningTimerIsANoOp() {
        let timer = RestTimerController()
        timer.adjust(by: 15)
        #expect(!timer.isRunning)
        #expect(timer.totalSeconds == 0)
    }

    @Test func skipClearsEverything() {
        let timer = RestTimerController()
        timer.start(seconds: 15, label: "Mini", micro: true, ownerID: UUID())
        timer.skip()
        #expect(!timer.isRunning)
        #expect(timer.remaining() == 0)
        #expect(!timer.isMicro)
        #expect(timer.microOwnerID == nil)
    }
}
