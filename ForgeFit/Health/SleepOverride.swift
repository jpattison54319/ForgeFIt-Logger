import Foundation
import Observation

/// A user's correction of one night's sleep, when the app flagged it as
/// probable partial-wear capture.
enum SleepNightOverride: Equatable, Codable {
    /// "That's right" — trust the captured value as a real (short) night.
    case confirmed
    /// "I didn't wear it" — drop this night's sleep from readiness and debt.
    case untracked
    /// "Edit" — use this hand-entered duration instead of the fragment.
    case manual(minutes: Int)
}

/// On-device store of per-night sleep corrections, keyed by the calendar day
/// the sleep ended (the readiness day). Deliberately `UserDefaults`, NOT
/// SwiftData/CloudKit: sleep is health data, and the privacy invariant keeps
/// it off sync and off backup. A correction is a local, device-only annotation.
@MainActor
@Observable
final class SleepOverrideStore {
    static let shared = SleepOverrideStore()

    private let defaultsKey = "sleepNightOverrides.v1"
    private let eagerDeleteRepairKey = "sleepNightOverrides.repairedEagerDelete.v1"
    private let defaults: UserDefaults
    private let calendar: Calendar

    /// Corrections keyed by `startOfDay` of the readiness day.
    private(set) var overrides: [Date: SleepNightOverride] = [:]

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        load()
        repairRecentEagerDeleteIfNeeded()
    }

    func override(for day: Date) -> SleepNightOverride? {
        overrides[calendar.startOfDay(for: day)]
    }

    func set(_ override: SleepNightOverride, for day: Date) {
        overrides[calendar.startOfDay(for: day)] = override
        persist()
    }

    func clear(for day: Date) {
        overrides.removeValue(forKey: calendar.startOfDay(for: day))
        persist()
    }

    // MARK: - Applying corrections

    /// Annotates a raw HealthKit series for sleep integrity and applies the
    /// user's stored corrections in one pass — the processing every readiness
    /// computation and the Home banner share. A corrected night is stamped
    /// `userCorrected` so it's trusted for today's score but kept out of the
    /// rolling baselines; `untracked` clears the night's sleep entirely;
    /// `manual` substitutes the entered duration and clears the fragment-derived
    /// stage/HR fields that no longer describe it.
    func process(_ metrics: [RecoveryEngine.DailyHealthMetric]) -> [RecoveryEngine.DailyHealthMetric] {
        var corrected = metrics.map { metric -> RecoveryEngine.DailyHealthMetric in
            var copy = metric
            // `process` is also safe when handed a previously processed series:
            // clearing an override must clear its presentation metadata too.
            copy.sleepOverride = nil
            copy.integrityFlags.remove(SleepIntegrity.Flag.userCorrected)
            guard let override = override(for: metric.date) else { return copy }
            copy.sleepOverride = override
            copy.integrityFlags.insert(SleepIntegrity.Flag.userCorrected)
            switch override {
            case .confirmed:
                break
            case .untracked:
                copy.sleepTotalMinutes = nil
                copy.sleepDeepMinutes = nil
                copy.sleepREMMinutes = nil
                copy.sleepAwakeMinutes = nil
                copy.sleepingHR = nil
                copy.nocturnalHRV = nil
            case .manual(let minutes):
                copy.sleepTotalMinutes = max(0, minutes)
                // The fragment's stages/HR describe only the worn slice, not
                // the hand-entered whole — drop them rather than imply detail
                // the user didn't provide.
                copy.sleepDeepMinutes = nil
                copy.sleepREMMinutes = nil
                copy.sleepAwakeMinutes = nil
                copy.sleepingHR = nil
                copy.nocturnalHRV = nil
            }
            return copy
        }
        // Re-run detection so a correction immediately clears (or, for a still
        // genuinely-short confirmed night, keeps) the partial-wear judgment.
        corrected = SleepIntegrity.annotate(corrected)
        // `annotate` may re-stamp partialWear on a `confirmed` night; the
        // correction wins — a night the user vouched for is trustworthy.
        for index in corrected.indices where override(for: corrected[index].date) != nil {
            corrected[index].integrityFlags.remove(SleepIntegrity.Flag.partialWear)
        }
        return corrected
    }

    // MARK: - Persistence

    private func persist() {
        let coded = overrides.reduce(into: [String: SleepNightOverride]()) { dict, pair in
            dict[String(pair.key.timeIntervalSince1970)] = pair.value
        }
        if let data = try? JSONEncoder().encode(coded) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let coded = try? JSONDecoder().decode([String: SleepNightOverride].self, from: data) else { return }
        overrides = coded.reduce(into: [Date: SleepNightOverride]()) { dict, pair in
            if let seconds = TimeInterval(pair.key) {
                dict[Date(timeIntervalSince1970: seconds)] = pair.value
            }
        }
    }

    /// The first sleep-card implementation persisted Delete before its Undo
    /// flow had finished, so a refresh could permanently hide the affected
    /// night. Repair only recent destructive entries once; older corrections
    /// and every non-destructive correction remain untouched.
    private func repairRecentEagerDeleteIfNeeded() {
        guard !defaults.bool(forKey: eagerDeleteRepairKey) else { return }

        let cutoff = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -2, to: .now) ?? .now
        )
        let affectedDays = overrides.compactMap { day, override in
            override == .untracked && day >= cutoff ? day : nil
        }
        for day in affectedDays {
            overrides.removeValue(forKey: day)
        }
        if !affectedDays.isEmpty { persist() }
        defaults.set(true, forKey: eagerDeleteRepairKey)
    }
}
