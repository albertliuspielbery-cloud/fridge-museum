import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FridgeMuseum

struct AvatarImageTests {
    private struct BitmapError: Error {}

    /// Two-colour test image: `first` fills the left half (or the top half when `vertical`), `second` the rest.
    private func image(width: Int, height: Int, vertical: Bool,
                       first: (CGFloat, CGFloat, CGFloat), second: (CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: second.0, green: second.1, blue: second.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: first.0, green: first.1, blue: first.2, alpha: 1))
        // CGContext has a lower-left origin: the top half is y ∈ [h/2, h].
        let half = vertical
            ? CGRect(x: 0, y: height / 2, width: width, height: height - height / 2)
            : CGRect(x: 0, y: 0, width: width / 2, height: height)
        ctx.fill(half)
        return try #require(ctx.makeImage())
    }

    private func decoded(_ jpeg: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// RGB (0…255) of the centre pixel.
    private func centre(_ image: CGImage) throws -> (r: Int, g: Int, b: Int) {
        let W = image.width, H = image.height
        var px = [UInt8](repeating: 0, count: W * H * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        if !drawn { throw BitmapError() }
        let i = ((H / 2) * W + W / 2) * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }

    @Test func makesASquareJPEGAtMost512() throws {
        let src = try image(width: 3000, height: 2000, vertical: false, first: (1, 0, 0), second: (0, 0, 1))
        let jpeg = try #require(AvatarImage.make(from: src, crop: .centered))
        let out = try decoded(jpeg)
        #expect(out.width == out.height)
        #expect(out.width == AvatarImage.pixelSize)
    }

    @Test func smallSourcesAreNotUpscaled() throws {
        let src = try image(width: 300, height: 200, vertical: false, first: (1, 0, 0), second: (0, 0, 1))
        let out = try decoded(try #require(AvatarImage.make(from: src, crop: .centered)))
        #expect(out.width == 200 && out.height == 200)
    }

    @Test func zoomShrinksTheWindowButKeepsTheSquare() throws {
        let src = try image(width: 800, height: 600, vertical: false, first: (1, 0, 0), second: (0, 0, 1))
        let out = try decoded(try #require(AvatarImage.make(from: src, crop: AvatarCrop(zoom: 2, offsetX: 0, offsetY: 0))))
        #expect(out.width == 300 && out.height == 300)
    }

    @Test func clampsZoomAndKeepsTheWindowInsideTheImage() {
        let c = AvatarImage.clamped(AvatarCrop(zoom: 10, offsetX: 5, offsetY: -5), width: 1200, height: 800)
        #expect(c.zoom == AvatarCrop.maxZoom)
        // side = 800 / 4 = 200 → x may move (1200 - 200) / 400 = 2.5, y (800 - 200) / 400 = 1.5
        #expect(abs(c.offsetX - 2.5) < 1e-9)
        #expect(abs(c.offsetY + 1.5) < 1e-9)
        let low = AvatarImage.clamped(AvatarCrop(zoom: 0.2, offsetX: 1, offsetY: 1), width: 1200, height: 800)
        #expect(low.zoom == 1)
        #expect(abs(low.offsetX - 0.25) < 1e-9)
        #expect(low.offsetY == 0)
    }

    /// Dragging the image right shows its left side; dragging it down shows its top.
    @Test func panMovesTheWindowLikeTheDraggedImage() throws {
        let wide = try image(width: 1200, height: 800, vertical: false, first: (1, 0, 0), second: (0, 0, 1))
        let right = try centre(decoded(try #require(AvatarImage.make(from: wide, crop: AvatarCrop(zoom: 1, offsetX: 0.25, offsetY: 0)))))
        #expect(right.r > 200 && right.b < 60)
        let left = try centre(decoded(try #require(AvatarImage.make(from: wide, crop: AvatarCrop(zoom: 1, offsetX: -0.25, offsetY: 0)))))
        #expect(left.b > 200 && left.r < 60)

        let tall = try image(width: 600, height: 900, vertical: true, first: (1, 0, 0), second: (0, 0, 1))
        let down = try centre(decoded(try #require(AvatarImage.make(from: tall, crop: AvatarCrop(zoom: 1, offsetX: 0, offsetY: 0.25)))))
        #expect(down.r > 200 && down.b < 60)
        let up = try centre(decoded(try #require(AvatarImage.make(from: tall, crop: AvatarCrop(zoom: 1, offsetX: 0, offsetY: -0.25)))))
        #expect(up.b > 200 && up.r < 60)
    }

    @Test func decodesEncodedPhotosToo() throws {
        let src = try image(width: 1600, height: 1200, vertical: false, first: (1, 0, 0), second: (0, 0, 1))
        let photo = try #require(ImageEncoding.jpegData(src, quality: 0.9))
        let out = try decoded(try #require(AvatarImage.make(from: photo, crop: .centered)))
        #expect(out.width == AvatarImage.pixelSize && out.height == AvatarImage.pixelSize)
        let preview = try #require(AvatarImage.preview(of: photo))
        #expect(preview.width == AvatarImage.previewMaxEdge && preview.height == 900)
    }
}
