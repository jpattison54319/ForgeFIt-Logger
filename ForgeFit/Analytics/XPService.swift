import ForgeCore
import ForgeData
import Foundation
import SwiftData

enum XPService {
    struct Award: Equatable {
        var amount: Int
        var base: Int
        var duration: Int
        var strength: Int
        var cardioDuration: Int
        var cardioDistance: Int
        var yogaDuration: Int
        var eligible: Bool

        init(
            amount: Int,
            base: Int,
            duration: Int,
            strength: Int,
            cardioDuration: Int,
            cardioDistance: Int,
            yogaDuration: Int = 0,
            eligible: Bool
        ) {
            self.amount = amount
            self.base = base
            self.duration = duration
            self.strength = strength
            self.cardioDuration = cardioDuration
            self.cardioDistance = cardioDistance
            self.yogaDuration = yogaDuration
            self.eligible = eligible
        }

        var components: [String: Int] {
            [
                "base": base,
                "duration": duration,
                "strength": strength,
                "cardioDuration": cardioDuration,
                "cardioDistance": cardioDistance,
                "yogaDuration": yogaDuration
            ]
        }
    }

    struct Progress: Equatable {
        var totalXP: Int
        var level: Int
        var currentLevelXP: Int
        var nextLevelXP: Int

        var xpIntoLevel: Int { totalXP - currentLevelXP }
        var xpNeededForNextLevel: Int { max(1, nextLevelXP - currentLevelXP) }
        var remainingXP: Int { max(0, nextLevelXP - totalXP) }
        var fraction: Double {
            min(1, max(0, Double(xpIntoLevel) / Double(xpNeededForNextLevel)))
        }
    }

    static let perWorkoutCap = 250

    static func previewAward(for workout: WorkoutModel, now: Date = Date(), requireEnded: Bool = true) -> Award {
        guard workout.deletedAt == nil, workout.xpAwardedAt == nil, !workout.isImportedHistory else {
            return Award(amount: 0, base: 0, duration: 0, strength: 0, cardioDuration: 0, cardioDistance: 0, eligible: false)
        }

        let completedWorkingSets = workout.exercises
            .flatMap(\.sets)
            .filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
            .count
        // Yoga rides the cardio session model but earns its own component,
        // so a yin hold never inflates "cardio" XP.
        let cardioSeconds = workout.cardioSessions
            .filter { !$0.isYogaSession }
            .reduce(0) { total, session in total + effectiveCardioSeconds(session, now: now) }
        let yogaSeconds = workout.cardioSessions
            .filter(\.isYogaSession)
            .reduce(0) { total, session in total + effectiveCardioSeconds(session, now: now) }
        // Active practices earn at the cardio rate; restorative styles at
        // half — an honest signal, not gamified savasana.
        let weightedYogaMinutes = workout.cardioSessions
            .filter(\.isYogaSession)
            .reduce(0.0) { total, session in
                let minutes = Double(effectiveCardioSeconds(session, now: now)) / 60
                return total + minutes * (session.resolvedYogaStyle.isRestorative ? 0.6 : 1.2)
            }
        let distanceMeters = workout.cardioSessions.compactMap(\.distanceMeters).reduce(0, +)
        let workoutSeconds = effectiveWorkoutSeconds(workout, now: now)
        let hasEnded = workout.endedAt != nil || !requireEnded
        let eligible = hasEnded && (completedWorkingSets > 0 || cardioSeconds >= 300 || yogaSeconds >= 300)

        guard eligible else {
            return Award(amount: 0, base: 0, duration: 0, strength: 0, cardioDuration: 0, cardioDistance: 0, eligible: false)
        }

        let base = 50
        let duration = min(90, Int((Double(workoutSeconds) / 60).rounded(.down)))
        let strength = min(120, completedWorkingSets * 6)
        let cardioDuration = min(100, Int((Double(cardioSeconds) / 60 * 1.2).rounded()))
        let cardioDistance = min(60, Int((distanceMeters / 1000 * 4).rounded()))
        let yogaDuration = min(100, Int(weightedYogaMinutes.rounded()))
        let total = min(perWorkoutCap, base + duration + strength + cardioDuration + cardioDistance + yogaDuration)

        return Award(
            amount: total,
            base: base,
            duration: duration,
            strength: strength,
            cardioDuration: cardioDuration,
            cardioDistance: cardioDistance,
            yogaDuration: yogaDuration,
            eligible: true
        )
    }

    @MainActor
    @discardableResult
    static func awardXPIfNeeded(for workout: WorkoutModel, in context: ModelContext, now: Date = Date()) -> Award {
        if let amount = workout.xpAwardedAmount, workout.xpAwardedAt != nil {
            return Award(amount: amount, base: 0, duration: 0, strength: 0, cardioDuration: 0, cardioDistance: 0, eligible: amount > 0)
        }

        let award = previewAward(for: workout, now: now)
        guard award.eligible, award.amount > 0 else { return award }

        let progress = progressModel(for: workout.userID, in: context, now: now)
        progress.totalXP += award.amount
        progress.level = level(forTotalXP: progress.totalXP)
        progress.updatedAt = now

        workout.xpAwardedAmount = award.amount
        workout.xpAwardedAt = now
        workout.updatedAt = now

        context.insert(WorkoutXPEventModel(
            userID: workout.userID,
            workoutID: workout.id,
            amount: award.amount,
            componentsJSON: componentsJSON(for: award),
            createdAt: now
        ))
        try? context.save()
        return award
    }

    @MainActor
    static func progress(for userID: UUID = ForgeFitDemo.userID, in context: ModelContext) -> Progress {
        let totalXP = progressModel(for: userID, in: context).totalXP
        return progress(forTotalXP: totalXP)
    }

    static func progress(forTotalXP totalXP: Int) -> Progress {
        let level = level(forTotalXP: totalXP)
        return Progress(
            totalXP: totalXP,
            level: level,
            currentLevelXP: requiredTotalXP(forLevel: level),
            nextLevelXP: requiredTotalXP(forLevel: level + 1)
        )
    }

    static func level(forTotalXP totalXP: Int) -> Int {
        var level = 1
        while totalXP >= requiredTotalXP(forLevel: level + 1) {
            level += 1
        }
        return level
    }

    static func requiredTotalXP(forLevel level: Int) -> Int {
        guard level > 1 else { return 0 }
        return Int((300 * pow(Double(level - 1), 1.65)).rounded(.up))
    }

    private static func effectiveWorkoutSeconds(_ workout: WorkoutModel, now: Date) -> Int {
        let end = workout.endedAt ?? now
        return max(0, Int(end.timeIntervalSince(workout.startedAt)))
    }

    private static func effectiveCardioSeconds(_ session: CardioSessionModel, now: Date) -> Int {
        if let seconds = session.durationSeconds, seconds > 0 { return seconds }
        guard let liveStart = session.liveStartedAt else { return 0 }
        let end = session.endedAt ?? now
        return max(0, Int(end.timeIntervalSince(liveStart)))
    }

    @MainActor
    private static func progressModel(for userID: UUID, in context: ModelContext, now: Date = Date()) -> UserProgressModel {
        let descriptor = FetchDescriptor<UserProgressModel>(
            predicate: #Predicate { $0.userID == userID && $0.deletedAt == nil }
        )
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let created = UserProgressModel(userID: userID, createdAt: now, updatedAt: now)
        context.insert(created)
        return created
    }

    private static func componentsJSON(for award: Award) -> String {
        guard let data = try? JSONEncoder().encode(award.components),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
