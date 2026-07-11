import Foundation
import Testing
@testable import ForgeCore

struct ProgramMatcherTests {

    private func profile(
        focus: ProgramFocus = .strength,
        goal: String = "muscle gain",
        experience: String = "intermediate",
        sessionsPerWeek: Int = 4,
        sessionMinutes: Int = 60,
        equipment: Set<String> = ["barbell", "dumbbell", "bench"],
        preferredCardio: String? = nil
    ) -> CoachingProfileInput {
        CoachingProfileInput(
            focus: focus, goal: goal, experience: experience,
            sessionsPerWeek: sessionsPerWeek, sessionMinutes: sessionMinutes,
            equipment: equipment, preferredCardio: preferredCardio
        )
    }

    private func candidate(
        id: String, focus: ProgramFocus = .strength, goal: String = "muscle gain",
        level: String = "intermediate", daysPerWeek: Int = 4, weeks: Int = 6,
        equipment: [String] = ["barbell"]
    ) -> ProgramCandidate {
        ProgramCandidate(
            id: id, name: id, focus: focus, goal: goal, level: level,
            daysPerWeek: daysPerWeek, weeks: weeks, equipment: equipment
        )
    }

    @Test func exactMatchWhenEverythingAligns() {
        let upperLower = candidate(id: "upper-lower", daysPerWeek: 4)
        let result = ProgramMatcher.match(profile: profile(), candidates: [upperLower])
        guard case .exact(let match) = result else {
            Issue.record("expected exact match, got \(result)")
            return
        }
        #expect(match.id == "upper-lower")
    }

    @Test func fallbackPrefersHighestFrequencyAtOrBelowRequested() {
        let threeDay = candidate(id: "three-day", daysPerWeek: 3)
        let twoDay = candidate(id: "two-day", daysPerWeek: 2)
        // Requesting 5x/week with no exact 5-day program available.
        let result = ProgramMatcher.match(profile: profile(sessionsPerWeek: 5), candidates: [threeDay, twoDay])
        guard case .fallback(let match, let reasons) = result else {
            Issue.record("expected fallback, got \(result)")
            return
        }
        #expect(match.id == "three-day")
        #expect(reasons.contains { $0.contains("3x/week") })
    }

    @Test func neverRecommendsHigherFrequencyThanRequested() {
        // Every candidate needs MORE days than the lifter has — nothing safe
        // to offer, even though they'd otherwise match perfectly.
        let fiveDay = candidate(id: "five-day", daysPerWeek: 5)
        let result = ProgramMatcher.match(profile: profile(sessionsPerWeek: 3), candidates: [fiveDay])
        guard case .none(let reason) = result else {
            Issue.record("expected none, got \(result)")
            return
        }
        #expect(reason.contains("5x/week"))
        #expect(reason.contains("3x/week"))
    }

    @Test func equipmentMustBeSubsetOfUsersEquipment() {
        let cableMachine = candidate(id: "cable-program", equipment: ["cable machine"])
        let bodyweight = candidate(id: "bodyweight-program", equipment: [])
        let result = ProgramMatcher.match(
            profile: profile(equipment: ["dumbbell"]),
            candidates: [cableMachine, bodyweight]
        )
        guard case .exact(let match) = result else {
            Issue.record("expected exact match on the bodyweight program, got \(result)")
            return
        }
        // Bodyweight-only equipment (empty set) is always a subset.
        #expect(match.id == "bodyweight-program")
    }

    @Test func focusCompatibilityTable() {
        #expect(ProgramMatcher.focusCompatible(requested: .strength, candidate: .strength))
        #expect(ProgramMatcher.focusCompatible(requested: .strength, candidate: .mixed))
        #expect(ProgramMatcher.focusCompatible(requested: .mixed, candidate: .cardio))
        #expect(ProgramMatcher.focusCompatible(requested: .mixed, candidate: .mixed))
        #expect(!ProgramMatcher.focusCompatible(requested: .strength, candidate: .cardio))
        #expect(!ProgramMatcher.focusCompatible(requested: .cardio, candidate: .yoga))
        #expect(!ProgramMatcher.focusCompatible(requested: .yoga, candidate: .strength))
    }

