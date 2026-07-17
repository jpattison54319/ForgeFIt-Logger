import SwiftUI

// MARK: - Screen scaffolding

/// Full-bleed canvas used by every screen.
struct ScreenBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        theme.background.ignoresSafeArea()
    }
}

/// Standard rounded card container.
struct Card<Content: View>: View {
    var padding: CGFloat = Space.lg
    var fill: Color? = nil
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill ?? theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

// MARK: - Buttons

/// Full-width prominent action rendered with iOS 26 Liquid Glass
/// (`.glassProminent`).
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.bodyStrong)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glassProminent)
        .tint(tint ?? theme.accent)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: Radius.control))
    }
}

/// Secondary action rendered with clear Liquid Glass (`.glass`).
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.bodyStrong)
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: Radius.control))
    }
}

/// Circular icon button used in nav headers, rendered as interactive
/// Liquid Glass. `label` is REQUIRED: icon-only buttons are invisible to
/// VoiceOver without one (the fallback reads the SF Symbol name — "chevron
/// left" says nothing about what the button does).
struct CircleIconButton: View {
    let systemImage: String
    let label: String
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.bodyStrong)
                .foregroundStyle(tint ?? theme.textPrimary)
                .frame(width: 44, height: 44)   // HIG minimum touch target
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

/// Navigation counterpart to `CircleIconButton`. Keeping the same 44 pt glass
/// treatment makes header destinations and header actions feel identical while
/// still participating in a `NavigationStack`'s typed route system.
struct CircleIconNavigationLink<Value: Hashable>: View {
    let systemImage: String
    let label: String
    let value: Value
    var tint: Color? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        NavigationLink(value: value) {
            Image(systemName: systemImage)
                .font(.bodyStrong)
                .foregroundStyle(tint ?? theme.textPrimary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Reusable interactive Liquid Glass tile for dashboard and quick-action
/// controls. Dense data cards stay solid; tap targets get the glass treatment.
struct GlassTile<Content: View>: View {
    var tint: Color? = nil
    var cornerRadius: CGFloat = Radius.control
    var verticalPadding: CGFloat = 18
    var horizontalPadding: CGFloat = Space.lg
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let tint {
            content
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            content
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.interactive(), in: shape)
        }
    }
}

// MARK: - Section header

/// "Routines" / "Dashboard" style header with an optional trailing control.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var trailing: Trailing

    @Environment(\.theme) private var theme

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

// MARK: - Segmented pills

/// Hevy's "Volume / Reps / Duration" pill selector.
struct SegmentedPills<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T

    @Environment(\.theme) private var theme

    var body: some View {
        GlassEffectContainer(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                ForEach(options, id: \.self) { option in
                    let isSelected = option == selection
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { selection = option }
                    } label: {
                        Text(title(option))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : theme.textSecondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .glassEffect(
                        isSelected ? .regular.tint(theme.accent).interactive() : .regular.interactive(),
                        in: Capsule()
                    )
                }
            }
        }
    }
}

// MARK: - Exercise / pose name

/// DESIGN RULE — exercise and yoga-pose names are content, not controls:
/// the name always renders in primary (white) text, and ONLY the trailing
/// disclosure chevron is sage (`theme.accent`), signalling "tap for details".
/// Never tint the name itself with accent colors. This is just the visual —
/// wrap it in a Button or NavigationLink at the call site.
struct ExerciseNameLabel: View {
    @Environment(\.theme) private var theme
    let name: String
    var font: Font = .bodyStrong

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(font)
                .foregroundStyle(theme.textPrimary)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.accent)
        }
    }
}

// MARK: - Stat column

/// Label-over-value stat used across headers and cards (Duration / Volume / Sets).
struct StatColumn: View {
    let label: String
    let value: String
    var valueColor: Color? = nil
    var alignment: HorizontalAlignment = .leading
    /// Opt-in rolling-digit morph for values that change while visible (live
    /// logger stats). Off by default: most columns render once per screen.
    var animatesValue: Bool = false

    @Environment(\.theme) private var theme

    private var accessibilityID: String {
        "stat-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.label)
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.statValue)
                .foregroundStyle(valueColor ?? theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(animatesValue ? .numericText() : .identity)
                .animation(animatesValue ? Motion.stateChange : nil, value: value)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
        .accessibilityIdentifier(accessibilityID)
    }
}

// MARK: - Tag / chip

struct Tag: View {
    let text: String
    var color: Color? = nil
    var background: Color? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.tag)
            .foregroundStyle(color ?? theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background ?? theme.surfaceHighlight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
    }
}

// MARK: - Dashboard tile (2x2 grid entry)

struct DashboardTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            GlassTile {
                HStack(spacing: Space.md) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 24)
                    Text(title)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Progress ring

/// Circular readiness / progress ring with a value in the middle.
struct ProgressRing: View {
    var progress: Double          // 0...1
    var lineWidth: CGFloat = 12
    var color: Color
    var track: Color? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .stroke(track ?? theme.surfaceHighlight, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: progress)
        }
    }
}

// MARK: - Empty state

struct EmptyStateCard: View {
    let title: String
    let message: String
    let systemImage: String

    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            VStack(spacing: Space.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                Text(title)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.md)
        }
    }
}
