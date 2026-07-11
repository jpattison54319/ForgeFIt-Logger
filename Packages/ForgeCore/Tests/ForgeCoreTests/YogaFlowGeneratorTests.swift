import Foundation
import Testing
@testable import ForgeCore

struct YogaFlowGeneratorTests {

    // MARK: - Fixture catalog

    private typealias Pose = YogaFlowGenerator.PoseInput
    private typealias Category = YogaFlowGenerator.Category

    /// ~1.5 dozen fake poses spanning every category and difficulty tier so
    /// each style template has something to draw from at each difficulty.
    private static let catalog: [Pose] = [
        pose("cat-cow", .warmup, .beginner, hold: 40),
        pose("sun-salutation", .warmup, .intermediate, hold: 45),
        pose("mountain-pose", .standing, .beginner, hold: 30),
        pose("warrior-ii", .standing, .beginner, unilateral: true, hold: 40),
        pose("chair-pose", .standing, .intermediate, hold: 30),
        pose("tree-pose", .balance, .beginner, unilateral: true, hold: 30),
        pose("eagle-pose", .balance, .advanced, unilateral: true, hold: 30),
        pose("cobra", .backbend, .beginner, hold: 30),
        pose("wheel", .backbend, .advanced, hold: 25),
        pose("plank", .core, .beginner, hold: 30),
        pose("boat-pose", .core, .intermediate, hold: 30),
        pose("headstand", .inversion, .advanced, hold: 45),
        pose("seated-forward-fold", .forwardFold, .beginner, hold: 60),
        pose("supine-twist", .twist, .beginner, unilateral: true, hold: 45),
        pose("butterfly", .hipOpener, .beginner, hold: 75),
        pose("pigeon", .hipOpener, .intermediate, unilateral: true, hold: 90),
        pose("savasana", .resting, .beginner, hold: 120),
        pose("childs-pose", .resting, .beginner, hold: 45)
    ]

    private static func pose(
        _ slug: String,
        _ category: Category,
        _ difficulty: YogaFlowGenerator.Difficulty,
        unilateral: Bool = false,
        hold: Int
    ) -> Pose {
        Pose(
            slug: slug,
            poseID: UUID(),
            name: slug.split(separator: "-").map(\.capitalized).joined(separator: " "),
            category: category,
            difficulty: difficulty,
            unilateral: unilateral,
            defaultHoldSeconds: hold
        )
    }

    private static let categoryBySlug: [String: Category] = Dictionary(
        uniqueKeysWithValues: catalog.map { ($0.slug, $0.category) }
    )

    private static let advancedSlugs: Set<String> = Set(
        catalog.filter { $0.difficulty == .advanced }.map(\.slug)
    )

    private static let unilateralSlugs: Set<String> = Set(
        catalog.filter(\.unilateral).map(\.slug)
    )

    private func generate(
        style: YogaStyle,
        minutes: Int,
        difficulty: YogaFlowGenerator.Difficulty = .intermediate,
        seed: UInt64 = 42,
        poses: [Pose] = YogaFlowGeneratorTests.catalog
    ) -> YogaFlowPlan? {
        YogaFlowGenerator.generate(
            request: .init(style: style, targetMinutes: minutes, difficulty: difficulty, seed: seed),
            poses: poses
        )
    }

    private func category(of step: YogaFlowPlan.PoseStep) -> Category {
        let slug = try! #require(step.poseSlug)
        return try! #require(Self.categoryBySlug[slug])
    }

    // MARK: - Duration budget

