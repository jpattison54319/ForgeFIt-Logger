#if canImport(UIKit)
import Foundation
import ImageIO
import UIKit

/// Loads bundled yoga photos at the exact pixel size their view needs.
/// Source JPEGs stay compact on disk; ImageIO decoding happens off-main and
/// the cost-limited cache prevents a long pose list retaining full-size art.
enum YogaPoseImageStore {
    static let sourcePixelSize = 1_024

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    static func resourceName(slug: String, instructor: YogaInstructor) -> String {
        "yoga_\(slug.replacingOccurrences(of: "-", with: "_"))_\(instructor.rawValue)"
    }

    static func imageURL(slug: String, instructor: YogaInstructor) -> URL? {
        let name = resourceName(slug: slug, instructor: instructor)
        return Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "YogaPoseImages")
            ?? Bundle.main.url(forResource: name, withExtension: "jpg")
    }

    static func image(
        slug: String,
        instructor: YogaInstructor,
        requestedPixelSize: CGFloat
    ) async -> UIImage? {
        let pixelSize = pixelBucket(for: requestedPixelSize)
        let cacheKey = "\(resourceName(slug: slug, instructor: instructor))@\(pixelSize)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard let url = imageURL(slug: slug, instructor: instructor) else { return nil }

        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value

        if let image, let cgImage = image.cgImage {
            imageCache.setObject(
                image,
                forKey: cacheKey,
                cost: cgImage.bytesPerRow * cgImage.height
            )
        }
        return image
    }

    private static func pixelBucket(for requestedPixelSize: CGFloat) -> Int {
        let requested = max(96, Int(ceil(requestedPixelSize)))
        let bucket = Int(ceil(Double(requested) / 64.0)) * 64
        return min(sourcePixelSize, bucket)
    }
}
#endif
