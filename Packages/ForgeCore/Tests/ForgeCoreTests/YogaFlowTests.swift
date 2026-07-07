import Foundation
import Testing
@testable import ForgeCore

struct YogaFlowTests {

    private func step(
        _ name: String,
        hold: Int = 30,
        side: YogaFlowPlan.Side? = nil
    ) -> YogaFlowPlan.PoseStep {
        YogaFlowPlan.PoseStep(poseID: UUID(), poseSlug: nil, name: name, holdSeconds: hold, side: side)
    }

    @Test func totalSecondsDoublesBothSidesSteps() {
        let plan = YogaFlowPlan(style: .hatha, steps: [
            step("Mountain", hold: 20),
            step("Pigeon", hold: 60, side: .bothSides),
            step("Child's Pose", hold: 45)
        ])
        #expect(plan.totalSeconds == 20 + 120 + 45)
        #expect(plan.expandedStepCount == 4)
        #expect(plan.hasSteps)
    }

    @Test func structureSummaryCountsPosesNotExpandedHolds() {
        let plan = YogaFlowPlan(style: .yin, steps: [
            step("Pigeon", hold: 120, side: .bothSides),
            step("Butterfly", hold: 180)
        ])
        #expect(plan.structureSummary == "2 poses · 7min")
    }

    @Test func jsonRoundTripPreservesEverything() throws {
        let original = YogaFlowPlan(style: .vinyasa, steps: [
            YogaFlowPlan.PoseStep(
                poseID: UUID(),
                poseSlug: "warrior-ii",
                name: "Warrior II",
                holdSeconds: 40,
                side: .bothSides,
                transitionCue: "Step your right foot forward"
            ),
            step("Downward-Facing Dog", hold: 30)
        ])
        let json = try #require(original.encodedJSON())
        let decoded = try #require(YogaFlowPlan.decode(from: json))
        #expect(decoded == original)
        #expect(decoded.style == .vinyasa)
    }

    @Test func decodeToleratesUnknownStyleRaw() throws {
        // Forward compatibility: a future style raw decodes and falls back.
        let plan = YogaFlowPlan(styleRaw: "aerial", steps: [step("Mountain")])
        let json = try #require(plan.encodedJSON())
        let decoded = try #require(YogaFlowPlan.decode(from: json))
        #expect(decoded.style == .hatha)
        #expect(decoded.styleRaw == "aerial")
    }

    @Test func decodeReturnsNilForGarbage() {
        #expect(YogaFlowPlan.decode(from: nil) == nil)
        #expect(YogaFlowPlan.decode(from: "") == nil)
        #expect(YogaFlowPlan.decode(from: "not json") == nil)
    }

    @Test func restorativeClassification() {
        #expect(YogaStyle.yin.isRestorative)
        #expect(YogaStyle.restorative.isRestorative)
        #expect(YogaStyle.gentle.isRestorative)
        #expect(!YogaStyle.vinyasa.isRestorative)
        #expect(!YogaStyle.power.isRestorative)
        #expect(!YogaStyle.hatha.isRestorative)
    }
}
