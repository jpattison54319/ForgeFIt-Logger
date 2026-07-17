import Foundation

/// Machine-modality derivations shared by the phone UI, analytics, and tests.
/// Pure math over stored session numbers — every function returns nil rather
/// than inventing a value from incomplete inputs (the honest-framing rule:
/// a dash beats a fabricated stat).
public enum CardioDerivations {

    /// Rowing split: seconds per 500 m. Prefers real distance+time; a stored
    /// machine readout is the caller's fallback, not computed here.
    public static func split500Seconds(distanceMeters: Double?, durationSeconds: Int?) -> Double? {
        guard let distanceMeters, distanceMeters > 0,
              let durationSeconds, durationSeconds > 0 else { return nil }
        return Double(durationSeconds) / (distanceMeters / 500)
    }

    /// "m:ss" for split-style readouts (rowing /500 m, swimming /100 m).
    public static func splitString(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Stair-machine climb rate. Fractional floors read as noise on a
    /// per-minute stat, so this rounds to one decimal.
    public static func floorsPerMinute(floors: Int?, durationSeconds: Int?) -> Double? {
        guard let floors, floors > 0, let durationSeconds, durationSeconds > 0 else { return nil }
        return ((Double(floors) / (Double(durationSeconds) / 60)) * 10).rounded() / 10
    }

    /// Steps/strides/jumps per minute for step-counted modalities.
    public static func stepsPerMinute(steps: Int?, durationSeconds: Int?) -> Int? {
        guard let steps, steps > 0, let durationSeconds, durationSeconds > 0 else { return nil }
        return Int((Double(steps) / (Double(durationSeconds) / 60)).rounded())
    }

    // MARK: - Swimming

    /// Total swum distance from the pool contract; nil unless both halves
    /// are known — never guess a pool length.
    public static func swimDistanceMeters(poolLengthMeters: Double?, lengths: Int?) -> Double? {
        guard let poolLengthMeters, poolLengthMeters > 0, let lengths, lengths > 0 else { return nil }
        return poolLengthMeters * Double(lengths)
    }

    /// Swim pace: seconds per 100 m.
    public static func pacePer100mSeconds(distanceMeters: Double?, durationSeconds: Int?) -> Double? {
        guard let distanceMeters, distanceMeters > 0,
              let durationSeconds, durationSeconds > 0 else { return nil }
        return Double(durationSeconds) / (distanceMeters / 100)
    }

    /// SWOLF — the classic swim-efficiency score: average seconds per length
    /// plus average strokes per length, rounded to the nearest whole point.
    /// Requires the full pool contract; a SWOLF over a guessed pool length
    /// is fiction.
    public static func swolf(durationSeconds: Int?, lengths: Int?, strokes: Int?) -> Int? {
        guard let durationSeconds, durationSeconds > 0,
              let lengths, lengths > 0,
              let strokes, strokes > 0 else { return nil }
        let secondsPerLength = Double(durationSeconds) / Double(lengths)
        let strokesPerLength = Double(strokes) / Double(lengths)
        return Int((secondsPerLength + strokesPerLength).rounded())
    }
}

/// Stroke style for a swim session — stored raw on the session so history
/// filters and future analytics can group by stroke.
public enum SwimStrokeStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case freestyle, backstroke, breaststroke, butterfly, kickboard, mixed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .freestyle: "Freestyle"
        case .backstroke: "Backstroke"
        case .breaststroke: "Breaststroke"
        case .butterfly: "Butterfly"
        case .kickboard: "Kick"
        case .mixed: "Mixed"
        }
    }
}
