import Foundation
import ForgeCore
import ForgeData
import SwiftUI

/// Rich cardio classification used to drive the Strava-style cardio UI: which
/// metrics matter, the muscles worked, and how to format pace/speed.
nonisolated enum CardioKind: String, CaseIterable {
    case run, walk, trailRun, cycle, row, elliptical, stair, jumpRope, skate, swim, other

    var title: String {
        switch self {
        case .run: "Run"
        case .walk: "Walk"
        case .trailRun: "Trail Run"
        case .cycle: "Ride"
        case .row: "Row"
        case .elliptical: "Elliptical"
        case .stair: "Stair Climb"
        case .jumpRope: "Jump Rope"
        case .skate: "Skate"
        case .swim: "Swim"
        case .other: "Cardio"
        }
    }

    var systemImage: String {
        switch self {
        case .run, .trailRun: "figure.run"
        case .walk: "figure.walk"
        case .cycle: "figure.outdoor.cycle"
        case .row: "figure.rower"
        case .elliptical: "figure.elliptical"
        case .stair: "figure.stair.stepper"
        case .jumpRope: "figure.jumprope"
        case .skate: "figure.skating"
        case .swim: "figure.pool.swim"
        case .other: "heart.fill"
        }
    }

    /// Primary movers, plus the cardiovascular "system" is always appended.
    var muscles: [String] {
        switch self {
        case .run, .trailRun, .walk: ["quadriceps", "hamstrings", "glutes", "calves"]
        case .cycle: ["quadriceps", "glutes", "hamstrings", "calves"]
        case .row: ["lats", "upper back", "quadriceps", "biceps"]
        case .elliptical: ["quadriceps", "glutes", "hamstrings", "calves"]
        case .stair: ["quadriceps", "glutes", "calves"]
        case .jumpRope: ["calves", "shoulders"]
        case .skate: ["quadriceps", "glutes", "adductors"]
        case .swim: ["lats", "shoulders", "core"]
        case .other: ["full body"]
        }
    }
    var musclesWorked: [String] { ["cardiovascular"] + muscles }

    var metricLabels: [String] {
        var labels = ["Time", "Heart rate", "Effort"]
        if usesDistance { labels.append("Distance") }
        labels.append(usesPace ? "Pace" : "Speed")
        if usesElevation { labels.append("Elevation") }
        if usesIncline { labels.append("Incline") }
        if usesPower { labels.append("Power") }
        if usesStrokeRate { labels.append("Stroke rate") }
        if usesCadence { labels.append("Cadence") }
        return labels
    }

    // Which metrics this modality surfaces.
    var usesDistance: Bool { self != .other }
    var usesPace: Bool { [.run, .trailRun, .walk, .row, .swim].contains(self) }   // pace vs speed
    var usesElevation: Bool { [.run, .trailRun, .walk, .cycle].contains(self) }
    var usesIncline: Bool { [.run, .walk, .stair].contains(self) }
    var usesPower: Bool { [.cycle, .row].contains(self) }
    var usesStrokeRate: Bool { self == .row }
    var usesCadence: Bool { [.run, .trailRun, .walk, .cycle].contains(self) }
    /// Pool swims are always measured in fixed meters, regardless of the user's
    /// km/mi preference; every other modality follows the user's distance unit.
    var usesFixedMeters: Bool { self == .swim }

    static func infer(name: String, equipment: String?) -> CardioKind {
        let n = name.lowercased()
        if n.contains("trail") { return .trailRun }
        if n.contains("run") || n.contains("treadmill") && !n.contains("walk") || n.contains("jog") || n.contains("sprint") { return .run }
        if n.contains("walk") || n.contains("hik") { return .walk }
        if n.contains("cycl") || n.contains("bike") || n.contains("spin") { return .cycle }
        if n.contains("row") { return .row }
        if n.contains("elliptical") { return .elliptical }
        if n.contains("stair") || n.contains("step mill") || n.contains("stepmill") { return .stair }
        if n.contains("rope") || n.contains("skip") { return .jumpRope }
        if n.contains("skat") { return .skate }
        if n.contains("swim") { return .swim }
        // Fall back to the quick-start modality strings.
        switch name.lowercased() {
        case "run": return .run
        case "cycle", "ride": return .cycle
        case "row": return .row
        case "zone 2 walk", "walk": return .walk
        default: return .other
        }
    }

    /// Resolve a stored `CardioSessionModel.modality` string back to a kind.
    static func from(modality: String) -> CardioKind {
        CardioKind(rawValue: modality) ?? infer(name: modality, equipment: nil)
    }

    /// An indoor / machine variant of an otherwise-outdoor modality — a
    /// treadmill run, a stationary/spin bike, an indoor rower/erg — detected
    /// from the exercise name or equipment. GPS distance is meaningless here.
    static func isIndoorVariant(name: String, equipment: String?) -> Bool {
        let hay = (name + " " + (equipment ?? "")).lowercased()
        let keywords = ["treadmill", "indoor", "stationary", "spin bike", "spinning",
                        "spin ", "smart trainer", "bike trainer", "erg", "assault"]
        return keywords.contains { hay.contains($0) }
    }

    /// Whether this specific exercise yields a real GPS route/distance. Outdoor
    /// run/walk/cycle do; indoor machines (treadmill, spin bike, erg) and
    /// modalities without a route (elliptical, stair, rope, swim) do not — for
    /// those, distance is a machine read-out the user enters manually.
    static func providesGPSDistance(name: String, equipment: String?) -> Bool {
        guard infer(name: name, equipment: equipment).supportsOutdoorRoute else { return false }
        return !isIndoorVariant(name: name, equipment: equipment)
    }
}

