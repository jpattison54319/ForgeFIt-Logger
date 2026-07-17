import SwiftUI

/// Compact live-player affordance that keeps the selected instructor visible
/// and allows the pose photo to switch without leaving the class.
struct YogaInstructorMenu: View {
    @Environment(\.theme) private var theme
    @AppStorage(YogaInstructor.preferenceKey) private var instructorRaw = YogaInstructor.female.rawValue

    private var instructor: YogaInstructor {
        YogaInstructor.resolved(from: instructorRaw)
    }

    var body: some View {
        Menu {
            Picker("Yoga instructor", selection: $instructorRaw) {
                ForEach(YogaInstructor.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
        } label: {
            Label(instructor.title, systemImage: "person.crop.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(theme.surfaceElevated)
                .clipShape(Capsule())
        }
        .accessibilityLabel("Yoga instructor")
        .accessibilityValue(instructor.title)
        .accessibilityIdentifier("yoga-instructor-menu")
    }
}
