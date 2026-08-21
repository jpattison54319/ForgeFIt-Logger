import Foundation

/// An authored rep target carried into a workout without pretending a range
/// is a performed result. A single surviving bound is an exact target so old
/// and partially-authored plans remain useful.
public enum PlannedRepTarget: Equatable, Sendable {
    case exact(Int)
    case range(Int, Int)

    public init?(low: Int?, high: Int?) {
        switch (low, high) {
        case let (low?, high?) where low != high:
            self = .range(min(low, high), max(low, high))
        case let (low?, _):
            self = .exact(low)
        case let (_, high?):
            self = .exact(high)
        case (nil, nil):
            return nil
        }
    }

    public var lowerBound: Int {
        switch self {
        case .exact(let value), .range(let value, _): value
        }
    }

    public var upperBound: Int {
        switch self {
        case .exact(let value), .range(_, let value): value
        }
    }

    /// The value completion may materialize without inventing a performed
    /// result. A range deliberately has no automatic concrete value.
    public var exactValue: Int? {
        guard case .exact(let value) = self else { return nil }
        return value
    }

    public var displayText: String {
        switch self {
        case .exact(let value): "\(value)"
        case .range(let low, let high): "\(low)–\(high)"
        }
    }
}