/// Derived cardio metric formatting (pace, speed) and heart-rate zone modeling.
enum CardioMetrics {

    /// Pace in seconds per km. nil when distance/duration missing.
    static func paceSecPerKm(distanceMeters: Double?, durationSeconds: Int?) -> Double? {
        guard let distanceMeters, distanceMeters > 0, let durationSeconds, durationSeconds > 0 else { return nil }
        return Double(durationSeconds) / (distanceMeters / 1000)
    }

    /// Formatted pace in the user's distance unit (min/km or min/mi); pool
    /// swims render per-100m regardless of the preference.
    static func paceString(distanceMeters: Double?, durationSeconds: Int?, kind: CardioKind = .run, unit: DistanceUnit = Fmt.distanceUnit) -> String {
        guard let secPerKm = paceSecPerKm(distanceMeters: distanceMeters, durationSeconds: durationSeconds) else { return "—" }
        if kind.usesFixedMeters {
            let s = secPerKm / 10   // per-100m for swims
            return String(format: "%d:%02d /100m", Int(s) / 60, Int(s) % 60)
        }
        let secPerUnit = secPerKm * (unit.metersPerUnit / 1000)
        return String(format: "%d:%02d %@", Int(secPerUnit) / 60, Int(secPerUnit) % 60, unit.paceSuffix)
    }

    static func speedKmh(distanceMeters: Double?, durationSeconds: Int?) -> Double? {
        guard let distanceMeters, distanceMeters > 0, let durationSeconds, durationSeconds > 0 else { return nil }
        return (distanceMeters / 1000) / (Double(durationSeconds) / 3600)
    }

    static func speedString(distanceMeters: Double?, durationSeconds: Int?, unit: DistanceUnit = Fmt.distanceUnit) -> String {
        guard let kmh = speedKmh(distanceMeters: distanceMeters, durationSeconds: durationSeconds) else { return "—" }
        let value = unit == .km ? kmh : kmh / (DistanceUnit.mi.metersPerUnit / 1000)
        return "\(value.formatted(.number.precision(.fractionLength(1)))) \(unit.speedSuffix)"
    }

    /// Estimated time-in-zone distribution centered on the average-HR zone.
    /// Clearly an estimate until a per-second HR stream is available via HealthKit.
    static func estimatedZoneSeconds(avgHR: Int?, durationSeconds: Int?) -> [(zone: Int, seconds: Int)] {
        guard let avgHR, let durationSeconds, durationSeconds > 0 else { return [] }
        let center = HRZone.zone(forAvgHR: avgHR)
        // Weight mass on the center zone, tapering to neighbors.
        let weights: [Int: Double] = [center: 0.6, center - 1: 0.2, center + 1: 0.15, center - 2: 0.03, center + 2: 0.02]
        var out: [(Int, Int)] = []
        for z in 1...5 {
            let w = weights[z] ?? 0
            if w > 0 { out.append((z, Int(Double(durationSeconds) * w))) }
        }
        return out
    }

    static func estimatedZoneSecondsArray(avgHR: Int?, durationSeconds: Int?) -> [Int] {
        var zones = [Int](repeating: 0, count: 5)
        for item in estimatedZoneSeconds(avgHR: avgHR, durationSeconds: durationSeconds) where (1...5).contains(item.zone) {
            zones[item.zone - 1] = item.seconds
        }
        return zones
    }
}
