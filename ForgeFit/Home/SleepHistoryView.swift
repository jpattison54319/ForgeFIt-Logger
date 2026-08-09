import SwiftUI

struct SleepHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var history = SleepHistoryStore.shared
    @State private var health = HealthMetricsStore.shared
    @State private var searchText = ""
    @State private var selectedDate: Date?
    @State private var pickerDate = Date.now
    @State private var showingDatePicker = false

    private var filteredNights: [RecoveryEngine.DailyHealthMetric] {
        SleepHistorySupport.filtered(
            history.nights,
            searchText: searchText,
            selectedDate: selectedDate
        )
    }

    private var sections: [SleepHistorySupport.MonthSection] {
        SleepHistorySupport.sections(for: filteredNights)
    }

    var body: some View {
        VStack(spacing: 0) {
            SleepHistoryHeader(
                hasDateFilter: selectedDate != nil,
                dismiss: dismiss,
                showDatePicker: showDatePicker
            )
            SleepHistorySearchBar(searchText: $searchText)
            if let selectedDate {
                SleepHistoryDateFilter(date: selectedDate, clear: clearDateFilter)
            }
            SleepHistoryContent(
                isLoading: history.isLoading && !history.hasLoaded,
                hasAnyHistory: !history.nights.isEmpty,
                searchText: searchText,
                selectedDate: selectedDate,
                sections: sections,
                clearFilters: clearFilters
            )
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .task { await history.load(recentMetrics: health.metrics) }
        .sheet(isPresented: $showingDatePicker) {
            SleepHistoryDatePicker(
                selection: $pickerDate,
                earliestDate: history.nights.last?.date,
                apply: applyDateFilter
            )
        }
        .accessibilityIdentifier("sleep-history")
    }

    private func showDatePicker() {
        pickerDate = selectedDate ?? history.nights.first?.date ?? .now
        showingDatePicker = true
    }

    private func applyDateFilter() {
        selectedDate = pickerDate
        showingDatePicker = false
    }

    private func clearDateFilter() {
        selectedDate = nil
    }

    private func clearFilters() {
        searchText = ""
        selectedDate = nil
    }
}

private struct SleepHistoryHeader: View {
    @Environment(\.theme) private var theme
    let hasDateFilter: Bool
    let dismiss: DismissAction
    let showDatePicker: () -> Void

    var body: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back", action: dismiss.callAsFunction)
            Spacer()
            Text("Sleep history")
                .font(.rowValue)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            CircleIconButton(
                systemImage: hasDateFilter ? "calendar.badge.checkmark" : "calendar",
                label: "Choose date",
                action: showDatePicker
            )
            .accessibilityIdentifier("sleep-history-date-picker")
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
    }
}

private struct SleepHistorySearchBar: View {
    @Binding var searchText: String

    var body: some View {
        DarkTextField(
            text: $searchText,
            placeholder: "Search month, day, or year",
            accessibilityIdentifier: "sleep-history-search"
        )
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
    }
}

private struct SleepHistoryDateFilter: View {
    @Environment(\.theme) private var theme
    let date: Date
    let clear: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Label(date.formatted(date: .long, time: .omitted), systemImage: "calendar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button("Clear date", systemImage: "xmark", action: clear)
                .labelStyle(.iconOnly)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, height: 44)
        }
        .padding(.leading, Space.md)
        .background(theme.surfaceElevated)
        .clipShape(.capsule)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .accessibilityIdentifier("sleep-history-date-filter")
    }
}

private struct SleepHistoryContent: View {
    @Environment(\.theme) private var theme
    let isLoading: Bool
    let hasAnyHistory: Bool
    let searchText: String
    let selectedDate: Date?
    let sections: [SleepHistorySupport.MonthSection]
    let clearFilters: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.md) {
                if isLoading {
                    ProgressView("Loading sleep history")
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.xxl)
                } else if sections.isEmpty {
                    emptyState
                } else {
                    ForEach(sections) { section in
                        SectionHeader(section.title)
                        ForEach(section.nights, id: \.date) { metric in
                            SleepHistoryRow(metric: metric)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
            .padding(.bottom, Space.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty || selectedDate != nil {
            EmptyStateCard(
                title: selectedDate.map { "No sleep on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "No matching nights",
                message: "Try another date or clear the current filters.",
                systemImage: "calendar.badge.exclamationmark"
            )
            SecondaryButton(title: "Clear Filters", systemImage: "xmark", action: clearFilters)
                .accessibilityIdentifier("sleep-history-clear-filters")
        } else if !hasAnyHistory {
            EmptyStateCard(
                title: "No sleep history available",
                message: "Sleep recorded in Apple Health will appear here.",
                systemImage: "moon.zzz"
            )
        }
    }
}

private struct SleepHistoryRow: View {
    @Environment(\.theme) private var theme
    let metric: RecoveryEngine.DailyHealthMetric

    var body: some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: metric.sleepUserCorrected ? "pencil" : "moon.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12))
                    .clipShape(.circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    if let detail = metric.sleepOverrideStatus?.detailPrefix {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer(minLength: Space.sm)
                Text(SleepMetricPresentation.value(for: metric))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        if metric.sleepOverrideStatus == .notTracked { theme.textTertiary }
        else if metric.sleepLikelyPartial && !metric.sleepUserCorrected { theme.warmup }
        else { theme.zone2 }
    }
}

private struct SleepHistoryDatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Binding var selection: Date
    let earliestDate: Date?
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Choose a night")
                .font(.rowValue)
                .foregroundStyle(theme.textPrimary)
            DatePicker(
                "Sleep date",
                selection: $selection,
                in: (earliestDate ?? .distantPast)...Date.now,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            PrimaryButton(title: "Show Night", action: apply)
            SecondaryButton(title: "Cancel", action: dismiss.callAsFunction)
        }
        .padding(Space.lg)
        .presentationDetents([.large])
        .presentationBackground(theme.background)
    }
}
