import Foundation
import Testing
@testable import ForgeCore

struct WarmupRampConfigTests {

    @Test func defaultRampMatchesLegacyValues() {
        let config = WarmupRampConfig()
        #expect(config.stages.count == 3)
        #expect(config.stages.map(\.weightPercent) == [40, 60, 80])
        #expect(config.stages.map(\.reps) == [10, 6, 3])
        #expect(config.isDefault)
    }

    @Test func customRampIsNotDefault() {
        let config = WarmupRampConfig(stages: [.init(weightPercent: 50, reps: 8)])
        #expect(!config.isDefault)
        #expect(config.stages.count == 1)
    }

    @Test func stageInitClampsOutOfRangeValues() {
        let stage = WarmupRampConfig.Stage(weightPercent: 250, reps: 0)
        #expect(stage.weightPercent == 95)
        #expect(stage.reps == 1)
        let low = WarmupRampConfig.Stage(weightPercent: 0, reps: 99)
        #expect(low.weightPercent == 5)
        #expect(low.reps == 30)
    }

    @Test func emptyStagesFallBackToDefault() {
        let config = WarmupRampConfig(stages: [])
        #expect(config.isDefault)
    }

    @Test func tooManyStagesAreTrimmed() {
        let many = (0..<12).map { _ in WarmupRampConfig.Stage(weightPercent: 50, reps: 5) }
        let config = WarmupRampConfig(stages: many)
        #expect(config.stages.count == WarmupRampConfig.maxStages)
    }

    /// The synthesized Codable decoder bypasses the clamping init, so the store
    /// re-wraps decoded stages — malformed persisted data must not survive.
    @Test func decodeReclampsThroughStore() throws {
        let malformed = Data(#"{"stages":[{"weightPercent":999,"reps":0}]}"#.utf8)
        let suite = "warmupRampConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(malformed, forKey: WarmupRampConfigStore.key)

        let loaded = WarmupRampConfigStore.load(defaults: defaults)
        #expect(loaded.stages.first?.weightPercent == 95)
        #expect(loaded.stages.first?.reps == 1)
    }

    @Test func loadReturnsDefaultWhenAbsent() {
        let suite = "warmupRampConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WarmupRampConfigStore.load(defaults: defaults).isDefault)
    }

    @Test func saveThenLoadRoundTrips() {
        let suite = "warmupRampConfigTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = WarmupRampConfig(stages: [
            .init(weightPercent: 50, reps: 8),
            .init(weightPercent: 75, reps: 4),
        ])
        WarmupRampConfigStore.save(config, defaults: defaults)
        #expect(WarmupRampConfigStore.load(defaults: defaults) == config)
    }

    // MARK: - Weight computation

    @Test func weightSnapsToStep() {
        let config = WarmupRampConfig() // 40 / 60 / 80
        // 100 lb top, 5 lb step → 40, 60, 80.
        #expect(config.weight(forStageAt: 0, topWeightInDisplayUnit: 100, step: 5) == 40)
        #expect(config.weight(forStageAt: 1, topWeightInDisplayUnit: 100, step: 5) == 60)
        #expect(config.weight(forStageAt: 2, topWeightInDisplayUnit: 100, step: 5) == 80)
    }

    @Test func weightRoundsToNearestStep() {
        let config = WarmupRampConfig(stages: [.init(weightPercent: 40, reps: 10)])
        // 135 * 0.4 = 54 → nearest 5 = 55.
        #expect(config.weight(forStageAt: 0, topWeightInDisplayUnit: 135, step: 5) == 55)
    }

    @Test func weightIsNilWithoutTopOrStage() {
        let config = WarmupRampConfig()
        #expect(config.weight(forStageAt: 0, topWeightInDisplayUnit: 0, step: 5) == nil)
        #expect(config.weight(forStageAt: 9, topWeightInDisplayUnit: 100, step: 5) == nil)
    }

    @Test func weightFloorsAtOneStep() {
        // A tiny top weight still yields at least one step, never zero.
        let config = WarmupRampConfig(stages: [.init(weightPercent: 5, reps: 10)])
        #expect(config.weight(forStageAt: 0, topWeightInDisplayUnit: 10, step: 5) == 5)
    }
}
