import ForgeCore
import ForgeData
import Foundation

/// Headline facts that describe the authored modalities, not their persistence
/// details. Conditioning-generated set rows therefore never become Strength
/// volume or set counts in history/share summaries.
struct WorkoutOverviewPresentation {
    struct Fact: Equatable {
        let label: String
        let value: String
    }

    let facts: [Fact]
    let strengthVolume: Double
    let strengthSets: Double

    static func make(
        workout: WorkoutModel,
        exercises: [ExerciseLibraryModel],
        durationSeconds: Int
    ) -> Self {
        let plan = WorkoutPresentationPlan.make(for: workout)
        let sessions = workout.cardioSessions.filter { $0.deletedAt == nil }
        let strengthSets = plan.strengthExercises
            .flatMap(\.sets)
            .filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
        let volume = strengthSets.reduce(0) { $0 + ($1.totalVolume ?? 0) }
        let effectiveSets = strengthSets.reduce(0) { $0 + VolumeMath.effectiveSetCount($1.domainEntry) }

        if plan.modalities == [.conditioning] {
            let contexts = ConditioningSharePresentation.contexts(for: workout)
            if contexts.isEmpty {
                let completed = sessions.filter { $0.isConditioningSession && $0.endedAt != nil }
                guard !completed.isEmpty else {
                    return Self(
                        facts: [
                            Fact(label: "Total time", value: Fmt.durationShort(durationSeconds)),
                            Fact(label: "Status", value: "Skipped")
                        ],
                        strengthVolume: volume,
                        strengthSets: effectiveSets
                    )
                }
                let avgHR = workout.avgHR ?? completed.compactMap(\.avgHR).averageRounded
                let energy = workout.activeEnergyKcal
                    ?? completed.compactMap(\.activeEnergyKcal).reduce(0, +)
                return Self(
                    facts: [
                        Fact(label: "Duration", value: Fmt.durationShort(durationSeconds)),
                        Fact(label: "Avg HR", value: avgHR.map(String.init) ?? "—"),
                        Fact(label: "Energy", value: energy > 0 ? "\(Int(energy)) kcal" : "—")
                    ],
                    strengthVolume: volume,
                    strengthSets: effectiveSets
                )
            }
            if contexts.allSatisfy({ $0.result == nil }) {
                return Self(
                    facts: [
                        Fact(label: "Total time", value: Fmt.durationShort(durationSeconds)),
                        Fact(label: "Status", value: "Skipped")
                    ],
                    strengthVolume: volume,
                    strengthSets: effectiveSets
                )
            }
            return Self(
                facts: ConditioningSharePresentation.workoutFacts(
                    for: workout,
                    durationSeconds: durationSeconds
                ).map { Fact(label: $0.label, value: $0.value) },
                strengthVolume: volume,
                strengthSets: effectiveSets
            )
        }

        if plan.modalities == [.yoga] {
            let yogaSessions = sessions.filter { $0.isYogaSession && $0.endedAt != nil }
            if yogaSessions.isEmpty {
                return Self(
                    facts: [
                        Fact(label: "Total time", value: Fmt.durationShort(durationSeconds)),
                        Fact(label: "Status", value: "Skipped")
                    ],
                    strengthVolume: volume,
                    strengthSets: effectiveSets
                )
            }
            let duration = yogaSessions.compactMap(\.durationSeconds).reduce(0, +)
            let poses = yogaSessions.reduce(0) { total, session in
                let flow = yogaPlan(for: session, workout: workout)
                return total + YogaHistoryPresentation.poseCount(session: session, plan: flow)
            }
            let style = yogaSessions.count == 1
                ? (yogaSessions.first?.resolvedYogaStyle.title ?? "Yoga")
                : "\(yogaSessions.count) practices"
            return Self(
                facts: [
                    Fact(label: "Duration", value: Fmt.durationShort(duration > 0 ? duration : durationSeconds)),
                    Fact(label: "Poses", value: poses > 0 ? "\(poses)" : "—"),
                    Fact(label: "Style", value: style)
                ],
                strengthVolume: volume,
                strengthSets: effectiveSets
            )
        }

        if plan.modalities == [.cardio] {
            let cardio = sessions.filter { !$0.isYogaSession && !$0.isConditioningSession }
            let distance = cardio.compactMap(\.distanceMeters).reduce(0, +)
            return Self(
                facts: [
                    Fact(label: "Duration", value: Fmt.durationShort(durationSeconds)),
                    Fact(label: "Distance", value: distance > 0 ? Fmt.distance(distance) : "—"),
                    Fact(
                        label: cardio.count > 1 ? "Activities" : "Avg HR",
                        value: cardio.count > 1
                            ? "\(cardio.count)"
                            : cardio.first?.avgHR.map(String.init) ?? workout.avgHR.map(String.init) ?? "—"
                    )
                ],
                strengthVolume: volume,
                strengthSets: effectiveSets
            )
        }

        if plan.modalities == [.strength] || plan.modalities.isEmpty {
            return Self(
                facts: [
                    Fact(label: "Total time", value: Fmt.durationShort(durationSeconds)),
                    Fact(label: "Volume", value: Fmt.volume(volume)),
                    Fact(label: "Sets", value: Fmt.sets(effectiveSets))
                ],
                strengthVolume: volume,
                strengthSets: effectiveSets
            )
        }

        // Mixed-workout headlines stay session-level. The timeline immediately
        // below owns each modality's score, duration, poses, pace, and sets;
        // repeating whichever three happen to fit here would both duplicate
        // numbers and omit a fourth modality.
        let facts = [
            Fact(label: "Total time", value: Fmt.durationShort(durationSeconds)),
            Fact(label: "Modalities", value: "\(plan.modalities.count)"),
            Fact(label: "Activities", value: "\(plan.items.count)")
        ]
        return Self(facts: facts, strengthVolume: volume, strengthSets: effectiveSets)
    }

    private static func yogaPlan(for session: CardioSessionModel, workout: WorkoutModel) -> YogaFlowPlan? {
        if let blockID = session.workoutBlockID,
           let block = workout.blocks.first(where: { $0.id == blockID }) {
            return YogaFlowPlan.decode(from: block.planSnapshotJSON)
        }
        if let exerciseID = session.workoutExerciseID,
           let exercise = workout.exercises.first(where: { $0.id == exerciseID }) {
            return YogaFlowPlan.decode(from: exercise.yogaFlowJSON)
        }
        return nil
    }
}

private extension Collection where Element == Int {
    var averageRounded: Int? {
        guard !isEmpty else { return nil }
        return Int((Double(reduce(0, +)) / Double(count)).rounded())
    }
}
