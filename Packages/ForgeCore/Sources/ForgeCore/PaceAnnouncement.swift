import Foundation

/// Builds the spoken split announcements for outdoor cardio ("Kilometer 3.
/// Split 5 minutes 12 seconds.") — pure string math so the exact phrasing is
/// testable without an audio session.
public enum PaceAnnouncement {

    /// - Parameters:
    ///   - unitLabel: "kilometer" or "mile" (spoken, so words not symbols).
    ///   - index: 1-based split number just completed.
    ///   - splitSeconds: duration of the split just completed.
    ///   - totalSeconds: whole-session elapsed; announced from the second
    ///     split on (the first split IS the total — saying it twice is noise).
    public static func phrase(unitLabel: String, index: Int, splitSeconds: Int, totalSeconds: Int? = nil) -> String {
        var parts = ["\(unitLabel.capitalized) \(index)."]
        parts.append("Split \(spokenDuration(splitSeconds)).")
        if let totalSeconds, index > 1 {
            parts.append("Total \(spokenDuration(totalSeconds)).")
        }
        return parts.joined(separator: " ")
    }

    /// "5 minutes 12 seconds", "58 seconds", "1 hour 2 minutes" — natural
    /// speech, singular/plural correct, zero components dropped.
    public static func spokenDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        // Below an hour, seconds always speak (they're the precision that
        // matters for a split); above an hour they're noise.
        if hours == 0, secs > 0 || parts.isEmpty {
            parts.append("\(secs) \(secs == 1 ? "second" : "seconds")")
        }
        return parts.joined(separator: " ")
    }
}
