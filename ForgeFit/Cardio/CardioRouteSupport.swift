import CoreLocation
import ForgeCore
import ForgeData
import Foundation
import Observation
import SwiftData

/// Pure route math plus caller-owned ModelContext mutations. It is safe on the
/// foreground MainActor and on the Health importer's private ModelActor.
nonisolated enum CardioRouteMath {
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
        // 0-based, matching every other split producer; the UI renders index + 1.
        var index = 0

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

enum CardioRouteOwnershipPolicy {
    static func shouldStartAfterAuthorization(
        isAuthorized: Bool,
        pendingSessionID: UUID?,
        recordingSessionID: UUID?
    ) -> Bool {
        guard isAuthorized, let pendingSessionID else { return false }
        return pendingSessionID == recordingSessionID
    }

    static func shouldCancelAsOrphan(
        recordingSessionID: UUID?,
        pendingSessionID: UUID?,
        validSessionIDs: Set<UUID>
    ) -> Bool {
        guard let sessionID = recordingSessionID ?? pendingSessionID else { return false }
        return !validSessionIDs.contains(sessionID)
    }
}

@MainActor
@Observable
final class CardioRouteRecorder: NSObject, CLLocationManagerDelegate {
    static let shared = CardioRouteRecorder()

    /// Phone GPS running total. Consumers must use
    /// `authoritativeLiveDistance` so a fresh Watch stream and speech agree.
    private(set) var liveDistanceMeters: Double = 0

    @ObservationIgnored private let manager = CLLocationManager()
    private(set) var recordingSessionID: UUID?
    @ObservationIgnored private var locations: [CLLocation] = []
    @ObservationIgnored private var lastLiveLocation: CLLocation?
    @ObservationIgnored private var pendingStartSessionID: UUID?
    private var watchDistanceReading: LiveDistanceReading?
    private var phoneGPSDistanceReading: LiveDistanceReading?
    @ObservationIgnored private var milestoneTracker = DistanceMilestoneTracker(
        boundaryMeters: CardioRouteMath.defaultSplitDistanceMeters
    )
    @ObservationIgnored private var splitAnchorDate: Date?
    @ObservationIgnored private var recordingStartDate: Date?

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
        if let recordingSessionID, recordingSessionID != session.id {
            cancel()
        }
        beginSession(
            sessionID: session.id,
            startedAt: session.liveStartedAt ?? session.startedAt
        )
        if authorizationStatus == .notDetermined {
            pendingStartSessionID = session.id
            requestAuthorization()
            return
        }
        guard isAuthorized else { return }
        startLocationUpdates()
    }

    private func beginSession(sessionID: UUID, startedAt: Date) {
        recordingSessionID = sessionID
        locations = []
        lastLiveLocation = nil
        liveDistanceMeters = 0
        watchDistanceReading = nil
        phoneGPSDistanceReading = nil
        milestoneTracker = DistanceMilestoneTracker(
            boundaryMeters: CardioRouteMath.defaultSplitDistanceMeters
        )
        splitAnchorDate = startedAt
        recordingStartDate = startedAt
    }

    private func startLocationUpdates() {
        pendingStartSessionID = nil
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    /// The same distance source used by the logger, intervals, Live Activity,
    /// and milestone speech. Watch freshness is based on phone receipt time,
    /// not the Watch sample's `asOf` (which may be an HR timestamp).
    func authoritativeLiveDistance(
        for sessionID: UUID,
        storedMeters: Double? = nil,
        at referenceDate: Date = .now
    ) -> Double? {
        guard recordingSessionID == sessionID else { return storedMeters }
        return LiveDistanceArbiter.preferred(
            watch: watchDistanceReading,
            phoneGPS: phoneGPSDistanceReading,
            storedMeters: storedMeters,
            at: referenceDate
        )?.meters
    }

    func updateWatchDistance(_ meters: Double?, receivedAt: Date = .now) {
        guard recordingSessionID != nil,
              let meters,
              meters.isFinite,
              meters >= 0 else { return }
        watchDistanceReading = LiveDistanceReading(
            meters: meters,
            observedAt: receivedAt,
            source: .watch
        )
        announceMilestonesIfCrossed(at: receivedAt)
    }

    func stop(session: CardioSessionModel, in context: ModelContext) {
        defer { cancel() }
        guard recordingSessionID == session.id, !locations.isEmpty else { return }
        CardioRouteMath.replaceRoute(for: session, locations: locations, in: context)
        session.distanceMeters = session.routePoints.count > 1
            ? zip(session.routePoints.sorted { $0.timestamp < $1.timestamp }, session.routePoints.sorted { $0.timestamp < $1.timestamp }.dropFirst())
                .reduce(0) { $0 + CardioRouteMath.distanceMeters($1.0, $1.1) }
            : session.distanceMeters
        session.elevationGainMeters = elevationGain(session.routePoints)
        session.updatedAt = Date()
    }

    /// Stop GPS without persisting a route. Used when a session/workout is
    /// discarded, replaced, reset, or found orphaned during lifecycle
    /// reconciliation. Idempotent so terminal paths can safely overlap.
    func cancel(sessionID: UUID? = nil) {
        if let sessionID,
           recordingSessionID != sessionID,
           pendingStartSessionID != sessionID {
            return
        }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        PaceAnnouncer.shared.stop()
        recordingSessionID = nil
        pendingStartSessionID = nil
        locations = []
        lastLiveLocation = nil
        liveDistanceMeters = 0
        watchDistanceReading = nil
        phoneGPSDistanceReading = nil
        milestoneTracker = DistanceMilestoneTracker(
            boundaryMeters: CardioRouteMath.defaultSplitDistanceMeters
        )
        splitAnchorDate = nil
        recordingStartDate = nil
    }

    /// Defensive lifecycle backstop: a CLLocationManager must not outlive the
    /// active model session that owns it.
    func cancelIfOrphaned(validSessionIDs: Set<UUID>) {
        guard CardioRouteOwnershipPolicy.shouldCancelAsOrphan(
            recordingSessionID: recordingSessionID,
            pendingSessionID: pendingStartSessionID,
            validSessionIDs: validSessionIDs
        ) else { return }
        cancel()
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
                let receivedAt = Date.now
                self.phoneGPSDistanceReading = LiveDistanceReading(
                    meters: self.liveDistanceMeters,
                    observedAt: receivedAt,
                    source: .phoneGPS
                )
                self.announceMilestonesIfCrossed(at: receivedAt)
            }
        }
    }

    private func announceMilestonesIfCrossed(at timestamp: Date) {
        guard let sessionID = recordingSessionID,
              let distance = authoritativeLiveDistance(for: sessionID, at: timestamp) else { return }

        for milestone in milestoneTracker.consume(distanceMeters: distance) {
            let splitSeconds = splitAnchorDate.map { max(1, Int(timestamp.timeIntervalSince($0))) } ?? 0
            let totalSeconds = recordingStartDate.map { max(1, Int(timestamp.timeIntervalSince($0))) }
            splitAnchorDate = timestamp
            PaceAnnouncer.shared.announceSplit(
                unitLabel: Locale.current.measurementSystem == .us ? "mile" : "kilometer",
                index: milestone,
                splitSeconds: splitSeconds,
                totalSeconds: totalSeconds
            )
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard CardioRouteOwnershipPolicy.shouldStartAfterAuthorization(
                isAuthorized: self.isAuthorized,
                pendingSessionID: self.pendingStartSessionID,
                recordingSessionID: self.recordingSessionID
            ) else { return }
            self.startLocationUpdates()
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
