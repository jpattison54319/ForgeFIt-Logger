import SwiftUI

struct ImportedExerciseMuscleSection: View {
    @Environment(\.theme) private var theme
    let title: String
    let muscles: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(.tag)
                .foregroundStyle(theme.textTertiary)
            if muscles.isEmpty {
                Tag(text: "None suggested", color: theme.textSecondary, background: theme.surfaceElevated)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(muscles, id: \.self) { muscle in
                            Tag(text: muscle.capitalized, color: theme.textPrimary, background: theme.surfaceElevated)
                        }
                    }
                }
            }
        }
    }
}
