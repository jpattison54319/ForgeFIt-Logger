import Foundation
import Testing
@testable import ForgeCore

/// The interval plan's versioning contract: v1 JSON keeps decoding, v2
/// fields round-trip, and the repeat-shape detector routes plans to the
/// right editor without silently flattening custom structures.
struct IntervalPlanEvolutionTests {

    /// A plan persisted by a pre-goals build — exactly the keys v1 wrote.
    private let v1JSON = """
    {"steps":[{"id":"11111111-1111-1111-1111-111111111111","kind":"warmup","seconds":300,"label":"Warm-up"},\
    {"id":"22222222-2222-2222-2222-222222222222","kind":"work","seconds":60,"label":"Work 1/2","hrZone":4},\
    {"id":"33333333-3333-3333-3333-333333333333","kind":"recover","seconds":90,"label":"Recover 1/1"},\
    {"id":"44444444-4444-4444-4444-444444444444","kind":"work","seconds":60,"label":"Work 2/2","hrZone":4},\
    {"id":"55555555-5555-5555-5555-555555555555","kind":"cooldown","seconds":300,"label":"Cool-down"}],\
    "hrZoneTarget":2}
    """

    @Test func v1PlanJSONStillDecodesWithNilNewFields() throws {
        let plan = try #require(IntervalPlan.decode(from: v1JSON))
        #expect(plan.steps.count == 5)
        #expect(plan.hrZoneTarget == 2)
        #expect(plan.goal == nil)
        #expect(plan.target == nil)
        #expect(plan.steps.allSatisfy { $0.distanceMeters == nil && $0.target == nil })
        #expect(plan.totalSeconds == 810)
        #expect(plan.matchesRepeatBuilderShape)
    }

    @Test func plansWithoutNewFeaturesEncodeCleanV1CompatibleJSON() throws {
        let plan = IntervalPlan.build(
            warmupSeconds: 300, repeats: 2, workSeconds: 60, recoverSeconds: 90, cooldownSeconds: 300,
            hrZoneTarget: 2, workZone: 4
        )
        let json = try #require(plan.encodedJSON())
        // Nil optionals are omitted, so older builds decode this untouched.
        #expect(!json.contains("\"goal\""))
        #expect(!json.contains("\"target\""))
        #expect(!json.contains("distanceMeters"))
    }

    @Test func distanceStepsAndTargetsRoundTrip() throws {
        let target = IntervalPlan.Target(metric: .pace, low: 290, high: 310)
        let plan = IntervalPlan(
            steps: [
                .init(kind: .work, seconds: 0, label: "Work 1/2", distanceMeters: 400, target: target),
                .init(kind: .recover, seconds: 60, label: "Recover 1/1"),
                .init(kind: .work, seconds: 0, label: "Work 2/2", distanceMeters: 400, target: target),
            ],
            goal: nil,
            target: nil
        )
        let decoded = try #require(IntervalPlan.decode(from: plan.encodedJSON()))
        #expect(decoded == plan)
        #expect(decoded.hasDistanceSteps)
        #expect(decoded.totalDistanceMeters == 800)
        #expect(decoded.totalSeconds == 60)   // distance steps carry no knowable duration
        #expect(!decoded.matchesRepeatBuilderShape)
    }

    @Test func sessionGoalAndPlanTargetRoundTripAndGateMeaningfulness() throws {
        let empty = IntervalPlan(steps: [])
        #expect(!empty.isMeaningful)

        let goalOnly = IntervalPlan(steps: [], goal: .init(kind: .distance, value: 5000))
        let decoded = try #require(IntervalPlan.decode(from: goalOnly.encodedJSON()))
        #expect(decoded.goal?.kind == .distance)
        #expect(decoded.isMeaningful)

        let bandOnly = IntervalPlan(steps: [], target: .init(metric: .pace, low: 320, high: 340))
        #expect(bandOnly.isMeaningful)

        let hollowTarget = IntervalPlan(steps: [], target: .init(metric: .power))
        #expect(!hollowTarget.isMeaningful)   // a band with no bounds is not a goal

        let hollowGoal = IntervalPlan(steps: [], goal: .init(kind: .calories, value: 0))
        #expect(!hollowGoal.isMeaningful)
    }

    @Test func builderEmitsDistanceWorkStepsWhenMetersProvided() {
        let plan = IntervalPlan.build(
            warmupSeconds: 300, repeats: 3, workSeconds: 60, recoverSeconds: 90, cooldownSeconds: 120,
            workDistanceMeters: 400
        )
        let works = plan.steps.filter { $0.kind == .work }
        #expect(works.count == 3)
        #expect(works.allSatisfy { $0.isDistanceBased && $0.distanceMeters == 400 && $0.seconds == 0 })
        // Recovers stay timed; warmup/cooldown always timed.
        #expect(plan.steps.filter { $0.kind == .recover }.allSatisfy { !$0.isDistanceBased && $0.seconds == 90 })
        #expect(plan.steps.first?.kind == .warmup)
        #expect(plan.steps.last?.kind == .cooldown)
    }

