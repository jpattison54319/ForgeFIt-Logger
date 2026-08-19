import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// FF-001 entry-path regression tests.
///
/// Both strength entry callers — the runner weight field
/// (`ActiveWorkoutLoggerView.commitWeightDraft` / `quickWeightBase`) and the
/// myo/activation block weight field + its quick increment (`SetTypeBlocks`)
/// — parse the draft with `Fmt.loadKilograms(from:unit:)` and store the
/// result through `SetModel.setModeWeight`. These tests run that exact
/// pipeline against a real `SetModel`, so a decimal-comma draft can never
/// again silently persist as 100× the load that tonnage, volume, e1RM,
/// CloudKit, and HealthKit all read from.
@MainActor
struct LocalizedWeightEntryTests {
    private let userID = ForgeFitDemo.userID

    @Test func typedDecimalCommaPersistsAsFractionalKilograms() async throws {
        let (container, context) = try TestStore.make()
        let set = SetModel(userID: userID, reps: 10)
        context.insert(set)

        // ActiveWorkoutLoggerView.commitWeightDraft() path: parse the draft
        // in the display unit, store through setModeWeight, then persist.
        let next = Fmt.loadKilograms(from: "72,5", unit: .kg)
        set.setModeWeight(next)
        try context.save()

        #expect(abs((set.modeWeight ?? 0) - 72.5) < 0.0001)
        // Derived metrics prove the downstream consumers see 72.5, not 725.
        #expect(abs((set.effectiveLoad ?? 0) - 72.5) < 0.0001)
        #expect(abs((set.totalVolume ?? 0) - 725) < 0.0001)
        #expect(abs((set.estimated1RM ?? 0) - 72.5 * (1 + 10.0 / 30)) < 0.0001)
        _ = container
    }

    @Test func groupedIntegerTypedIntoBlockFieldStaysWhole() async throws {
        let (container, context) = try TestStore.make()
        let set = SetModel(userID: userID, reps: 5)
        context.insert(set)

        // SetTypeBlocks weightField setter path: per-keystroke parse + store.
        let weight = Fmt.loadKilograms(from: "1,000", unit: .kg)
        set.setModeWeight(weight)
        try context.save()

        #expect(abs((set.modeWeight ?? 0) - 1000) < 0.0001)
        #expect(abs((set.totalVolume ?? 0) - 5000) < 0.0001)
        _ = container
    }

    @Test func quickIncrementBaseReadsDecimalCommaDraftAsDisplayValue() {
        // ActiveWorkoutLoggerView.quickWeightBase() mirrors this expression
        // exactly; the fan must increment from 72.5, not 725.
        let draft = Fmt.loadKilograms(from: "72,5", unit: .kg)
            .map(WeightUnit.kg.displayValue(fromKilograms:))
        #expect(draft == 72.5)

        // Grouped integers roll into the fan as whole units, not 1.0.
        let grouped = Fmt.loadKilograms(from: "1,000", unit: .kg)
            .map(WeightUnit.kg.displayValue(fromKilograms:))
        #expect(grouped == 1000)
    }

    @Test func poundDisplayKeepsItsExistingConversionForBothSeparators() throws {
        let comma = try #require(Fmt.loadKilograms(from: "72,5", unit: .lb))
        let point = try #require(Fmt.loadKilograms(from: "72.5", unit: .lb))

        #expect(abs(comma - point) < 0.0001)
        // Identical to the unit's own pre-existing conversion — the fix
        // introduces no new kg↔lb behavior.
        #expect(abs(comma - WeightUnit.lb.kilograms(fromDisplayValue: 72.5)) < 0.0001)
        #expect(abs(comma - (72.5 / 2.2046226218)) < 0.0001)
    }

    @Test func malformedDraftCannotPersistACorruptedLoad() async throws {
        let (container, context) = try TestStore.make()
        let set = SetModel(userID: userID, reps: 10)
        context.insert(set)

        // A separator mix the old comma-strip would have turned into 7253 —
        // the commit path must refuse it instead.
        let next = Fmt.loadKilograms(from: "72,5,3", unit: .kg)
        #expect(next == nil)
        set.setModeWeight(next)
        try context.save()
        #expect(set.modeWeight == nil)
        _ = container
    }
}