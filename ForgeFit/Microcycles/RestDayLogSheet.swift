import SwiftUI

struct RestDayLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let initialDate: Date
    let onLog: (Date) throws -> Void

    @State private var date: Date
    @State private var errorMessage: String?

    init(initialDate: Date = .now, onLog: @escaping (Date) throws -> Void) {
        self.initialDate = initialDate
        self.onLog = onLog
        _date = State(initialValue: min(initialDate, .now))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.lg) {
                Card {
                    DatePicker(
                        "Rest day",
                        selection: $date,
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                }
                PrimaryButton(title: "Log Rest Day", systemImage: "moon.zzz.fill", action: log)
                    .accessibilityIdentifier("confirm-log-rest-day")
                Spacer()
            }
            .padding(Space.lg)
            .background(theme.background)
            .navigationTitle("Log Rest Day")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
            .alert("Couldn't log rest day", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium])
    }

    private func log() {
        do {
            try onLog(date)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
