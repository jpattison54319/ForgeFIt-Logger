import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum ForgeSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
}

public enum ForgeRadius {
    public static let control: CGFloat = 8
    public static let panel: CGFloat = 8
}

public enum ForgeColor {
    public static var background: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.black
        #endif
    }

    public static var groupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.gray.opacity(0.18)
        #endif
    }

    public static let primaryText = Color.primary
    public static let secondaryText = Color.secondary
    public static let accent = Color.accentColor
}

public struct MetricTile: View {
    private let title: String
    private let value: String
    private let systemImage: String

    public init(title: String, value: String, systemImage: String) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ForgeSpacing.sm) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(ForgeColor.accent)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ForgeColor.primaryText)
            Text(title)
                .font(.caption)
                .foregroundStyle(ForgeColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ForgeSpacing.md)
        .background(ForgeColor.groupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: ForgeRadius.panel, style: .continuous))
    }
}
