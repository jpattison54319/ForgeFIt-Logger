import SwiftUI

/// Persistent, direct instructor choice shown where a yoga flow is configured
/// and where a pose photo is inspected in detail.
struct YogaInstructorPicker: View {
    @Environment(\.theme) private var theme
    @AppStorage(YogaInstructor.preferenceKey) private var instructorRaw = YogaInstructor.female.rawValue

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Instructor")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text("Applies to every yoga pose")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: Space.sm)
            Picker("Yoga instructor", selection: $instructorRaw) {
                ForEach(YogaInstructor.allCases) { instructor in
                    Text(instructor.title).tag(instructor.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 164)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .accessibilityIdentifier("yoga-instructor-picker")
    }
}
