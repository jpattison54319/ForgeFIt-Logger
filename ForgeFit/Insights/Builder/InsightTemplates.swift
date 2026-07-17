import ForgeCore
import Foundation

/// The smart starting points the builder offers. Each is a plain recipe with
/// a stable template ID; availability gating happens at presentation time
/// (Health-backed templates need authorization + data, exercise-scoped ones
/// need the user to pick the exercise on the way in).
struct InsightTemplate: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let recipe: InsightRecipe

    /// The one unresolved scope choice this template must collect before it
    /// can open a valid canvas. This is derived from metric contracts rather
    /// than duplicated template flags, so future required modality/routine
    /// metrics automatically get the same launch flow.
    var requiredScopeToPick: InsightScopeKind? {
        recipe.operands.compactMap { operand -> InsightScopeKind? in
            guard let required = InsightMetricCatalog.definition(for: operand.metricID)?.requiredScope,
                  !operand.hasScope(required) else { return nil }
            return required
        }.first
    }

    /// Resolves the launch choice across every compatible operand so all
    /// sides of a template ask about the same domain (for example, running
    /// pace and running heart rate).
    func resolvedRecipe(scope: InsightScopeKind, value: String) -> InsightRecipe {
        var resolved = recipe
        resolved.operands = resolved.operands.map { operand in
            guard InsightMetricCatalog.definition(for: operand.metricID)?
                .supportedScopes.contains(scope) == true else { return operand }
            switch scope {
            case .exercise:
                guard let id = UUID(uuidString: value) else { return operand }
                return InsightOperand(metricID: operand.metricID, exerciseID: id)
            case .modality:
                return InsightOperand(metricID: operand.metricID, modality: value)
            case .routine:
                guard let id = UUID(uuidString: value) else { return operand }
                return InsightOperand(metricID: operand.metricID, routineID: id)
            }
        }
        return resolved
    }

    var requiresHealth: Bool {
        recipe.allMetricIDs.contains { InsightMetricCatalog.definition(for: $0)?.requiresHealth == true }
    }
}

enum InsightTemplateCatalog {

