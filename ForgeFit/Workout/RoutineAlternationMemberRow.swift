import ForgeData
import SwiftUI

struct RoutineAlternationMemberRow: View {
    @Environment(\.theme) private var theme

    let routine: RoutineModel?
    let fallbackName: String
    let location: String
    let position: Int
    let memberCount: Int
    let isNext: Bool
    let allowsRemoval: Bool
    let removalStopsAlternation: Bool
    let onRemove: () -> Void
    let onStopAlternating: () -> Void

    @State private var showingStopConfirmation = false

    private var name: String {
        routine?.name ?? fallbackName
    }

    private var isUnavailable: Bool {
        guard let routine else { return true }
        return routine.deletedAt != nil || routine.archivedAt != nil
    }

    private var status: String {
        let parts = [
            isNext ? "Next" : nil,
            "Position \(position) of \(memberCount)",
            location
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            label
                .accessibilityIdentifier(memberAccessibilityIdentifier)

            if allowsRemoval {
                Button(
                    "Remove \(name) from cycle",
                    systemImage: "minus.circle",
                    role: .destructive
                ) {
                    if removalStopsAlternation {
                        showingStopConfirmation = true
                    } else {
                        onRemove()
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(theme.danger)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .accessibilityIdentifier("remove-alternation-member-\(routine?.id.uuidString ?? fallbackName)")
                .accessibilityHint(memberCount <= 2
                    ? "Stops alternating. The routines stay in your library."
                    : "The routine stays in your library.")
                .confirmationDialog(
                    "Stop alternating these routines?",
                    isPresented: $showingStopConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Stop Alternating", role: .destructive, action: onStopAlternating)
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("The routines stay in your library and remain available to start.")
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .listRowBackground(theme.background)
    }

    private var memberAccessibilityIdentifier: String {
        "alternation-member-\(routine?.id.uuidString ?? fallbackName)"
    }

    private var label: some View {
        HStack(spacing: Space.md) {
            Text("\(position)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(isNext ? theme.accent : theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 32, height: 32)
                .background(
                    isNext ? theme.accentSoft : theme.surfaceElevated,
                    in: Circle()
                )
                .accessibilityHidden(true)

            Text(name)
                .font(.bodyStrong)
                .foregroundStyle(isUnavailable ? theme.textSecondary : theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isNext {
                Tag(
                    text: "NEXT",
                    color: theme.accent,
                    background: theme.accentSoft
                )
                .accessibilityHidden(true)
            } else if isUnavailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.danger)
                    .frame(minWidth: 24, minHeight: 44)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(status)
        .accessibilityHint(routine == nil ? "This routine is unavailable." : "")
    }
}
