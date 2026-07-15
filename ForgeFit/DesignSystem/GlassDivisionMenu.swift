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
    /// label rises out from under the glass as its bubble settles. Horizontal
    /// fans (`.leading` / `.trailing`) reserve a band under the row for the
    /// captions; vertical fans (`.up` / `.down`) draw them in the inter-bubble
    /// gap instead — pass a `gap` large enough to hold a caption line (≈32).
    var showsLabels: Bool = false
    /// Cap on a caption's width: long captions (e.g. routine names) tail-
    /// truncate inside a centered slot this wide. nil = natural width —
    /// captions never wrap, which is fine for one-word labels on a card but
    /// can run off-screen for a fan hugging a screen edge.
    var labelMaxWidth: CGFloat? = nil
    /// How strongly each child bubble's glass carries its `tint`. The default
    /// keeps the tinted look the sleep card ships with; pass 0 for clear
    /// see-through glass that matches the tab bar, letting the glyph alone
    /// carry the color.
    var bubbleGlassTintOpacity: CGFloat = 0.18
    /// Uses ordinary material-backed circles and a deterministic relay instead
    /// of native Liquid Glass compositing. This is for root-level controls whose
    /// children cross cards, bars, and screen edges: the native compositor can
    /// keep subpixel glass fragments alive after SwiftUI has hidden a child.
    /// The sleep correction menu keeps the native cell-division effect.
    var usesStableMaterialRelay: Bool = false
    /// Tint of the trigger's glass (nil = neutral/clear glass).
    var triggerTint: Color? = nil
    var dismissSystemImage: String = "xmark"
    /// Optional quiet caption drawn beside the expanded dismiss control (its
    /// trailing edge `labelGap` left of the control) — e.g. "Hold to edit" to
    /// teach the long-press right where it applies. Below the control is not
    /// an option for `.up` fans: that space belongs to whatever the fan is
    /// anchored above. Rendered only when `showsLabels` is on.
    var dismissCaption: String? = nil
    var triggerAccessibilityLabel: String = "More options"
    var triggerAccessibilityHint: String = ""
    var triggerAccessibilityID: String? = nil
    var dismissAccessibilityLabel: String = "Dismiss"
    var dismissAccessibilityHint: String = ""
    var dismissAccessibilityID: String? = nil
    /// Optional action for the collapsed bubble. When nil, tapping expands the
    /// menu as usual. This lets a destructive choice retract to one persistent
    /// Undo bubble without mounting a second control beside the trigger.
    var collapsedAction: (() -> Void)? = nil
    /// Fired whenever the menu expands (true) or collapses (false) — e.g. to
    /// make room in a surrounding layout while the fan is open.
    var onExpandedChange: (Bool) -> Void = { _ in }
    /// Increment to request a collapse from outside (e.g. a tap-outside
    /// scrim). One-directional by design: the menu keeps sole ownership of its
    /// expand/collapse state machine (generation guards, deferred spacing
    /// release) — callers observe state via `onExpandedChange`.
    var collapseSignal: Int = 0
    /// Optional long-press on the menu's "main button" in BOTH states — the
    /// collapsed trigger and the expanded dismiss control (e.g. opening a
    /// "customize these actions" editor). Attached only when set, so existing
    /// call sites keep an unchanged gesture graph. A recognized long press
    /// suppresses the Button's tap — SwiftUI fires it on the eventual
    /// touch-up even after a hold — so only the hook runs.
    var onTriggerLongPress: (() -> Void)? = nil
    @ViewBuilder var trigger: () -> Trigger

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var morph

    @State private var expanded = false
    @State private var childrenShown = false
    @State private var clusterSpacing: CGFloat = 8
    /// Stable-material children reveal by birth index: nearest first, then the
    /// next child from that settled neighbor. -1 is fully retracted.
    @State private var relayStage = -1
    /// Invalidates delayed reveal/retract work when the user opens and closes
    /// the menu quickly. Without it, an older task can leave a new fan at its
    /// hidden 5% birth scale (the "tiny dots" failure).
    @State private var transitionGeneration = 0
    /// Set when the main button's long press recognizes (trigger or dismiss —
    /// never both mounted at once); the Button's action (which still fires on
    /// the same touch's release) consumes it and does nothing, so a hold
    /// doesn't also expand or collapse the menu.
    @State private var suppressNextTriggerTap = false

    // Morph tuning — see the doc comment / memory reference. Merged ≈ bubble
    // radius so the neck bridges the rest gap; crisp is small enough that the
    // gap no longer bridges, so dropping to it releases the necks into circles.
    private var clusterSpacingMerged: CGFloat { bubbleSize * 0.6 }
    private var clusterSpacingCrisp: CGFloat { min(8, gap - 2) }
    private let beat = 0.07
    private var birthSpring: Animation { .spring(response: 0.30, dampingFraction: 0.58) }
    private let relayBeat: Duration = .milliseconds(72)
    private let retractionBeat: Duration = .milliseconds(34)
    private var relaySpring: Animation { .spring(response: 0.18, dampingFraction: 0.84) }
    private var retractionSpring: Animation { .spring(response: 0.13, dampingFraction: 0.92) }
    /// A visible 5% birth scale left a real 2.2 pt glass particle behind when
    /// the vertical fan was replaced by its trigger. Keep the glass mounted for
    /// the spring, but below a physical pixel while it is inside its parent.
    private let hiddenScale: CGFloat = 0.001
    private let rootID = "glass-division-root"
    /// Air between a bubble's bottom edge and its label. 6, not 4: the bubble's
    /// spring overshoot briefly swells its radius ~2.4pt into the gap.
    private let labelGap: CGFloat = 6
    /// Reserved vertical band below a horizontal fan so labels aren't clipped
    /// and content below keeps its distance (caption line + gap + margin).
    private var labelBand: CGFloat { showsLabels && direction.isHorizontal ? 22 : 0 }

    var body: some View {
        Group {
            if usesStableMaterialRelay {
                menuContents
            } else {
                GlassEffectContainer(spacing: clusterSpacing) {
                    menuContents
                }
                .animation(
                    reduceMotion ? .easeOut(duration: 0.18) : .bouncy(duration: 0.52, extraBounce: 0.18),
                    value: expanded
                )
            }
        }
        .onChange(of: collapseSignal) { _, _ in
            if expanded { collapse() }
        }
    }

    @ViewBuilder
    private var menuContents: some View {
        if expanded {
            fan
        } else {
            triggerButton
        }
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
        let isShown = usesStableMaterialRelay ? relayStage >= birthIndex : childrenShown
        let button = Button(role: item.role) { handleTap(item) } label: {
            childFace(item, isShown: isShown, birth: birth, retract: retract)
        }
        .buttonStyle(PressableButtonStyle())
        return transformedChild(
            button,
            isShown: isShown,
            birth: birth,
            retract: retract,
            offset: offset
        )
        .allowsHitTesting(isShown)
        // The fan mounts on expand; the container-level animation would fade the
        // bubble in (opacity on glass = pop-in). Suppress it — the birth spring
        // owns all motion.
        .transition(.identity)
        // Label attached AFTER the birth transforms: it never inherits the
        // sideways bud ride, and `.background` draws it BEHIND the glass, so the
        // glass occludes it as it rises out — a free mask (see Fable advisory).
        .background(alignment: .top) {
            if showsLabels { bubbleLabel(item, birth: birth, isShown: isShown) }
        }
        .accessibilityIdentifier(item.accessibilityID ?? "")
        .accessibilityLabel(item.accessibilityLabel)
    }

    @ViewBuilder
    private func childFace(
        _ item: GlassDivisionItem,
        isShown: Bool,
        birth: Double,
        retract: Double
    ) -> some View {
        let glyph = item.icon
            .foregroundStyle(item.tint)
            // Crossfade when the slot's content is swapped in place (e.g. an
            // option becoming its own Undo).
            .id(item.contentKey)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.22), value: item.contentKey)
            .opacity(usesStableMaterialRelay ? 1 : (isShown ? 1 : 0))
            .animation(
                .easeOut(duration: 0.10).delay(isShown ? birth + 0.10 : retract),
                value: isShown
            )
            .frame(width: bubbleSize, height: bubbleSize)
            .contentShape(Circle())

        if usesStableMaterialRelay {
            glyph.background {
                stableMaterialCircle(tint: item.tint, tintOpacity: bubbleGlassTintOpacity)
            }
        } else {
            // Native glass stays on the label: putting it outside the Button
            // swallows taps on iOS 26.
            glyph
                .glassEffect(bubbleGlass(for: item), in: Circle())
                .glassEffectID(item.id, in: morph)
        }
    }

    @ViewBuilder
    private func transformedChild<Content: View>(
        _ content: Content,
        isShown: Bool,
        birth: Double,
        retract: Double,
        offset: CGSize
    ) -> some View {
        if usesStableMaterialRelay {
            content
                // A flat squeeze travels from its actual parent. Ordinary
                // material respects opacity, so no hidden compositor particle
                // remains after the circle reaches that parent.
                .scaleEffect(
                    x: reduceMotion ? 1 : (isShown ? 1 : 0.68),
                    y: reduceMotion ? 1 : (isShown ? 1 : 0.12)
                )
                .offset(reduceMotion ? .zero : (isShown ? .zero : offset))
                .opacity(isShown ? 1 : 0)
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : (isShown ? relaySpring : retractionSpring),
                    value: isShown
                )
        } else {
            content
                .scaleEffect(reduceMotion ? 1 : (isShown ? 1 : hiddenScale))
                .offset(reduceMotion ? .zero : (isShown ? .zero : offset))
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.18)
                        : (isShown ? birthSpring.delay(birth) : birthSpring.delay(retract)),
                    value: isShown
                )
        }
    }

    /// A caption that rises out from under its bubble as the bubble settles.
    /// Trails the bubble's birth by 0.12s — it emerges right as the bubble pops
    /// to full size, so it reads as "the button produced this."
    private func bubbleLabel(_ item: GlassDivisionItem, birth: Double, isShown: Bool) -> some View {
        let delay = usesStableMaterialRelay ? 0.045 : birth + 0.12
        // Fade fast, move soft. The type never bounces — the bubble owns the
        // jelly; bouncing text reads cheap. On exit, labels die first and
        // together (fast, no stagger) so they never ride the goo backward.
        let fade: Animation = isShown
            ? .easeOut(duration: 0.15).delay(reduceMotion ? 0.10 : delay)
            : .easeIn(duration: 0.08)
        let rise: Animation = isShown
            ? (reduceMotion ? .easeOut(duration: 0.15).delay(0.10) : .spring(response: 0.22, dampingFraction: 0.84).delay(delay))
            : .easeIn(duration: 0.08)
        return Text(item.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(item.role == .destructive ? theme.danger : theme.textSecondary)
            // Natural width (never clamped to the bubble) unless the caller
            // caps it; a capped caption truncates inside its centered slot.
            .fixedSize(horizontal: labelMaxWidth == nil, vertical: true)
            .frame(width: labelMaxWidth)
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .contentTransition(.opacity)       // crossfade the caption on a content swap
            .animation(.easeInOut(duration: 0.22), value: item.label)
            .opacity(isShown ? 1 : 0)
            .animation(fade, value: isShown)
            .offset(y: (isShown || reduceMotion) ? 0 : -12)   // starts tucked under the glass
            .animation(rise, value: isShown)
            .offset(y: bubbleSize + labelGap)  // static slot: top = bubble bottom + gap
            .allowsHitTesting(false)
            .accessibilityHidden(true)         // the Button already carries the label
    }

    // MARK: Trigger + dismiss (share glassEffectID so they morph, not cross-fade)

    private func bubbleGlass(for item: GlassDivisionItem) -> Glass {
        bubbleGlassTintOpacity > 0
            ? .regular.tint(item.tint.opacity(bubbleGlassTintOpacity)).interactive()
            : .regular.interactive()
    }

    private func rootGlass(tint: Color?) -> Glass {
        if let tint { return .regular.tint(tint).interactive() }
        return .regular.interactive()
    }

    private func stableMaterialCircle(tint: Color?, tintOpacity: CGFloat) -> some View {
        Circle()
            .fill(.thinMaterial)
            .overlay {
                if let tint, tintOpacity > 0 {
                    Circle().fill(tint.opacity(tintOpacity))
                }
            }
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
            }
            .shadow(color: Color.black.opacity(0.16), radius: 8, y: 3)
    }

    @ViewBuilder
    private func rootFace<Content: View>(_ content: Content, tint: Color?) -> some View {
        if usesStableMaterialRelay {
            content.background {
                stableMaterialCircle(tint: tint, tintOpacity: tint == nil ? 0 : 0.16)
            }
        } else {
            content
                .glassEffect(rootGlass(tint: tint), in: Circle())
                .glassEffectID(rootID, in: morph)
        }
    }

    @ViewBuilder
    private var triggerButton: some View {
        let button = Button {
            if suppressNextTriggerTap {
                // A long press just ran the hook; this is the same touch's
                // release reaching the Button. Swallow it.
                suppressNextTriggerTap = false
            } else if let collapsedAction {
                collapsedAction()
            } else {
                expand()
            }
        } label: {
            rootFace(
                trigger()
                    .frame(width: triggerSize, height: triggerSize)
                    .contentShape(Circle()),
                tint: triggerTint
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier(triggerAccessibilityID ?? "")
        .accessibilityLabel(triggerAccessibilityLabel)
        .accessibilityHint(triggerAccessibilityHint)

        // `.simultaneousGesture` rather than `.onLongPressGesture`-on-Button:
        // the latter can eat the Button's tap; simultaneous keeps it alive and
        // the suppression flag closes the resulting hold-then-release double
        // fire. Attached only when configured.
        if onTriggerLongPress != nil {
            button.simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    triggerLongPressRecognized()
                }
            )
        } else {
            button
        }
    }

    private func triggerLongPressRecognized() {
        guard let onTriggerLongPress else { return }
        suppressNextTriggerTap = true
        onTriggerLongPress()
        // Self-heal: if the surface the hook presents cancels the touch, the
        // Button's action never consumes the flag — clear it so the next
        // plain tap still works.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            suppressNextTriggerTap = false
        }
    }

    @ViewBuilder
    private var dismissBubble: some View {
        let button = Button {
            if suppressNextTriggerTap {
                // A long press just ran the hook; this is the same touch's
                // release reaching the Button. Swallow it — the hook's owner
                // decides whether to collapse.
                suppressNextTriggerTap = false
            } else {
                collapse()
            }
        } label: {
            rootFace(
                Image(systemName: dismissSystemImage)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: triggerSize, height: triggerSize)
                    .contentShape(Circle()),
                tint: nil
            )
        }
        .buttonStyle(PressableButtonStyle())
        .allowsHitTesting(childrenShown)
        .accessibilityLabel(dismissAccessibilityLabel)
        .accessibilityHint(dismissAccessibilityHint)
        .accessibilityIdentifier(dismissAccessibilityID ?? "")
        // Quiet gesture hint beside the control. `.background` draws behind
        // the glass and takes no layout space; trailing alignment + the fixed
        // offset pins the caption's trailing edge `labelGap` left of the
        // control's leading edge regardless of text width.
        .background(alignment: .trailing) {
            if let dismissCaption, showsLabels {
                dismissCaptionView(dismissCaption)
            }
        }

        if onTriggerLongPress != nil {
            button.simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    triggerLongPressRecognized()
                }
            )
        } else {
            button
        }
    }

    /// Styled like a child caption, but always present while the fan is open
    /// (it labels the control's hold gesture, not a spawned action).
    private func dismissCaptionView(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .opacity(childrenShown ? 1 : 0)
            .animation(
                childrenShown
                    ? .easeOut(duration: 0.15).delay(
                        reduceMotion ? 0.10 : (usesStableMaterialRelay ? 0.11 : 0.30)
                    )
                    : .easeIn(duration: 0.08),
                value: childrenShown
            )
            .offset(x: -(triggerSize + labelGap))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Actions

    private func expand() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        childrenShown = false
        relayStage = -1
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

        if usesStableMaterialRelay {
            guard !items.isEmpty else { return }
            guard !reduceMotion else {
                relayStage = items.count - 1
                return
            }
            Task { @MainActor in
                // Render one fully hidden frame at the real parent positions,
                // then hand the motion from parent to child every 72 ms.
                await Task.yield()
                for stage in items.indices {
                    guard expanded, transitionGeneration == generation else { return }
                    withAnimation(relaySpring) {
                        relayStage = stage
                    }
                    if stage < items.count - 1 {
                        try? await Task.sleep(for: relayBeat)
                    }
                }
            }
            return
        }

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
        onExpandedChange(false)

        guard !reduceMotion else {
            childrenShown = false
            relayStage = -1
            clusterSpacing = clusterSpacingCrisp
            expanded = false
            return
        }

        if usesStableMaterialRelay {
            retractStableRelay(generation: generation)
            return
        }

        // First widen the glass blend field so the separated circles grow
        // necks again. Only then retract them toward the trigger. The old code
        // replaced the fan after a fixed 260 ms, even though the nearest child
        // still had its stagger plus most of a 300 ms spring left; SwiftUI then
        // reparented that live 5%-scale layer as the detached exit speck.
        withAnimation(.easeIn(duration: 0.08)) {
            clusterSpacing = clusterSpacingMerged
        } completion: {
            guard transitionGeneration == generation else { return }
            withAnimation(birthSpring) {
                childrenShown = false
            } completion: {
                guard transitionGeneration == generation, childrenShown == false else { return }
                clusterSpacing = clusterSpacingCrisp
                expanded = false
            }
        }
    }

    private func retractStableRelay(generation: Int) {
        childrenShown = false
        let firstStage = min(relayStage, items.count - 1)
        guard firstStage >= 0 else {
            relayStage = -1
            expanded = false
            return
        }

        Task { @MainActor in
            // Outside-in: the farthest child squeezes back into its parent,
            // then that parent follows. The final material spring is allowed
            // to finish before the fan subtree is replaced by the trigger.
            for stage in stride(from: firstStage, through: 0, by: -1) {
                guard transitionGeneration == generation else { return }
                withAnimation(retractionSpring) {
                    relayStage = stage - 1
                }
                if stage > 0 {
                    try? await Task.sleep(for: retractionBeat)
                }
            }
            try? await Task.sleep(for: .milliseconds(145))
            guard transitionGeneration == generation, relayStage == -1 else { return }
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
