import SwiftUI

// MARK: - Direction

/// Which way a `GlassDivisionMenu` fans its children out from the trigger.
enum GlassDivisionDirection {
    /// Children spawn to the left; the trigger/dismiss stays on the right.
    case leading
    /// Children spawn to the right; the trigger/dismiss stays on the left.
    case trailing
    /// Children spawn upward; the trigger/dismiss stays at the bottom.
    case up
    /// Children spawn downward; the trigger/dismiss stays at the top.
    case down

    var isHorizontal: Bool { self == .leading || self == .trailing }
    /// True when the trigger sits at the END of the layout stack (children
    /// come first): `.leading` (trigger on the right) and `.up` (bottom).
    fileprivate var triggerAtEnd: Bool { self == .leading || self == .up }
}

// MARK: - Item model

/// One child bubble a `GlassDivisionMenu` spawns: its glyph, tint, and what it
/// does when tapped. Build an array of these to pick how many buttons spawn and
/// what each one is.
struct GlassDivisionItem: Identifiable {
    let id: String
    /// Short caption shown under the bubble when `showsLabels` is on — keep it
    /// to one word so three sit side by side without colliding ("Confirm", not
    /// "Confirm sleep").
    var label: String
    /// Fuller description for VoiceOver; defaults to `label`.
    var accessibilityLabel: String
    var tint: Color
    var role: ButtonRole?
    var accessibilityID: String?
    /// Whether tapping collapses the menu back to its trigger. Set `false` for
    /// actions that open their own surface (a sheet or modal) and want the menu
    /// to stay put behind it.
    var dismissesOnTap: Bool
    /// Changes when this slot's content (icon/label/tint) is swapped in place —
    /// e.g. an option becoming an "Undo" of itself. When it changes the bubble
    /// crossfades its content instead of snapping. Keep the `id` stable across
    /// the swap so the bubble updates rather than remounting.
    var contentKey: AnyHashable?
    fileprivate let icon: AnyView
    let action: () -> Void

    /// A child backed by an SF Symbol.
    init(
        id: String,
        systemImage: String,
        label: String,
        accessibilityLabel: String? = nil,
        tint: Color,
        role: ButtonRole? = nil,
        accessibilityID: String? = nil,
        dismissesOnTap: Bool = true,
        contentKey: AnyHashable? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            id: id, label: label, accessibilityLabel: accessibilityLabel, tint: tint, role: role,
            accessibilityID: accessibilityID, dismissesOnTap: dismissesOnTap, contentKey: contentKey,
            icon: { Image(systemName: systemImage).font(.system(size: 18, weight: .bold)) },
            action: action
        )
    }

    /// A child backed by an arbitrary glyph view (for composed icons).
    init<Icon: View>(
        id: String,
        label: String,
        accessibilityLabel: String? = nil,
        tint: Color,
        role: ButtonRole? = nil,
        accessibilityID: String? = nil,
        dismissesOnTap: Bool = true,
        contentKey: AnyHashable? = nil,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.label = label
        self.accessibilityLabel = accessibilityLabel ?? label
        self.tint = tint
        self.role = role
        self.accessibilityID = accessibilityID
        self.dismissesOnTap = dismissesOnTap
        self.contentKey = contentKey
        self.icon = AnyView(icon())
        self.action = action
    }
}

// MARK: - Menu

