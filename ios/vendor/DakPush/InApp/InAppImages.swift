import Foundation
import ImageIO
import UIKit

/// Loads a message's image before it shows: https only (redirects too), at
/// most 5 MB and 5 seconds, decoded at about the size it is drawn rather than
/// the file's full size. The last few stay in memory.
final class InAppImages: @unchecked Sendable {
    private let timeout: TimeInterval
    private let protocolClasses: [AnyClass]?
    private let cache = NSCache<NSString, UIImage>()

    /// [protocolClasses] are for tests (a fake web).
    init(timeout: TimeInterval = 5, protocolClasses: [AnyClass]? = nil) {
        self.timeout = timeout
        self.protocolClasses = protocolClasses
        cache.countLimit = 8
    }

    /// The longest side, in pixels, the image is decoded to for [layout] on a
    /// screen of [size] points and [scale] (the Flutter SDK's sizes).
    static func maxPixels(_ layout: InAppLayout, screen size: CGSize, scale: CGFloat) -> CGFloat {
        let points: CGFloat
        switch layout {
        case .modal: points = min(size.width - 48, 400)
        // Wide images fill the card's 200-high box by its height.
        case .card: points = min(size.width, 600) * 1.5
        // Aspect fill in a tall box: the longer side of the screen.
        case .fullscreen: points = max(size.width, size.height)
        case .bannerTop, .bannerBottom: points = 96
        }
        return max(points, 48) * max(scale, 1)
    }

    /// Calls [completion] on the main queue with the image, or nil when it
    /// cannot be loaded.
    func load(_ text: String, maxPixels: CGFloat, completion: @escaping @MainActor (UIImage?) -> Void) {
        let key = "\(Int(maxPixels)) \(text)" as NSString
        if let hit = cache.object(forKey: key) {
            onMain { completion(hit) }
            return
        }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            onMain { completion(nil) }
            return
        }
        let cache = self.cache
        DakImageDownload.start(
            url, maxBytes: DakImageDownload.maxBytes, timeout: timeout, protocolClasses: protocolClasses
        ) { file in
            var image: UIImage?
            if let file {
                image = Self.decode(file, maxPixels: maxPixels)
                try? FileManager.default.removeItem(at: file)
            }
            if let image { cache.setObject(image, forKey: key) }
            let result = image
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The image at most [maxPixels] on its longer side, decoded now (not
    /// while it animates in), the right way up.
    static func decode(_ file: URL, maxPixels: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, options), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixels.rounded())),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
