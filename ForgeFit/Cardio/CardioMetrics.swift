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
        labels.append(usesSplit500 ? "Split /500m" : (usesPace ? "Pace" : "Speed"))
        if usesElevation { labels.append("Elevation") }
        if usesIncline { labels.append("Incline") }
        if usesPower { labels.append("Power") }
        if usesStrokeRate { labels.append("Stroke rate") }
        if usesCadence { labels.append(cadenceFieldLabel) }
        if usesFloors { labels.append("Floors") }
        if usesStepCount { labels.append(stepCountLabel) }
        if usesResistance { labels.append("Resistance") }
        if usesSwimContract { labels.append(contentsOf: ["Pool length", "Lengths", "Strokes"]) }
        return labels
    }

    // Which metrics this modality surfaces.
    /// Stair machines and jump rope have no meaningful distance — their
    /// consoles speak floors and jumps; storage keeps any legacy value.
    var usesDistance: Bool { ![.other, .stair, .jumpRope].contains(self) }
    var usesPace: Bool { [.run, .trailRun, .walk, .row, .swim].contains(self) }   // pace vs speed
    var usesElevation: Bool { [.run, .trailRun, .walk, .cycle].contains(self) }
    var usesIncline: Bool { [.run, .walk, .stair, .elliptical].contains(self) }
    var usesPower: Bool { [.cycle, .row, .run, .trailRun].contains(self) }
    var usesStrokeRate: Bool { self == .row }
    var usesCadence: Bool { [.run, .trailRun, .walk, .cycle, .elliptical, .jumpRope].contains(self) }
    /// Machine level/resistance — stair, bike, and elliptical consoles all
    /// expose one; the number is the machine's own scale, so no unit.
    var usesResistance: Bool { [.stair, .cycle, .elliptical].contains(self) }
    /// Stair machines count floors; floors/min is the derived climb rate.
    var usesFloors: Bool { self == .stair }
    /// Step-counted modalities: stairs count steps, ellipticals strides,
    /// jump rope jumps — same storage (`totalSteps`), different vocabulary.
    var usesStepCount: Bool { [.stair, .elliptical, .jumpRope].contains(self) }
    /// Rowing headlines the /500 m split — the erg's native pace language.
    var usesSplit500: Bool { self == .row }
    /// Pool swims carry the pool contract: length, lengths, strokes, stroke
    /// style; distance and SWOLF derive from it.
    var usesSwimContract: Bool { self == .swim }
    /// Pool swims are always measured in fixed meters, regardless of the user's
    /// km/mi preference; every other modality follows the user's distance unit.
    var usesFixedMeters: Bool { self == .swim }

    /// The cadence input's vocabulary per modality — a cyclist pedals rpm,
    /// an elliptical counts strides, a rope counts jumps.
    var cadenceFieldLabel: String {
        switch self {
        case .elliptical: "Strides/min"
        case .jumpRope: "Jumps/min"
        default: "Cadence"
        }
    }

    var cadenceUnit: String {
        switch self {
        case .cycle: "rpm"
        case .elliptical, .jumpRope: "/min"
        default: "spm"
        }
    }

    var stepCountLabel: String {
        switch self {
        case .elliptical: "Strides"
        case .jumpRope: "Jumps"
        default: "Steps"
        }
    }

    /// Title for the headline pace/speed read-out slot.
    var paceHeadline: String {
        if usesSplit500 { return "Split" }
        return usesPace ? "Pace" : "Speed"
    }

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
        if kind.usesSplit500 {
            let s = secPerKm / 2   // per-500m for rowing
            return String(format: "%d:%02d /500m", Int(s) / 60, Int(s) % 60)
        }
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
    /// This is the FALLBACK for sessions without a usable HR series (manual
    /// logs, sparse phone-only HR) — prefer `measuredZoneSecondsArray` and
    /// label anything that came from here as an estimate.
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

    /// Real time-in-zone summed from a session's stored per-10s HR series,
    /// classified against the user's configured zone model. nil when the series
    /// is missing or too sparse to be honest — fall back to the estimate and
    /// say so in the UI.
    static func measuredZoneSecondsArray(series: CardioSampleSeries) -> [Int]? {
        let config = HRZone.config
        return series.hrZoneSeconds { config.zone(for: $0) }
    }

    static func measuredZoneSecondsArray(seriesJSON: String?) -> [Int]? {
        CardioSampleSeries.decode(from: seriesJSON).flatMap(measuredZoneSecondsArray(series:))
    }

    /// Rowing split headline: derive /500 m from real distance + time, and
    /// only fall back to the erg's own stored readout when the piece has no
    /// distance yet. "—" over a guess when neither exists.
    static func rowingSplitString(distanceMeters: Double?, durationSeconds: Int?, storedSplitSeconds: Double?) -> String {
        let derived = CardioDerivations.split500Seconds(distanceMeters: distanceMeters, durationSeconds: durationSeconds)
        guard let text = CardioDerivations.splitString(seconds: derived ?? storedSplitSeconds) else { return "—" }
        return "\(text) /500m"
    }
}

extension IntervalPlan {
    /// User-facing goal summary in display units: goal + zone + pace band
    /// composed the way the goal rows show them. Core's `structureSummary`
    /// stays unit-neutral; this is the app-side, Fmt-aware voice of it.
    var displaySummary: String {
        var text = structureSummary(distance: { Fmt.cardioDistance($0, kind: .run) })
        if !hasSteps, let band = target, band.isMeaningful {
            let bandText = IntervalTargetFormatting.text(for: band)
            text = text == "Open" ? bandText : "\(text) · \(bandText)"
        }
        return text
    }
}

extension ExerciseLibraryModel {
    /// The cardio modality for this exercise: an explicit choice made at
    /// creation wins; otherwise infer from name/equipment (the built-in
    /// library and legacy custom exercises).
    var resolvedCardioKind: CardioKind {
        cardioKindRaw.flatMap(CardioKind.init(rawValue:))
            ?? CardioKind.infer(name: name, equipment: equipment)
    }
}
