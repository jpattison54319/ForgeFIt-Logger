import Foundation

public enum LiveDistanceSource: Sendable, Equatable {
    case watch
    case phoneGPS
    case stored
}

public struct LiveDistanceReading: Sendable, Equatable {
    public let meters: Double
    public let observedAt: Date
    public let source: LiveDistanceSource

    public init(meters: Double, observedAt: Date, source: LiveDistanceSource) {
        self.meters = meters
        self.observedAt = observedAt
        self.source = source
    }
}

/// Chooses the single live-distance truth shared by UI, interval progress,
/// Live Activities, and milestone speech. A recently received Watch value wins
/// over phone GPS because it is the distance the athlete sees on their wrist.
public enum LiveDistanceArbiter {
    public static func preferred(
        watch: LiveDistanceReading?,
        phoneGPS: LiveDistanceReading?,
        storedMeters: Double?,
        at referenceDate: Date,
        watchFreshness: TimeInterval = 15
    ) -> LiveDistanceReading? {
        if let watch,
           isValid(watch.meters),
           max(0, referenceDate.timeIntervalSince(watch.observedAt)) <= watchFreshness {
            return watch
        }
        if let phoneGPS, isValid(phoneGPS.meters) {
            return phoneGPS
        }
        if let storedMeters, isValid(storedMeters) {
            return LiveDistanceReading(meters: storedMeters, observedAt: referenceDate, source: .stored)
        }
        return nil
    }

    private static func isValid(_ meters: Double) -> Bool {
        meters.isFinite && meters >= 0
    }
}

/// Emits each newly crossed distance boundary once. Decreasing/noisy samples
/// cannot un-cross a milestone, and a large gap may emit multiple boundaries.
public struct DistanceMilestoneTracker: Sendable, Equatable {
    public let boundaryMeters: Double
    public private(set) var completedCount: Int
    private var maximumDistanceMeters: Double

    public init(boundaryMeters: Double, completedCount: Int = 0) {
        precondition(boundaryMeters.isFinite && boundaryMeters > 0)
        self.boundaryMeters = boundaryMeters
        self.completedCount = max(0, completedCount)
        maximumDistanceMeters = Double(self.completedCount) * boundaryMeters
    }

    public mutating func consume(distanceMeters: Double) -> [Int] {
        guard distanceMeters.isFinite, distanceMeters >= 0 else { return [] }
        maximumDistanceMeters = max(maximumDistanceMeters, distanceMeters)
        let reachedCount = Int(floor(maximumDistanceMeters / boundaryMeters))
        guard reachedCount > completedCount else { return [] }

        let crossed = Array((completedCount + 1)...reachedCount)
        completedCount = reachedCount
        return crossed
    }
}
