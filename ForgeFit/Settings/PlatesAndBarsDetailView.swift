import ForgeCore
import SwiftUI

/// Detail screen for the plate inventory editor, navigated to from the main
/// settings list. Wraps the existing `PlateInventoryEditor` in a scrollable
/// container with a nav title.
struct PlatesAndBarsDetailView: View {
    @Environment(\.theme) private var theme
    @State private var unit: WeightUnit = Fmt.unit

    var body: some View {
        ScrollView {
            PlateInventoryEditor(unit: unit)
                .id(unit)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(theme.background)
        .navigationTitle("Plates & Bars")
        .navigationBarTitleDisplayMode(.inline)
    }
}