/// A Liquid Glass button that, when tapped, splits into a fan of option bubbles
/// with a cell-division morph — each bubble buds out of the previous one with a
/// gooey metaball neck that pinches off, then the trigger becomes a dismiss
/// control. Configure the children with `items`, the spawn direction with
/// `direction`, and the collapsed glyph with the `trigger` builder.
///
/// The morph is delicate; the tuning lives in `references` on
/// [[forgefit-liquid-glass-tap-gotcha]]. In short: the glass must sit on the
/// button's *label* (not outside, or it eats the tap), the bubbles must
/// *travel* out of a merged blend field to pinch off (scale-in-place can't),
/// the reveal fires from `.onAppear` (so the hidden "from" frame renders), and
/// the container spacing is held wide during the split then dropped so the
/// settled bubbles are crisp circles rather than permanent teardrops.
struct GlassDivisionMenu<Trigger: View>: View {
    /// The children to spawn, ordered NEAREST the trigger first — item 0 buds
    /// off the dismiss anchor, item 1 off item 0, and so on.
    let items: [GlassDivisionItem]
    var direction: GlassDivisionDirection = .leading
    /// Diameter of each child bubble.
    var bubbleSize: CGFloat = 44
    /// Diameter of the trigger / dismiss control.
    var triggerSize: CGFloat = 52
    /// Rest gap between adjacent bubbles.
    var gap: CGFloat = 12
    /// Show each child's `label` as a caption directly below its bubble. The
    /// label rises out from under the glass as its bubble settles. Intended for
    /// horizontal fans (`.leading` / `.trailing`), where the label band sits
    /// below the row.
    var showsLabels: Bool = false
    /// Tint of the trigger's glass (nil = neutral/clear glass).
    var triggerTint: Color? = nil
    var dismissSystemImage: String = "xmark"
    var triggerAccessibilityLabel: String = "More options"
    var triggerAccessibilityHint: String = ""
    var triggerAccessibilityID: String? = nil
    var dismissAccessibilityLabel: String = "Dismiss"
    var dismissAccessibilityID: String? = nil
    /// Optional action for the collapsed bubble. When nil, tapping expands the
    /// menu as usual. This lets a destructive choice retract to one persistent
    /// Undo bubble without mounting a second control beside the trigger.
    var collapsedAction: (() -> Void)? = nil
    /// Fired whenever the menu expands (true) or collapses (false) — e.g. to
    /// make room in a surrounding layout while the fan is open.
    var onExpandedChange: (Bool) -> Void = { _ in }
    @ViewBuilder var trigger: () -> Trigger

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var morph

    @State private var expanded = false
    @State private var childrenShown = false
    @State private var clusterSpacing: CGFloat = 8
    /// Invalidates delayed reveal/retract work when the user opens and closes
    /// the menu quickly. Without it, an older task can leave a new fan at its
    /// hidden 5% birth scale (the "tiny dots" failure).
    @State private var transitionGeneration = 0

    // Morph tuning — see the doc comment / memory reference. Merged ≈ bubble
    // radius so the neck bridges the rest gap; crisp is small enough that the
    // gap no longer bridges, so dropping to it releases the necks into circles.
    private var clusterSpacingMerged: CGFloat { bubbleSize * 0.6 }
    private var clusterSpacingCrisp: CGFloat { min(8, gap - 2) }
    private let beat = 0.07
    private var birthSpring: Animation { .spring(response: 0.30, dampingFraction: 0.58) }
    private let rootID = "glass-division-root"
    /// Air between a bubble's bottom edge and its label. 6, not 4: the bubble's
    /// spring overshoot briefly swells its radius ~2.4pt into the gap.
    private let labelGap: CGFloat = 6
    /// Reserved vertical band below a horizontal fan so labels aren't clipped
    /// and content below keeps its distance (caption line + gap + margin).
    private var labelBand: CGFloat { showsLabels && direction.isHorizontal ? 22 : 0 }

    var body: some View {
        GlassEffectContainer(spacing: clusterSpacing) {
            if expanded {
                fan
            } else {
                triggerButton
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.18) : .bouncy(duration: 0.52, extraBounce: 0.18),
            value: expanded
        )
    }

    // MARK: Fan

    private var fan: some View {
        let layout = direction.isHorizontal
            ? AnyLayout(HStackLayout(spacing: gap))
            : AnyLayout(VStackLayout(spacing: gap))
        return layout {
            if !direction.triggerAtEnd { dismissBubble }
            ForEach(orderedChildren, id: \.item.id) { entry in
                childBubble(entry.item, birthIndex: entry.index)
            }
            if direction.triggerAtEnd { dismissBubble }
        }
        // Reserve the label band so no ancestor clips the captions and content
        // below keeps its distance. Uniform padding can't disturb per-item
        // geometry, so the bubble centers stay on one line.
        .padding(.bottom, labelBand)
        // Flip the reveal from onAppear, not the tap handler: the fan has
        // already rendered once at the hidden (dot-inside-neighbor) state, so
        // the scoped springs have a real "from" to divide out of. (Flipping in
        // the tap handler coalesces the change into one render pass and nothing
        // animates — the bubbles just pop in.)
        .onAppear(perform: revealChildren)
    }

    /// Children in VISUAL (stack) order, each carrying its birth index. Leading
    /// / up place the farthest child first (it ends up on the outside); trailing
    /// / down keep the near-first order.
    private var orderedChildren: [(item: GlassDivisionItem, index: Int)] {
        let indexed = items.enumerated().map { (item: $0.element, index: $0.offset) }
        return direction.triggerAtEnd ? indexed.reversed() : indexed
    }

