import CoreGraphics
import Foundation
import UIKit

/// Pan / zoom of the circular avatar crop, independent of resolution.
/// The crop window is a square of side `min(width, height) / zoom`, centred on the image centre and shifted by
/// `offset × side` (offset = how far the image was dragged, as a fraction of the crop square; +x right, +y down).
struct AvatarCrop: Sendable, Equatable {
    static let maxZoom = 4.0
    static let centered = AvatarCrop(zoom: 1, offsetX: 0, offsetY: 0)

    var zoom: Double
    var offsetX: Double
    var offsetY: Double
}

/// A decoded, downscaled copy of the source photo for the crop screen (re-encoded so it crosses actors as Data).
struct AvatarPreview: Sendable {
    var jpeg: Data
    var width: Int
    var height: Int
}

/// Makes the child avatar: a small square JPEG, cropped on the phone (nothing is uploaded).
/// Pure functions, no actor isolation: callers run them off the main actor (Task.detached).
enum AvatarImage {
    static let pixelSize = 512
    /// Long edge the source is decoded at before cropping (enough for 512 px at the maximum zoom on most photos).
    static let sourceMaxEdge = 2048
    static let previewMaxEdge = 1200

    /// Keeps the zoom in 1…maxZoom and the crop window inside the image.
    static func clamped(_ crop: AvatarCrop, width: Int, height: Int) -> AvatarCrop {
        let w = Double(max(width, 1)), h = Double(max(height, 1))
        let zoom = min(max(crop.zoom.isFinite ? crop.zoom : 1, 1), AvatarCrop.maxZoom)
        let side = min(w, h) / zoom
        let maxX = (w - side) / (2 * side)
        let maxY = (h - side) / (2 * side)
        let x = crop.offsetX.isFinite ? crop.offsetX : 0
        let y = crop.offsetY.isFinite ? crop.offsetY : 0
        return AvatarCrop(zoom: zoom, offsetX: min(max(x, -maxX), maxX), offsetY: min(max(y, -maxY), maxY))
    }

    static func preview(of data: Data) -> AvatarPreview? {
        guard let image = ImageMetadata.uprightThumbnail(of: data, maxPixelSize: previewMaxEdge),
              let jpeg = ImageEncoding.jpegData(image, quality: 0.85) else { return nil }
        return AvatarPreview(jpeg: jpeg, width: image.width, height: image.height)
    }

    /// Decodes `data` (any ImageIO format, EXIF orientation applied) and crops it.
    static func make(from data: Data, crop: AvatarCrop) -> Data? {
        guard let image = ImageMetadata.uprightThumbnail(of: data, maxPixelSize: sourceMaxEdge) else { return nil }
        return make(from: image, crop: crop)
    }

    /// Square JPEG of the crop window, at most `pixelSize` px (smaller sources are not upscaled).
    /// Transparent sources (craft cut-outs) get a white background.
    static func make(from image: CGImage, crop: AvatarCrop) -> Data? {
        let w = Double(image.width), h = Double(image.height)
        guard w >= 1, h >= 1 else { return nil }
        let c = clamped(crop, width: image.width, height: image.height)
        let side = min(w, h) / c.zoom
        let cx = w / 2 - c.offsetX * side
        let cy = h / 2 - c.offsetY * side
        let out = max(1, min(pixelSize, Int(side.rounded())))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: out, height: out))
        ctx.interpolationQuality = .high
        let scale = Double(out) / side
        // CGContext user space has a lower-left origin; the crop window is measured from the top-left.
        let rect = CGRect(x: -(cx - side / 2) * scale, y: -(h - cy - side / 2) * scale,
                          width: w * scale, height: h * scale)
        ctx.draw(image, in: rect)
        guard let result = ctx.makeImage() else { return nil }
        return ImageEncoding.jpegData(result, quality: 0.85)
    }
}

/// Decoded avatars, so shelves and lists don't decode the JPEG on every redraw.
@MainActor
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private var entries: [UUID: (data: Data, image: UIImage)] = [:]

    private init() {}

    func image(for child: Child) -> UIImage? {
        guard let data = child.avatarImageData else { return nil }
        if let e = entries[child.id], e.data == data { return e.image }
        guard let image = UIImage(data: data) else { return nil }
        entries[child.id] = (data, image)
        return image
    }
}