    @Test func repeatShapeDetectorAcceptsEveryBuilderOutput() {
        let variants: [IntervalPlan] = [
            .build(warmupSeconds: 300, repeats: 6, workSeconds: 60, recoverSeconds: 90, cooldownSeconds: 300),
            .build(warmupSeconds: 0, repeats: 1, workSeconds: 45, recoverSeconds: 0, cooldownSeconds: 0),
            .build(warmupSeconds: 600, repeats: 4, workSeconds: 240, recoverSeconds: 180, cooldownSeconds: 300, workZone: 4, recoverZone: 3),
            .build(warmupSeconds: 120, repeats: 0, workSeconds: 0, recoverSeconds: 0, cooldownSeconds: 60),
            .build(warmupSeconds: 300, repeats: 8, workSeconds: 20, recoverSeconds: 0, cooldownSeconds: 300, workZone: 5),
        ]
        for plan in variants {
            #expect(plan.matchesRepeatBuilderShape, "builder output should stay stepper-editable: \(plan.steps.map(\.label))")
        }
    }

    @Test func repeatShapeDetectorRejectsCustomStructures() {
        // Pyramid: non-uniform work lengths.
        let pyramid = IntervalPlan(steps: [
            .init(kind: .work, seconds: 60, label: "1min"),
            .init(kind: .recover, seconds: 60, label: "Easy"),
            .init(kind: .work, seconds: 120, label: "2min"),
        ])
        #expect(!pyramid.matchesRepeatBuilderShape)

        // Custom order: a recover before any work.
        let recoverFirst = IntervalPlan(steps: [
            .init(kind: .recover, seconds: 60, label: "Ease in"),
            .init(kind: .work, seconds: 60, label: "Go"),
        ])
        #expect(!recoverFirst.matchesRepeatBuilderShape)

        // Mid-plan warmup breaks the builder shape.
        let sandwich = IntervalPlan(steps: [
            .init(kind: .work, seconds: 60, label: "Go"),
            .init(kind: .warmup, seconds: 120, label: "Re-warm"),
            .init(kind: .work, seconds: 60, label: "Go again"),
        ])
        #expect(!sandwich.matchesRepeatBuilderShape)

        // A step target forces the custom editor even in a repeat shape.
        let targeted = IntervalPlan(steps: [
            .init(kind: .work, seconds: 60, label: "Go", target: .init(metric: .cadence, low: 22, high: 26)),
        ])
        #expect(!targeted.matchesRepeatBuilderShape)
    }

    @Test func targetClassifiesAgainstOpenAndClosedBands() {
        let band = IntervalPlan.Target(metric: .pace, low: 290, high: 310)
        #expect(band.classify(280) == .below)
        #expect(band.classify(300) == .within)
        #expect(band.classify(320) == .above)

        let floorOnly = IntervalPlan.Target(metric: .power, low: 180)
        #expect(floorOnly.classify(150) == .below)
        #expect(floorOnly.classify(500) == .within)   // no ceiling

        let ceilingOnly = IntervalPlan.Target(metric: .cadence, high: 90)
        #expect(ceilingOnly.classify(50) == .within)  // no floor
        #expect(ceilingOnly.classify(95) == .above)
    }

    @Test func sessionGoalFractionIsUncappedAndZeroSafe() {
        let goal = IntervalPlan.SessionGoal(kind: .distance, value: 5000)
        #expect(goal.fraction(current: 2500) == 0.5)
        #expect(goal.fraction(current: 6000) == 1.2)
        #expect(IntervalPlan.SessionGoal(kind: .duration, value: 0).fraction(current: 100) == 0)
    }

    @Test func structureSummaryCoversGoalsDistanceRepsAndLegacyShapes() {
        let goalPlan = IntervalPlan(steps: [], hrZoneTarget: 2, goal: .init(kind: .distance, value: 5000))
        #expect(goalPlan.structureSummary == "5 km goal · Zone 2 lock")

        let caloriePlan = IntervalPlan(steps: [], goal: .init(kind: .calories, value: 400))
        #expect(caloriePlan.structureSummary == "400 kcal goal")

        let distanceReps = IntervalPlan.build(
            warmupSeconds: 0, repeats: 6, workSeconds: 0, recoverSeconds: 60, cooldownSeconds: 0,
            workDistanceMeters: 400
        )
        #expect(distanceReps.structureSummary == "6 × 400 m / 1min · 2.4 km of reps")

        let classic = IntervalPlan.build(
            warmupSeconds: 300, repeats: 6, workSeconds: 60, recoverSeconds: 90, cooldownSeconds: 300)
        #expect(classic.structureSummary == "6 × 1min / 1min 30s · 23min 30s total")
    }
}