    @Test(arguments: [10, 20, 45])
    func totalDurationWithinTenPercentOfTarget(minutes: Int) throws {
        for style in [YogaStyle.hatha, .vinyasa, .power, .yin] {
            let plan = try #require(generate(style: style, minutes: minutes))
            let target = minutes * 60
            // totalSeconds already counts bothSides steps twice.
            let deviation = abs(plan.totalSeconds - target)
            #expect(
                deviation <= target / 10,
                "\(style) \(minutes)min: total \(plan.totalSeconds)s vs target \(target)s"
            )
        }
    }

    @Test func bothSidesDoublingIsCountedInBudget() throws {
        let plan = try #require(generate(style: .hatha, minutes: 20))
        let manualTotal = plan.steps.reduce(0) {
            $0 + $1.holdSeconds * ($1.side == .bothSides ? 2 : 1)
        }
        #expect(manualTotal == plan.totalSeconds)
        #expect(plan.steps.contains { $0.side == .bothSides })
    }

    // MARK: - Resting closer

    @Test func alwaysEndsWithRestingHoldOfAtLeastSixtySeconds() throws {
        for style in YogaStyle.allCases {
            let plan = try #require(generate(style: style, minutes: 20))
            let closer = try #require(plan.steps.last)
            #expect(category(of: closer) == .resting, "\(style) must close resting")
            #expect(closer.holdSeconds >= 60, "\(style) closer was \(closer.holdSeconds)s")
        }
    }

    @Test func nilWhenNoRestingPoseAvailable() {
        let noResting = Self.catalog.filter { $0.category != .resting }
        #expect(generate(style: .hatha, minutes: 20, poses: noResting) == nil)
        // Resting poses exist but sit above the requested difficulty ceiling.
        let hardRestingOnly = noResting + [
            Self.pose("advanced-savasana", .resting, .advanced, hold: 120)
        ]
        #expect(generate(style: .hatha, minutes: 20, difficulty: .beginner, poses: hardRestingOnly) == nil)
    }

    @Test func nilWhenTargetTooShortForRestingCloser() {
        #expect(generate(style: .yin, minutes: 1) == nil)
        #expect(generate(style: .hatha, minutes: 0) == nil)
    }

    // MARK: - Difficulty ceiling

    @Test func beginnerRequestContainsNoAdvancedPose() throws {
        for style in YogaStyle.allCases {
            let plan = try #require(generate(style: style, minutes: 20, difficulty: .beginner))
            for step in plan.steps {
                let slug = try #require(step.poseSlug)
                #expect(!Self.advancedSlugs.contains(slug), "\(slug) is advanced")
            }
        }
    }

    @Test func intermediateRequestNeverExceedsIntermediate() throws {
        let plan = try #require(generate(style: .power, minutes: 30, difficulty: .intermediate))
        for step in plan.steps {
            let slug = try #require(step.poseSlug)
            #expect(!Self.advancedSlugs.contains(slug), "\(slug) exceeds requested difficulty")
        }
    }

    // MARK: - Style templates

    @Test func yinUsesOnlyYinLegalCategoriesWithLongHolds() throws {
        let plan = try #require(generate(style: .yin, minutes: 20))
        let legal: Set<Category> = [.resting, .hipOpener, .forwardFold]
        for step in plan.steps {
            #expect(legal.contains(category(of: step)), "\(step.name) illegal in yin")
            #expect(step.holdSeconds >= 120, "\(step.name) held only \(step.holdSeconds)s")
            #expect(step.holdSeconds <= 300 || step == plan.steps.last)
        }
    }

    @Test func restorativeBodyHoldsStayInNinetyToOneEightyWindow() throws {
        let plan = try #require(generate(style: .restorative, minutes: 20, difficulty: .beginner))
        for step in plan.steps.dropLast() {
            #expect((90...180).contains(step.holdSeconds), "\(step.name): \(step.holdSeconds)s")
        }
        #expect(try #require(plan.steps.last).holdSeconds >= 90)
    }

    @Test func powerIncludesCoreOrBalanceWork() throws {
        let plan = try #require(generate(style: .power, minutes: 20))
        let strengthCount = plan.steps.filter {
            let cat = category(of: $0)
            return cat == .core || cat == .balance
        }.count
        #expect(strengthCount >= 1)
    }

    // MARK: - Determinism

    @Test func sameSeedProducesIdenticalPlan() throws {
        let a = try #require(generate(style: .vinyasa, minutes: 25, seed: 99))
        let b = try #require(generate(style: .vinyasa, minutes: 25, seed: 99))
        // Full equality — including generated step ids — because the RNG also
        // drives UUID creation.
        #expect(a == b)
    }

    @Test func differentSeedProducesDifferentOrder() throws {
        let a = try #require(generate(style: .vinyasa, minutes: 25, seed: 1))
        let b = try #require(generate(style: .vinyasa, minutes: 25, seed: 2))
        #expect(a.steps.map(\.poseSlug) != b.steps.map(\.poseSlug))
    }

    // MARK: - Sides

    @Test func unilateralPosesGetBothSidesAndBilateralGetNil() throws {
        let plan = try #require(generate(style: .hatha, minutes: 20))
        let warrior = try #require(plan.steps.first { $0.poseSlug == "warrior-ii" })
        #expect(warrior.side == .bothSides)
        for step in plan.steps.dropLast() {
            let slug = try #require(step.poseSlug)
            let expected: YogaFlowPlan.Side? = Self.unilateralSlugs.contains(slug) ? .bothSides : nil
            #expect(step.side == expected, "\(slug) side mismatch")
        }
        // The resting closer is one continuous block even if the pose were
        // unilateral in the catalog.
        #expect(try #require(plan.steps.last).side == nil)
    }

    // MARK: - Arc ordering

    @Test func standingBlockComesBeforeFloorBlock() throws {
        let plan = try #require(generate(style: .hatha, minutes: 20))
        let categories = plan.steps.map { category(of: $0) }
        let firstStanding = try #require(
            categories.firstIndex { $0 == .standing || $0 == .balance }
        )
        let firstFloor = try #require(
            categories.firstIndex { $0 == .hipOpener || $0 == .forwardFold || $0 == .twist }
        )
        #expect(firstStanding < firstFloor)
        // Warm-up, when present, opens the class.
        if let firstWarmup = categories.firstIndex(of: .warmup) {
            #expect(firstWarmup == 0)
        }
    }

    // MARK: - Reuse rules

    @Test func smallCatalogReusesPosesButNeverSameSlugConsecutively() throws {
        for style in [YogaStyle.hatha, .yin] {
            let plan = try #require(generate(style: style, minutes: 45))
            let slugs = plan.steps.compactMap(\.poseSlug)
            for (previous, current) in zip(slugs, slugs.dropFirst()) {
                #expect(previous != current, "\(style): \(current) repeated consecutively")
            }
        }
        // A 45-minute class from this small catalog must reuse something —
        // duplicates are allowed, just never adjacent.
        let long = try #require(generate(style: .hatha, minutes: 45))
        let counts = Dictionary(grouping: long.steps.compactMap(\.poseSlug), by: { $0 })
        #expect(counts.values.contains { $0.count >= 2 })
    }
}
