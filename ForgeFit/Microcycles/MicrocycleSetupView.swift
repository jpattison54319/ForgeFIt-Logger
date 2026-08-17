import ForgeData
import SwiftUI

struct MicrocycleSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let folder: RoutineFolderModel
    let routines: [RoutineModel]
    let replacingTrackingName: String?
    let onStart: (Date, Int) throws -> Void

    @State private var startDate: Date
    @State private var durationDays: Int
    @State private var errorMessage: String?

    init(
        folder: RoutineFolderModel,
        routines: [RoutineModel],
        replacingTrackingName: String? = nil,
        onStart: @escaping (Date, Int) throws -> Void
    ) {
        self.folder = folder
        self.routines = routines.sorted { $0.position < $1.position }
        self.replacingTrackingName = replacingTrackingName
        self.onStart = onStart
        _startDate = State(initialValue: .now)
        _durationDays = State(initialValue: folder.defaultMicrocycleLengthDays ?? 7)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if let replacingTrackingName {
                        Card(fill: theme.warmup.opacity(0.12)) {
                            Label(
                                "Starting this tracker stops \(replacingTrackingName). Its history stays saved.",
                                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                            )
                            .font(.subheadline)
                            .foregroundStyle(theme.textPrimary)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            LabeledContent("Day target") {
                                Stepper(
                                    "\(durationDays) days",
                                    value: $durationDays,
                                    in: 1...31
                                )
                                .labelsHidden()
                                .frame(minHeight: TouchTarget.minimum)
                                Text("\(durationDays) days")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                            }
                            Text("Each cycle lasts this many calendar days before the next one begins.")
                                .font(.subheadline)
                                .foregroundStyle(theme.textSecondary)
                            DatePicker(
                                "Start date",
                                selection: $startDate,
                                in: ...Date.now,
                                displayedComponents: .date
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Workouts each cycle")
                            .font(.sectionTitle)
                            .foregroundStyle(theme.textPrimary)
                        Card {
                            VStack(spacing: Space.md) {
                                ForEach(routines) { routine in
                                    HStack(spacing: Space.sm) {
                                        Image(systemName: "circle")
                                            .foregroundStyle(theme.textTertiary)
                                            .accessibilityHidden(true)
                                        Text(routine.name)
                                            .font(.body)
                                            .foregroundStyle(theme.textPrimary)
                                        Spacer()
                                    }
                                }
                            }
                        }
                    }

                    PrimaryButton(title: "Start Tracking", systemImage: "play.fill", action: start)
                        .accessibilityIdentifier("start-microcycle")
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.tabBarClearance)
            }
            .scrollIndicators(.hidden)
            .background(theme.background)
            .navigationTitle(folder.name)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
            .alert("Couldn't start microcycle", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func start() {
        do {
            try onStart(startDate, durationDays)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
