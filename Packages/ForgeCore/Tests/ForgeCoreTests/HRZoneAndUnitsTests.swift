import Foundation
import Testing
@testable import ForgeCore

struct DistanceUnitTests {

    @Test func kilometersConvertMetersOneToOne() {
        #expect(DistanceUnit.km.metersPerUnit == 1000)
        #expect(DistanceUnit.km.distance(fromMeters: 5000) == 5)
        #expect(DistanceUnit.km.meters(fromDistance: 5) == 5000)
        #expect(DistanceUnit.km.abbreviation == "km")
        #expect(DistanceUnit.km.speedSuffix == "km/h")
        #expect(DistanceUnit.km.paceSuffix == "/km")
    }

    @Test func milesConvertViaExactFactor() {
        #expect(DistanceUnit.mi.metersPerUnit == 1609.344)
        #expect(abs(DistanceUnit.mi.distance(fromMeters: 1609.344) - 1) < 1e-9)
        #expect(abs(DistanceUnit.mi.meters(fromDistance: 3) - 4828.032) < 1e-6)
        #expect(DistanceUnit.mi.abbreviation == "mi")
        #expect(DistanceUnit.mi.speedSuffix == "mph")
        #expect(DistanceUnit.mi.paceSuffix == "/mi")
    }

    @Test func toggleFlips() {
        #expect(DistanceUnit.km.toggled == .mi)
        #expect(DistanceUnit.mi.toggled == .km)
    }
}

struct HRZoneConfigTests {

    @Test func defaultModelClassifiesAgainst190() {
        let config = HRZoneConfig()
        #expect(config.maxHR == 190)
        #expect(config.zone(for: 100) == 1)   // 0.53
        #expect(config.zone(for: 114) == 2)   // exactly 0.60 -> Z2
        #expect(config.zone(for: 140) == 3)   // 0.74
        #expect(config.zone(for: 160) == 4)   // 0.84
        #expect(config.zone(for: 185) == 5)   // 0.97
    }

    @Test func bpmRangesMatchBoundaries() {
        let config = HRZoneConfig()   // max 190, bounds 60/70/80/90
        #expect(config.rangeBPM(forZone: 1) == 0...114)
        #expect(config.rangeBPM(forZone: 2) == 114...133)
        #expect(config.rangeBPM(forZone: 5) == 171...190)
    }

    @Test func customMaxHRScalesZones() {
        let config = HRZoneConfig(maxHR: 200)
        #expect(config.rangeBPM(forZone: 2) == 120...140)   // 0.60*200 ... 0.70*200
        #expect(config.zone(for: 199) == 5)
    }

    @Test func ageFormulaClampsSensibly() {
        #expect(HRZoneConfig.maxHR(forAge: 30) == 190)
        #expect(HRZoneConfig.maxHR(forAge: 20) == 200)
        #expect(HRZoneConfig.maxHR(forAge: 200) == 100)   // 220-200=20 -> clamped up
    }

    @Test func malformedBoundsFallBackToDefault() {
        #expect(HRZoneConfig(zoneUpperBounds: [0.9, 0.8, 0.7, 0.6]).zoneUpperBounds == HRZoneConfig.defaultBounds)
        #expect(HRZoneConfig(zoneUpperBounds: [0.6, 0.7]).zoneUpperBounds == HRZoneConfig.defaultBounds)
        #expect(HRZoneConfig(zoneUpperBounds: [0.5, 0.6, 0.75, 0.88]).zoneUpperBounds == [0.5, 0.6, 0.75, 0.88])
    }

    @Test func roundTripsThroughStore() {
        let defaults = UserDefaults(suiteName: "hrzone.test.\(UUID().uuidString)")!
        let config = HRZoneConfig(maxHR: 205, restingHR: 48)
        HRZoneConfigStore.save(config, defaults: defaults)
        #expect(HRZoneConfigStore.load(defaults: defaults) == config)
    }
}

struct IntervalPlanZoneTargetTests {

    @Test func zoneTargetRoundTrips() {
        let plan = IntervalPlan.build(warmupSeconds: 0, repeats: 0, workSeconds: 0, recoverSeconds: 0, cooldownSeconds: 0, hrZoneTarget: 2)
        #expect(plan.hrZoneTarget == 2)
        #expect(plan.hasSteps == false)
        #expect(plan.isMeaningful == true)   // zone target alone is meaningful
        let decoded = IntervalPlan.decode(from: plan.encodedJSON())
        #expect(decoded?.hrZoneTarget == 2)
    }

    @Test func legacyJSONWithoutZoneTargetDecodesToNil() {
        // A plan encoded before hrZoneTarget existed has no such key.
        let legacy = #"{"steps":[]}"#
        let decoded = IntervalPlan.decode(from: legacy)
        #expect(decoded != nil)
        #expect(decoded?.hrZoneTarget == nil)
        #expect(decoded?.isMeaningful == false)
    }
}
