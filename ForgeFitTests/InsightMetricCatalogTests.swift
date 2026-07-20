import ForgeCore
@testable import ForgeFit
import Foundation
import Testing

/// Catalog integrity: stable unique IDs, descriptors that validate under the
/// compatibility engine, and a producer behind every ID. Pure value tests —
/// snapshots are plain Sendable structs, no model container involved.
struct InsightMetricCatalogTests {

    // MARK: - Fixtures

    private let benchID = UUID()

    private func session(
        daysAgo: Int = 1,
        strength: Bool = true,
        cardio: Bool = false,
        yoga: Bool = false,
        imported: Bool = false
    ) -> InsightSessionSnapshot {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000 - Double(daysAgo) * 86_400)
        return InsightSessionSnapshot(
            id: UUID(),
            startedAt: date,
            durationSeconds: 3_600,
            strengthDurationSeconds: strength ? (cardio ? 1_500 : 3_600) : 0,
            volumeKg: strength ? 5_000 : 0,
            workingSets: strength ? 18 : 0,
            reps: strength ? 120 : 0,
            hasStrength: strength,
            isCardio: cardio,
            hasYoga: yoga,
            modality: cardio ? "run" : (yoga ? "yoga" : "strength"),
            routineID: UUID(),
            exerciseIDs: [benchID],
            primaryMuscles: ["chest"],
            exerciseVolumeKg: strength ? [benchID: 1_200] : [:],
            exerciseSets: strength ? [benchID: 9] : [:],
            exerciseReps: strength ? [benchID: 45] : [:],
            avgRPE: strength ? 8 : nil,
            avgRIR: strength ? 2 : nil,
            rpeSampleCount: strength ? 18 : 0,
            rirSampleCount: strength ? 18 : 0,
            exerciseRPE: strength ? [benchID: 8.5] : [:],
            exerciseRPECounts: strength ? [benchID: 9] : [:],
            exerciseRIR: strength ? [benchID: 1.5] : [:],
            exerciseRIRCounts: strength ? [benchID: 9] : [:],
            weekday: 3,
            isImported: imported,
            readinessAtStart: 72,
            cardioSegments: cardio ? [
                InsightCardioSegment(
                    startedAt: date, modality: "run", durationSeconds: 2_100,
                    distanceMeters: 8_000, avgHR: 152, maxHR: 181,
                    activeEnergyKcal: 640, avgPowerWatts: 240,
                    elevationGainMeters: 55, steps: 7_400,
                    zoneSeconds: [60, 300, 900, 700, 200]
                ),
            ] : [],
            yogaDurationSeconds: yoga ? 1_800 : 0,
            yogaPosesCompleted: yoga ? 9 : 0,
            yogaStyle: yoga ? "hatha" : nil
        )
    }

    private func healthDay(daysAgo: Int = 1, estimated: Bool = false) -> InsightDailyHealthSnapshot {
        InsightDailyHealthSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 800_000_000 - Double(daysAgo) * 86_400),
            hrvSDNN: 55,
            nocturnalHRV: 63,
            restingHR: 58,
            sleepingHR: 51,
            respiratoryRate: 14.6,
            oxygenSaturationPercent: 97,
            sleepTotalMinutes: 452,
            sleepDeepMinutes: 66,
            sleepREMMinutes: 98,
            isEstimated: estimated
        )
    }

    private var richInputs: InsightMetricCatalog.Inputs {
        InsightMetricCatalog.Inputs(
            sessions: [
                session(daysAgo: 3, strength: true),
                session(daysAgo: 2, strength: false, cardio: true),
                session(daysAgo: 1, strength: false, yoga: true),
            ],
            health: [healthDay()],
            activity: [
                InsightDailyActivitySnapshot(
                    date: Date(timeIntervalSinceReferenceDate: 800_000_000 - 86_400),
                    steps: 9_400, exerciseMinutes: 48, activeEnergyKcal: 610
                ),
            ],
            bodyweight: [
                InsightObservation(
                    timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000 - 86_400),
                    value: 82.4, provenance: .measured
                ),
            ],
            e1rmByExercise: [
                benchID: [
                    InsightObservation(
                        timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000 - 86_400),
                        value: 142.5, provenance: .estimated
                    ),
                ],
            ],
            scopedExerciseID: benchID
        )
    }

    // MARK: - Catalog integrity

    @Test func idsAreUniqueAndNamespaced() {
        let ids = InsightMetricCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.contains(".") })
    }

    /// Every catalog descriptor must validate as at least a simple trend —
    /// a descriptor whose own declared semantics fail the compatibility
    /// engine is a catalog bug, not a user error.
    @Test func everyMetricValidatesAsASimpleTrend() {
        for descriptor in InsightMetricCatalog.all {
            let operand: InsightOperand
            switch descriptor.requiredScope {
            case .exercise:
                operand = InsightOperand(metricID: descriptor.id, exerciseID: UUID())
            case .modality:
                operand = InsightOperand(metricID: descriptor.id, modality: "run")
            case .routine:
                operand = InsightOperand(metricID: descriptor.id, routineID: UUID())
            case nil:
                operand = InsightOperand(metricID: descriptor.id)
            }
            let recipe = InsightRecipe(shape: .trend, operands: [operand], bucket: .daily)
            let validation = InsightCompatibilityEngine.validate(recipe, descriptors: InsightMetricCatalog.all)
            #expect(validation.isValid, "\(descriptor.id): \(validation.issues)")
        }
    }

    @Test func eventCountsRequireCalendarBucketsAndExcludeConstantOneAnalyses() {
        let eventIDs = [
            "strength.workouts", "strength.exerciseFrequency", "training.frequency",
            "cardio.sessions", "yoga.sessions",
        ]
        let expectedShapes: Set<InsightShape> = [.trend, .periodComparison, .distribution]
        for id in eventIDs {
            let descriptor = InsightMetricCatalog.definition(for: id)
            #expect(descriptor?.nativeBuckets == [.daily], "\(id) must not offer a constant-one session bucket")
            #expect(descriptor?.supportedShapes == expectedShapes, "\(id) must use a calendar denominator")
            #expect(descriptor?.zeroFillPolicy == .zeroWhenAbsent)
        }
    }

    @Test func paceAndPowerRequireOneCardioType() {
        for id in ["cardio.pace", "cardio.power"] {
            let descriptor = InsightMetricCatalog.definition(for: id)
            #expect(descriptor?.requiredScope == .modality)
            #expect(descriptor?.supportedScopes.contains(.modality) == true)

            let bare = InsightRecipe(shape: .trend, primaryMetricID: id, bucket: .daily)
            #expect(InsightCompatibilityEngine.validate(
                bare, descriptors: InsightMetricCatalog.descriptors(covering: bare)
            ).issues.contains(.missingRequiredScope(metricID: id, scope: .modality)))

            let scoped = InsightRecipe(
                shape: .trend,
                operands: [InsightOperand(metricID: id, modality: "run")],
                bucket: .daily
            )
            #expect(InsightCompatibilityEngine.validate(
                scoped, descriptors: InsightMetricCatalog.descriptors(covering: scoped)
            ).isValid)
        }
    }

    @Test func optionalRecordedSumsNeverTreatMissingSensorsAsZero() {
        let optionalIDs = [
            "cardio.distance", "cardio.energy", "cardio.zoneTime",
            "cardio.elevation", "cardio.steps", "health.steps",
            "health.exerciseMinutes", "health.activeEnergy",
        ]
        for id in optionalIDs {
            let descriptor = InsightMetricCatalog.definition(for: id)
            #expect(descriptor?.zeroFillPolicy == .never, "\(id) is unknown when absent, not zero")
            #expect(descriptor?.supportedShapes.contains(.periodComparison) == false)

            let period = InsightRecipe(
                shape: .periodComparison,
                primaryMetricID: id,
                bucket: .daily
            )
            let validation = InsightCompatibilityEngine.validate(
                period, descriptors: InsightMetricCatalog.descriptors(covering: period)
            )
            #expect(validation.issues.contains(.shapeUnsupported(metricID: id)))
        }

        var noSensors = session(strength: false, cardio: true)
        noSensors.cardioSegments[0].distanceMeters = nil
        noSensors.cardioSegments[0].activeEnergyKcal = nil
        noSensors.cardioSegments[0].elevationGainMeters = nil
        noSensors.cardioSegments[0].steps = nil
        noSensors.cardioSegments[0].zoneSeconds = []
        let inputs = InsightMetricCatalog.Inputs(
            sessions: [noSensors],
            activity: [
                InsightDailyActivitySnapshot(
                    date: noSensors.startedAt, steps: nil,
                    exerciseMinutes: nil, activeEnergyKcal: nil
                ),
            ]
        )
        for id in optionalIDs {
            #expect(
                InsightMetricCatalog.observations(for: id, inputs: inputs).isEmpty,
                "\(id) emitted a fabricated zero"
            )
        }
    }

    @Test func catalogPopulationDefaultsToTrainingDaysAndHealthHasNoOverride() {
        let volumeAndSleep = InsightRecipe(
            shape: .relationship,
            primaryMetricID: "strength.volume",
            comparisonMetricIDs: ["health.sleepTotal"],
            bucket: .daily
        )
        let mixedDescriptors = InsightMetricCatalog.descriptors(covering: volumeAndSleep)
        #expect(
            InsightCompatibilityEngine.allowedRelationshipPopulations(
                for: volumeAndSleep,
                descriptors: mixedDescriptors
            ) == [.activeBucketsOnly, .includeInactiveBuckets]
        )
        #expect(
            InsightCompatibilityEngine.resolvedRelationshipPopulation(
                for: volumeAndSleep,
                descriptors: mixedDescriptors
            ) == .activeBucketsOnly
        )

        let healthOnly = InsightRecipe(
            shape: .relationship,
            primaryMetricID: "health.sleepTotal",
            comparisonMetricIDs: ["health.hrv"],
            bucket: .daily,
            relationshipPopulation: .includeInactiveBuckets
        )
        #expect(
            InsightCompatibilityEngine.allowedRelationshipPopulations(
                for: healthOnly,
                descriptors: InsightMetricCatalog.descriptors(covering: healthOnly)
            ).isEmpty
        )
    }

    @Test func onlyPartitioningDimensionsCanRenderShares() {
        let cardio = InsightMetricCatalog.definition(for: "cardio.duration")
        let strength = InsightMetricCatalog.definition(for: "strength.volume")
        #expect(cardio?.exclusiveGroupingDimensions.contains(.modality) == true)
        #expect(strength?.exclusiveGroupingDimensions.contains(.checkinTag) == false)

        let cardioShare = InsightRecipe(
            shape: .groupComparison, primaryMetricID: "cardio.duration",
            dimension: .modality, bucket: .daily, chart: .donutShare
        )
        #expect(InsightCompatibilityEngine.validate(
            cardioShare, descriptors: InsightMetricCatalog.all
        ).isValid)

        let overlappingTags = InsightRecipe(
            shape: .groupComparison, primaryMetricID: "strength.volume",
            dimension: .checkinTag, bucket: .daily, chart: .donutShare
        )
        #expect(InsightCompatibilityEngine.validate(
            overlappingTags, descriptors: InsightMetricCatalog.all
        ).issues.contains(.chartIncompatible(chart: .donutShare)))
    }

    /// A descriptor without a producer yields silent empty cards — this pins
    /// that every catalog ID produces observations from a fully-stocked
    /// fixture.
    @Test func everyCatalogIDHasAProducer() {
        for descriptor in InsightMetricCatalog.all {
            let observations = InsightMetricCatalog.observations(for: descriptor.id, inputs: richInputs)
            #expect(!observations.isEmpty, "No producer output for \(descriptor.id)")
        }
    }

    // MARK: - Producer semantics

    @Test func hrvPrefersTheNocturnalWindow() throws {
        let observations = InsightMetricCatalog.observations(for: "health.hrv", inputs: richInputs)
        #expect(try #require(observations.first).value == 63)
    }

    @Test func restingHRPrefersSleepingHR() throws {
        let observations = InsightMetricCatalog.observations(for: "health.restingHR", inputs: richInputs)
        #expect(try #require(observations.first).value == 51)
    }

    @Test func paceCarriesItsDistanceWeight() throws {
        let observations = InsightMetricCatalog.observations(for: "cardio.pace", inputs: richInputs)
        let pace = try #require(observations.first)
        // Pace uses the SEGMENT's duration over its distance — never the
        // whole workout's wall clock.
        #expect(abs(pace.value - 2_100.0 / 8_000.0) < 1e-9)
        #expect(pace.weight == 8_000)
    }

    @Test func insightPaceUsesTheSelectedActivityDenominator() {
        let secondsPerMeter = 120.0 / 500.0
        #expect(
            InsightValueFormat.paceString(secondsPerMeter: secondsPerMeter, modality: "row")
                == "2:00/500m"
        )
        #expect(
            InsightValueFormat.paceString(secondsPerMeter: secondsPerMeter, modality: "swim")
                == "0:24/100m"
        )
    }

    @Test func mixedRelationshipPopulationCopyNamesItsAsymmetricZeroPolicy() {
        let recipe = InsightRecipe(
            shape: .relationship,
            operands: [
                InsightOperand(metricID: "health.sleepTotal"),
                InsightOperand(metricID: "strength.workingSets"),
            ],
            bucket: .daily,
            lag: InsightLag(unit: .days, count: 0),
            relationshipPopulation: .includeInactiveBuckets
        )
        let copy = InsightRelationshipPopulationCopy.text(
            recipe: recipe,
            bucketNoun: "days",
            titleFor: { key in
                InsightMetricCatalog.definition(for: InsightOperand.metricID(fromKey: key))?.title ?? key
            }
        )
        #expect(copy.contains("Sleep duration had a recorded value"))
        #expect(copy.contains("absent working sets total counted as zero"))
        #expect(!copy.contains("both metrics had a recorded value"))
    }

    @Test func automaticRelationshipPopulationCopyNamesExcludedTrainingDays() {
        let recipe = InsightRecipe(
            shape: .relationship,
            operands: [
                InsightOperand(metricID: "strength.volume"),
                InsightOperand(metricID: "health.sleepTotal"),
            ],
            bucket: .daily,
            lag: InsightLag(unit: .days, count: 0)
        )
        let copy = InsightRelationshipPopulationCopy.text(
            recipe: recipe,
            bucketNoun: "days",
            titleFor: { key in
                InsightMetricCatalog.definition(for: InsightOperand.metricID(fromKey: key))?.title ?? key
            }
        )
        #expect(copy.contains("days without working volume were excluded"))
        #expect(!copy.contains("counted as zero"))
    }

    @Test func insufficientPairStateUsesOneConciseProgressLine() {
        let state = InsightPresentationState.insufficientPairs(found: 7, needed: 10)
        #expect(!state.showsSummary)
        #expect(state.progressText(bucketNoun: "days") == "7/10 matched days to create insight")
    }

    @Test func mixedPaceDenominatorsCannotShareOneDisplayAxis() {
        func recipe(_ first: String, _ second: String) -> InsightRecipe {
            InsightRecipe(
                shape: .trend,
                operands: [
                    InsightOperand(metricID: "cardio.pace", modality: first),
                    InsightOperand(metricID: "cardio.pace", modality: second),
                ],
                bucket: .daily
            )
        }

        #expect(InsightDisplayUnitPolicy.hasMixedPaceDenominators(recipe("row", "swim")))
        #expect(InsightDisplayUnitPolicy.hasMixedPaceDenominators(recipe("row", "run")))
        #expect(!InsightDisplayUnitPolicy.hasMixedPaceDenominators(recipe("run", "walk")))
    }

    @Test func cardioMetricsReadSegmentsNotTheWholeWorkout() {
        var hybrid = session(strength: true, cardio: true)
        let inputs = InsightMetricCatalog.Inputs(sessions: [hybrid])
        #expect(InsightMetricCatalog.observations(for: "cardio.duration", inputs: inputs).map(\.value) == [2_100])
        // Strength time = wall clock minus the cardio block.
        #expect(InsightMetricCatalog.observations(for: "strength.duration", inputs: inputs).map(\.value) == [1_500])
        // Two cardio blocks in one workout are two data points.
        hybrid.cardioSegments.append(hybrid.cardioSegments[0])
        let two = InsightMetricCatalog.observations(for: "cardio.sessions", inputs: .init(sessions: [hybrid]))
        #expect(two.count == 2)
    }

    @Test func yogaMetricsUseTheSessionNotThePlan() {
        let flow = session(strength: false, yoga: true)
        let inputs = InsightMetricCatalog.Inputs(sessions: [flow])
        #expect(InsightMetricCatalog.observations(for: "yoga.duration", inputs: inputs).map(\.value) == [1_800])
        #expect(InsightMetricCatalog.observations(for: "yoga.poses", inputs: inputs).map(\.value) == [9])
    }

    @Test func exerciseScopeReadsTheExercisesOwnNumbers() {
        var day = session(strength: true)
        let bench = UUID()
        day.exerciseVolumeKg = [bench: 1_200]
        day.exerciseSets = [bench: 9]
        day.exerciseReps = [bench: 45]
        var inputs = InsightMetricCatalog.Inputs(sessions: [day])
        inputs.scopedExerciseID = bench
        #expect(InsightMetricCatalog.observations(for: "strength.volume", inputs: inputs).map(\.value) == [1_200])
        #expect(InsightMetricCatalog.observations(for: "strength.workingSets", inputs: inputs).map(\.value) == [9])
        #expect(InsightMetricCatalog.observations(for: "strength.reps", inputs: inputs).map(\.value) == [45])
        inputs.scopedExerciseID = nil
        #expect(InsightMetricCatalog.observations(for: "strength.volume", inputs: inputs).map(\.value) == [5_000])
    }

    @Test func zoneTimeSumsTheHardZonesOnly() throws {
        let observations = InsightMetricCatalog.observations(for: "cardio.zoneTime", inputs: richInputs)
        #expect(try #require(observations.first).value == 900)
    }

    /// A complete zone record with no time in zones 4–5 is a measured zero;
    /// an absent/incomplete zone record remains missing (covered above).
    @Test func zoneTimePreservesACompleteTrueZero() throws {
        var easy = session(strength: false, cardio: true)
        easy.cardioSegments[0].zoneSeconds = [600, 900, 600, 0, 0]
        let rows = InsightMetricCatalog.observations(
            for: "cardio.zoneTime", inputs: .init(sessions: [easy])
        )
        #expect(try #require(rows.first).value == 0)
    }

    @Test func importedSessionsCarryImportedProvenance() throws {
        var inputs = richInputs
        inputs.sessions = [session(strength: true, imported: true)]
        let observations = InsightMetricCatalog.observations(for: "strength.volume", inputs: inputs)
        #expect(try #require(observations.first).provenance == .imported)
    }

    @Test func estimatedHealthDaysCarryEstimatedProvenance() throws {
        var inputs = richInputs
        inputs.health = [healthDay(estimated: true)]
        let observations = InsightMetricCatalog.observations(for: "health.sleepTotal", inputs: inputs)
        #expect(try #require(observations.first).provenance == .estimated)
    }

    @Test func readinessComesFromSessionsNotHealthStore() {
        var inputs = InsightMetricCatalog.Inputs()
        inputs.sessions = [session(strength: true)]
        let observations = InsightMetricCatalog.observations(for: "health.readiness", inputs: inputs)
        #expect(observations.map(\.value) == [72])
    }

    @Test func unknownIDProducesNothing() {
        #expect(InsightMetricCatalog.observations(for: "future.metric", inputs: richInputs).isEmpty)
    }

    // MARK: - Round-3 metrics

    @Test func relativeStrengthDividesByNearbyBodyweight() throws {
        var inputs = richInputs
        let observations = InsightMetricCatalog.observations(for: "strength.relativeE1RM", inputs: inputs)
        let first = try #require(observations.first)
        #expect(abs(first.value - 142.5 / 82.4) < 1e-9)
        #expect(first.provenance == .estimated)
        // No body-weight reading within a week → no ratio, never a guess.
        inputs.bodyweight = []
        #expect(InsightMetricCatalog.observations(for: "strength.relativeE1RM", inputs: inputs).isEmpty)
    }

    @Test func effortAndDensityMetricsProduce() {
        var inputs = InsightMetricCatalog.Inputs(sessions: [session(strength: true)])
        #expect(InsightMetricCatalog.observations(for: "strength.avgRPE", inputs: inputs).map(\.value) == [8])
        #expect(InsightMetricCatalog.observations(for: "strength.avgRIR", inputs: inputs).map(\.value) == [2])
        #expect(InsightMetricCatalog.observations(for: "training.frequency", inputs: inputs).map(\.value) == [1])
        let density = InsightMetricCatalog.observations(for: "strength.volumeDensity", inputs: inputs)
        #expect(density.map(\.value) == [5_000 / 60])
        // Exercise scope reads that exercise's own mean RPE.
        inputs.scopedExerciseID = benchID
        #expect(InsightMetricCatalog.observations(for: "strength.avgRPE", inputs: inputs).map(\.value) == [8.5])
        let scopedRIR = InsightMetricCatalog.observations(for: "strength.avgRIR", inputs: inputs)
        #expect(scopedRIR.map(\.value) == [1.5])
        #expect(scopedRIR.map(\.weight) == [9])
    }

    // MARK: - Operands (schemaVersion 2)

    @Test func operandScopesUnlockScopedTwins() {
        let bench = UUID()
        let squat = UUID()
        let twins = InsightRecipe(
            shape: .trend,
            operands: [
                InsightOperand(metricID: "strength.e1rm", exerciseID: bench),
                InsightOperand(metricID: "strength.e1rm", exerciseID: squat),
            ],
            bucket: .daily
        )
        let validation = InsightCompatibilityEngine.validate(
            twins, descriptors: InsightMetricCatalog.descriptors(covering: twins)
        )
        #expect(validation.isValid, "\(validation.issues)")

        // The SAME scope twice is a duplicate, not a comparison.
        let dupe = InsightRecipe(
            shape: .trend,
            operands: [
                InsightOperand(metricID: "strength.e1rm", exerciseID: bench),
                InsightOperand(metricID: "strength.e1rm", exerciseID: bench),
            ],
            bucket: .daily
        )
        let dupeValidation = InsightCompatibilityEngine.validate(
            dupe, descriptors: InsightMetricCatalog.descriptors(covering: dupe)
        )
        #expect(dupeValidation.issues.contains {
            if case .duplicateMetric = $0 { return true } else { return false }
        })
    }

    @Test func legacyRecipesDefaultPopulationAndV3RoundTrips() throws {
        let v1JSON = """
        {"schemaVersion":1,"id":"11111111-1111-1111-1111-111111111111","name":"Old","shape":"trend",\
        "primaryMetricID":"strength.volume","comparisonMetricIDs":["health.sleepTotal"],"filters":[],\
        "range":"twelveWeeks","bucket":"daily","normalization":"none",\
        "createdAt":700000000,"updatedAt":700000000}
        """
        let migrated = try #require(InsightRecipe.decode(from: v1JSON))
        #expect(migrated.allMetricIDs == ["strength.volume", "health.sleepTotal"])
        #expect(migrated.operandKeys == ["strength.volume", "health.sleepTotal"])
        #expect(migrated.relationshipPopulation == .automatic)

        let v3 = InsightRecipe(
            shape: .relationship,
            operands: [
                InsightOperand(metricID: "strength.volume"),
                InsightOperand(metricID: "health.sleepTotal"),
            ],
            relationshipPopulation: .includeInactiveBuckets
        )
        let json = try #require(v3.encodedJSON())
        let decoded = try #require(InsightRecipe.decode(from: json))
        #expect(decoded == v3)
    }

    // MARK: - Muscle-scoped metrics

    @Test func muscleMetricIDRoundTripsThroughTheTaxonomy() {
        let id = InsightMetricCatalog.muscleSetsID(for: "Front_Delts")
        #expect(id == "strength.muscleSets.front-delts")
        #expect(InsightMetricCatalog.muscle(fromMetricID: id) == "front delts")

        let descriptor = InsightMetricCatalog.definition(for: id)
        #expect(descriptor?.title == "Front delts sets")
        #expect(descriptor?.aggregation == .sum)
        // Grouping one muscle's sets by muscle would be circular.
        #expect(descriptor?.supportedDimensions.contains(.muscle) == false)
        #expect(InsightMetricCatalog.definition(for: "strength.muscleSets.") == nil)
    }

    @Test func muscleObservationsReadTheSessionBreakdown() {
        var chestDay = session(strength: true)
        chestDay.muscleSets = ["chest": 4.5, "back": 2]
        let inputs = InsightMetricCatalog.Inputs(sessions: [chestDay])

        let chest = InsightMetricCatalog.observations(
            for: InsightMetricCatalog.muscleSetsID(for: "chest"), inputs: inputs
        )
        #expect(chest.map(\.value) == [4.5])

        let quads = InsightMetricCatalog.observations(
            for: InsightMetricCatalog.muscleSetsID(for: "quadriceps"), inputs: inputs
        )
        #expect(quads.isEmpty)
    }

    @Test func muscleRecipesValidateThroughCoveringDescriptors() {
        let recipe = InsightRecipe(
            shape: .trend,
            primaryMetricID: InsightMetricCatalog.muscleSetsID(for: "chest"),
            comparisonMetricIDs: [InsightMetricCatalog.muscleSetsID(for: "back")],
            bucket: .weekly
        )
        let validation = InsightCompatibilityEngine.validate(
            recipe, descriptors: InsightMetricCatalog.descriptors(covering: recipe)
        )
        #expect(validation.isValid, "\(validation.issues)")
        // Two same-unit muscle lines share one chart.
        #expect(validation.allowedCharts.first == .sharedUnitOverlay)
    }

    /// Every shipped template must validate after the launcher's one required
    /// scope choice — a template that opens onto a warning wall is worse than
    /// no template.
    @Test func everyTemplateValidates() {
        for template in InsightTemplateCatalog.all {
            var recipe = template.recipe
            let unresolvedScopes: Set<InsightScopeKind> = Set(recipe.operands.compactMap { operand in
                InsightMetricCatalog.definition(for: operand.metricID)?.requiredScope
            })
            #expect(unresolvedScopes.count <= 1, "\(template.id) needs a multi-step scope launcher")
            if let scope = template.requiredScopeToPick {
                let value = scope == .modality ? "run" : UUID().uuidString
                recipe = template.resolvedRecipe(scope: scope, value: value)
            }
            let validation = InsightCompatibilityEngine.validate(
                recipe, descriptors: InsightMetricCatalog.descriptors(covering: recipe)
            )
            #expect(validation.isValid, "\(template.id): \(validation.issues)")
        }
    }

    @Test func relationshipTemplatesUseTheCorrectTimeAndDomainAlignment() throws {
        let sleep = try #require(InsightTemplateCatalog.all.first {
            $0.id == "template.sleepVsPerformance"
        })
        let hrv = try #require(InsightTemplateCatalog.all.first {
            $0.id == "template.hrvVsPerformance"
        })
        #expect(sleep.recipe.lag == InsightLag(unit: .days, count: 0))
        #expect(hrv.recipe.lag == InsightLag(unit: .days, count: 0))

        let readiness = try #require(InsightTemplateCatalog.all.first {
            $0.id == "template.readinessVsOutput"
        })
        #expect(readiness.recipe.bucket == .session)
        #expect(readiness.recipe.lag == InsightLag(unit: .days, count: 0))

        let pace = try #require(InsightTemplateCatalog.all.first {
            $0.id == "template.paceVsHeartRate"
        })
        #expect(pace.requiredScopeToPick == .modality)
        let scopedRecipe = pace.resolvedRecipe(scope: .modality, value: "run")
        #expect(scopedRecipe.operands.allSatisfy { $0.modality == "run" })
        #expect(InsightCompatibilityEngine.validate(
            scopedRecipe, descriptors: InsightMetricCatalog.descriptors(covering: scopedRecipe)
        ).isValid)

        let exerciseTrend = try #require(InsightTemplateCatalog.all.first {
            $0.id == "template.volumeVsE1RM"
        })
        let exerciseID = UUID()
        let exerciseRecipe = exerciseTrend.resolvedRecipe(
            scope: .exercise,
            value: exerciseID.uuidString
        )
        #expect(exerciseRecipe.operands.allSatisfy { $0.exerciseID == exerciseID })
    }

    @Test func muscleBalanceTemplateValidates() throws {
        let template = try #require(InsightTemplateCatalog.all.first { $0.id == "template.muscleBalance" })
        let validation = InsightCompatibilityEngine.validate(
            template.recipe, descriptors: InsightMetricCatalog.descriptors(covering: template.recipe)
        )
        #expect(validation.isValid, "\(validation.issues)")
    }

    @Test func muscleOptionsCanonicalizePrioritizeAndSurfaceParents() {
        let options = InsightMetricCatalog.muscleOptions(from: [
            ["front_delts", "chest"], ["lats", "Quads"], ["chest"],
        ])
        // Children ("lats", "front delts") surface their parents ("back",
        // "shoulders") so parent-level comparisons are always offered.
        #expect(options == ["chest", "back", "shoulders", "quadriceps", "front delts", "lats"])
    }
}