    /// Hidden birth offset: the child starts concentric with the neighbor it
    /// buds from, which is always the one toward the trigger.
    private var hiddenOffset: CGSize {
        let step = bubbleSize + gap
        switch direction {
        case .leading: return CGSize(width: step, height: 0)
        case .trailing: return CGSize(width: -step, height: 0)
        case .up: return CGSize(width: 0, height: step)
        case .down: return CGSize(width: 0, height: -step)
        }
    }

    private func childBubble(_ item: GlassDivisionItem, birthIndex: Int) -> some View {
        let birth = Double(birthIndex) * beat
        let retract = Double(max(items.count - 1, 0)) * beat - birth
        let offset = hiddenOffset
        return Button(role: item.role) { handleTap(item) } label: {
            // Glass on the LABEL (outside the Button it swallows the tap); scale
            // + offset wrap the whole button so the glass bubble travels with
            // them. Only the GLYPH fades — fading the glass reads as a pop-in.
            item.icon
                .foregroundStyle(item.tint)
                // Crossfade when the slot's content is swapped in place (e.g. an
                // option becoming its own Undo) — the `id` change drives an
                // opacity transition while the stable `glassEffectID` keeps the
                // glass put.
                .id(item.contentKey)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.22), value: item.contentKey)
                .opacity(childrenShown ? 1 : 0)
                .animation(.easeOut(duration: 0.10).delay(childrenShown ? birth + 0.10 : 0), value: childrenShown)
                .frame(width: bubbleSize, height: bubbleSize)
                .contentShape(Circle())
                .glassEffect(.regular.tint(item.tint.opacity(0.18)).interactive(), in: Circle())
                .glassEffectID(item.id, in: morph)
        }
        .buttonStyle(PressableButtonStyle())
        .scaleEffect(reduceMotion ? 1 : (childrenShown ? 1 : 0.05))
        .offset(reduceMotion ? .zero : (childrenShown ? .zero : offset))
        .allowsHitTesting(childrenShown)
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.18)
                : (childrenShown ? birthSpring.delay(birth) : birthSpring.delay(retract)),
            value: childrenShown
        )
        // The fan mounts on expand; the container-level animation would fade the
        // bubble in (opacity on glass = pop-in). Suppress it — the birth spring
        // owns all motion.
        .transition(.identity)
        // Label attached AFTER the birth transforms: it never inherits the
        // sideways bud ride, and `.background` draws it BEHIND the glass, so the
        // glass occludes it as it rises out — a free mask (see Fable advisory).
        .background(alignment: .top) {
            if showsLabels { bubbleLabel(item, birth: birth) }
        }
        .accessibilityIdentifier(item.accessibilityID ?? "")
        .accessibilityLabel(item.accessibilityLabel)
    }

    /// A caption that rises out from under its bubble as the bubble settles.
    /// Trails the bubble's birth by 0.12s — it emerges right as the bubble pops
    /// to full size, so it reads as "the button produced this."
    private func bubbleLabel(_ item: GlassDivisionItem, birth: Double) -> some View {
        let delay = birth + 0.12
        // Fade fast, move soft. The type never bounces — the bubble owns the
        // jelly; bouncing text reads cheap. On exit, labels die first and
        // together (fast, no stagger) so they never ride the goo backward.
        let fade: Animation = childrenShown
            ? .easeOut(duration: 0.15).delay(reduceMotion ? 0.10 : delay)
            : .easeIn(duration: 0.08)
        let rise: Animation = childrenShown
            ? (reduceMotion ? .easeOut(duration: 0.15).delay(0.10) : .spring(response: 0.28, dampingFraction: 0.8).delay(delay))
            : .easeIn(duration: 0.08)
        return Text(item.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(item.role == .destructive ? theme.danger : theme.textSecondary)
            .fixedSize()                       // natural width; never clamps to the bubble
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .contentTransition(.opacity)       // crossfade the caption on a content swap
            .animation(.easeInOut(duration: 0.22), value: item.label)
            .opacity(childrenShown ? 1 : 0)
            .animation(fade, value: childrenShown)
            .offset(y: (childrenShown || reduceMotion) ? 0 : -12)   // starts tucked under the glass
            .animation(rise, value: childrenShown)
            .offset(y: bubbleSize + labelGap)  // static slot: top = bubble bottom + gap
            .allowsHitTesting(false)
            .accessibilityHidden(true)         // the Button already carries the label
    }

    // MARK: Trigger + dismiss (share glassEffectID so they morph, not cross-fade)

    private var triggerGlass: Glass {
        if let triggerTint { return .regular.tint(triggerTint).interactive() }
        return .regular.interactive()
    }

    private var triggerButton: some View {
        Button {
            if let collapsedAction {
                collapsedAction()
            } else {
                expand()
            }
        } label: {
            trigger()
                .frame(width: triggerSize, height: triggerSize)
                .contentShape(Circle())
                .glassEffect(triggerGlass, in: Circle())
                .glassEffectID(rootID, in: morph)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier(triggerAccessibilityID ?? "")
        .accessibilityLabel(triggerAccessibilityLabel)
        .accessibilityHint(triggerAccessibilityHint)
    }

    private var dismissBubble: some View {
        Button(action: collapse) {
            Image(systemName: dismissSystemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: triggerSize, height: triggerSize)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID(rootID, in: morph)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(dismissAccessibilityLabel)
        .accessibilityIdentifier(dismissAccessibilityID ?? "")
    }

    // MARK: Actions

    private func expand() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        childrenShown = false
        clusterSpacing = reduceMotion ? clusterSpacingCrisp : clusterSpacingMerged
        expanded = true
        onExpandedChange(true)
        // `.onAppear` remains the primary reveal hook so the hidden frame is
        // rendered first. The yielded fallback covers SwiftUI reusing the fan
        // subtree during very rapid close/reopen cycles and skipping onAppear.
        Task { @MainActor in
            await Task.yield()
            guard expanded, transitionGeneration == generation else { return }
            revealChildren(generation: generation)
        }
    }

    private func revealChildren() {
        revealChildren(generation: transitionGeneration)
    }

    private func revealChildren(generation: Int) {
        guard expanded, transitionGeneration == generation else { return }
        guard !childrenShown else { return }
        childrenShown = true
        guard !reduceMotion else { return }
        // Hold the merged field through the division, then release the necks so
        // the settled bubbles round into crisp circles.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            guard expanded, transitionGeneration == generation else { return }
            withAnimation(.easeInOut(duration: 0.24)) { clusterSpacing = clusterSpacingCrisp }
        }
    }

    private func handleTap(_ item: GlassDivisionItem) {
        item.action()
        if item.dismissesOnTap { collapse() }
    }

    private func collapse() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        // Re-merge so the bubbles goo back together as they retract into the
        // dismiss anchor, then flip to the trigger once they've melted in.
        if !reduceMotion { clusterSpacing = clusterSpacingMerged }
        withAnimation(birthSpring) { childrenShown = false }
        onExpandedChange(false)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard transitionGeneration == generation, childrenShown == false else { return }
            clusterSpacing = clusterSpacingCrisp
            expanded = false
        }
    }
}

