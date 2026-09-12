import CoreGraphics
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct QuickIncrementPreferencesTests {
    @Test func defaultsAndIndependentGroupsPersistAcrossReload() throws {
        let suite = "QuickIncrementTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for kind in QuickIncrementKind.allCases {
            #expect(QuickIncrementPreferences.load(kind, from: defaults) == kind.defaults)
        }
        #expect(QuickIncrementPreferences.save([2, 6, 11], for: .reps, to: defaults))
        #expect(QuickIncrementPreferences.save([0.25, 1.75, 12.25], for: .pounds, to: defaults))
        #expect(QuickIncrementPreferences.save([0.1, 0.75, 4.5], for: .kilograms, to: defaults))
        let reloaded = try #require(UserDefaults(suiteName: suite))
        #expect(QuickIncrementPreferences.load(.reps, from: reloaded) == [2, 6, 11])
        #expect(QuickIncrementPreferences.load(.pounds, from: reloaded) == [0.25, 1.75, 12.25])
        #expect(QuickIncrementPreferences.load(.kilograms, from: reloaded) == [0.1, 0.75, 4.5])
        #expect(Set(QuickIncrementPreferences.keys).isSubset(of: Set(AppPreferenceKeys.backedUp)))
        for key in QuickIncrementPreferences.keys { defaults.removeObject(forKey: key) }
        for kind in QuickIncrementKind.allCases {
            #expect(QuickIncrementPreferences.load(kind, from: reloaded) == kind.defaults)
        }
    }

    @Test func invalidValuesNeverReplaceSavedPreferences() throws {
        let suite = "QuickIncrementTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for kind in QuickIncrementKind.allCases {
            for invalid in [[0, 2, 3], [-1, 2, 3], [1, 1, 3], [3, 2, 1], [1, 2], [1, 2, 1001], [.nan, 2, 3], [1, 2, .infinity]] {
                #expect(!QuickIncrementPreferences.save(invalid, for: kind, to: defaults))
                #expect(QuickIncrementPreferences.load(kind, from: defaults) == kind.defaults)
            }
            defaults.set(-4, forKey: kind.key(0))
            #expect(QuickIncrementPreferences.load(kind, from: defaults) == kind.defaults)
        }
        #expect(!QuickIncrementKind.reps.isValid([0.5, 2, 3]))
        #expect(!QuickIncrementKind.pounds.isValid([0.001, 2, 3]))
        #expect(!QuickIncrementKind.kilograms.isValid([1.234, 2, 3]))
    }

    @Test func everyCustomBandAppliesExactlyOnceAndFloorsAtZero() throws {
        let cases: [([Double], Double, [Double])] = [
            ([2, 6, 11], 10, [21, 16, 12, 8, 4, 0]),
            ([0.25, 1.75, 12.25], 100, [112.25, 101.75, 100.25, 99.75, 98.25, 87.75]),
            ([0.1, 0.75, 4.5], 3, [7.5, 3.75, 3.1, 2.9, 2.25, 0]),
        ]
        for (increments, base, expected) in cases {
            let options = QuickIncrementController.options(increments: increments)
            for index in options.indices {
                let controller = QuickIncrementController()
                controller.overlayBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
                var applied: [Double] = []
                let id = try #require(controller.begin(
                    fieldFrame: CGRect(x: 160, y: 400, width: 80, height: 44),
                    options: options, baseValue: base, applyValue: { applied.append($0) }
                ))
                let slot = try #require(controller.layout())[index]
                let point = CGPoint(x: slot.rect.midX, y: slot.rect.midY)
                controller.updateHover(at: point, transactionID: id)
                controller.finish(at: point, transactionID: id)
                controller.finish(at: point, transactionID: id)
                #expect(applied.count == 1)
                #expect(abs(try #require(applied.first) - expected[index]) < 0.000_001)
            }
        }
    }

    @Test func fractionalCustomWeightAndRepsSurviveCommitAndFreshContext() throws {
        let (container, context) = try TestStore.make()
        for unit in [WeightUnit.lb, .kg] {
            let set = SetModel(userID: ForgeFitDemo.userID, reps: 10)
            let identifier = set.id
            context.insert(set)
            // The logger formats the adjusted display value, then commits it
            // through the same parser as typing. Verify durable kg storage.
            let displayWeight = 100.25
            let draft = Fmt.load(unit.kilograms(fromDisplayValue: displayWeight), unit: unit)
            #expect(draft == "100.25")
            set.setModeWeight(Fmt.loadKilograms(from: draft, unit: unit))
            set.reps = 16
            try context.save()
            let fresh = ModelContext(container)
            let reloaded = try #require(fresh.fetch(FetchDescriptor<SetModel>(predicate: #Predicate { $0.id == identifier })).first)
            #expect(abs(unit.displayValue(fromKilograms: try #require(reloaded.modeWeight)) - 100.25) < 0.000_001)
            #expect(reloaded.reps == 16)
        }
    }
}
