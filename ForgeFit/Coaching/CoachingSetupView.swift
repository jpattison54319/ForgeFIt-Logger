import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Catalog goal vocabulary the setup flow offers — mirrors the `goal` strings
/// authored in `routine_programs.json` exactly, so a selection can either hit
/// an exact program match or produce an honest, explainable fallback.
enum CoachGoalOption: String, CaseIterable, Identifiable {
    case generalFitness = "general fitness"
    case muscleGain = "muscle gain"
    case strength = "strength"
    case hybridFitness = "hybrid fitness"
    case cardioBase = "cardio base"
    case maintenance = "maintenance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .generalFitness: "General Fitness"
        case .muscleGain: "Muscle Gain"
        case .strength: "Strength"
        case .hybridFitness: "Hybrid Fitness"
        case .cardioBase: "Cardio Base"
        case .maintenance: "Maintenance"
        }
    }
}

/// Equipment vocabulary — mirrors the `equipment` strings authored in the
/// catalog JSON exactly (`ProgramMatcher.equipmentSatisfied` compares
/// normalized strings).
enum CoachEquipmentOption: String, CaseIterable, Identifiable {
    case barbell, dumbbell, cable, machine
    case bodyOnly = "body only"
    case outdoor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .barbell: "Barbell"
        case .dumbbell: "Dumbbell"
        case .cable: "Cable"
        case .machine: "Machine"
        case .bodyOnly: "Body Only"
        case .outdoor: "Outdoor"
        }
    }
}

