import ForgeCore
@testable import ForgeFit
import Foundation
import Testing

/// Property-style coverage of the real Insights Builder catalog. These tests
/// deliberately exercise the compatibility projections the UI consumes, not
/// a second hand-written compatibility table.
@MainActor
struct InsightRecipeMatrixTests {

    // Stable, distinct placeholders make scoped twins deterministic while
    // remaining valid UUID-backed exercise/routine selections.
    private let exerciseA = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    private let exerciseB = UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID()
    private let exerciseC = UUID(uuidString: "00000000-0000-0000-0000-000000000003") ?? UUID()
    private let exerciseD = UUID(uuidString: "00000000-0000-0000-0000-000000000004") ?? UUID()
    private let routineA = UUID(uuidString: "10000000-0000-0000-0000-000000000001") ?? UUID()
    private let routineB = UUID(uuidString: "10000000-0000-0000-0000-000000000002") ?? UUID()

    /// Static catalog plus two parameterized metrics that the muscle picker
    /// can actually create. Dynamic descriptors must obey the same matrix.
    private var descriptors: [InsightMetricDescriptor] {
        let dynamic = [
            InsightMetricCatalog.muscleSetsID(for: "chest"),
            InsightMetricCatalog.muscleSetsID(for: "back"),
        ].compactMap(InsightMetricCatalog.definition(for:))
        return InsightMetricCatalog.all + dynamic
    }

    private func descriptor(_ id: String) -> InsightMetricDescriptor {
        descriptors.first(where: { $0.id == id })
            ?? InsightMetricDescriptor(
                id: id,
                title: id,
                category: "missing",
                valueKind: .count,
                timingRole: .either,
                nativeBuckets: [],
                aggregation: .sum,
                supportedShapes: []
            )
    }

    private func operand(
        for metric: InsightMetricDescriptor,
        variant: Int = 0
    ) -> InsightOperand {
        switch metric.requiredScope {
        case .exercise:
            let exercises = [exerciseA, exerciseB, exerciseC, exerciseD]
            return InsightOperand(metricID: metric.id, exerciseID: exercises[variant % exercises.count])
        case .modality:
            let modalities = ["run", "cycle", "row", "swim"]
            return InsightOperand(metricID: metric.id, modality: modalities[variant % modalities.count])
        case .routine:
            return InsightOperand(metricID: metric.id, routineID: variant.isMultiple(of: 2) ? routineA : routineB)
        case nil:
            return InsightOperand(metricID: metric.id)
        }
    }

    private func companion(excluding metricID: String) -> InsightMetricDescriptor {
        let preferred = metricID == "strength.volume" ? "health.hrv" : "strength.volume"
        return descriptor(preferred)
    }

    /// Produces one intended-valid representative of a metric/shape. The
    /// projection tests then replace every selectable axis around this base.
    private func baseRecipe(
        for metric: InsightMetricDescriptor,
        shape: InsightShape
    ) -> InsightRecipe {
        var operands = [operand(for: metric)]
        if shape == .relationship {
            operands.append(operand(for: companion(excluding: metric.id)))
        }
        var recipe = InsightRecipe(
            shape: shape,
            operands: operands,
            range: .twelveWeeks,
            bucket: .daily,
            lag: shape == .relationship ? InsightLag(unit: .days, count: 0) : nil
        )
        if shape == .groupComparison {
            recipe.dimension = InsightCompatibilityEngine.allowedDimensions(
                for: recipe,
                descriptors: descriptors
            ).first
        }
        return recipe
    }

    private func validation(_ recipe: InsightRecipe) -> InsightValidation {
        InsightCompatibilityEngine.validate(
            recipe,
            descriptors: InsightMetricCatalog.descriptors(covering: recipe)
        )
    }

    private func contains(_ lags: [InsightLag], _ candidate: InsightLag?) -> Bool {
        guard let candidate else { return false }
        return lags.contains { $0 == candidate }
    }

    private func chartCanRenderPayload(
        _ chart: InsightChartKind,
        for shape: InsightShape
    ) -> Bool {
        switch shape {
        case .trend:
            return [
                .lineTrend, .barTrend, .sharedUnitOverlay,
                .smallMultiples, .baselineIndexLines,
            ].contains(chart)
        case .relationship:
            return chart == .scatterWithTrend
        case .groupComparison:
            return [.groupedBars, .boxSummary, .donutShare].contains(chart)
        case .periodComparison:
            return [.periodComparisonCards, .groupedBars].contains(chart)
        case .distribution:
            return [.histogram, .boxSummary].contains(chart)
        }
    }

