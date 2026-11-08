import Foundation

public enum StrengthHold {
    public static let defaultSeconds = 30
    public static let maximumSeconds = 59 * 60 + 59

    public static func validSeconds(_ seconds: Int?) -> Int? {
        seconds.flatMap { (1...maximumSeconds).contains($0) ? $0 : nil }
    }
}
