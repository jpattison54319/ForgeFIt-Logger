import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ExerciseAnimationView: View {
    @Environment(\.theme) private var theme
    let exercise: ExerciseLibraryModel
    var cornerRadius: CGFloat = Radius.card

    @State private var showEnd = false
    @State private var isPaused = false

    #if canImport(UIKit)
    private var startImage: UIImage? { ExerciseCatalog.localThumbnail(path: exercise.mediaSlug) }
    private var endImage: UIImage? { ExerciseCatalog.localThumbnail(path: ExerciseCatalog.frameOnePath(from: exercise.mediaSlug)) }
    #endif

    var body: some View {
        ZStack {
            Color(white: 0.96)
            #if canImport(UIKit)
            if let startImage {
                Image(uiImage: startImage)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                if let endImage {
                    Image(uiImage: endImage)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                        .opacity(showEnd ? 1 : 0)
                }
            } else {
                fallback
            }
            #else
            fallback
            #endif

            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.55))
                    .clipShape(Circle())
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.separator, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            #if canImport(UIKit)
            if endImage != nil { isPaused.toggle() }
            #endif
        }
        .task {
            #if canImport(UIKit)
            guard endImage != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.9))
                guard !Task.isCancelled, !isPaused else { continue }
                withAnimation(.easeInOut(duration: 0.45)) {
                    showEnd.toggle()
                }
            }
            #endif
        }
        .accessibilityLabel("Exercise demonstration")
        .accessibilityHint("Tap to pause or resume")
    }

    private var fallback: some View {
        Image(systemName: exercise.isCardio ? "figure.run" : "dumbbell.fill")
            .font(.system(size: 46, weight: .semibold))
            .foregroundStyle(theme.accent)
    }
}

struct ExerciseInfoCard: View {
    @Environment(\.theme) private var theme
    let exercise: ExerciseLibraryModel

    private var chips: [(String, Color)] {
        [
            exercise.difficulty.map { ($0.capitalized, theme.accent) },
            exercise.mechanic.map { ($0.capitalized, theme.secondaryAccent) },
            exercise.force.map { ($0.capitalized, theme.textSecondary) },
            exercise.equipment.map { ($0.capitalized, theme.textSecondary) }
        ]
        .compactMap { $0 }
    }

    private var muscles: [String] {
        var seen = Set<String>()
        return (exercise.primaryMuscles + exercise.secondaryMuscles).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ExerciseAnimationView(exercise: exercise)

            if !chips.isEmpty {
                WrappingChips(chips: chips)
            }

            if !muscles.isEmpty {
                MuscleChips(muscles: muscles)
            }

            if !exercise.instructions.isEmpty {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("How to perform")
                        .font(.sectionTitle)
                        .foregroundStyle(theme.textPrimary)
                    Card(padding: Space.md) {
                        VStack(alignment: .leading, spacing: Space.md) {
                            ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { index, instruction in
                                HStack(alignment: .top, spacing: Space.md) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .background(theme.accent)
                                        .clipShape(Circle())
                                    Text(instruction)
                                        .font(.system(size: 14))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            } else {
                Card(padding: Space.md) {
                    Text("No step-by-step instructions are available for this exercise yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }
}

private struct WrappingChips: View {
    @Environment(\.theme) private var theme
    let chips: [(String, Color)]

    var body: some View {
        FlexibleWrap(spacing: 8, rowSpacing: 8) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Tag(text: chip.0, color: chip.1, background: chip.1.opacity(0.14))
            }
        }
    }
}

private struct FlexibleWrap: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, proposal: proposal)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * rowSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func arrange(subviews: Subviews, proposal: ProposedViewSize) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if current.width > 0, current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.items.append(Item(subview: subview, size: size))
            current.width += (current.items.count == 1 ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}
