import Testing
@testable import ForgeCore

/// Golden vectors for seed-time muscle refinement — names taken from the
/// bundled exercise library, including the ones that trip naive rules.
struct MuscleRefinementTests {
    private func primary(_ name: String, _ muscles: [String] = ["shoulders"]) -> [String] {
        MuscleRefinement.refine(name: name, primaryMuscles: muscles, secondaryMuscles: []).primary
    }

    // MARK: Shoulders

    @Test func pressingRefinesToFrontDelts() {
        #expect(primary("Barbell Shoulder Press") == ["front delts"])
        #expect(primary("Standing Military Press") == ["front delts"])
        #expect(primary("Arnold Dumbbell Press") == ["front delts"])
        #expect(primary("Push Press - Behind the Neck") == ["front delts"])
        #expect(primary("Handstand Push-Ups") == ["front delts"])
        #expect(primary("Front Plate Raise") == ["front delts"])
        #expect(primary("Standing Dumbbell Straight-Arm Front Delt Raise Above Head") == ["front delts"])
    }

    @Test func lateralWorkRefinesToSideDelts() {
        #expect(primary("Side Lateral Raise") == ["side delts"])
        #expect(primary("Cable Seated Lateral Raise") == ["side delts"])
        #expect(primary("Upright Barbell Row") == ["side delts"])
        #expect(primary("Smith Machine One-Arm Upright Row") == ["side delts"])
        #expect(primary("Dumbbell Scaption") == ["side delts"])
    }

    @Test func rearWorkRefinesToRearDelts() {
        #expect(primary("Reverse Flyes") == ["rear delts"])
        #expect(primary("Reverse Machine Flyes") == ["rear delts"])
        #expect(primary("Face Pull") == ["rear delts"])
        #expect(primary("Band Pull Apart") == ["rear delts"])
        #expect(primary("Cable Rope Rear-Delt Rows") == ["rear delts"])
    }

    /// "Bent over ... side lateral" is rear-delt work — the bent-over check
    /// must beat the "side lateral" keyword.
    @Test func bentOverLateralIsRearNotSide() {
        #expect(primary("Bent Over Low-Pulley Side Lateral") == ["rear delts"])
        #expect(primary("Dumbbell Lying Rear Lateral Raise") == ["rear delts"])
    }

    /// Cuban and anti-gravity presses are rotator/rear work wearing a press
    /// name; ambiguous compounds keep the honest parent tag.
    @Test func ambiguousShoulderWorkKeepsParent() {
        #expect(primary("Cuban Press") == ["shoulders"])
        #expect(primary("Anti-Gravity Press") == ["shoulders"])
        #expect(primary("Clean and Jerk") == ["shoulders"])
        #expect(primary("Kettlebell Turkish Get-Up (Lunge style)") == ["shoulders"])
        #expect(primary("Shoulder Stretch") == ["shoulders"])
    }

    // MARK: Chest

    @Test func inclineDeclineAndDipsRefineChest() {
        #expect(primary("Incline Dumbbell Press", ["chest"]) == ["upper chest"])
        #expect(primary("Smith Machine Incline Bench Press", ["chest"]) == ["upper chest"])
        #expect(primary("Decline Barbell Bench Press", ["chest"]) == ["lower chest"])
        #expect(primary("Dips - Chest Version", ["chest"]) == ["lower chest"])
    }

    /// Push-up geometry is inverted vs a bench: hands elevated ("incline")
    /// hits lower chest, feet elevated ("decline") hits upper chest.
    @Test func pushUpInclineDeclineIsInverted() {
        #expect(primary("Incline Push-Up", ["chest"]) == ["lower chest"])
        #expect(primary("Decline Push-Up", ["chest"]) == ["upper chest"])
        #expect(primary("Push-Ups With Feet Elevated", ["chest"]) == ["upper chest"])
        #expect(primary("Pushups", ["chest"]) == ["chest"])
    }

    @Test func flatPressingKeepsParentChest() {
        #expect(primary("Barbell Bench Press - Medium Grip", ["chest"]) == ["chest"])
        #expect(primary("Dumbbell Flyes", ["chest"]) == ["chest"])
        #expect(primary("Cable Crossover", ["chest"]) == ["chest"])
    }

    // MARK: Secondary shoulders

    @Test func secondaryShouldersFollowsMovementContext() {
        // Pressing loads front delts...
        let bench = MuscleRefinement.refine(
            name: "Barbell Bench Press - Medium Grip",
            primaryMuscles: ["chest"], secondaryMuscles: ["shoulders", "triceps"])
        #expect(bench.secondary == ["front delts", "triceps"])

        // ...pulling loads rear delts...
        let row = MuscleRefinement.refine(
            name: "Bent Over Barbell Row",
            primaryMuscles: ["middle back"], secondaryMuscles: ["shoulders", "biceps", "lats"])
        #expect(row.secondary == ["rear delts", "biceps", "lats"])

        // ...pullovers and throws are not "pulls" ("overhead thROW" must not
        // word-match "row")...
        let pullover = MuscleRefinement.refine(
            name: "Bent-Arm Barbell Pullover",
            primaryMuscles: ["lats"], secondaryMuscles: ["shoulders"])
        #expect(pullover.secondary == ["shoulders"])
        let throwEx = MuscleRefinement.refine(
            name: "Catch and Overhead Throw",
            primaryMuscles: ["lats"], secondaryMuscles: ["shoulders"])
        #expect(throwEx.secondary == ["shoulders"])

        // ...and ambiguous compounds keep the parent.
        let clean = MuscleRefinement.refine(
            name: "Clean Shrug",
            primaryMuscles: ["traps"], secondaryMuscles: ["shoulders", "forearms"])
        #expect(clean.secondary == ["shoulders", "forearms"])
    }

    /// Already-granular tags pass through untouched, and refinement never
    /// creates duplicate buckets.
    @Test func granularTagsPassThroughAndDedupe() {
        let granular = MuscleRefinement.refine(
            name: "Chest Supported T-Bar Row",
            primaryMuscles: ["lats", "mid_back"], secondaryMuscles: ["rear_delts", "biceps"])
        #expect(granular.primary == ["lats", "mid_back"])
        #expect(granular.secondary == ["rear_delts", "biceps"])

        let dupe = MuscleRefinement.refine(
            name: "Face Pull",
            primaryMuscles: ["shoulders", "rear delts"], secondaryMuscles: [])
        #expect(dupe.primary == ["rear delts"])
    }
}
