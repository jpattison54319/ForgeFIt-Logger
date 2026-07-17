import ForgeData
import SwiftData
import SwiftUI

/// The "See all workouts" destination: full history with search, smart
/// filters, sorting, and windowed pagination.
///
/// Performance model: one async index build per workout-history fingerprint
/// (the only pass that faults sets/exercises), then every keystroke, filter,
/// and scroll works on value-type entries — rows never touch the model graph.
/// The list renders a growing window (`pageSize` rows at a time) so a
/// multi-year history mounts a handful of cards, not thousands.
struct WorkoutHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    private static let pageSize = 40

    @State private var index: WorkoutHistoryIndex?
    @State private var query = WorkoutHistoryQuery()
    @State private var searchDraft = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var visibleCount = WorkoutHistoryView.pageSize
    @State private var filteredMemo = Memo<String, [WorkoutHistoryEntry]>()
    @State private var showCustomRange = false
    @State private var customStart = Date()
    @State private var customEnd = Date()

    private var fingerprint: String { AnalyticsFingerprint.of(workouts) }

    private var filtered: [WorkoutHistoryEntry] {
        guard let index else { return [] }
        let key = "\(fingerprint)|\(query.searchText)|\(query.kind.rawValue)|\(query.date.title)|\(query.muscle ?? "")|\(query.exercise?.id.uuidString ?? "")|\(query.source.rawValue)|\(query.prsOnly)|\(query.sort.rawValue)"
        return filteredMemo(key) {
            WorkoutHistoryQueryEngine.apply(query, to: index)
        }
    }

    private var suggestions: [WorkoutHistoryQueryEngine.Suggestion] {
        guard let index, !searchDraft.isEmpty else { return [] }
        return WorkoutHistoryQueryEngine.suggestions(for: searchDraft, index: index, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            DarkTextField(text: $searchDraft, placeholder: "Search exercise, month, notes…")
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
                .accessibilityIdentifier("history-search-field")

            if !suggestions.isEmpty {
                suggestionRows
            }

            filterChips

            content
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .task(id: fingerprint) {
            let built = await WorkoutHistoryIndexer.build(workouts: workouts, exercises: exercises)
            guard !Task.isCancelled else { return }
            index = built
        }
        .onChange(of: searchDraft) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                query.searchText = newValue
            }
        }
        .onChange(of: query) { _, _ in
            visibleCount = Self.pageSize
        }
        .sheet(isPresented: $showCustomRange) { customRangeSheet }
        .navigationDestination(for: UUID.self) { id in
            if let workout = workouts.first(where: { $0.id == id }) {
                WorkoutDetailView(workout: workout, exercises: exercises, history: workouts)
            }
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
            Spacer()
            Text("History").font(.rowValue).foregroundStyle(theme.textPrimary)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
    }

    // MARK: Suggestions

    private var suggestionRows: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    apply(suggestion)
                } label: {
                    suggestionLabel(suggestion)
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if suggestion.id != suggestions.last?.id {
                    Divider().overlay(theme.surfaceElevated)
                }
            }
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .accessibilityIdentifier("history-search-suggestions")
    }

    @ViewBuilder
    private func suggestionLabel(_ suggestion: WorkoutHistoryQueryEngine.Suggestion) -> some View {
        HStack(spacing: Space.md) {
            switch suggestion {
            case .exercise(let facet):
                Image(systemName: "dumbbell").foregroundStyle(theme.accent).frame(width: 22)
                Text(facet.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(facet.count)×").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
            case .muscle(let facet):
                Image(systemName: "figure.arms.open").foregroundStyle(theme.accent).frame(width: 22)
                Text(facet.muscle.capitalized).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Text("muscle").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
            case .month(let facet):
                Image(systemName: "calendar").foregroundStyle(theme.accent).frame(width: 22)
                Text(facet.title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(facet.count) workout\(facet.count == 1 ? "" : "s")").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
            case .prs:
                Image(systemName: "trophy").foregroundStyle(theme.accent).frame(width: 22)
                Text("Workouts with PRs").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
            }
        }
    }

    private func apply(_ suggestion: WorkoutHistoryQueryEngine.Suggestion) {
        switch suggestion {
        case .exercise(let facet): query.exercise = facet
        case .muscle(let facet): query.muscle = facet.muscle
        case .month(let facet): query.date = .month(title: facet.title, interval: facet.interval)
        case .prs: query.prsOnly = true
        }
        debounceTask?.cancel()
        searchDraft = ""
        query.searchText = ""
    }

    // MARK: Filter chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    // Clear leads the row while anything is active: undoing a
                    // filter must never require scrolling to the row's far end.
                    if query.hasActiveFilters {
                        Button {
                            clearFilters()
                        } label: {
                            FilterChip(title: "Clear", active: false, systemImage: "xmark")
                        }
                        .accessibilityIdentifier("history-clear-filters")
                    }
                    sortChip
                    kindChip
                    dateChip
                    muscleChip
                    if let exercise = query.exercise {
                        Button {
                            query.exercise = nil
                        } label: {
                            FilterChip(title: exercise.name, active: true, systemImage: "xmark")
                        }
                        .accessibilityIdentifier("history-filter-exercise-clear")
                    }
                    Button {
                        query.prsOnly.toggle()
                    } label: {
                        FilterChip(title: "PRs", active: query.prsOnly, systemImage: "trophy")
                    }
                    .accessibilityIdentifier("history-filter-prs")
                    sourceChip
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
        }
        .accessibilityIdentifier("history-filter-row")
    }

    private var sortChip: some View {
        Menu {
            Picker("Sort", selection: $query.sort) {
                ForEach(WorkoutHistoryQuery.Sort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
        } label: {
            FilterChip(
                title: query.sort == .recent ? "Sort" : query.sort.title,
                active: query.sort != .recent,
                systemImage: "arrow.up.arrow.down"
            )
        }
        .accessibilityIdentifier("history-sort-menu")
    }

    private var kindChip: some View {
        Menu {
            ForEach(WorkoutHistoryQuery.KindFilter.allCases, id: \.self) { kind in
                Button(kind == .all ? "All types" : kind.title) { query.kind = kind }
            }
        } label: {
            FilterChip(title: query.kind.title, active: query.kind != .all, systemImage: "figure.run.square.stack")
        }
        .accessibilityIdentifier("history-filter-type")
    }

    private var dateChip: some View {
        Menu {
            Button("Any date") { query.date = .all }
            Button("Last 7 days") { query.date = .last7Days }
            Button("Last 30 days") { query.date = .last30Days }
            Button("Last 90 days") { query.date = .last90Days }
            Button("This year") { query.date = .thisYear }
            Button("Custom range…") {
                if case .custom(let start, let end) = query.date {
                    customStart = start
                    customEnd = end
                } else {
                    customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
                    customEnd = Date()
                }
                showCustomRange = true
            }
        } label: {
            FilterChip(title: query.date.title, active: query.date != .all, systemImage: "calendar")
        }
        .accessibilityIdentifier("history-filter-date")
    }

    private var muscleChip: some View {
        Menu {
            Button("All muscles") { query.muscle = nil }
            ForEach(index?.muscles ?? []) { facet in
                Button("\(facet.muscle.capitalized) (\(facet.count))") { query.muscle = facet.muscle }
            }
        } label: {
            FilterChip(title: query.muscle?.capitalized ?? "Muscle", active: query.muscle != nil, systemImage: "figure.arms.open")
        }
        .accessibilityIdentifier("history-filter-muscle")
    }

    private var sourceChip: some View {
        Menu {
            Button("All sources") { query.source = .all }
            Button("Logged in ForgeFit") { query.source = .logged }
            Button("Imported") { query.source = .imported }
        } label: {
            FilterChip(title: query.source.title, active: query.source != .all, systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("history-filter-source")
    }

    private func clearFilters() {
        let sort = query.sort
        query = WorkoutHistoryQuery(sort: sort)
        debounceTask?.cancel()
        searchDraft = ""
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if index == nil {
            Spacer()
            ProgressView("Loading history…")
                .tint(theme.accent)
            Spacer()
        } else if index?.entries.isEmpty == true {
            ScrollView(showsIndicators: false) {
                EmptyStateCard(
                    title: "No workouts yet",
                    message: "Your completed sessions will show up here.",
                    systemImage: "dumbbell"
                )
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
            }
        } else if filtered.isEmpty {
            noResults
        } else {
            list
        }
    }

    private var noResults: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: Space.lg) {
                EmptyStateCard(
                    title: "No workouts match",
                    message: "Nothing in your history matches this search and the active filters.",
                    systemImage: "magnifyingglass"
                )
                SecondaryButton(title: "Clear search & filters") {
                    clearFilters()
                }
                .accessibilityIdentifier("history-clear-from-empty")
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
        }
    }

    private var list: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text("\(filtered.count) workout\(filtered.count == 1 ? "" : "s")")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .padding(.top, Space.xs)

                if query.sort.isChronological {
                    ForEach(visibleSections, id: \.month) { section in
                        Text(section.month)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textSecondary)
                            .padding(.top, Space.sm)
                        ForEach(section.items) { entry in
                            row(entry)
                        }
                    }
                } else {
                    ForEach(visibleEntries) { entry in
                        row(entry)
                    }
                }

                if visibleCount < filtered.count {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.md)
                        .onAppear { visibleCount += Self.pageSize }
                        .accessibilityIdentifier("history-load-more")
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        // Scrolling results means the user is done typing — drop the keyboard
        // and give the rows the full viewport.
        .scrollDismissesKeyboard(.immediately)
    }

    private var visibleEntries: ArraySlice<WorkoutHistoryEntry> {
        filtered.prefix(visibleCount)
    }

    private var visibleSections: [(month: String, items: [WorkoutHistoryEntry])] {
        var order: [String] = []
        var map: [String: [WorkoutHistoryEntry]] = [:]
        for entry in visibleEntries {
            if map[entry.monthKey] == nil {
                order.append(entry.monthKey)
                map[entry.monthKey] = []
            }
            map[entry.monthKey]?.append(entry)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func row(_ entry: WorkoutHistoryEntry) -> some View {
        NavigationLink(value: entry.id) {
            WorkoutHistoryRow(entry: entry, showsYear: !query.sort.isChronological)
        }
        .buttonStyle(.plain)
    }

    // MARK: Custom range sheet

    private var customRangeSheet: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Custom range").font(.rowValue).foregroundStyle(theme.textPrimary)
            DatePicker("From", selection: $customStart, in: ...customEnd, displayedComponents: .date)
            DatePicker("To", selection: $customEnd, in: customStart..., displayedComponents: .date)
            PrimaryButton(title: "Apply") {
                query.date = .custom(start: customStart, end: customEnd)
                showCustomRange = false
            }
            SecondaryButton(title: "Cancel") { showCustomRange = false }
        }
        .padding(Space.lg)
        .presentationDetents([.medium])
        .presentationBackground(theme.background)
    }
}