// MARK: - Preview

#Preview("Directions") {
    struct Demo: View {
        @Environment(\.theme) private var theme
        func items(_ n: Int) -> [GlassDivisionItem] {
            let palette: [(String, Color)] = [
                ("checkmark", .green), ("pencil", .blue), ("trash.fill", .red), ("star.fill", .yellow)
            ]
            return (0..<n).map { i in
                GlassDivisionItem(id: "\(i)", systemImage: palette[i].0, label: palette[i].0, tint: palette[i].1) {}
            }
        }
        var body: some View {
            VStack(spacing: 60) {
                HStack {
                    Text("leading, 3").foregroundStyle(theme.textSecondary)
                    Spacer()
                    GlassDivisionMenu(items: items(3), direction: .leading, triggerTint: theme.accent) {
                        Image(systemName: "ellipsis").foregroundStyle(.white)
                    }
                }
                GlassDivisionMenu(items: items(4), direction: .down, triggerTint: theme.accent) {
                    Image(systemName: "plus").foregroundStyle(.white)
                }
                HStack {
                    GlassDivisionMenu(items: items(2), direction: .trailing, triggerTint: theme.secondaryAccent) {
                        Image(systemName: "bolt.fill").foregroundStyle(.white)
                    }
                    Spacer()
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
        }
    }
    return Demo().environment(\.theme, AppTheme.sage)
}
