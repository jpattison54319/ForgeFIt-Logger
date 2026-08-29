import ForgeCore
import SwiftUI

struct MicrocyclePlannedRestDayRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingLogConfirmation = false
    @State private var showingOptions = false

    let restDay: MicrocyclePlanProgress.PlannedRestDay
    let position: Int
    let itemCount: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canLogToday: Bool
    let isDragging: Bool
    let onLogToday: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void
    let onDragStarted: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: restDay.isCompleted ? "checkmark.circle.fill" : "moon.zzz")
                .font(.headline)
                .foregroundStyle(restDay.isCompleted ? theme.accent : theme.textSecondary)
                .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Rest Day")
                    .font(.body)
                    .foregroundStyle(restDay.isCompleted ? theme.textSecondary : theme.textPrimary)
                    .accessibilityIdentifier("planned-rest-title-\(restDay.id.uuidString)")
                    .accessibilityValue("Position \(position) of \(itemCount)")
                if let completedAt = restDay.completedAt {
                    Text("Logged \(completedAt.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption)
                        .foregroundStyle(theme.textTertiary)
                } else {
                    Text("Planned")
                        .font(.caption)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Rest day, \(restDay.isCompleted ? "logged" : "planned")")
            .frame(maxWidth: .infinity, alignment: .leading)

            if !restDay.isCompleted {
                Button {
                    showingLogConfirmation = true
                } label: {
                    MicrocycleCompactPrimaryActionLabel(title: "Log")
                }
                .buttonStyle(.plain)
                .disabled(!canLogToday)
                .accessibilityLabel("Log rest today")
                .accessibilityIdentifier("microcycle-log-planned-rest-\(restDay.id.uuidString)")
                .alert(
                    "Log today as a rest day?",
                    isPresented: $showingLogConfirmation
                ) {
                    Button("Cancel", role: .cancel) { }
                    Button("Log Rest Day", action: onLogToday)
                } message: {
                    Text("This marks today as rest and completes this planned rest slot.")
                }
            }

            Image(systemName: "line.3.horizontal")
                .font(.bodyStrong)
                .foregroundStyle(theme.textSecondary)
                .minimumTouchTarget()
                .accessibilityHidden(true)

            Button {
                showingOptions = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.accent)
                    .minimumTouchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rest day options")
            .accessibilityIdentifier("planned-rest-options-\(restDay.id.uuidString)")
            .confirmationDialog(
                "Rest Day Options",
                isPresented: $showingOptions,
                titleVisibility: .visible
            ) {
                Button("Move Up", systemImage: "arrow.up", action: onMoveUp)
                    .disabled(!canMoveUp)
                Button("Move Down", systemImage: "arrow.down", action: onMoveDown)
                    .disabled(!canMoveDown)
                Button("Remove Rest Day", systemImage: "trash", role: .destructive, action: onRemove)
                Button("Cancel", role: .cancel) { }
            }
        }
        .frame(minHeight: TouchTarget.minimum)
        .contentShape(Rectangle())
        .onDrag {
            onDragStarted()
            return NSItemProvider(object: restDay.id.uuidString as NSString)
        } preview: {
            MicrocycleRestDragPreview()
        }
        .scaleEffect(isDragging ? 1.02 : 1)
        .opacity(isDragging ? 0.86 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.22 : 0), radius: isDragging ? 10 : 0, y: 4)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isDragging)
        .accessibilityAction(named: "Move Up", onMoveUp)
        .accessibilityAction(named: "Move Down", onMoveDown)
        .accessibilityAction(named: "Remove Rest Day", onRemove)
    }
}
