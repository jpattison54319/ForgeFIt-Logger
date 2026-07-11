import Foundation
import Testing
@testable import ForgeCore

struct HeartRateMeasurementTests {

    @Test func parsesUInt8HeartRate() {
        let data = Data([0x00, 72])
        let m = HeartRateMeasurement.parse(data)
        #expect(m == HeartRateMeasurement(bpm: 72))
    }

    @Test func parsesUInt16HeartRate() {
        // Flags bit 0 set: 16-bit little-endian value 0x0141 = 321.
        let data = Data([0x01, 0x41, 0x01])
        let m = HeartRateMeasurement.parse(data)
        #expect(m?.bpm == 321)
        #expect(m?.rrIntervals.isEmpty == true)
    }

    @Test func skipsEnergyExpendedField() {
        // Flags: energy expended (bit 3) + RR intervals (bit 4), 8-bit HR.
        // Energy bytes must be skipped, not read as an RR interval.
        let data = Data([0x18, 65, 0x34, 0x12, 0x00, 0x04])
        let m = HeartRateMeasurement.parse(data)
        #expect(m?.bpm == 65)
        #expect(m?.rrIntervals == [1.0]) // 0x0400 = 1024 -> exactly 1 s
    }

    @Test func parsesMultipleRRIntervals() {
        // 8-bit HR with two RR intervals: 512/1024 = 0.5 s, 1024/1024 = 1 s.
        let data = Data([0x10, 80, 0x00, 0x02, 0x00, 0x04])
        let m = HeartRateMeasurement.parse(data)
        #expect(m?.bpm == 80)
        #expect(m?.rrIntervals == [0.5, 1.0])
    }

    @Test func ignoresRRFlagWithNoPayload() {
        let data = Data([0x10, 80])
        let m = HeartRateMeasurement.parse(data)
        #expect(m?.bpm == 80)
        #expect(m?.rrIntervals.isEmpty == true)
    }

    @Test func rejectsMalformedPayloads() {
        #expect(HeartRateMeasurement.parse(Data()) == nil)
        #expect(HeartRateMeasurement.parse(Data([0x00])) == nil)
        // 16-bit flag but only one value byte.
        #expect(HeartRateMeasurement.parse(Data([0x01, 72])) == nil)
        // Energy-expended flag but truncated energy field.
        #expect(HeartRateMeasurement.parse(Data([0x08, 72, 0x01])) == nil)
    }

    @Test func rejectsZeroReading() {
        #expect(HeartRateMeasurement.parse(Data([0x00, 0])) == nil)
        #expect(HeartRateMeasurement.parse(Data([0x01, 0x00, 0x00])) == nil)
    }
}
