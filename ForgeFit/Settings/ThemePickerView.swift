import ForgeCore
import SwiftUI

struct ThemePickerView: View {
    @Environment(\.theme) private var theme

    private let columns = [
        GridItem(.flexible(), spacing: Space.lg),
        GridItem(.flexible(), spacing: Space.lg),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Space.xl) {
                ForEach(ThemeFamily.allCases) { family in
                    ThemeChoiceView(family: family)
                }
            }
            .padding(Space.lg)
        }
        .background(theme.background)
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}
