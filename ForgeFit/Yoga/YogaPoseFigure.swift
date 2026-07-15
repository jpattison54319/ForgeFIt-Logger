import SwiftUI

/// One pose's line-art figure from the bundled `yoga_pose_figures.json` —
/// hand-authored stick-figure geometry (head + stroked limb polylines) in a
/// 100×100 space, y down, facing LEFT. It provides an immediate loading and
/// custom-pose fallback while instructor photos decode off-main.
struct YogaPoseFigure: Decodable {
    /// [cx, cy, radius] — the head, drawn as a filled circle.
    let head: [Double]
    /// Limb/torso polylines, stroked with round caps and joins.
    let lines: [[[Double]]]
    /// Optional [x1, x2, y] faint floor line for orientation.
    let ground: [Double]?

    /// Side length of the authoring coordinate space.
    static let space: Double = 100
}

enum YogaPoseFigureCatalog {
    private static var cached: [String: YogaPoseFigure]?

    static func load() -> [String: YogaPoseFigure] {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "yoga_pose_figures", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: YogaPoseFigure].self, from: data) else {
            cached = [:]
            return [:]
        }
        cached = decoded
        return decoded
    }

    static func figure(forSlug slug: String?) -> YogaPoseFigure? {
        guard let slug else { return nil }
        return load()[slug]
    }
}

/// Renders a `YogaPoseFigure` at any size in the theme accent color.
struct YogaPoseFigureView: View {
    @Environment(\.theme) private var theme
    let figure: YogaPoseFigure
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / YogaPoseFigure.space
            // Proportional stroke: 7.5% of the figure space reads as one
            // continuous "body" width at every render size.
            let limb = StrokeStyle(lineWidth: 7.5 * s, lineCap: .round, lineJoin: .round)

            if let ground = figure.ground, ground.count == 3 {
                var floor = Path()
                floor.move(to: CGPoint(x: ground[0] * s, y: ground[2] * s))
                floor.addLine(to: CGPoint(x: ground[1] * s, y: ground[2] * s))
                context.stroke(
                    floor,
                    with: .color(theme.accent.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 4.5 * s, lineCap: .round)
                )
            }

            for line in figure.lines where line.count >= 2 {
                var path = Path()
                path.move(to: CGPoint(x: line[0][0] * s, y: line[0][1] * s))
                for point in line.dropFirst() where point.count >= 2 {
                    path.addLine(to: CGPoint(x: point[0] * s, y: point[1] * s))
                }
                context.stroke(path, with: .color(theme.accent), style: limb)
            }

            if figure.head.count >= 3 {
                let r = figure.head[2] * s
                let rect = CGRect(
                    x: figure.head[0] * s - r,
                    y: figure.head[1] * s - r,
                    width: r * 2,
                    height: r * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(theme.accent))
            }
        }
        .frame(width: size, height: size)
    }
}
