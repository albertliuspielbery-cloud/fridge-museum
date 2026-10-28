import Foundation
import CoreGraphics
import Testing
@testable import FridgeMuseum

/// Cast-shadow removal (1.0.1) on generated sheets: off-white paper, ink lines, a vivid red blob and two pale-yellow
/// crayon patches (striped, so paper shows between the strokes), optionally under a shadow.
struct ShadowRemovalTests {
    enum Shadow { case none, hard, soft }

    static let width = 900, height = 1200
    static let paper: (Float, Float, Float) = (235, 232, 225)
    static let yellow: (Float, Float, Float) = (250, 240, 170)

    /// Shadow strength 0...1 at a pixel (1 = full shadow).
    static func shadowAmount(_ kind: Shadow, _ x: Int, _ y: Int) -> Float {
        let w = Float(width), h = Float(height), fx = Float(x), fy = Float(y)
        switch kind {
        case .none: return 0
        case .hard: return (fx < 0.42 * w && fy > 0.55 * h) ? 1 : 0
        case .soft:
            let dx = (fx - 0.3 * w) / (0.25 * w), dy = (fy - 0.35 * h) / (0.2 * h)
            return 1 - smoothStep(Float(0.8), 1.2, (dx * dx + dy * dy).squareRoot())
        }
    }

    static func sheet(_ kind: Shadow) -> RGBA8Image {
        let W = width, H = height
        var img = RGBA8Image(width: W, height: H)
        var seed: UInt32 = 12345
        // hard: phone shadow, 30 % light and bluish; soft: hand shadow, 62 % light, same tint
        let level: Float = kind == .hard ? 0.30 : 0.62
        let tint: (Float, Float, Float) = (0.92, 1.0, 1.10)
        for y in 0..<H {
            for x in 0..<W {
                var c = paper
                let ink = ([150, 450, 700].contains { x >= $0 && x < $0 + 4 } && y > 100 && y < 1100)
                    || (y >= 300 && y < 304 && x > 50 && x < 850)
                let dxr = Float(x - 650), dyr = Float(y - 300)
                if ink {
                    c = (31, 31, 31)
                } else if dxr * dxr + dyr * dyr < 90 * 90 {
                    c = (220, 40, 40)
                } else if y % 4 != 3, [(90, 820), (560, 820)].contains(where: { x >= $0.0 && x < $0.0 + 180 && y >= $0.1 && y < $0.1 + 150 }) {
                    c = yellow
                }
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Float(Int(seed >> 29) - 3) * 0.67      // about ±2 levels, same on all channels
                let m = shadowAmount(kind, x, y)
                func v(_ base: Float, _ t: Float) -> UInt8 {
                    let f = 1 - m * (1 - level * t)
                    return UInt8(((base + noise) * f).rounded().clamped(0, 255))
                }
                img.set(x, y, (v(c.0, tint.0), v(c.1, tint.1), v(c.2, tint.2)))
            }
        }
        return img
    }

    /// Mean of pixel / light-map cell × gain over a pixel rectangle (the CPU equivalent of the divide without the
    /// per-pixel edge step, which is only active at shadow edges).
    static func flattenedMean(_ img: RGBA8Image, _ m: FlattenModel, x: Range<Int>, y: Range<Int>) -> SIMD3<Float> {
        var acc = SIMD3<Float>(repeating: 0)
        for yy in y {
            for xx in x {
                let i = (yy * img.width + xx) * 4
                let ci = ((yy / m.blockSize) * m.width + xx / m.blockSize) * 4
                for c in 0..<3 {
                    let v = Float(img.pixels[i + c]) / 255 / max(m.map[ci + c], 0.02) * m.gain
                    acc[c] += min(v, 1.638)
                }
            }
        }
        return acc / Float(x.count * y.count)
    }

    @Test func noShadowLeavesModelUnchanged() {
        let img = Self.sheet(.none)
        let plain = IlluminationEstimator.model(img)
        let withDetection = IlluminationEstimator.model(img, shadows: true)
        #expect(withDetection.shadow == nil)
        #expect(withDetection == plain)
    }

