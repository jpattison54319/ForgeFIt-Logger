import ForgeData
import SwiftData
import SwiftUI

/// Profile → Wrapped: every generated report, permanently accessible,
/// grouped by year (yearly report first, then months newest-first).
struct WrappedListView: View {
    @Environment(\.theme) private var theme
    @Query(filter: #Predicate<WrappedReportModel> { $0.deletedAt == nil })
    private var reports: [WrappedReportModel]

    @State private var presentedReport: WrappedReportModel?

    private var byYear: [(year: Int, reports: [WrappedReportModel])] {
        let grouped = Dictionary(grouping: reports, by: \.year)
        return grouped.keys.sorted(by: >).map { year in
            // Yearly recap leads its year, then months newest-first.
            let sorted = (grouped[year] ?? []).sorted { lhs, rhs in
                if lhs.isMonthly != rhs.isMonthly { return !lhs.isMonthly }
                return lhs.month > rhs.month
            }
            return (year, sorted)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                if reports.isEmpty {
                    EmptyStateCard(
                        title: "No reports yet",
                        message: "Your first Monthly Wrapped arrives on the 1st — train this month and it'll have a story to tell.",
                        systemImage: "sparkles"
                    )
                } else {
                    ForEach(byYear, id: \.year) { group in
                        SectionHeader(String(group.year))
                        ForEach(group.reports) { report in
                            row(report)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .navigationTitle("Wrapped")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $presentedReport) { report in
            WrappedStoryView(report: report)
        }
    }

    private func row(_ report: WrappedReportModel) -> some View {
        Button {
            presentedReport = report
        } label: {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: report.isMonthly ? "sparkles" : "trophy.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(report.isMonthly ? theme.accent : theme.warmup)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WrappedReportService.title(for: report))
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(report.isMonthly ? "Monthly report" : "Year in review")
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    if !report.isViewed {
                        Text("NEW")
                            .font(.tag)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(theme.accentSoft)
                            .clipShape(Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
    }
}
