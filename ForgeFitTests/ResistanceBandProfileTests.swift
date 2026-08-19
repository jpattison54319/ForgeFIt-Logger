import Foundation
import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
@Suite("Resistance band loads")
struct ResistanceBandProfileTests {
    @Test func defaultsResolveColorsToCanonicalKilograms() throws {
        let profile = ResistanceBandProfile.standard
        let purple = try #require(profile.presets.first { $0.name == "Purple" })

        #expect(abs(WeightUnit.lb.displayValue(fromKilograms: purple.weightKilograms) - 50) < 0.001)
        #expect(profile.matching(weightKilograms: purple.weightKilograms)?.hue == .purple)
    }

    @Test func customBandsCanBeAddedAndRoundTrip() throws {
        var profile = ResistanceBandProfile.standard
        profile.addPreset()
        profile.presets[profile.presets.count - 1].name = "Extra Heavy"
        profile.presets[profile.presets.count - 1].weightKilograms = 42

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ResistanceBandProfile.self, from: data)

        #expect(decoded.presets.count == ResistanceBandProfile.standard.presets.count + 1)
        #expect(decoded.presets.last?.name == "Extra Heavy")
        #expect(decoded.presets.last?.weightKilograms == 42)
    }

    @Test func bandDetectionCoversEquipmentAndAssistedNames() {
        #expect(ResistanceBandSupport.isBandExercise(name: "Lateral Raise", equipment: "Bands"))
        #expect(ResistanceBandSupport.isBandExercise(name: "Band Assisted Pull-Up", equipment: "Other"))
        #expect(!ResistanceBandSupport.isBandExercise(name: "Barbell Row", equipment: "Barbell"))
    }

    @Test func selectedBandUsesExistingExternalAddedAndAssistedMath() throws {
        let band = try #require(ResistanceBandProfile.standard.presets.first { $0.hue == .black })

        let external = SetModel(userID: UUID(), position: 0, weightMode: .external, reps: 1)
        external.setModeWeight(band.weightKilograms)
        #expect(external.effectiveLoad == band.weightKilograms)

        let added = SetModel(
            userID: UUID(), position: 0, weightMode: .bodyweightAdded,
            reps: 1, bodyweightKg: 100
        )
        added.setModeWeight(band.weightKilograms)
        #expect(added.effectiveLoad == 100 + band.weightKilograms)

        let assisted = SetModel(
            userID: UUID(), position: 0, weightMode: .bodyweightAssisted,
            reps: 1, bodyweightKg: 100
        )
        assisted.setModeWeight(band.weightKilograms)
        #expect(assisted.effectiveLoad == 100 - band.weightKilograms)
    }
}
