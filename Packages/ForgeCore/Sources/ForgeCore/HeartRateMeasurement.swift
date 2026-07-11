import Foundation

/// A single reading decoded from the Bluetooth Heart Rate Measurement
/// characteristic (0x2A37), as broadcast by Garmin watches in "Broadcast
/// Heart Rate" mode, chest straps, and other standard BLE heart-rate
/// monitors. Pure parsing lives in ForgeCore so it can be unit-tested
/// without CoreBluetooth.
public struct HeartRateMeasurement: Sendable, Equatable {
    public var bpm: Int
    /// RR intervals in seconds (present only when the sensor sends them).
    /// Unused today; retained transiently as the hook for session HRV later.
    public var rrIntervals: [Double]

    public init(bpm: Int, rrIntervals: [Double] = []) {
        self.bpm = bpm
        self.rrIntervals = rrIntervals
    }

    /// Decodes the characteristic payload per the Bluetooth SIG spec:
    /// flags byte, then uint8 or uint16-LE heart rate (flags bit 0), an
    /// optional uint16 energy-expended field (bit 3) that must be skipped,
    /// then zero or more uint16-LE RR intervals in 1/1024 s units (bit 4).
    /// Returns nil for malformed payloads or a zero reading (the sensor's
    /// "no measurement" signal).
    public static func parse(_ data: Data) -> HeartRateMeasurement? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let flags = bytes[0]
        var offset = 1

        let bpm: Int
        if flags & 0x01 != 0 {
            guard bytes.count >= offset + 2 else { return nil }
            bpm = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2
        } else {
            bpm = Int(bytes[offset])
            offset += 1
        }
        guard bpm > 0 else { return nil }

        if flags & 0x08 != 0 {
            guard bytes.count >= offset + 2 else { return nil }
            offset += 2
        }

        var rrIntervals: [Double] = []
        if flags & 0x10 != 0 {
            while bytes.count >= offset + 2 {
                let raw = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
                rrIntervals.append(Double(raw) / 1024.0)
                offset += 2
            }
        }
        return HeartRateMeasurement(bpm: bpm, rrIntervals: rrIntervals)
    }
}
