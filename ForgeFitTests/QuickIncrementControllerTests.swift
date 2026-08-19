import CoreGraphics
import Foundation
import Testing
@testable import ForgeFit

struct QuickIncrementControllerTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    private let field = CGRect(x: 150, y: 400, width: 60, height: 32)

    @Test func repsOptionsFanFromPlusThreeToMinusThree() {
        let options = QuickIncrementController.repsOptions()
        #expect(options.map(\.delta) == [3, 2, 1, -1, -2, -3])
        #expect(options.map(\.label) == ["+3", "+2", "+1", "−1", "−2", "−3"])
    }

    @Test func weightOptionsUseNativeStepsForEachUnit() {
        let pounds = QuickIncrementController.weightOptions(unit: .lb)
        #expect(pounds.map(\.delta) == [7.5, 5, 2.5, -2.5, -5, -7.5])
        #expect(pounds.map(\.label) == ["+7.5", "+5", "+2.5", "−2.5", "−5", "−7.5"])

        let kilograms = QuickIncrementController.weightOptions(unit: .kg)
        #expect(kilograms.map(\.delta) == [3.75, 2.5, 1.25, -1.25, -2.5, -3.75])
        #expect(kilograms.map(\.label) == ["+3.75", "+2.5", "+1.25", "−1.25", "−2.5", "−3.75"])
    }

    @Test func displayedBaseUsesTheVisibleGhostNotTheHiddenRoutineValue() {
        let base = QuickIncrementController.displayedBase(
            draftValue: 625.18,
            isDraftEdited: false,
            enteredValue: 625.18,
            suggestedValue: 72.5,
            isShowingSuggestion: true
        )

        #expect(base == 72.5)
        #expect(QuickIncrementController.displayedBase(
            draftValue: 80,
            isDraftEdited: true,
            enteredValue: 625.18,
            suggestedValue: 72.5,
            isShowingSuggestion: true
        ) == 80)
        #expect(QuickIncrementController.displayedBase(
            draftValue: nil,
            isDraftEdited: true,
            enteredValue: 625.18,
            suggestedValue: 72.5,
            isShowingSuggestion: true
        ) == nil)
    }

    @Test func revealStagesPairEqualDistancesAndBudOutward() {
        let count = QuickIncrementController.repsOptions().count
        let stages = (0..<count).map {
            QuickIncrementController.revealStage(for: $0, count: count)
        }
        let parents = (0..<count).map {
            QuickIncrementController.revealParentIndex(for: $0, count: count)
        }

        #expect(stages == [2, 1, 0, 0, 1, 2])
        #expect(parents == [1, 2, nil, nil, 3, 4])
    }

    @Test func layoutStacksAroundTheFieldAndFreezesForTheTransaction() {
        let controller = configuredController()
        _ = begin(controller, options: QuickIncrementController.repsOptions(), base: 0)

        let slots = try! #require(controller.layout())
        #expect(slots.count == 6)
        #expect(slots[0].rect.maxY <= slots[1].rect.minY + 0.001)
        #expect(slots[2].rect.maxY <= field.minY)
        #expect(slots[3].rect.minY >= field.maxY)
        #expect(slots[5].rect.minY > slots[4].rect.minY)

        controller.overlayBounds = CGRect(x: 0, y: 200, width: 250, height: 300)
        #expect(controller.layout() == slots)
    }

    @Test func guidedMyoRepLayoutIsLargerWithoutChangingCompactMetrics() {
        let compact = configuredController()
        _ = begin(compact, options: QuickIncrementController.repsOptions(), base: 4)
        let compactSlots = try! #require(compact.layout())

        let guided = QuickIncrementController(metrics: .guidedMyoRep)
        guided.overlayBounds = CGRect(x: 0, y: 59, width: 400, height: 741)
        _ = begin(guided, options: QuickIncrementController.repsOptions(), base: 4)
        let guidedSlots = try! #require(guided.layout())

        #expect(compactSlots[0].rect.size == CGSize(width: 92, height: 44))
        #expect(guidedSlots[0].rect.size == CGSize(width: 120, height: 56))
        #expect(compact.metrics.bandHeight - compact.metrics.visualHeightInset == 36)
        #expect(guided.metrics.bandHeight - guided.metrics.visualHeightInset == 48)
        #expect(guided.metrics.visualHeightInset == compact.metrics.visualHeightInset)
        #expect(compact.overlayLocalRect(for: compactSlots[0].rect) == compactSlots[0].rect)
        #expect(
            guided.overlayLocalRect(for: guidedSlots[0].rect)
                == guidedSlots[0].rect.offsetBy(dx: 0, dy: -59)
        )
    }

    @Test func layoutSlidesInsideBoundsNearTheTopEdge() {
        let controller = configuredController()
        let topField = CGRect(x: 150, y: 20, width: 60, height: 32)
        _ = begin(controller, field: topField, options: QuickIncrementController.repsOptions(), base: 0)

        let slots = try! #require(controller.layout())
        #expect(slots.allSatisfy { $0.rect.minY >= bounds.minY })
        #expect(slots.allSatisfy { $0.rect.maxY <= bounds.maxY })
    }

    @Test func highlightedBandAppliesAndTerminalJitterCannotReplaceIt() {
        let controller = configuredController()
        var applied: Double?
        let transactionID = begin(
            controller,
            options: QuickIncrementController.repsOptions(),
            base: 10,
            apply: { applied = $0 }
        )
        let slots = try! #require(controller.layout())

        controller.updateHover(
            at: CGPoint(x: slots[2].rect.maxX + 30, y: slots[2].rect.midY),
            transactionID: transactionID
        )
        #expect(controller.fan?.hoveredIndex == 2)

        // UIKit can report a noisy terminal coordinate on a fast lift. The
        // option already highlighted to the user remains authoritative.
        controller.finish(
            at: CGPoint(x: slots[4].rect.midX, y: slots[4].rect.midY),
            transactionID: transactionID
        )
        #expect(applied == 11)
        #expect(!controller.isActive)
    }

    @Test func fastReleaseUsesTerminalPointWhenNoChangedEventArrived() {
        let controller = configuredController()
        var applied: Double?
        let transactionID = begin(
            controller,
            options: QuickIncrementController.weightOptions(unit: .kg),
            base: 72.5,
            apply: { applied = $0 }
        )
        let slots = try! #require(controller.layout())

        controller.finish(
            at: CGPoint(x: slots[2].rect.midX, y: slots[2].rect.midY),
            transactionID: transactionID
        )

        #expect(applied == 73.75)
        #expect(!controller.isActive)
    }

    @Test func neutralReleaseCancelsWithoutApplying() {
        let controller = configuredController()
        var applied: Double?
        let transactionID = begin(
            controller,
            options: QuickIncrementController.repsOptions(),
            base: 10,
            apply: { applied = $0 }
        )

        controller.finish(
            at: CGPoint(x: field.midX, y: field.midY),
            transactionID: transactionID
        )

        #expect(applied == nil)
        #expect(!controller.isActive)
    }

    @Test func onlyTheRecognizerThatOpenedTheFanCanUpdateOrFinishIt() {
        let controller = configuredController()
        var applied: Double?
        let transactionID = begin(
            controller,
            options: QuickIncrementController.repsOptions(),
            base: 10,
            apply: { applied = $0 }
        )
        let slots = try! #require(controller.layout())
        let staleID = UUID()

        controller.updateHover(at: CGPoint(x: slots[2].rect.midX, y: slots[2].rect.midY), transactionID: staleID)
        controller.finish(at: CGPoint(x: slots[2].rect.midX, y: slots[2].rect.midY), transactionID: staleID)
        controller.cancel(transactionID: staleID)

        #expect(controller.isActive)
        #expect(controller.fan?.hoveredIndex == nil)
        #expect(applied == nil)

        controller.finish(at: CGPoint(x: slots[2].rect.midX, y: slots[2].rect.midY), transactionID: transactionID)
        #expect(applied == 11)
    }

    @Test func adjustmentUsesTheBaseCapturedWhenTheHoldBegins() {
        let controller = configuredController()
        var visibleValue = 72.5
        var applied: Double?
        let transactionID = begin(
            controller,
            options: QuickIncrementController.weightOptions(unit: .kg),
            base: visibleValue,
            apply: { applied = $0 }
        )

        visibleValue = 625.18
        let slots = try! #require(controller.layout())
        controller.updateHover(at: CGPoint(x: slots[1].rect.midX, y: slots[1].rect.midY), transactionID: transactionID)
        controller.finish(at: CGPoint(x: slots[1].rect.midX, y: slots[1].rect.midY), transactionID: transactionID)

        #expect(visibleValue == 625.18)
        #expect(applied == 75)
    }

    @Test func everyBandAppliesExactlyOnceInKilogramsAndPounds() {
        for unit in [WeightUnit.kg, .lb] {
            let options = QuickIncrementController.weightOptions(unit: unit)
            for index in options.indices {
                let controller = configuredController()
                var applied: [Double] = []
                let transactionID = begin(
                    controller,
                    options: options,
                    base: 72.5,
                    apply: { applied.append($0) }
                )
                let slots = try! #require(controller.layout())
                let point = CGPoint(x: slots[index].rect.midX, y: slots[index].rect.midY)
                controller.updateHover(at: point, transactionID: transactionID)
                controller.finish(at: point, transactionID: transactionID)
                controller.finish(at: point, transactionID: transactionID)

                #expect(applied == [max(0, 72.5 + options[index].delta)])
            }
        }
    }

    @Test func invalidGeometryOrValueCannotOpenATransaction() {
        let controller = QuickIncrementController()
        controller.overlayBounds = bounds

        #expect(controller.begin(
            fieldFrame: .zero,
            options: QuickIncrementController.repsOptions(),
            baseValue: 10,
            applyValue: { _ in }
        ) == nil)
        #expect(controller.begin(
            fieldFrame: field,
            options: QuickIncrementController.repsOptions(),
            baseValue: .nan,
            applyValue: { _ in }
        ) == nil)
        #expect(!controller.isActive)
    }

    private func configuredController() -> QuickIncrementController {
        let controller = QuickIncrementController()
        controller.overlayBounds = bounds
        return controller
    }

    private func begin(
        _ controller: QuickIncrementController,
        field: CGRect? = nil,
        options: [QuickIncrementController.Option],
        base: Double,
        apply: @escaping (Double) -> Void = { _ in }
    ) -> UUID {
        try! #require(controller.begin(
            fieldFrame: field ?? self.field,
            options: options,
            baseValue: base,
            applyValue: apply
        ))
    }
}
