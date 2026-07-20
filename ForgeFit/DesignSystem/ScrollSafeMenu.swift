import SwiftUI
import UIKit

/// One entry in a `ScrollSafeMenu`. An empty `title` in its own section is
/// not needed — separators come from splitting items into sections.
struct ScrollSafeMenuItem {
    var title: String
    var systemImage: String? = nil
    /// Optional fixed tint for identity-bearing menu icons, such as the dot
    /// that maps a superset name to the same color used in exercise headers.
    var iconColor: Color? = nil
    var isChecked = false
    var isDestructive = false
    /// Non-empty turns this item into a submenu; `action` is ignored then.
    var children: [ScrollSafeMenuItem] = []
    var action: () -> Void = {}

    private var uiImage: UIImage? {
        guard let image = systemImage.flatMap({ UIImage(systemName: $0) }) else { return nil }
        guard let iconColor else { return image }
        return image.withTintColor(UIColor(iconColor), renderingMode: .alwaysOriginal)
    }

    fileprivate var uiElement: UIMenuElement {
        guard children.isEmpty else {
            return UIMenu(
                title: title,
                image: uiImage,
                children: children.map(\.uiElement)
            )
        }
        return UIAction(
            title: title,
            image: uiImage,
            attributes: isDestructive ? .destructive : [],
            state: isChecked ? .on : .off,
            handler: { _ in action() }
        )
    }
}

/// A tap-to-open menu whose label never claims the scroll gesture.
///
/// SwiftUI's `Menu` claims the touch stream the moment a finger lands on its
/// label, so a vertical scroll that happens to START on one dead-stops — the
/// "app feels frozen" bug on set rows, whose badge/effort/rest chips are all
/// menus. A UIKit `UIButton` with `showsMenuAsPrimaryAction` participates in
/// standard scroll-view touch cancellation instead: drags always scroll, taps
/// still open the menu. Use this for any menu that lives inside the workout
/// scroll surface; `Menu` remains fine for toolbars and sheets.
struct ScrollSafeMenu<Label: View>: View {
    let sections: [[ScrollSafeMenuItem]]
    @ViewBuilder let label: () -> Label

    init(sections: [[ScrollSafeMenuItem]], @ViewBuilder label: @escaping () -> Label) {
        self.sections = sections
        self.label = label
    }

    init(items: [ScrollSafeMenuItem], @ViewBuilder label: @escaping () -> Label) {
        self.init(sections: [items], label: label)
    }

    var body: some View {
        label()
            .overlay { MenuButtonOverlay(sections: sections) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }
}

/// Transparent UIButton stretched over the SwiftUI label. The button carries
/// the UIMenu; the SwiftUI label carries the visuals and accessibility.
private struct MenuButtonOverlay: UIViewRepresentable {
    let sections: [[ScrollSafeMenuItem]]

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        // The SwiftUI wrapper is the accessibility element; a second, blank
        // UIKit element here would double up the VoiceOver focus order.
        button.isAccessibilityElement = false
        button.menu = builtMenu
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        // Rebuild every update: checkmark state (current set type, picked
        // rest) must track the model.
        button.menu = builtMenu
    }

    private var builtMenu: UIMenu {
        let groups = sections.map { section in
            UIMenu(options: .displayInline, children: section.map(\.uiElement))
        }
        return UIMenu(children: groups)
    }
}
