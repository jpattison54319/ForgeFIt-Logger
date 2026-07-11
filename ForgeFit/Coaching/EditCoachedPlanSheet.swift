import ForgeData
import SwiftData
import SwiftUI

/// Edit sheet for the active coached plan: weekly session target and program
/// length, changeable at any point mid-program. Nothing else about the plan
/// (folder, routines, start date) is touched — this is a dial, not a rebuild.
struct EditCoachedPlanSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let program: CoachedProgramModel
    let programName: String

    @State private var sessionsPerWeek: Int
    @State private var isOpenEnded: Bool
    @State private var weeks: Int

    /// The week the program is currently in — the floor for `weeks`, so an
    /// edit can end the plan this week but never rewrite it into the past
    /// (which would make "Week X of N" read X > N).
    private let currentWeek: Int
    /// Never below `currentWeek`, so the stepper range stays valid even for
    /// an open-ended plan that has been running longer than a year.
    private let maxWeeks: Int

    init(program: CoachedProgramModel, programName: String) {
        self.program = program
        self.programName = programName
        let week = CoachPlanService.currentWeek(of: program)
        currentWeek = week
        maxWeeks = max(52, week)
        _sessionsPerWeek = State(initialValue: min(max(program.weeklySessionTarget, 2), 6))
        _isOpenEnded = State(initialValue: program.weeks == 0)
        _weeks = State(initialValue: program.weeks > 0 ? max(program.weeks, week) : max(week, 8))
    }

    private static let sessionCounts = Array(2...6)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(programName)
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Adjust the plan without restarting it — your routines, history, and progress all stay put.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Sessions per week")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        SegmentedPills(options: Self.sessionCounts, title: { "\($0)x" }, selection: $sessionsPerWeek)
                    }

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Program length")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Card {
                            VStack(alignment: .leading, spacing: Space.md) {
                                Toggle(isOn: $isOpenEnded.animation(.easeOut(duration: 0.15))) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Open-ended")
                                            .font(.bodyStrong)
                                            .foregroundStyle(theme.textPrimary)
                                        Text("No fixed end — the coach just tracks the weekly target.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(theme.textSecondary)
                                    }
                                }
                                .tint(theme.accent)

                                if !isOpenEnded {
                                    Divider().overlay(theme.separator)
                                    Stepper(value: $weeks, in: currentWeek...maxWeeks) {
                                        Text("\(weeks) \(weeks == 1 ? "week" : "weeks")")
                                            .font(.bodyStrong)
                                            .foregroundStyle(theme.textPrimary)
                                            .contentTransition(.numericText())
                                            .animation(.easeOut(duration: 0.15), value: weeks)
                                    }
                                    .accessibilityIdentifier("coach-edit-plan-weeks-stepper")
                                    Text(lengthFootnote)
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    PrimaryButton(title: "Save Changes", systemImage: "checkmark.circle.fill") {
                        CoachPlanService.updatePlan(
                            program,
                            weeks: isOpenEnded ? 0 : weeks,
                            weeklySessionTarget: sessionsPerWeek,
                            in: modelContext
                        )
                        dismiss()
                    }
                    .accessibilityIdentifier("coach-edit-plan-save")
                }
                .padding(Space.xl)
            }
            .background(theme.background)
            .navigationTitle("Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Honest footnote about what the chosen length means from where the
    /// program stands today (currently in week `currentWeek`).
    private var lengthFootnote: String {
        if weeks == currentWeek {
            return "You're in week \(currentWeek) now — the program will finish at the end of this week."
        }
        return "You're in week \(currentWeek) now, so \(weeks - currentWeek + 1) \(weeks - currentWeek + 1 == 1 ? "week" : "weeks") remain including this one."
    }
}