    @Test func cardioRequestNeverResolvesToStrengthProgram() {
        let strengthOnly = candidate(id: "strength-only", focus: .strength)
        let result = ProgramMatcher.match(profile: profile(focus: .cardio), candidates: [strengthOnly])
        guard case .none = result else {
            Issue.record("expected none — no cardio-compatible candidate exists, got \(result)")
            return
        }
    }

    @Test func beginnerNeverGetsIntermediateProgramAsExact() {
        let intermediateProgram = candidate(id: "intermediate-program", level: "intermediate")
        let result = ProgramMatcher.match(
            profile: profile(experience: "beginner"),
            candidates: [intermediateProgram]
        )
        guard case .fallback(let match, let reasons) = result else {
            Issue.record("expected fallback (level mismatch), got \(result)")
            return
        }
        #expect(match.id == "intermediate-program")
        #expect(reasons.contains { $0.lowercased().contains("intermediate") })
    }

    @Test func advancedLifterGetsIntermediateAsExact_hardestCatalogTier() {
        let intermediateProgram = candidate(id: "intermediate-program", level: "intermediate")
        let result = ProgramMatcher.match(
            profile: profile(experience: "advanced"),
            candidates: [intermediateProgram]
        )
        guard case .exact(let match) = result else {
            Issue.record("expected exact — intermediate is the hardest tier the catalog offers, got \(result)")
            return
        }
        #expect(match.id == "intermediate-program")
    }

    @Test func tiesBreakStablyByID() {
        let b = candidate(id: "b-program")
        let a = candidate(id: "a-program")
        let result1 = ProgramMatcher.match(profile: profile(), candidates: [b, a])
        let result2 = ProgramMatcher.match(profile: profile(), candidates: [a, b])
        guard case .exact(let match1) = result1, case .exact(let match2) = result2 else {
            Issue.record("expected exact matches")
            return
        }
        #expect(match1.id == "a-program")
        #expect(match2.id == "a-program")
    }

    @Test func noneReasonDistinguishesEquipmentFocusFromFrequency() {
        // Case 1: nothing matches equipment/focus at all.
        let unreachable = candidate(id: "unreachable", focus: .yoga, equipment: ["yoga wheel"])
        let equipmentFocusNone = ProgramMatcher.match(
            profile: profile(focus: .strength, equipment: []),
            candidates: [unreachable]
        )
        guard case .none(let reason1) = equipmentFocusNone else {
            Issue.record("expected none"); return
        }
        #expect(reason1.contains("equipment") || reason1.contains("focus"))

        // Case 2: equipment/focus match, but every candidate needs more days.
        let tooFrequent = candidate(id: "too-frequent", daysPerWeek: 6, equipment: [])
        let frequencyNone = ProgramMatcher.match(
            profile: profile(sessionsPerWeek: 2, equipment: []),
            candidates: [tooFrequent]
        )
        guard case .none(let reason2) = frequencyNone else {
            Issue.record("expected none"); return
        }
        #expect(reason2.contains("6x/week"))
        #expect(reason1 != reason2)
    }

    @Test func matchingIsDeterministic() {
        let candidates = [
            candidate(id: "upper-lower", daysPerWeek: 4),
            candidate(id: "full-body", daysPerWeek: 3),
            candidate(id: "ppl", daysPerWeek: 6)
        ]
        let p = profile()
        let first = ProgramMatcher.match(profile: p, candidates: candidates)
        let second = ProgramMatcher.match(profile: p, candidates: candidates)
        #expect(first == second)
    }

    @Test func goalMismatchProducesFallbackWithReason() {
        let fatLossProgram = candidate(id: "fat-loss-4day", goal: "fat loss")
        let result = ProgramMatcher.match(profile: profile(goal: "muscle gain"), candidates: [fatLossProgram])
        guard case .fallback(let match, let reasons) = result else {
            Issue.record("expected fallback, got \(result)")
            return
        }
        #expect(match.id == "fat-loss-4day")
        #expect(reasons.contains { $0.contains("fat loss") })
    }
}