/// One history row rendered purely from the prebuilt index entry — scrolling
/// never faults a workout's sets. Mirrors `WorkoutFeedRow`'s layout so the
/// feed and the full history read as one surface.
private struct WorkoutHistoryRow: View {
    @Environment(\.theme) private var theme
    let entry: WorkoutHistoryEntry
    let showsYear: Bool

    private var dateText: String {
        showsYear
            ? entry.startedAt.formatted(date: .abbreviated, time: .omitted)
            : entry.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Image(systemName: entry.kindSystemImage)
                        .foregroundStyle(theme.accent)
                        .frame(width: 34, height: 34)
                        .background(theme.surfaceElevated).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(entry.title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            if entry.prCount > 0 {
                                Tag(text: entry.prCount == 1 ? "PR" : "\(entry.prCount) PRs", color: theme.warmup, background: theme.warmup.opacity(0.15))
                            }
                            if entry.isImported {
                                Tag(text: "Imported", color: theme.textTertiary, background: theme.surfaceElevated)
                            }
                        }
                        Text(dateText)
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                }
                HStack {
                    StatColumn(label: "Time", value: Fmt.durationShort(entry.durationSeconds))
                    if entry.kind == .cardio || entry.kind == .yoga {
                        StatColumn(label: "Avg HR", value: Fmt.bpm(entry.avgHR))
                    } else {
                        StatColumn(label: "Volume", value: Fmt.volume(entry.volume))
                        StatColumn(label: "Sets", value: Fmt.sets(entry.effectiveSets))
                    }
                }
            }
        }
        .accessibilityIdentifier("history-workout-\(entry.title)")
    }
}