/// Sheet-presentable Coach's Corner setup flow: collects training focus,
/// goal, experience, weekly cadence, session length, and equipment, then
/// shows a program recommendation (exact match, honest fallback, or an
/// honest "nothing fits" state) and confirms it into a coached plan.
///
/// Entry-point wiring (Home / Coach's Corner tab) is Phase 4's job — this
/// view is self-contained and only needs a model context and a sheet
/// presentation to work.
struct CoachingSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    /// Phase 4 hook: called when the lifter chooses "Build my own routine
    /// instead" from the honest none-match state. Nil (the default) just
    /// dismisses the sheet — the caller wires real navigation once the
    /// routine-builder entry point exists.
    var onBuildOwnRoutine: (() -> Void)?
    /// Lets a presenting Coach's Corner dismiss both stacked sheets before
    /// switching tabs. Standalone presentations fall back to local dismissal.
    var onViewWorkout: (() -> Void)?

    @State private var focus: TrainingFocus = .mixed
    @State private var goal: CoachGoalOption = .generalFitness
    @State private var experience: CoachingExperience = .beginner
    @State private var sessionsPerWeek: Int = 3
    @State private var sessionMinutes: Int = 60
    @State private var equipment: Set<String> = []
    @State private var preferredCardio: CardioKind?
    @State private var recommendation: CoachPlanRecommendation?
    @State private var didConfirm = false
    @State private var didPrefill = false

    private static let cardioOptions: [CardioKind] = [.run, .walk, .trailRun, .cycle, .row, .swim]
    private static let sessionLengths = [30, 45, 60, 90]
    private static let sessionCounts = Array(2...6)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                if let recommendation, !didConfirm {
                    recommendationSection(recommendation)
                } else if didConfirm {
                    confirmedSection
                } else {
                    formSection
                }
            }
            .background(theme.background)
            .navigationTitle("Coach's Corner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !didConfirm {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(recommendation == nil ? "Cancel" : "Back") {
                            if recommendation != nil {
                                recommendation = nil
                            } else {
                                dismiss()
                            }
                        }
                    }
                }
            }
            .task { prefillFromProfile() }
        }
    }

    /// Starts the form from the answers the user gave last time (persisted
    /// as `CoachingProfileModel`) instead of resetting to defaults — someone
    /// re-running setup to change programs shouldn't have to re-answer six
    /// questions they already answered.
    private func prefillFromProfile() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let profile = (try? modelContext.fetch(FetchDescriptor<CoachingProfileModel>()))?
            .first(where: { $0.userID == ForgeFitDemo.userID }) else { return }

        if let savedFocus = TrainingFocus(rawValue: profile.focusRaw) { focus = savedFocus }
        if let savedGoal = CoachGoalOption(rawValue: profile.goalRaw) { goal = savedGoal }
        if let savedExperience = profile.experience { experience = savedExperience }
        if Self.sessionCounts.contains(profile.sessionsPerWeek) { sessionsPerWeek = profile.sessionsPerWeek }
        if Self.sessionLengths.contains(profile.sessionMinutes) { sessionMinutes = profile.sessionMinutes }
        equipment = Set(profile.equipment)
        if focus == .cardio || focus == .mixed {
            preferredCardio = profile.preferredCardioRaw.flatMap(CardioKind.init(rawValue:))
        }
    }

    // MARK: - Form

    private var formSection: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Let's build your plan")
                    .font(.screenTitle)
                    .foregroundStyle(theme.textPrimary)
            }

            formGroup(title: "What do you train?") {
                HStack(spacing: Space.sm) {
                    ForEach(TrainingFocus.allCases) { option in
                        focusChip(option)
                    }
                }
            }

            formGroup(title: "What's your goal?") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Space.sm) {
                    ForEach(CoachGoalOption.allCases) { option in
                        selectableChip(title: option.title, isSelected: goal == option) {
                            goal = option
                        }
                    }
                }
            }

            formGroup(title: "Experience") {
                SegmentedPills(options: CoachingExperience.allCases, title: { $0.rawValue.capitalized }, selection: $experience)
            }

            formGroup(title: "Sessions per week") {
                SegmentedPills(options: Self.sessionCounts, title: { "\($0)x" }, selection: $sessionsPerWeek)
            }

            formGroup(title: "Session length") {
                SegmentedPills(options: Self.sessionLengths, title: { "\($0) min" }, selection: $sessionMinutes)
            }

            formGroup(title: "Equipment you have access to") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Space.sm) {
                    ForEach(CoachEquipmentOption.allCases) { option in
                        selectableChip(title: option.title, isSelected: equipment.contains(option.rawValue)) {
                            toggleEquipment(option.rawValue)
                        }
                    }
                }
            }

            if focus == .cardio || focus == .mixed {
                formGroup(title: "Preferred cardio (optional)") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Space.sm) {
                        ForEach(Self.cardioOptions, id: \.self) { kind in
                            selectableChip(title: kind.title, isSelected: preferredCardio == kind) {
                                preferredCardio = preferredCardio == kind ? nil : kind
                            }
                        }
                    }
                }
            }

            PrimaryButton(title: "See my plan", systemImage: "wand.and.stars") {
                recommendation = CoachPlanService.buildPlan(answers: currentAnswers(), in: modelContext)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.xl)
        .padding(.bottom, Space.tabBarClearance)
    }

    private func formGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            content()
        }
    }

    private func focusChip(_ option: TrainingFocus) -> some View {
        let isSelected = focus == option
        return Button {
            focus = option
            if option != .cardio, option != .mixed {
                preferredCardio = nil
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(option.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? theme.accent.opacity(0.14) : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(option.title)\(isSelected ? ", selected" : "")")
    }

    private func selectableChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 10)
            .background(isSelected ? theme.accent.opacity(0.14) : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(title)\(isSelected ? ", selected" : "")")
    }

    private func toggleEquipment(_ raw: String) {
        if equipment.contains(raw) {
            equipment.remove(raw)
        } else {
            equipment.insert(raw)
        }
    }

    private func currentAnswers() -> CoachSetupAnswers {
        CoachSetupAnswers(
            focus: focus,
            goal: goal.rawValue,
            experience: experience,
            sessionsPerWeek: sessionsPerWeek,
            sessionMinutes: sessionMinutes,
            equipment: equipment,
            preferredCardio: preferredCardio?.rawValue
        )
    }

    // MARK: - Recommendation

    @ViewBuilder
    private func recommendationSection(_ recommendation: CoachPlanRecommendation) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            switch recommendation {
            case .program(.exact(let candidate)):
                exactMatchCard(candidate)
            case .program(.fallback(let candidate, let reasons)):
                fallbackCard(candidate, reasons: reasons)
            case .program(.none(let reason)):
                noneCard(reason)
            case .yoga(let sessionsPerWeek):
                yogaCard(sessionsPerWeek: sessionsPerWeek)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.xl)
        .padding(.bottom, Space.tabBarClearance)
    }

    private func exactMatchCard(_ candidate: ProgramCandidate) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This is your plan")
                    .font(.screenTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("Matches everything you told us — goal, level, frequency, and focus.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }
            programCard(candidate)
            PrimaryButton(title: "Start this plan", systemImage: "checkmark.circle.fill") {
                confirm(candidate: candidate)
            }
        }
    }

    private func fallbackCard(_ candidate: ProgramCandidate, reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Closest fit")
                    .font(.screenTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("Nothing in the catalog is an exact match — here's the closest safe option.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }
            programCard(candidate)
            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Why this one")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    ForEach(reasons, id: \.self) { reason in
                        HStack(alignment: .top, spacing: Space.sm) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textTertiary)
                            Text(reason)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
            PrimaryButton(title: "Start this plan", systemImage: "checkmark.circle.fill") {
                confirm(candidate: candidate)
            }
        }
    }

    private func noneCard(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("No bundled program fits")
                    .font(.screenTitle)
                    .foregroundStyle(theme.textPrimary)
            }
            EmptyStateCard(
                title: "Nothing honestly matches",
                message: reason,
                systemImage: "questionmark.folder.fill"
            )
            SecondaryButton(title: "Build my own routine instead", systemImage: "hammer.fill") {
                if let onBuildOwnRoutine {
                    onBuildOwnRoutine()
                } else {
                    dismiss()
                }
            }
        }
    }

    private func yogaCard(sessionsPerWeek: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your yoga target")
                    .font(.screenTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("Yoga isn't a bundled program — the coach sets a weekly session target over your guided flows instead.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }
            Card {
                HStack(spacing: Space.md) {
                    Image(systemName: "figure.yoga")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(sessionsPerWeek)x per week")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Any guided flow")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            PrimaryButton(title: "Set my target", systemImage: "checkmark.circle.fill") {
                CoachPlanService.confirmYogaPlan(answers: currentAnswers(), sessionsPerWeek: sessionsPerWeek, in: modelContext)
                didConfirm = true
            }
        }
    }

    private func programCard(_ candidate: ProgramCandidate) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(candidate.name)
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("\(candidate.level.capitalized) · \(candidate.daysPerWeek)x/week · \(candidate.weeks) weeks")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Text("Goal: \(candidate.goal.capitalized)")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                if !candidate.equipment.isEmpty {
                    HStack(spacing: Space.xs) {
                        ForEach(candidate.equipment, id: \.self) { item in
                            Tag(text: item.capitalized)
                        }
                    }
                }
            }
        }
    }

    private func confirm(candidate: ProgramCandidate) {
        CoachPlanService.confirmPlan(candidate: candidate, answers: currentAnswers(), in: modelContext)
        didConfirm = true
    }

    // MARK: - Confirmed

    private var confirmedSection: some View {
        VStack(spacing: Space.xl) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(theme.success)
            Text("Plan activated")
                .font(.screenTitle)
                .foregroundStyle(theme.textPrimary)
            Text("Your coach is now tracking this plan.")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "View in Workout", systemImage: "dumbbell.fill") {
                if let onViewWorkout {
                    onViewWorkout()
                } else {
                    appState.selectedTab = .workout
                    dismiss()
                }
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.xxl * 2)
    }
}

#Preview("Coaching setup") {
    CoachingSetupView()
        .modelContainer(for: ForgeDataSchema.models, inMemory: true)
        .environment(\.theme, .sageDark)
        .environment(AppState())
}