    static let all: [InsightTemplate] = [
        InsightTemplate(
            id: "template.sleepVsPerformance",
            title: "Sleep vs same-day training",
            subtitle: "Does a longer night show up in that day's working volume?",
            systemImage: "moon.zzz.fill",
            recipe: InsightRecipe(
                name: "Sleep vs same-day volume",
                templateID: "template.sleepVsPerformance",
                shape: .relationship,
                primaryMetricID: "strength.volume",
                comparisonMetricIDs: ["health.sleepTotal"],
                range: .twelveWeeks,
                bucket: .daily,
                // Sleep is stored on its wake/end day, so that night's sleep
                // and the ensuing training share the same calendar bucket.
                lag: InsightLag(unit: .days, count: 0)
            )
        ),
        InsightTemplate(
            id: "template.hrvVsPerformance",
            title: "HRV vs same-day training",
            subtitle: "Higher overnight HRV against that day's output.",
            systemImage: "waveform.path.ecg",
            recipe: InsightRecipe(
                name: "HRV vs same-day volume",
                templateID: "template.hrvVsPerformance",
                shape: .relationship,
                primaryMetricID: "strength.volume",
                comparisonMetricIDs: ["health.hrv"],
                range: .twelveWeeks,
                bucket: .daily,
                // Nocturnal HRV is attributed to the wake/end day.
                lag: InsightLag(unit: .days, count: 0)
            )
        ),
        InsightTemplate(
            id: "template.readinessVsOutput",
            title: "Readiness vs session output",
            subtitle: "Readiness at workout start against what the session produced.",
            systemImage: "gauge.with.needle",
            recipe: InsightRecipe(
                name: "Readiness vs session volume",
                templateID: "template.readinessVsOutput",
                shape: .relationship,
                primaryMetricID: "strength.volume",
                comparisonMetricIDs: ["health.readiness"],
                range: .twelveWeeks,
                bucket: .session,
                lag: InsightLag(unit: .days, count: 0)
            )
        ),
        InsightTemplate(
            id: "template.tagVsRest",
            title: "Tagged days vs the rest",
            subtitle: "Training volume grouped by check-in state — including the days you didn't train at all.",
            systemImage: "checklist",
            recipe: InsightRecipe(
                name: "Volume by check-in state",
                templateID: "template.tagVsRest",
                shape: .groupComparison,
                primaryMetricID: "strength.volume",
                dimension: .checkinTag,
                range: .twelveWeeks,
                bucket: .daily
            )
        ),
        InsightTemplate(
            id: "template.muscleBalance",
            title: "Chest vs back balance",
            subtitle: "Weekly working sets for chest against back — is your push–pull ratio drifting?",
            systemImage: "figure.strengthtraining.traditional",
            recipe: InsightRecipe(
                name: "Chest vs back sets",
                templateID: "template.muscleBalance",
                shape: .trend,
                primaryMetricID: InsightMetricCatalog.muscleSetsID(for: "chest"),
                comparisonMetricIDs: [InsightMetricCatalog.muscleSetsID(for: "back")],
                range: .twelveWeeks,
                bucket: .weekly
            )
        ),
        InsightTemplate(
            id: "template.bodyweightVsE1RM",
            title: "Body weight vs strength",
            subtitle: "Body weight against estimated 1RM for one exercise.",
            systemImage: "scalemass.fill",
            recipe: InsightRecipe(
                name: "Body weight vs e1RM",
                templateID: "template.bodyweightVsE1RM",
                shape: .relationship,
                primaryMetricID: "strength.e1rm",
                comparisonMetricIDs: ["health.bodyweight"],
                range: .sixMonths,
                bucket: .daily,
                lag: InsightLag(unit: .days, count: 0)
            )
        ),
        InsightTemplate(
            id: "template.volumeVsE1RM",
            title: "Exercise volume vs strength trend",
            subtitle: "One exercise's weekly volume against its following weeks' e1RM.",
            systemImage: "chart.line.uptrend.xyaxis",
            recipe: InsightRecipe(
                name: "Exercise volume vs e1RM",
                templateID: "template.volumeVsE1RM",
                shape: .relationship,
                primaryMetricID: "strength.e1rm",
                comparisonMetricIDs: ["strength.volume"],
                range: .sixMonths,
                bucket: .weekly,
                lag: InsightLag(unit: .weeks, count: 1)
            )
        ),
        InsightTemplate(
            id: "template.paceVsHeartRate",
            title: "Pace vs heart rate",
            subtitle: "One cardio type's pace against its average heart rate.",
            systemImage: "figure.run",
            recipe: InsightRecipe(
                name: "Pace vs heart rate",
                templateID: "template.paceVsHeartRate",
                shape: .relationship,
                primaryMetricID: "cardio.avgHR",
                comparisonMetricIDs: ["cardio.pace"],
                range: .sixMonths,
                bucket: .daily,
                lag: InsightLag(unit: .days, count: 0)
            )
        ),
        InsightTemplate(
            id: "template.cardioVsRecovery",
            title: "Cardio volume vs recovery",
            subtitle: "Weekly cardio duration against the following week's HRV.",
            systemImage: "heart.fill",
            recipe: InsightRecipe(
                name: "Cardio vs next-week HRV",
                templateID: "template.cardioVsRecovery",
                shape: .relationship,
                primaryMetricID: "health.hrv",
                comparisonMetricIDs: ["cardio.duration"],
                range: .sixMonths,
                bucket: .weekly,
                lag: InsightLag(unit: .weeks, count: 1)
            )
        ),
        InsightTemplate(
            id: "template.yogaVsRecovery",
            title: "Yoga vs next-day recovery",
            subtitle: "Yoga minutes against the next day's HRV.",
            systemImage: "figure.yoga",
            recipe: InsightRecipe(
                name: "Yoga vs next-day HRV",
                templateID: "template.yogaVsRecovery",
                shape: .relationship,
                primaryMetricID: "health.hrv",
                comparisonMetricIDs: ["yoga.duration"],
                range: .twelveWeeks,
                bucket: .daily,
                lag: InsightLag(unit: .days, count: 1)
            )
        ),
        InsightTemplate(
            id: "template.checkinVsOutput",
            title: "How you feel vs training",
            subtitle: "Working volume grouped by your check-in tags.",
            systemImage: "face.smiling",
            recipe: InsightRecipe(
                name: "Check-ins vs volume",
                templateID: "template.checkinVsOutput",
                shape: .groupComparison,
                primaryMetricID: "strength.volume",
                dimension: .checkinTag,
                range: .twelveWeeks,
                bucket: .daily
            )
        ),
        InsightTemplate(
            id: "template.fourWeekComparison",
            title: "This month vs last month",
            subtitle: "The last four weeks of training against the four before.",
            systemImage: "calendar",
            recipe: InsightRecipe(
                name: "4 weeks vs previous 4",
                templateID: "template.fourWeekComparison",
                shape: .periodComparison,
                primaryMetricID: "strength.volume",
                comparisonMetricIDs: ["strength.workouts", "cardio.duration"],
                // Period semantics: the range IS the current period, compared
                // against the preceding equal window — 4W means 28 vs 28 days.
                range: .fourWeeks,
                bucket: .daily
            )
        ),
    ]
}
