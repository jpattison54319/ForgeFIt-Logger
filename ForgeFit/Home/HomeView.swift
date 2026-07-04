import ForgeCore
import ForgeData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The "Today" landing screen. Leads with a recovery/readiness read (the
/// signal that most reduces "what should I do today?" cognitive load), then
/// this week's training at a glance, quick starts, and recent activity.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var showSettings = false
    @State private var showCoach = false
    @State private var showExploreLibrary = false
    @State private var quickStartEditing = false
    @State private var draggedQuickStartAction: HomeQuickStartAction?
    @State private var showQuickStartAdd = false
    @State private var editingRoutine: RoutineModel?

    let workouts: [WorkoutModel]
    let routines: [RoutineModel]
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]

    // Recovery reports are full-history passes — memoized so the always-alive
    // tab doesn't recompute them on every unrelated re-render.
    @AppStorage("homeQuickStartActions.v1") private var quickStartActionsJSON = ""
    @State private var recoveryMemo = Memo<String, RecoveryEngine.Report>()
    @State private var targetRecoveryMemo = Memo<String, RecoveryEngine.Report>()
    @State private var weekMemo = Memo<String, TrainingAnalytics.WeekTotals>()

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }
    private var recovery: RecoveryEngine.Report {
        recoveryMemo(AnalyticsFingerprint.withHealth(workouts)) {
            RecoveryEngine(workouts: workouts, exercises: exercises, healthMetrics: HealthMetricsStore.shared.metrics).report()
        }
    }
    private var exerciseByID: [UUID: ExerciseLibraryModel] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    private var recentCompleted: [WorkoutModel] {
        workouts.filter { $0.endedAt != nil && $0.deletedAt == nil }.prefix(4).map { $0 }
    }

    private var hasReadinessSignal: Bool {
        workouts.contains { $0.endedAt != nil && $0.deletedAt == nil }
            || !HealthMetricsStore.shared.metrics.isEmpty
    }

    // MARK: - Smart next-workout suggestion

    @AppStorage("activeFolderID") private var activeFolderRaw = ""
    @Query private var allFolders: [RoutineFolderModel]

    /// The active folder plus its whole subtree, so an active macrocycle picks
    /// up routines inside its mesocycle subfolders too.
    private func folderSubtree(rootID: UUID) -> Set<UUID> {
        let live = allFolders.filter { $0.deletedAt == nil }
        var result: Set<UUID> = [rootID]
        var queue = [rootID]
        while let next = queue.popLast() {
            for child in live where child.parentID == next && !result.contains(child.id) {
                result.insert(child.id)
                queue.append(child.id)
            }
        }
        return result
    }

    /// What the app thinks you'll want to train next: rotates through the
    /// active mesocycle folder's routines in order; otherwise rotates through
    /// all routines based on what you performed last.
    private var suggestion: (routine: RoutineModel, reason: String)? {
        let active = routines
            .filter { $0.deletedAt == nil && !$0.exercises.isEmpty }
            .sorted { $0.position < $1.position }
        guard !active.isEmpty else { return nil }

        let folderID = UUID(uuidString: activeFolderRaw)
        let inFolder: [RoutineModel] = folderID.map { id in
            let subtree = folderSubtree(rootID: id)
            return active.filter { r in r.folderID.map(subtree.contains) ?? false }
        } ?? []
        let usingMeso = !inFolder.isEmpty
        let pool = usingMeso ? inFolder : active

        let completed = workouts
            .filter { $0.endedAt != nil && $0.deletedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }

        if let lastDone = completed.first(where: { w in pool.contains { $0.id == w.routineID } }),
           let lastIndex = pool.firstIndex(where: { $0.id == lastDone.routineID }) {
            let next = pool[(lastIndex + 1) % pool.count]
            var reason = usingMeso ? "Next in your mesocycle" : "Up after \(pool[lastIndex].name)"
            if let lastTime = completed.first(where: { $0.routineID == next.id })?.startedAt {
                reason += " · last done \(lastTime.formatted(.relative(presentation: .named)))"
            }
            return (next, reason)
        }
        return (pool[0], usingMeso ? "Start your mesocycle" : "Start your plan")
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(greeting, subtitle: Date().formatted(.dateTime.weekday(.wide).month().day()), trailing: {
                CircleIconButton(systemImage: "sparkles") { showCoach = true }
                    .accessibilityLabel("Open coach")
            }) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if hasReadinessSignal {
                        NavigationLink(value: HomeRoute.recovery) {
                            RecoveryHeroCard(report: recovery)
                        }
                        .buttonStyle(.plain)
                        .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    } else {
                        readinessEmptyState
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }

                    weekCard
                        .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)

                    SectionHeader("Jump back in")
                    if let suggestion {
                        suggestionCard(suggestion.routine, reason: suggestion.reason)
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }
                    quickStart

                    if !recentCompleted.isEmpty {
                        SectionHeader("Recent")
                        ForEach(recentCompleted) { workout in
                            NavigationLink(value: workout) {
                                WorkoutFeedRow(workout: workout, analytics: analytics)
                            }
                            .buttonStyle(.plain)
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if quickStartEditing {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismissQuickStartEdit)
                            .accessibilityHidden(true)
                    }
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .recovery: RecoveryDetailView(workouts: workouts, exercises: exercises)
                }
            }
            .navigationDestination(for: WorkoutModel.self) { workout in
                WorkoutDetailView(workout: workout, exercises: exercises, history: workouts)
            }
            .navigationDestination(item: $editingRoutine) { routine in
                RoutineEditorView(routine: routine, exercises: exercises, setupNotes: setupNotes)
            }
            .toolbar(.hidden, for: .navigationBar)
            // Pull down to re-query Apple Health and recompute readiness.
            .refreshable { await AppRefresh.run(in: modelContext) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showCoach) {
                AICoachChatView(
                    context: AICoachContext.build(
                        workouts: workouts,
                        routines: routines,
                        exercises: exercises,
                        recovery: recovery
                    )
                )
            }
            .sheet(isPresented: $showQuickStartAdd) {
                QuickStartAddSheet(
                    routines: activeRoutines,
                    configuredActions: quickStartActions,
                    onAdd: { action in
                        addQuickStartAction(action)
                        showQuickStartAdd = false
                    },
                    onCreateRoutine: {
                        showQuickStartAdd = false
                        editingRoutine = createRoutine()
                    }
                )
            }
            // Screenshot/UI-test hook, same family as -initialTab (unset in
            // production).
            .onAppear {
                if UserDefaults.standard.bool(forKey: "openSettings") { showSettings = true }
            }
            .sheet(isPresented: $showExploreLibrary) {
                RoutineLibraryView(
                    templates: RoutineTemplateCatalog.validTemplates(from: RoutineTemplateCatalog.load(), exercises: exercises),
                    exercises: exercises,
                    onImport: { template in
                        RoutineTemplateCatalog.importTemplate(template, folderID: UUID(uuidString: activeFolderRaw), existingRoutines: routines, in: modelContext)
                        showExploreLibrary = false
                    }
                )
            }
        }
        .interactiveBackSwipeEnabled()
    }

    private var activeRoutines: [RoutineModel] {
        routines.filter { $0.deletedAt == nil && !$0.exercises.isEmpty }.sorted { $0.position < $1.position }
    }

    private var readinessEmptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 38, height: 38)
                        .background(theme.accentSoft)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready when you are").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("Connect Health or add a starter routine to build your baseline.")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                }
                HStack(spacing: Space.md) {
                    Button("Connect Health") { showSettings = true }
                        .font(.bodyStrong)
                        .buttonStyle(.glassProminent)
                        .tint(theme.accent)
                    Button("Explore starters") { showExploreLibrary = true }
                        .font(.bodyStrong)
                        .buttonStyle(.glass)
                }
                .buttonBorderShape(.capsule)
            }
        }
    }

    private var weekCard: some View {
        let week = weekMemo(AnalyticsFingerprint.of(workouts)) { analytics.thisWeek() }
        return Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text("This week").font(.bodyStrong).foregroundStyle(theme.textSecondary)
                HStack {
                    StatColumn(label: "Workouts", value: "\(week.workoutCount)")
                    StatColumn(label: "Time", value: Fmt.durationShort(week.durationSeconds))
                    StatColumn(label: "Volume", value: Fmt.volume(week.volume))
                    StatColumn(label: "Sets", value: "\(week.sets)")
                }
            }
        }
    }

    private func suggestionCard(_ routine: RoutineModel, reason: String) -> some View {
        let targetReport = targetRecoveryMemo("\(AnalyticsFingerprint.withHealth(workouts))|\(routine.id)|\(routine.updatedAt.timeIntervalSince1970)") {
            RecoveryEngine(
                workouts: workouts,
                exercises: exercises,
                healthMetrics: HealthMetricsStore.shared.metrics,
                targetMuscles: targetMuscles(for: routine)
            ).report()
        }
        return Card {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Up next")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .textCase(.uppercase)
                    Text(routine.name)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text(reason)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: Space.sm) {
                        Image(systemName: targetReport.action.systemImage)
                            .font(.system(size: 11, weight: .bold))
                        Text("For \(routine.name): \(targetReport.preWorkoutAdjustment)")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                    }
                    .foregroundStyle(targetReport.action.tint)
                }
                Spacer(minLength: Space.sm)
                Button {
                    appState.requestStart {
                        _ = WorkoutFactory.start(routine: routine, exercises: exercises, in: modelContext)
                        appState.showingLogger = true
                    }
                } label: {
                    Text("Start")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                .buttonBorderShape(.capsule)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    private func targetMuscles(for routine: RoutineModel) -> [String] {
        var muscles: [String] = []
        for routineExercise in routine.exercises {
            guard let exercise = exerciseByID[routineExercise.exerciseID] else { continue }
            muscles.append(contentsOf: exercise.primaryMuscles)
        }
        var seen = Set<String>()
        return muscles.map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }

    private var quickStart: some View {
        VStack(spacing: Space.md) {
            SecondaryButton(title: "Start Empty Workout", systemImage: "plus") {
                appState.requestStart {
                    _ = WorkoutFactory.startEmpty(in: modelContext)
                    appState.showingLogger = true
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Space.md) {
                    ForEach(quickStartActions) { action in
                        QuickStartTile(
                            title: title(for: action),
                            systemImage: systemImage(for: action),
                            isEditing: quickStartEditing,
                            isDragging: draggedQuickStartAction == action,
                            onTap: { start(action) },
                            onLongPress: { withAnimation(.spring(duration: 0.28)) { quickStartEditing = true } },
                            onRemove: { removeQuickStartAction(action) }
                        )
                        .onDrag {
                            withAnimation(.spring(duration: 0.28)) { quickStartEditing = true }
                            draggedQuickStartAction = action
                            return NSItemProvider(object: action.id as NSString)
                        }
                        .onDrop(
                            of: [UTType.plainText],
                            delegate: QuickStartReorderDropDelegate(
                                target: action,
                                draggedAction: $draggedQuickStartAction,
                                moveAction: reorderQuickStartAction
                            )
                        )
                    }

                    Button {
                        showQuickStartAdd = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 19, weight: .bold))
                            Text("Add")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 104, height: 76)
                        .background(theme.surface.opacity(0.34))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                .stroke(style: StrokeStyle(lineWidth: 1.3, dash: [6, 5]))
                                .foregroundStyle(theme.separator)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            if quickStartEditing {
                Button("Done") {
                    dismissQuickStartEdit()
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var quickStartActions: [HomeQuickStartAction] {
        let decoded = HomeQuickStartAction.decodeList(from: quickStartActionsJSON)
        let actions = decoded.isEmpty ? HomeQuickStartAction.defaults : decoded
        return actions.filter { action in
            switch action.kind {
            case .cardio: true
            case .routine(let id): routines.contains { $0.id == id && $0.deletedAt == nil }
            }
        }
    }

    private func writeQuickStartActions(_ actions: [HomeQuickStartAction]) {
        quickStartActionsJSON = HomeQuickStartAction.encodeList(actions)
    }

    private func dismissQuickStartEdit() {
        guard quickStartEditing else { return }
        draggedQuickStartAction = nil
        withAnimation(.spring(duration: 0.24)) { quickStartEditing = false }
    }

    private func addQuickStartAction(_ action: HomeQuickStartAction) {
        var actions = quickStartActions
        guard !actions.contains(action) else { return }
        actions.append(action)
        writeQuickStartActions(actions)
    }

    private func removeQuickStartAction(_ action: HomeQuickStartAction) {
        let actions = quickStartActions.filter { $0.id != action.id }
        writeQuickStartActions(actions)
    }

    private func reorderQuickStartAction(_ dragged: HomeQuickStartAction, over target: HomeQuickStartAction) {
        var actions = quickStartActions
        guard let from = actions.firstIndex(of: dragged),
              let to = actions.firstIndex(of: target),
              from != to else { return }
        withAnimation(.spring(duration: 0.24)) {
            actions.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            writeQuickStartActions(actions)
        }
    }

    private func start(_ action: HomeQuickStartAction) {
        guard !quickStartEditing else { return }
        appState.requestStart {
            switch action.kind {
            case .cardio(let modality):
                _ = WorkoutFactory.startCardio(modality, exercises: exercises, in: modelContext)
            case .routine(let id):
                guard let routine = routines.first(where: { $0.id == id && $0.deletedAt == nil }) else { return }
                _ = WorkoutFactory.start(routine: routine, exercises: exercises, in: modelContext)
            }
            appState.showingLogger = true
        }
    }

    private func title(for action: HomeQuickStartAction) -> String {
        switch action.kind {
        case .cardio(let modality): modality.title
        case .routine(let id): routines.first { $0.id == id }?.name ?? "Routine"
        }
    }

    private func systemImage(for action: HomeQuickStartAction) -> String {
        switch action.kind {
        case .cardio(let modality): modality.systemImage
        case .routine: "list.bullet.clipboard"
        }
    }

    private func createRoutine() -> RoutineModel {
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "New Routine", position: routines.count)
        modelContext.insert(routine)
        try? modelContext.save()
        addQuickStartAction(.routine(routine.id))
        return routine
    }
}

enum HomeRoute: Hashable { case recovery }

private struct HomeQuickStartAction: Codable, Hashable, Identifiable {
    enum Kind: Hashable {
        case cardio(CardioModality)
        case routine(UUID)
    }

    var kind: Kind

    var id: String {
        switch kind {
        case .cardio(let modality): "cardio:\(modality.rawValue)"
        case .routine(let id): "routine:\(id.uuidString)"
        }
    }

    static let defaults: [HomeQuickStartAction] = [.cardio(.run), .cardio(.cycle), .cardio(.row), .cardio(.walk)]

    static func cardio(_ modality: CardioModality) -> HomeQuickStartAction {
        HomeQuickStartAction(kind: .cardio(modality))
    }

    static func routine(_ id: UUID) -> HomeQuickStartAction {
        HomeQuickStartAction(kind: .routine(id))
    }

    init(kind: Kind) {
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let modalityRaw = raw.removingPrefix("cardio:"),
           let modality = CardioModality(rawValue: modalityRaw) {
            kind = .cardio(modality)
        } else if let idRaw = raw.removingPrefix("routine:"),
                  let id = UUID(uuidString: idRaw) {
            kind = .routine(id)
        } else {
            kind = .cardio(.run)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    static func decodeList(from json: String) -> [HomeQuickStartAction] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([HomeQuickStartAction].self, from: data) else { return [] }
        return decoded
    }

    static func encodeList(_ actions: [HomeQuickStartAction]) -> String {
        guard let data = try? JSONEncoder().encode(actions),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

private extension View {
    func dismissesQuickStartEdit(isEditing: Bool, dismiss: @escaping () -> Void) -> some View {
        overlay {
            if isEditing {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct QuickStartTile: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    let isEditing: Bool
    let isDragging: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onRemove: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isDragging)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = isDragging ? sin(t * 7.0) * 0.9 : (isEditing ? -0.45 : 0)

            ZStack(alignment: .topTrailing) {
                GlassTile(tint: theme.secondaryAccent.opacity(0.12), verticalPadding: Space.md, horizontalPadding: Space.sm) {
                    VStack(spacing: 6) {
                        Image(systemName: systemImage).font(.system(size: 18, weight: .semibold))
                        Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity)
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .onTapGesture { onTap() }
                .onLongPressGesture(minimumDuration: 0.35) { onLongPress() }

                if isEditing {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 24, height: 24)
                            .background(theme.danger)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel("Remove \(title)")
                }
            }
            .rotationEffect(.degrees(angle))
        }
        .frame(width: 104)
        .scaleEffect(isDragging ? 1.03 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.28 : 0), radius: isDragging ? 12 : 0, y: isDragging ? 6 : 0)
        .animation(.easeInOut(duration: 0.18), value: isEditing)
        .animation(.easeInOut(duration: 0.16), value: isDragging)
    }
}

private struct QuickStartReorderDropDelegate: DropDelegate {
    let target: HomeQuickStartAction
    @Binding var draggedAction: HomeQuickStartAction?
    let moveAction: (HomeQuickStartAction, HomeQuickStartAction) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedAction, draggedAction != target else { return }
        moveAction(draggedAction, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedAction = nil
        return true
    }
}

private struct QuickStartAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let routines: [RoutineModel]
    let configuredActions: [HomeQuickStartAction]
    let onAdd: (HomeQuickStartAction) -> Void
    let onCreateRoutine: () -> Void

    private var configuredIDs: Set<String> {
        Set(configuredActions.map(\.id))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    SectionHeader("Presets")
                    VStack(spacing: Space.sm) {
                        presetRow(.run)
                        presetRow(.cycle)
                        presetRow(.row)
                        presetRow(.walk)
                    }

                    SectionHeader("Your Routines")
                    VStack(spacing: Space.sm) {
                        if routines.isEmpty {
                            EmptyStateCard(
                                title: "No routines yet",
                                message: "Create one here and it will be added to Home.",
                                systemImage: "list.bullet.clipboard"
                            )
                        } else {
                            ForEach(routines) { routine in
                                addRow(
                                    title: routine.name,
                                    subtitle: "\(routine.exercises.count) exercises",
                                    systemImage: "list.bullet.clipboard",
                                    isAdded: configuredIDs.contains(HomeQuickStartAction.routine(routine.id).id)
                                ) {
                                    onAdd(.routine(routine.id))
                                }
                            }
                        }
                    }

                    SecondaryButton(title: "Create New Routine", systemImage: "plus") {
                        onCreateRoutine()
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xl)
            }
            .background(theme.background)
            .navigationTitle("Add Quick Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.bodyStrong)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func presetRow(_ modality: CardioModality) -> some View {
        addRow(
            title: modality.title,
            subtitle: "Quick cardio workout",
            systemImage: modality.systemImage,
            isAdded: configuredIDs.contains(HomeQuickStartAction.cardio(modality).id)
        ) {
            onAdd(.cardio(modality))
        }
    }

    private func addRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isAdded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(theme.surfaceElevated)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(isAdded ? theme.success : theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
    }
}

/// The compact readiness card shown on Home.
struct RecoveryHeroCard: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report

    var body: some View {
        Card {
            HStack(spacing: Space.lg) {
                ZStack {
                    ProgressRing(progress: report.displayScore, lineWidth: 10, color: theme.readinessColor(report.displayScore))
                        .frame(width: 76, height: 76)
                    VStack(spacing: 0) {
                        Text("\(Int(report.displayScore * 100))")
                            .font(.system(size: 24, weight: .bold)).foregroundStyle(theme.textPrimary)
                        Text("ready").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Recovery").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                        Image(systemName: report.action.systemImage)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(report.action.tint)
                        Text(report.action.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(report.action.tint)
                    }
                    Text(report.recommendation)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(report.reasonChips.prefix(2)) { chip in
                            Tag(text: chip.text, color: chip.tone.foreground, background: chip.tone.background)
                        }
                        if report.confidence < 0.75 {
                            Tag(text: "Building baseline", color: theme.warmup, background: theme.warmup.opacity(0.14))
                        }
                    }
                }
                Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary)
            }
        }
    }
}

/// A workout row used across Home / Profile feeds.
struct WorkoutFeedRow: View {
    @Environment(\.theme) private var theme
    let workout: WorkoutModel
    let analytics: TrainingAnalytics

    var body: some View {
        let s = analytics.summary(for: workout)
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Image(systemName: s.isCardio ? "figure.run" : "dumbbell.fill")
                        .foregroundStyle(theme.accent)
                        .frame(width: 34, height: 34)
                        .background(theme.surfaceElevated).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workout.title ?? "Workout").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text(workout.startedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                }
                HStack {
                    StatColumn(label: "Time", value: Fmt.durationShort(s.durationSeconds))
                    if s.isCardio {
                        StatColumn(label: "Avg HR", value: Fmt.bpm(s.avgHR))
                    } else {
                        StatColumn(label: "Volume", value: Fmt.volume(s.volume))
                        StatColumn(label: "Sets", value: "\(s.sets)")
                    }
                }
            }
        }
    }
}
