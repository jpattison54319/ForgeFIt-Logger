import ForgeData
import SwiftUI

struct RoutineLibraryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let templates: [RoutineTemplate]
    let exercises: [ExerciseLibraryModel]
    let onImport: (RoutineTemplate) -> Void

    @State private var selectedGoal: String?
    @State private var selectedLevel: String?
    @State private var selectedEquipment: String?
    @State private var selectedDays: Int?
    @State private var selectedTemplate: RoutineTemplate?

    private var filteredTemplates: [RoutineTemplate] {
        templates.filter { template in
            (selectedGoal == nil || template.goal == selectedGoal)
            && (selectedLevel == nil || template.level == selectedLevel)
            && (selectedEquipment == nil || template.equipment.contains(selectedEquipment!))
            && (selectedDays == nil || template.daysPerWeek == selectedDays)
        }
    }

    private var goals: [String] { Array(Set(templates.map(\.goal))).sorted() }
    private var levels: [String] { Array(Set(templates.map(\.level))).sorted() }
    private var equipment: [String] { Array(Set(templates.flatMap(\.equipment))).sorted() }
    private var days: [Int] { Array(Set(templates.map(\.daysPerWeek))).sorted() }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    filterRail

                    if filteredTemplates.isEmpty {
                        EmptyStateCard(
                            title: "No matching templates",
                            message: "Clear a filter to see more routines.",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    } else {
                        ForEach(filteredTemplates) { template in
                            templateCard(template)
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.tabBarClearance)
            }
            .background(theme.background)
            .navigationTitle("Explore Routines")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accent)
                }
            }
            .sheet(item: $selectedTemplate) { template in
                templateDetail(template)
            }
        }
    }

    private var filterRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                Menu {
                    Button("Any Goal") { selectedGoal = nil }
                    ForEach(goals, id: \.self) { goal in Button(goal.capitalized) { selectedGoal = goal } }
                } label: {
                    FilterChip(title: selectedGoal?.capitalized ?? "Goal", active: selectedGoal != nil, systemImage: "target")
                }

                Menu {
                    Button("Any Level") { selectedLevel = nil }
                    ForEach(levels, id: \.self) { level in Button(level.capitalized) { selectedLevel = level } }
                } label: {
                    FilterChip(title: selectedLevel?.capitalized ?? "Level", active: selectedLevel != nil, systemImage: "chart.bar")
                }

                Menu {
                    Button("Any Equipment") { selectedEquipment = nil }
                    ForEach(equipment, id: \.self) { item in Button(item.capitalized) { selectedEquipment = item } }
                } label: {
                    FilterChip(title: selectedEquipment?.capitalized ?? "Equipment", active: selectedEquipment != nil, systemImage: "dumbbell")
                }

                Menu {
                    Button("Any Schedule") { selectedDays = nil }
                    ForEach(days, id: \.self) { day in Button("\(day)x/week") { selectedDays = day } }
                } label: {
                    FilterChip(title: selectedDays.map { "\($0)x/week" } ?? "Days", active: selectedDays != nil, systemImage: "calendar")
                }

                if selectedGoal != nil || selectedLevel != nil || selectedEquipment != nil || selectedDays != nil {
                    Button {
                        selectedGoal = nil
                        selectedLevel = nil
                        selectedEquipment = nil
                        selectedDays = nil
                    } label: {
                        FilterChip(title: "Clear", active: false, systemImage: "xmark")
                    }
                }
            }
        }
    }

    private func templateCard(_ template: RoutineTemplate) -> some View {
        Button {
            selectedTemplate = template
        } label: {
            Card(padding: Space.md) {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(template.name)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(template.daysPerWeek)x/wk")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }

                    Text(template.description)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        pill(template.level.capitalized, systemImage: "chart.bar")
                        pill("\(template.estimatedMinutes) min", systemImage: "clock")
                        pill(template.goal.capitalized, systemImage: "target")
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func templateDetail(_ template: RoutineTemplate) -> some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(template.name)
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text(template.description)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Card {
                        HStack {
                            StatColumn(label: "Goal", value: template.goal.capitalized)
                            StatColumn(label: "Level", value: template.level.capitalized)
                            StatColumn(label: "Time", value: "\(template.estimatedMinutes)m")
                        }
                    }

                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("Exercises")
                            .font(.sectionTitle)
                            .foregroundStyle(theme.textPrimary)
                        Card {
                            VStack(spacing: Space.md) {
                                ForEach(Array(template.exercises.enumerated()), id: \.offset) { index, item in
                                    exercisePreview(item, index: index)
                                    if index != template.exercises.count - 1 {
                                        Rectangle().fill(theme.separator).frame(height: 0.5)
                                    }
                                }
                            }
                        }
                    }

                    PrimaryButton(title: "Add to My Routines", systemImage: "plus") {
                        onImport(template)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.tabBarClearance)
            }
            .background(theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { selectedTemplate = nil }
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accent)
                }
            }
            .navigationDestination(for: UUID.self) { exerciseID in
                ExerciseDetailView(exerciseID: exerciseID, workouts: [], exercises: exercises)
            }
        }
    }

    private func exercisePreview(_ item: RoutineTemplateExercise, index: Int) -> some View {
        let exercise = exercise(for: item.slug)
        return HStack(spacing: Space.md) {
            if let exercise {
                ExerciseThumbnail(exercise: exercise, size: 42)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let exercise {
                        NavigationLink(value: exercise.id) {
                            HStack(spacing: 4) {
                                Text(exercise.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(2)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(item.slug.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(2)
                    }
                    if let group = item.supersetGroup {
                        SupersetChip(group: group)
                    }
                }
                Text(targetText(item))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
        }
    }

    private func exercise(for slug: String) -> ExerciseLibraryModel? {
        let id = ExerciseCatalog.deterministicID(for: slug)
        return exercises.first { $0.id == id }
    }

    private func targetText(_ item: RoutineTemplateExercise) -> String {
        if let duration = item.durationSeconds {
            return "\(item.sets) set\(item.sets == 1 ? "" : "s") · \(Fmt.durationShort(duration))"
        }
        let reps = [item.repsLow, item.repsHigh].compactMap { $0 }
        let repText = reps.count == 2 ? "\(reps[0])-\(reps[1]) reps" : reps.first.map { "\($0) reps" } ?? "reps"
        let effort = item.rpe.map { " · RPE \(Int($0))" } ?? ""
        return "\(item.sets) set\(item.sets == 1 ? "" : "s") · \(repText)\(effort)"
    }

    private func pill(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.surfaceElevated)
        .clipShape(Capsule())
    }
}
