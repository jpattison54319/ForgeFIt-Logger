import CoreGraphics
import Foundation
import Testing
@testable import ForgeFit

struct QuickIncrementControllerTests {

    @Test func repsOptionsFanFromPlusThreeToMinusThree() {
        let options = QuickIncrementController.repsOptions()
        #expect(options.map(\.delta) == [3, 2, 1, -1, -2, -3])
        #expect(options.map(\.label) == ["+3", "+2", "+1", "−1", "−2", "−3"])
    }

    @Test func weightOptionsMultiplyTheLogicalStep() {
        let lb = QuickIncrementController.weightOptions(step: 2.5, suffix: "lb")
        #expect(lb.map(\.delta) == [7.5, 5.0, 2.5, -2.5, -5.0, -7.5])
        #expect(lb.map(\.label) == ["+7.5", "+5", "+2.5", "−2.5", "−5", "−7.5"])

        let kgBarbell = QuickIncrementController.weightOptions(step: 2.5, suffix: "kg")
        #expect(kgBarbell.first?.delta == 7.5)

        let kgSmall = QuickIncrementController.weightOptions(step: 1.25, suffix: "kg")
        #expect(kgSmall.map(\.delta) == [3.75, 2.5, 1.25, -1.25, -2.5, -3.75])
    }

    @Test func revealStagesPairEqualDistancesAndBudOutward() {
        let count = QuickIncrementController.repsOptions().count
        let stages = (0..<count).map {
            QuickIncrementController.revealStage(for: $0, count: count)
        }
        let parents = (0..<count).map {
            QuickIncrementController.revealParentIndex(for: $0, count: count)
        }

        // Stored top-to-bottom: +3, +2, +1, −1, −2, −3.
        #expect(stages == [2, 1, 0, 0, 1, 2])
        #expect(parents == [1, 2, nil, nil, 3, 4])
    }

    @Test func layoutStacksPositivesAboveAndNegativesBelowTheField() {
        let controller = QuickIncrementController()
        controller.overlayBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        controller.begin(
            fieldFrame: CGRect(x: 150, y: 400, width: 60, height: 32),
            options: QuickIncrementController.repsOptions(),
            apply: { _ in }
        )

        let slots = try! #require(controller.layout())
        #expect(slots.count == 6)
        // First three above the field (higher = smaller y), last three below.
        #expect(slots[0].rect.maxY <= slots[1].rect.minY + 0.001)
        #expect(slots[2].rect.maxY <= 400)
        #expect(slots[3].rect.minY >= 432)
        #expect(slots[5].rect.minY > slots[4].rect.minY)
        // +1 (index 2) hugs the field; +3 (index 0) is furthest away.
        #expect(slots[2].rect.midY > slots[0].rect.midY)
    }

    @Test func layoutSlidesInsideBoundsNearTheTopEdge() {
        let controller = QuickIncrementController()
        controller.overlayBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        controller.begin(
            fieldFrame: CGRect(x: 150, y: 20, width: 60, height: 32),   // near top
            options: QuickIncrementController.repsOptions(),
            apply: { _ in }
        )

        let slots = try! #require(controller.layout())
        #expect(slots.allSatisfy { $0.rect.minY >= controller.overlayBounds.minY })
        #expect(slots.allSatisfy { $0.rect.maxY <= controller.overlayBounds.maxY })
    }

    @Test func hoverPicksTheBandUnderTheFingerAndFinishApplies() {
        let controller = QuickIncrementController()
        controller.overlayBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        var applied: Double?
        controller.begin(
            fieldFrame: CGRect(x: 150, y: 400, width: 60, height: 32),
            options: QuickIncrementController.repsOptions(),
            apply: { applied = $0 }
        )
        let slots = try! #require(controller.layout())

        // Hover the "+1" band (closest above the field, index 2).
        controller.updateHover(at: CGPoint(x: slots[2].rect.midX, y: slots[2].rect.midY))
        #expect(controller.fan?.hoveredIndex == 2)

        // Horizontal slop: well off to the side of the band still counts.
        controller.updateHover(at: CGPoint(x: slots[2].rect.maxX + 30, y: slots[2].rect.midY))
        #expect(controller.fan?.hoveredIndex == 2)

        controller.finish()
        #expect(applied == 1)
        #expect(!controller.isActive)
    }

    @Test func releasingOnTheFieldOrOutsideAppliesNothing() {
        let controller = QuickIncrementController()
        controller.overlayBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        var applied: Double?
        controller.begin(
            fieldFrame: CGRect(x: 150, y: 400, width: 60, height: 32),
            options: QuickIncrementController.repsOptions(),
            apply: { applied = $0 }
        )

        // On the field itself: the neutral cancel zone.
        controller.updateHover(at: CGPoint(x: 180, y: 416))
        #expect(controller.fan?.hoveredIndex == nil)
        controller.finish()
        #expect(applied == nil)
    }

    @Test func cancellationClearsTheFanAndTheNextInteractionStillApplies() {
        let controller = QuickIncrementController()
        controller.overlayBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        var applied: [Double] = []
        let field = CGRect(x: 150, y: 400, width: 60, height: 32)

        controller.begin(
            fieldFrame: field,
            options: QuickIncrementController.repsOptions(),
            apply: { applied.append($0) }
        )
        controller.cancel()
        #expect(!controller.isActive)
        #expect(applied.isEmpty)

        controller.begin(
            fieldFrame: field,
            options: QuickIncrementController.repsOptions(),
            apply: { applied.append($0) }
        )
        let slots = try! #require(controller.layout())
        controller.updateHover(at: CGPoint(x: slots[2].rect.midX, y: slots[2].rect.midY))
        controller.finish()

        #expect(applied == [1])
        #expect(!controller.isActive)
    }
}
