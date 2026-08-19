enum MyoRepSetFlow {
    static func hasStarted(
        side1ActivationReps: Int?,
        side1MiniReps: [Int],
        side2ActivationReps: Int?,
        side2MiniReps: [Int]
    ) -> Bool {
        side1ActivationReps != nil
            || !side1MiniReps.isEmpty
            || side2ActivationReps != nil
            || !side2MiniReps.isEmpty
    }

    static func startingSide(
        isUnilateral: Bool,
        side1ActivationReps: Int?,
        side2ActivationReps: Int?,
        preferredSide: Int = 1
    ) -> Int {
        guard isUnilateral else { return 1 }
        if side1ActivationReps == nil { return 1 }
        if side2ActivationReps == nil { return 2 }
        return preferredSide == 2 ? 2 : 1
    }

    static func canFinish(
        isUnilateral: Bool,
        side1ActivationReps: Int?,
        side2ActivationReps: Int?
    ) -> Bool {
        guard side1ActivationReps != nil else { return false }
        return !isUnilateral || side2ActivationReps != nil
    }

    static func nextMiniReps(
        logged: [Int],
        mirrored: [Int],
        previous: [Int]
    ) -> Int {
        logged.last ?? mirrored.first ?? previous.first ?? 1
    }

    static func totalReps(activationReps: Int?, miniReps: [Int]) -> Int {
        (activationReps ?? 0) + miniReps.reduce(0, +)
    }
}
