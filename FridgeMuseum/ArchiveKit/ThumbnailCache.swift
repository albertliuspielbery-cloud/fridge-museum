import UIKit

/// Decoded thumbnails, keyed by artwork id + render version.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(for artwork: Artwork) -> UIImage? {
        let key = "\(artwork.id.uuidString)-\(artwork.renderVersion)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let data = artwork.thumbnailData, let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
