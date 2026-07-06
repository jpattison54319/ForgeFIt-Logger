import CoreLocation
import ForgeData
import Foundation
import Observation
import SwiftData

enum CardioRouteMath {
    static var defaultSplitDistanceMeters: Double {
        Locale.current.measurementSystem == .us ? 1609.344 : 1000
    }

    static func distanceMeters(_ a: CardioRoutePointModel, _ b: CardioRoutePointModel) -> Double {
        let lhs = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let rhs = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return lhs.distance(from: rhs)
    }

    static func replaceSplits(for session: CardioSessionModel, in context: ModelContext, splitDistanceMeters: Double = defaultSplitDistanceMeters) {
        for split in session.splits {
            context.delete(split)
        }
        session.splits = []

        let points = session.routePoints.sorted { $0.timestamp < $1.timestamp }
        guard points.count >= 2 else { return }

        var splitStart = points[0]
        var previous = points[0]
        var accumulated = 0.0
        var elevationGain = 0.0
        var index = 1

        for point in points.dropFirst() {
            let segment = distanceMeters(previous, point)
            if let prevAltitude = previous.altitudeMeters,
               let altitude = point.altitudeMeters,
               altitude > prevAltitude {
                elevationGain += altitude - prevAltitude
            }
            accumulated += segment

            if accumulated >= splitDistanceMeters {
                let duration = max(1, Int(point.timestamp.timeIntervalSince(splitStart.timestamp)))
                let split = CardioSplitModel(
                    userID: session.userID,
                    cardioSessionID: session.id,
                    index: index,
                    distanceMeters: accumulated,
                    durationSeconds: duration,
                    paceSecondsPerKm: Double(duration) / max(0.001, accumulated / 1000),
                    elevationGainMeters: elevationGain > 0 ? elevationGain : nil,
                    startedAt: splitStart.timestamp,
                    endedAt: point.timestamp
                )
                context.insert(split)
                session.splits.append(split)
                splitStart = point
                accumulated = 0
                elevationGain = 0
                index += 1
            }
            previous = point
        }

        if accumulated > max(100, splitDistanceMeters * 0.2) {
            let duration = max(1, Int(previous.timestamp.timeIntervalSince(splitStart.timestamp)))
            let split = CardioSplitModel(
                userID: session.userID,
                cardioSessionID: session.id,
                index: index,
                distanceMeters: accumulated,
                durationSeconds: duration,
                paceSecondsPerKm: Double(duration) / max(0.001, accumulated / 1000),
                elevationGainMeters: elevationGain > 0 ? elevationGain : nil,
                startedAt: splitStart.timestamp,
                endedAt: previous.timestamp
            )
            context.insert(split)
            session.splits.append(split)
        }
    }

    static func replaceRoute(for session: CardioSessionModel, locations: [CLLocation], in context: ModelContext) {
        for point in session.routePoints {
            context.delete(point)
        }
        session.routePoints = []

        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else { continue }
            let point = CardioRoutePointModel(
                userID: session.userID,
                cardioSessionID: session.id,
                timestamp: location.timestamp,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
                horizontalAccuracyMeters: location.horizontalAccuracy,
                speedMetersPerSecond: location.speed >= 0 ? location.speed : nil
            )
            context.insert(point)
            session.routePoints.append(point)
        }
        replaceSplits(for: session, in: context)
    }
}

@MainActor
@Observable
final class CardioRouteRecorder: NSObject, CLLocationManagerDelegate {
    static let shared = CardioRouteRecorder()

    /// Live running distance total (meters) for the current session, updated as
    /// GPS fixes arrive so the logger can show distance in real time — the
    /// phone-side fallback when no Apple Watch is streaming.
    private(set) var liveDistanceMeters: Double = 0

    @ObservationIgnored private let manager = CLLocationManager()
    private(set) var recordingSessionID: UUID?
    @ObservationIgnored private var locations: [CLLocation] = []
    @ObservationIgnored private var lastLiveLocation: CLLocation?

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    override private init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func start(session: CardioSessionModel) {
        requestAuthorization()
        guard isAuthorized else { return }
        recordingSessionID = session.id
        locations = []
        lastLiveLocation = nil
        liveDistanceMeters = 0
        manager.startUpdatingLocation()
    }

    /// Live distance for a session if it's the one currently recording, else nil.
    func liveDistanceMeters(for sessionID: UUID) -> Double? {
        recordingSessionID == sessionID ? liveDistanceMeters : nil
    }

    func stop(session: CardioSessionModel, in context: ModelContext) {
        manager.stopUpdatingLocation()
        defer {
            recordingSessionID = nil
            locations = []
        }
        guard recordingSessionID == session.id, !locations.isEmpty else { return }
        CardioRouteMath.replaceRoute(for: session, locations: locations, in: context)
        session.distanceMeters = session.routePoints.count > 1
            ? zip(session.routePoints.sorted { $0.timestamp < $1.timestamp }, session.routePoints.sorted { $0.timestamp < $1.timestamp }.dropFirst())
                .reduce(0) { $0 + CardioRouteMath.distanceMeters($1.0, $1.1) }
            : session.distanceMeters
        session.elevationGainMeters = elevationGain(session.routePoints)
        session.updatedAt = Date()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.locations.append(contentsOf: locations)
            // Accumulate a live distance total from accurate fixes, ignoring
            // sub-metre GPS jitter so a stationary user's distance doesn't drift.
            for location in locations where location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 50 {
                if let last = self.lastLiveLocation {
                    let segment = location.distance(from: last)
                    if segment >= 1 { self.liveDistanceMeters += segment }
                }
                self.lastLiveLocation = location
            }
        }
    }

    private func elevationGain(_ points: [CardioRoutePointModel]) -> Double? {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        var gain = 0.0
        for (previous, point) in zip(sorted, sorted.dropFirst()) {
            guard let prevAltitude = previous.altitudeMeters,
                  let altitude = point.altitudeMeters,
                  altitude > prevAltitude else { continue }
            gain += altitude - prevAltitude
        }
        return gain > 0 ? gain : nil
    }
}

nonisolated extension CardioKind {
    var supportsOutdoorRoute: Bool {
        switch self {
        case .run, .trailRun, .walk, .cycle:
            true
        default:
            false
        }
    }
}