    @Test func hardBluishShadowComesOutWhite() {
        let img = Self.sheet(.hard)
        let m = IlluminationEstimator.model(img, shadows: true)
        #expect(m.mode == .white)
        let layers = m.shadow
        #expect(layers != nil)
        #expect((layers?.shadowCells ?? 0) > 500)
        // plain paper deep inside the shadow, and the same spot with v0.9 (no shadow step) for contrast
        let inside = Self.flattenedMean(img, m, x: 40..<140, y: 700..<800)
        #expect(inside.min() > 0.9 && inside.max() < 1.05)
        let old = Self.flattenedMean(img, IlluminationEstimator.model(img), x: 40..<140, y: 700..<800)
        #expect(old.min() < 0.85)
    }

    @Test func softShadowComesOutWhite() {
        let img = Self.sheet(.soft)
        let m = IlluminationEstimator.model(img, shadows: true)
        #expect(m.shadow != nil)
        let inside = Self.flattenedMean(img, m, x: 200..<260, y: 380..<460)
        #expect(inside.min() > 0.93 && inside.max() < 1.02)
    }

    @Test func paleYellowCrayonSurvivesInAndOutOfShadow() {
        let img = Self.sheet(.hard)
        let m = IlluminationEstimator.model(img, shadows: true)
        let inShadow = Self.flattenedMean(img, m, x: 110..<250, y: 870..<950)
        let lit = Self.flattenedMean(img, m, x: 590..<730, y: 870..<950)
        for c in [inShadow, lit] {
            #expect(c.x > 0.92)          // light, as on the paper…
            #expect(c.z < 0.88)          // …but still clearly yellow (blue well below red)
            #expect(c.x - c.z > 0.1)
        }
    }

    // MARK: End to end (ImageProcessor, Core Image kernel)

    private struct BitmapError: Error {}

    private func jpeg(_ img: RGBA8Image) throws -> Data {
        var px = img.pixels
        let cg: CGImage? = px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                      bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        let image = try #require(cg)
        return try #require(ImageEncoding.jpegData(image, quality: 0.92))
    }

    /// Mean output colour (0...1) over a rectangle given in fractions of the output image.
    private func mean(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) throws -> SIMD3<Float> {
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
        var acc = SIMD3<Float>(repeating: 0), count: Float = 0
        for yy in Int(y.lowerBound * Double(H))..<Int(y.upperBound * Double(H)) {
            for xx in Int(x.lowerBound * Double(W))..<Int(x.upperBound * Double(W)) {
                let i = (yy * W + xx) * 4
                acc += SIMD3<Float>(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])) / 255
                count += 1
            }
        }
        return acc / max(count, 1)
    }

    @Test func pipelineRemovesHardShadowOnlyWithCorners() async throws {
        let p = ImageProcessor()
        let id = UUID(), data = try jpeg(Self.sheet(.hard))
        var recipe = ProcessingRecipe(kind: .flat)
        // the sheet fills the photo; corners set just inside the frame (as if detected / placed by the user)
        recipe.corners = .inset(0.005)
        let r = try await p.preview(id: id, originalData: data, recipe: recipe, includeBefore: false)
        #expect(r.paperMode == .white)
        // plain paper inside the shadow (x 40…140, y 700…800 of 900 × 1200)
        let paperInShadow = try mean(r.output.cgImage, x: 0.06...0.14, y: 0.6...0.65)
        #expect(paperInShadow.min() > 0.9)
        // pale-yellow crayon inside the shadow keeps its colour
        let yellowInShadow = try mean(r.output.cgImage, x: 0.14...0.26, y: 0.73...0.78)
        #expect(yellowInShadow.x - yellowInShadow.z > 0.08)
        #expect(yellowInShadow.x > 0.85)

        // whole frame (no sheet found, no corners): shadow detection stays off, output as in v0.9
        recipe.corners = .full
        let full = try await p.preview(id: UUID(), originalData: data, recipe: recipe, includeBefore: false)
        let darkStill = try mean(full.output.cgImage, x: 0.06...0.14, y: 0.6...0.65)
        #expect(darkStill.max() < 0.9)
    }
}
