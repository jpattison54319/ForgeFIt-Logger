import Foundation
import Testing
import ForgeCore
import ForgeData
import SwiftData
@testable import ForgeFit

/// Distance-based interval steps: the runner advances on meters covered
/// (from an injected feed — tests never sleep through real seconds), falls
/// back to manual skip when no feed flows, and records honest split
/// distances either way.
@MainActor
struct IntervalRunnerDistanceTests {

    private func makeRunner(
        plan: IntervalPlan,
        feed: @escaping () -> Double?
    ) throws -> (runner: IntervalRunner, session: CardioSessionModel, container: ModelContainer) {
        let (container, context) = try TestStore.make()
        let session = CardioSessionModel(userID: ForgeFitDemo.userID, modality: "run", liveStartedAt: Date())
        context.insert(session)
        try context.save()
        let runner = try #require(IntervalRunner(planJSON: plan.encodedJSON(), session: session, context: context))
        runner.liveDistanceMeters = feed
        return (runner, session, container)
    }

    @Test func distanceStepAdvancesWhenTheFeedCrossesTheTarget() throws {
        let plan = IntervalPlan(steps: [
            .init(kind: .work, seconds: 0, label: "Work 1/2", distanceMeters: 400),
            .init(kind: .recover, seconds: 60, label: "Recover 1/1"),
            .init(kind: .work, seconds: 0, label: "Work 2/2", distanceMeters: 400),
        ])
        var meters: Double? = 1000   // cumulative session distance at step start
        let (runner, session, container) = try makeRunner(plan: plan) { meters }
        runner.start()

        #expect(runner.currentStep?.label == "Work 1/2")
        #expect(runner.stepEndsAt == .distantFuture)   // a place, not a time

        meters = 1200
        runner.pollTick()
        #expect(runner.currentIndex == 0)              // 200 of 400 m — still going
        #expect(runner.distanceProgress?.covered == 200)

        meters = 1405
        runner.pollTick()
        #expect(runner.currentStep?.label == "Recover 1/1")   // crossed → advanced

        let workSplit = try #require(session.splits.first { $0.label == "Work 1/2" })
        #expect(abs(workSplit.distanceMeters - 405) < 0.001)  // honest covered meters
        runner.stop()
        _ = container   // keep models alive to the end (see TestStore.make)
    }

    @Test func distanceStepWithoutAFeedWaitsForManualSkip() throws {
        let plan = IntervalPlan(steps: [
            .init(kind: .work, seconds: 0, label: "Work", distanceMeters: 500),
            .init(kind: .cooldown, seconds: 60, label: "Cool-down"),
        ])
        let (runner, session, container) = try makeRunner(plan: plan) { nil }
        runner.start()

        runner.pollTick()
        runner.pollTick()
        #expect(runner.currentStep?.label == "Work")   // no feed → no auto-advance
        #expect(runner.distanceProgress == nil)        // the strip shows the no-feed hint

        runner.skip()
        #expect(runner.currentStep?.label == "Cool-down")
        #expect(session.splits.count == 1)             // skip still writes the split
        runner.stop()
        _ = container
    }

    @Test func stepTargetOutranksPlanTargetAndHollowBandsDoNotCount() throws {
        let stepBand = IntervalPlan.Target(metric: .cadence, low: 22, high: 26)
        let planBand = IntervalPlan.Target(metric: .pace, low: 290, high: 310)
        let plan = IntervalPlan(
            steps: [
                .init(kind: .work, seconds: 60, label: "Work", target: stepBand),
                .init(kind: .recover, seconds: 60, label: "Recover"),
            ],
            target: planBand
        )
        let (runner, _, container) = try makeRunner(plan: plan) { nil }
        runner.start()

        #expect(runner.currentTarget == stepBand)      // step wins while active

        runner.skip()
        #expect(runner.currentTarget == planBand)      // plan band covers plain steps
        runner.stop()
        _ = container
    }

    @Test func feedAppearingMidStepAnchorsToItsFirstReading() throws {
        let plan = IntervalPlan(steps: [
            .init(kind: .work, seconds: 0, label: "Work", distanceMeters: 300),
        ])
        var meters: Double?
        let (runner, _, container) = try makeRunner(plan: plan) { meters }
        runner.start()

        runner.pollTick()                              // still no feed
        #expect(runner.distanceProgress == nil)

        meters = 5000                                  // watch wakes up mid-step
        runner.pollTick()
        #expect(runner.distanceProgress?.covered == 0) // anchored, not credited 5 km

        meters = 5299
        runner.pollTick()
        #expect(runner.currentStep != nil)             // 299 < 300

        meters = 5301
        runner.pollTick()
        #expect(runner.isFinished)                     // crossed the line
        runner.stop()
        _ = container
    }
}
