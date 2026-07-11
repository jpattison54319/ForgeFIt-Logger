import Testing
@testable import ForgeCore

struct PaceAnnouncementTests {
    @Test func firstSplitSkipsRedundantTotal() {
        let phrase = PaceAnnouncement.phrase(unitLabel: "kilometer", index: 1, splitSeconds: 312, totalSeconds: 312)
        #expect(phrase == "Kilometer 1. Split 5 minutes 12 seconds.")
    }

    @Test func laterSplitSpeaksTotal() {
        let phrase = PaceAnnouncement.phrase(unitLabel: "mile", index: 3, splitSeconds: 540, totalSeconds: 1650)
        #expect(phrase == "Mile 3. Split 9 minutes. Total 27 minutes 30 seconds.")
    }

    @Test func subMinuteSplit() {
        #expect(PaceAnnouncement.spokenDuration(58) == "58 seconds")
        #expect(PaceAnnouncement.spokenDuration(1) == "1 second")
    }

    @Test func exactMinutesDropSeconds() {
        #expect(PaceAnnouncement.spokenDuration(300) == "5 minutes")
        #expect(PaceAnnouncement.spokenDuration(60) == "1 minute")
    }

    @Test func hourLongTotalsDropSeconds() {
        #expect(PaceAnnouncement.spokenDuration(3723) == "1 hour 2 minutes")
        #expect(PaceAnnouncement.spokenDuration(7200) == "2 hours")
    }

    @Test func zeroAndNegativeAreSafe() {
        #expect(PaceAnnouncement.spokenDuration(0) == "0 seconds")
        #expect(PaceAnnouncement.spokenDuration(-5) == "0 seconds")
    }
}