    // MARK: - Catalog x shape declarations

    @Test func everyMetricAndShapeDeclarationMatchesAnExecutableRecipe() {
        var evaluated = 0
        for metric in descriptors {
            for shape in InsightShape.allCases {
                let recipe = baseRecipe(for: metric, shape: shape)
                let result = validation(recipe)
                evaluated += 1

                if metric.supportedShapes.contains(shape) {
                    #expect(
                        result.isValid,
                        "Declared surface is not executable: \(metric.id) / \(shape): \(result.issues)"
                    )
                    #expect(!result.allowedCharts.isEmpty)
                } else {
                    #expect(
                        result.issues.contains(.shapeUnsupported(metricID: metric.id)),
                        "Undeclared shape was not rejected: \(metric.id) / \(shape)"
                    )
                }
            }
        }
        // 38 static metrics + two parameterized muscle metrics, five shapes.
        #expect(evaluated == 200)
    }

    // MARK: - UI projection closure

    @Test func everyProjectedBucketRangeDimensionLagAndChartClosesToAValidRecipe() {
        var bases = 0
        var projectionCases = 0

        for metric in descriptors {
            for shape in InsightShape.allCases where metric.supportedShapes.contains(shape) {
                let base = baseRecipe(for: metric, shape: shape)
                let baseValidation = validation(base)
                #expect(baseValidation.isValid, "Invalid base \(metric.id) / \(shape): \(baseValidation.issues)")
                bases += 1

                let projectedBuckets = InsightCompatibilityEngine.allowedBuckets(
                    for: base, descriptors: descriptors
                )
                for bucket in InsightBucket.allCases {
                    var candidate = base
                    candidate.bucket = bucket
                    if shape == .relationship {
                        candidate.lag = InsightCompatibilityEngine.allowedLags(
                            for: candidate, descriptors: descriptors
                        ).first
                    }
                    let result = validation(candidate)
                    #expect(
                        result.isValid == projectedBuckets.contains(bucket),
                        "Bucket projection diverged for \(metric.id) / \(shape) / \(bucket): \(result.issues)"
                    )
                    projectionCases += 1
                }

                let projectedRanges = InsightCompatibilityEngine.allowedRanges(
                    for: base, descriptors: descriptors
                )
                for range in InsightRange.allCases {
                    var candidate = base
                    candidate.range = range
                    let result = validation(candidate)
                    #expect(
                        result.isValid == projectedRanges.contains(range),
                        "Range projection diverged for \(metric.id) / \(shape) / \(range): \(result.issues)"
                    )
                    projectionCases += 1
                }

                if shape == .groupComparison {
                    let projectedDimensions = InsightCompatibilityEngine.allowedDimensions(
                        for: base, descriptors: descriptors
                    )
                    for dimension in InsightDimension.allCases {
                        var candidate = base
                        candidate.dimension = dimension
                        let result = validation(candidate)
                        #expect(
                            result.isValid == projectedDimensions.contains(dimension),
                            "Dimension projection diverged for \(metric.id) / \(dimension): \(result.issues)"
                        )
                        projectionCases += 1
                    }

                    // Dimension-specific feasibility (notably 4W weekdays)
                    // must also close after the user changes grouping.
                    for dimension in projectedDimensions {
                        var grouped = base
                        grouped.dimension = dimension
                        let ranges = InsightCompatibilityEngine.allowedRanges(
                            for: grouped, descriptors: descriptors
                        )
                        for range in InsightRange.allCases {
                            var candidate = grouped
                            candidate.range = range
                            let result = validation(candidate)
                            #expect(
                                result.isValid == ranges.contains(range),
                                "Grouped range projection diverged for \(metric.id) / \(dimension) / \(range)"
                            )
                            projectionCases += 1
                        }
                    }
                }

                if shape == .relationship {
                    for bucket in projectedBuckets {
                        var bucketRecipe = base
                        bucketRecipe.bucket = bucket
                        let projectedLags = InsightCompatibilityEngine.allowedLags(
                            for: bucketRecipe, descriptors: descriptors
                        )
                        let counts: ClosedRange<Int>
                        if bucket == .session {
                            counts = 0...0
                        } else if bucket == .weekly {
                            counts = InsightLag.weekWhitelist
                        } else {
                            counts = InsightLag.dayWhitelist
                        }
                        let unit: InsightLag.Unit = bucket == .weekly ? .weeks : .days
                        for count in counts {
                            var candidate = bucketRecipe
                            candidate.lag = InsightLag(unit: unit, count: count)
                            let result = validation(candidate)
                            #expect(
                                result.isValid == contains(projectedLags, candidate.lag),
                                "Lag projection diverged for \(metric.id) / \(bucket) / \(count): \(result.issues)"
                            )
                            projectionCases += 1
                        }
                    }
                }

                for chart in InsightChartKind.allCases {
                    var candidate = base
                    candidate.chart = chart
                    let result = validation(candidate)
                    let isProjected = baseValidation.allowedCharts.contains(chart)
                    #expect(
                        result.isValid == isProjected,
                        "Chart projection diverged for \(metric.id) / \(shape) / \(chart): \(result.issues)"
                    )
                    if isProjected {
                        #expect(chartCanRenderPayload(chart, for: shape))
                    } else {
                        #expect(result.issues.contains(.chartIncompatible(chart: chart)))
                    }
                    projectionCases += 1
                }
            }
        }

        // 182 executable metric/shape bases. Their complete enum projections
        // cover 4,781 bucket/range/dimension/lag/chart selections.
        #expect(bases == 182)
        #expect(projectionCases == 4_781)
    }

    // MARK: - Operand counts, units, and chart families

    @Test func meaningfulOneThroughFourOperandRecipesCoverEveryChartPayload() {
        let workingSets = descriptor("strength.workingSets")
        let reps = descriptor("strength.reps")
        let volume = descriptor("strength.volume")
        let duration = descriptor("strength.duration")
        let workouts = descriptor("strength.workouts")
        let dailySteps = descriptor("health.steps")
        let e1rm = descriptor("strength.e1rm")

        let recipes = [
            // One operand.
            InsightRecipe(shape: .trend, operands: [operand(for: volume)], bucket: .daily),
            // Two operands sharing the count axis.
            InsightRecipe(
                shape: .trend,
                operands: [operand(for: workingSets), operand(for: reps)],
                bucket: .daily
            ),
            // Two mixed-unit operands require synced small multiples.
            InsightRecipe(
                shape: .trend,
                operands: [operand(for: volume), operand(for: duration)],
                bucket: .daily
            ),
            // Three mixed-unit operands.
            InsightRecipe(
                shape: .trend,
                operands: [
                    operand(for: volume), operand(for: duration),
                    operand(for: descriptor("health.hrv")),
                ],
                bucket: .daily
            ),
            // Four tallies deliberately share the founder-approved count axis.
            InsightRecipe(
                shape: .trend,
                operands: [
                    operand(for: workouts), operand(for: workingSets),
                    operand(for: reps), operand(for: dailySteps),
                ],
                bucket: .daily
            ),
            // Four scoped twins remain distinct because the scope is identity.
            InsightRecipe(
                shape: .trend,
                operands: (0..<4).map { operand(for: e1rm, variant: $0) },
                bucket: .daily
            ),
            InsightRecipe(
                shape: .relationship,
                operands: [operand(for: volume), operand(for: descriptor("health.hrv"))],
                bucket: .daily,
                lag: InsightLag(unit: .days, count: 0)
            ),
            InsightRecipe(
                shape: .groupComparison,
                operands: [operand(for: descriptor("cardio.duration"))],
                dimension: .modality,
                bucket: .daily
            ),
            InsightRecipe(
                shape: .periodComparison,
                operands: [operand(for: workingSets), operand(for: reps)],
                bucket: .daily
            ),
            InsightRecipe(
                shape: .periodComparison,
                operands: [
                    operand(for: volume), operand(for: workouts),
                    operand(for: descriptor("cardio.duration")),
                    operand(for: descriptor("health.sleepTotal")),
                ],
                bucket: .daily
            ),
            InsightRecipe(
                shape: .distribution,
                operands: [operand(for: volume)],
                bucket: .daily
            ),
            InsightRecipe(
                shape: .trend,
                operands: [operand(for: volume)],
                bucket: .daily,
                normalization: .baselineIndex
            ),
        ]

        var offeredCharts = Set<InsightChartKind>()
        for recipe in recipes {
            let result = validation(recipe)
            #expect(result.isValid, "Meaningful combination failed: \(recipe.operandKeys): \(result.issues)")
            offeredCharts.formUnion(result.allowedCharts)
        }
        #expect(offeredCharts == Set(InsightChartKind.allCases))

        let fiveOperands = InsightRecipe(
            shape: .trend,
            operands: (0..<5).map { operand(for: e1rm, variant: $0) },
            bucket: .daily
        )
        #expect(
            validation(fiveOperands).issues.contains(
                .metricCountInvalid(expected: "at most four metrics")
            )
        )
    }

    // MARK: - Scope and duplicate contracts

    @Test func everyRequiredScopeIsEnforcedAndEveryScopeConflictIsRejected() {
        for metric in descriptors {
            guard let required = metric.requiredScope else { continue }
            #expect(metric.supportedScopes.contains(required))

            let bare = InsightRecipe(
                shape: .trend,
                operands: [InsightOperand(metricID: metric.id)],
                bucket: .daily
            )
            #expect(
                validation(bare).issues.contains(
                    .missingRequiredScope(metricID: metric.id, scope: required)
                )
            )

            let correctlyScoped = baseRecipe(for: metric, shape: .trend)
            #expect(validation(correctlyScoped).isValid)

            for wrongScope in InsightScopeKind.allCases where wrongScope != required {
                var wrong = InsightOperand(metricID: metric.id)
                switch wrongScope {
                case .exercise: wrong.exerciseID = exerciseA
                case .modality: wrong.modality = "run"
                case .routine: wrong.routineID = routineA
                }
                let recipe = InsightRecipe(shape: .trend, operands: [wrong], bucket: .daily)
                let result = validation(recipe)
                #expect(
                    result.issues.contains(
                        .missingRequiredScope(metricID: metric.id, scope: required)
                    )
                )
                if !metric.supportedScopes.contains(wrongScope) {
                    #expect(
                        result.issues.contains(
                            .scopeUnsupported(metricID: metric.id, scope: wrongScope)
                        )
                    )
                }
            }

            var ambiguous = operand(for: metric)
            switch required {
            case .exercise: ambiguous.routineID = routineA
            case .modality: ambiguous.routineID = routineA
            case .routine: ambiguous.exerciseID = exerciseA
            }
            let ambiguousRecipe = InsightRecipe(
                shape: .trend,
                operands: [ambiguous],
                bucket: .daily
            )
            #expect(
                validation(ambiguousRecipe).issues.contains(
                    .multipleScopes(metricID: metric.id)
                )
            )
        }

        for metric in descriptors where metric.supportedShapes.contains(.trend) {
            let same = operand(for: metric)
            let duplicate = InsightRecipe(
                shape: .trend,
                operands: [same, same],
                bucket: .daily
            )
            #expect(
                validation(duplicate).issues.contains(.duplicateMetric(id: same.key)),
                "Exact duplicate escaped for \(metric.id)"
            )
        }

        for metric in descriptors where metric.supportedShapes.contains(.groupComparison) {
            for dimension in InsightDimension.allCases {
                let matchingScope: InsightScopeKind?
                switch dimension {
                case .exercise: matchingScope = .exercise
                case .modality: matchingScope = .modality
                case .routine: matchingScope = .routine
                case .muscle, .weekday, .source, .checkinTag: matchingScope = nil
                }
                guard let matchingScope,
                      metric.supportedScopes.contains(matchingScope),
                      metric.supportedDimensions.contains(dimension),
                      metric.requiredScope == nil || metric.requiredScope == matchingScope else {
                    continue
                }
                var scoped = InsightOperand(metricID: metric.id)
                switch matchingScope {
                case .exercise: scoped.exerciseID = exerciseA
                case .modality: scoped.modality = "run"
                case .routine: scoped.routineID = routineA
                }
                let recipe = InsightRecipe(
                    shape: .groupComparison,
                    operands: [scoped],
                    dimension: dimension,
                    bucket: .daily
                )
                let result = validation(recipe)
                #expect(result.issues.contains(.scopeDimensionConflict(metricID: metric.id, dimension: dimension)))
                #expect(
                    !InsightCompatibilityEngine.allowedDimensions(
                        for: recipe, descriptors: descriptors
                    ).contains(dimension)
                )
            }
        }
    }

    // MARK: - Missingness and sample feasibility

    @Test func optionalRecordedTotalsNeverOfferIncompletePeriodComparisons() {
        let optionalTotals = descriptors.filter {
            $0.aggregation == .sum && $0.zeroFillPolicy == .never
        }
        #expect(!optionalTotals.isEmpty)

        for metric in optionalTotals {
            #expect(
                !metric.supportedShapes.contains(.periodComparison),
                "Optional total exposes period comparison: \(metric.id)"
            )
            let recipe = InsightRecipe(
                shape: .periodComparison,
                operands: [operand(for: metric)],
                bucket: .daily
            )
            #expect(
                validation(recipe).issues.contains(.shapeUnsupported(metricID: metric.id)),
                "An optional partial total can be shown as a whole-period total: \(metric.id)"
            )
        }
    }

    @Test func everyProjectedGroupRangeCanReachTheMinimumBucketCount() {
        for metric in descriptors where metric.supportedShapes.contains(.groupComparison) {
            let base = baseRecipe(for: metric, shape: .groupComparison)
            for dimension in InsightCompatibilityEngine.allowedDimensions(
                for: base, descriptors: descriptors
            ) {
                var grouped = base
                grouped.dimension = dimension
                for bucket in InsightCompatibilityEngine.allowedBuckets(
                    for: grouped, descriptors: descriptors
                ) {
                    var bucketed = grouped
                    bucketed.bucket = bucket
                    for range in InsightCompatibilityEngine.allowedRanges(
                        for: bucketed, descriptors: descriptors
                    ) {
                        guard let days = range.days, bucket != .session else { continue }
                        let maximum: Int
                        if dimension == .weekday {
                            maximum = Int(ceil(Double(days) / 7))
                        } else if bucket == .weekly {
                            maximum = Int(ceil(Double(days) / 7)) + 1
                        } else {
                            maximum = days
                        }
                        #expect(
                            maximum >= InsightQueryEngine.groupMinimumBuckets,
                            "Projected group cannot reach minimum: \(metric.id) / \(dimension) / \(bucket) / \(range)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Templates

    @Test func everyTemplateResolvesRequiredPlaceholdersToAValidRecipe() {
        for template in InsightTemplateCatalog.all {
            var recipe = template.recipe
            let unresolved = recipe.operands.compactMap { operand -> InsightScopeKind? in
                guard let required = InsightMetricCatalog.definition(for: operand.metricID)?.requiredScope,
                      !operand.hasScope(required) else { return nil }
                return required
            }
            let distinctScopes = Set(unresolved)
            #expect(distinctScopes.count <= 1, "Template needs more than one launch picker: \(template.id)")
            #expect(template.requiredScopeToPick == unresolved.first)

            if let scope = template.requiredScopeToPick {
                let value = switch scope {
                case .exercise: exerciseA.uuidString
                case .modality: "run"
                case .routine: routineA.uuidString
                }
                recipe = template.resolvedRecipe(scope: scope, value: value)
            }

            let result = validation(recipe)
            #expect(result.isValid, "Template did not resolve: \(template.id): \(result.issues)")
        }

        let paceTemplate = InsightTemplateCatalog.all.first { $0.id == "template.paceVsHeartRate" }
        #expect(paceTemplate?.requiredScopeToPick == .modality)
        if let paceTemplate {
            let paceRecipe = paceTemplate.resolvedRecipe(scope: .modality, value: "run")
            #expect(paceRecipe.operands.allSatisfy { $0.modality == "run" })
            #expect(validation(paceRecipe).isValid)
        }
    }

    // MARK: - Query invariants

    @Test func coverageAndRelationshipSampleCountsRespectStructuralMaximums() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 16, hour: 12)
        ) ?? Date(timeIntervalSinceReferenceDate: 806_000_000)
        let outcome = descriptor("strength.workingSets")
        let exposure = descriptor("strength.reps")
        let rows = (0..<400).map { offset -> InsightObservation in
            let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            return InsightObservation(timestamp: date, value: 1, provenance: .measured)
        }

        for bucket in InsightBucket.allCases {
            for range in InsightRange.allCases {
                var recipe = InsightRecipe(
                    shape: .relationship,
                    operands: [operand(for: outcome), operand(for: exposure)],
                    range: range,
                    bucket: bucket,
                    lag: InsightLag(unit: bucket == .weekly ? .weeks : .days, count: 0)
                )
                let lags = InsightCompatibilityEngine.allowedLags(
                    for: recipe, descriptors: descriptors
                )
                for lag in lags {
                    recipe.lag = lag
                    guard validation(recipe).isValid else { continue }
                    let result = InsightQueryEngine.evaluate(
                        recipe: recipe,
                        descriptors: descriptors,
                        observations: [
                            recipe.operands[0].key: rows,
                            recipe.operands[1].key: rows,
                        ],
                        now: now,
                        calendar: calendar
                    )
                    #expect(result.coverage.populatedBuckets <= result.coverage.expectedBuckets)
                    #expect(result.coverage.fraction <= 1)

                    let structuralMaximum: Int
                    if bucket == .session {
                        structuralMaximum = result.coverage.expectedBuckets
                    } else {
                        structuralMaximum = max(0, result.coverage.expectedBuckets - lag.count)
                    }
                    #expect((result.relationship?.pairs.count ?? 0) <= structuralMaximum)
                    #expect((result.coverage.pairedSamples ?? 0) <= structuralMaximum)
                }
            }
        }
    }
}
