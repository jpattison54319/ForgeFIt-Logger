import ForgeData
import SwiftUI

/// Explore surface for prebuilt training programs (mesocycles). Each card is a
/// full program — a folder of day routines imported together — rather than a
/// one-off routine.
struct RoutineLibraryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let programs: [RoutineProgramTemplate]
    let templates: [RoutineTemplate]
    let exercises: [ExerciseLibraryModel]
    let onImport: (RoutineProgramTemplate) -> Void

    @State private var selectedGoal: String?
    @State private var selectedLevel: String?
    @State private var selectedEquipment: String?
    @State private var selectedDays: Int?
    @State private var selectedProgram: RoutineProgramTemplate?

    private var filteredPrograms: [RoutineProgramTemplate] {
        programs.filter { program in
            (selectedGoal == nil || program.goal == selectedGoal)
            && (selectedLevel == nil || program.level == selectedLevel)
            && (selectedEquipment == nil || program.equipment.contains(selectedEquipment!))
            && (selectedDays == nil || program.daysPerWeek == selectedDays)
        }
    }

    private var goals: [String] { Array(Set(programs.map(\.goal))).sorted() }
    private var levels: [String] { Array(Set(programs.map(\.level))).sorted() }
    private var equipment: [String] { Array(Set(programs.flatMap(\.equipment))).sorted() }
    private var days: [Int] { Array(Set(programs.map(\.daysPerWeek))).sorted() }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    filterRail

                    if filteredPrograms.isEmpty {
                        EmptyStateCard(
                            title: "No matching programs",
                            message: "Clear a filter to see more training programs.",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    } else {
                        ForEach(filteredPrograms) { program in
                            programCard(program)
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.tabBarClearance)
            }
            .background(theme.background)
            .navigationTitle("Explore Programs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accent)
                }
            }
            .sheet(item: $selectedProgram) { program in
                programDetail(program)
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

    private func programCard(_ program: RoutineProgramTemplate) -> some View {
        let dayNames = program.routines(from: templates).map(\.name)
        return Button {
            selectedProgram = program
        } label: {
            Card(padding: Space.md) {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(program.name)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(program.sessionsPerWeek)x/wk")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }

                    Text(program.description)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !dayNames.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(theme.accent)
                            Text(dayNames.joined(separator: " · "))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(2)
                        }
                    }

                    // The week strip answers "3x/week but 2 routines?" at a
                    // glance — shown whenever days repeat within the week.
                    if let letters = program.scheduleLetters, Set(program.routineIDs).count < letters.count {
                        Text("A typical week: \(letters.joined(separator: " · "))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                    }

                    HStack {
                        pill(program.level.capitalized, systemImage: "chart.bar")
                        pill("\(dayNames.count) day\(dayNames.count == 1 ? "" : "s")", systemImage: "list.bullet")
                        pill(program.goal.capitalized, systemImage: "target")
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func programDetail(_ program: RoutineProgramTemplate) -> some View {
        let dayRoutines = program.routines(from: templates)
        return NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(program.name)
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text(program.description)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            HStack {
                                StatColumn(label: "Goal", value: program.goal.capitalized)
                                StatColumn(label: "Level", value: program.level.capitalized)
                                StatColumn(label: "Sessions", value: "\(program.sessionsPerWeek)x/wk")
                            }
                            if let letters = program.scheduleLetters, Set(program.routineIDs).count < letters.count {
                                Text("A typical week: \(letters.joined(separator: " · ")) — the \(Set(program.routineIDs).count) day routines alternate.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    ForEach(dayRoutines) { routine in
                        VStack(alignment: .leading, spacing: Space.md) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(routine.name)
                                    .font(.sectionTitle)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text("~\(routine.estimatedMinutes) min")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Card {
                                VStack(spacing: Space.md) {
                                    ForEach(Array(routine.exercises.enumerated()), id: \.offset) { index, item in
                                        exercisePreview(item, index: index)
                                        if index != routine.exercises.count - 1 {
                                            Rectangle().fill(theme.separator).frame(height: 0.5)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    PrimaryButton(title: "Add Program to My Routines", systemImage: "folder.badge.plus") {
                        onImport(program)
                    }
                    Text("Adds a \"\(program.name)\" folder with \(dayRoutines.count) routine\(dayRoutines.count == 1 ? "" : "s") to your library.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.tabBarClearance)
            }
            .background(theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { selectedProgram = nil }
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
                            // House rule: exercise names are white, only the
                            // disclosure chevron is sage — via the shared label.
                            ExerciseNameLabel(name: exercise.name, font: .system(size: 15, weight: .semibold))
                                .lineLimit(2)
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
