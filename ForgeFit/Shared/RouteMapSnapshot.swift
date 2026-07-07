import ForgeCore
import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders a static image of a GPS route for embedding in an off-screen share
/// card. SwiftUI `Map` views don't rasterize through `ImageRenderer`, so we use
/// `MKMapSnapshotter` to produce a base map and draw the path over it with Core
/// Graphics. Async because the snapshotter fetches map tiles.
@MainActor
enum RouteMapSnapshot {
    static func image(coordinates: [CLLocationCoordinate2D], size: CGSize, theme: AppTheme) async -> UIImage? {
        guard coordinates.count >= 2, size.width > 0, size.height > 0 else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = region(for: coordinates)
        options.size = size
        options.scale = 3
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let lineColor = UIColor(theme.secondaryAccent)
        let startColor = UIColor(theme.success)
        let endColor = UIColor(theme.danger)

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            snapshot.image.draw(at: .zero)
            let cg = ctx.cgContext
            cg.setLineWidth(4)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)
            cg.setStrokeColor(lineColor.cgColor)
            for (index, coordinate) in coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                if index == 0 { cg.move(to: point) } else { cg.addLine(to: point) }
            }
            cg.strokePath()
            marker(cg, at: snapshot.point(for: coordinates.first!), fill: startColor)
            marker(cg, at: snapshot.point(for: coordinates.last!), fill: endColor)
        }
    }

    /// A filled dot with a white ring, matching the start (green) / end (red)
    /// pins the map uses on-screen.
    private static func marker(_ cg: CGContext, at point: CGPoint, fill: UIColor) {
        let radius: CGFloat = 5
        let inner = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        cg.setFillColor(UIColor.white.cgColor)
        cg.fillEllipse(in: inner.insetBy(dx: -2.5, dy: -2.5))
        cg.setFillColor(fill.cgColor)
        cg.fillEllipse(in: inner)
    }

    /// Bounding region of the route with 30% padding so the path isn't flush to
    /// the edges. The minimum span keeps very short routes from over-zooming.
    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        var minLat = coordinates[0].latitude, maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude, maxLon = coordinates[0].longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude); maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude); maxLon = max(maxLon, coordinate.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.002, (maxLat - minLat) * 1.3),
            longitudeDelta: max(0.002, (maxLon - minLon) * 1.3)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
