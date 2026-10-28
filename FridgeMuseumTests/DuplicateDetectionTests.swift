import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import FridgeMuseum

/// Synthetic "kid drawings" on a whitened 400×300 sheet (what the pipeline outputs), plus the ways a re-shoot of the
/// same sheet differs: light, a few % shift / crop, a couple of degrees of rotation, a different resolution.
enum Sketch {
    typealias RGB = (UInt8, UInt8, UInt8)
    static let width = 400, height = 300
    static let red: RGB = (220, 40, 40), blue: RGB = (40, 90, 220), yellow: RGB = (250, 210, 40)
    static let green: RGB = (40, 170, 60), ink: RGB = (30, 30, 30), brown: RGB = (140, 80, 40)
    static let pink: RGB = (240, 120, 180), orange: RGB = (245, 140, 30), skin: RGB = (250, 220, 190)

    static func rect(_ im: inout RGBA8Image, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: RGB) {
        let xa = max(0, x0), xb = min(im.width, x1), ya = max(0, y0), yb = min(im.height, y1)
        guard xa < xb, ya < yb else { return }
        for y in ya..<yb { for x in xa..<xb { im.set(x, y, c) } }
    }

    static func disc(_ im: inout RGBA8Image, _ cx: Int, _ cy: Int, _ r: Int, _ c: RGB) {
        let ya = max(0, cy - r), yb = min(im.height, cy + r + 1), xa = max(0, cx - r), xb = min(im.width, cx + r + 1)
        guard xa < xb, ya < yb else { return }
        for y in ya..<yb {
            for x in xa..<xb where (x - cx) * (x - cx) + (y - cy) * (y - cy) < r * r { im.set(x, y, c) }
        }
    }

    static func line(_ im: inout RGBA8Image, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: RGB, _ t: Int = 4) {
        let n = max(abs(x1 - x0), abs(y1 - y0)) + 1
        for i in 0..<n {
            let x = x0 + (x1 - x0) * i / max(n - 1, 1), y = y0 + (y1 - y0) * i / max(n - 1, 1)
            rect(&im, x - t / 2, y - t / 2, x - t / 2 + t, y - t / 2 + t, c)
        }
    }

    /// A house with a roof, door, sun, grass and two blue clouds.
    static func house() -> RGBA8Image {
        var im = RGBA8Image(width: width, height: height)
        rect(&im, 0, 255, 400, 300, green)
        disc(&im, 330, 60, 32, yellow)
        rect(&im, 110, 140, 250, 255, red)
        for k in stride(from: 0, to: 70, by: 2) { rect(&im, 110 + k, 140 - k, 250 - k, 142 - k, brown) }
        rect(&im, 160, 195, 195, 255, ink)
        line(&im, 20, 40, 80, 30, blue)
        line(&im, 30, 70, 100, 60, blue)
        return im
    }

    /// The same idea drawn again by the same kid: same crayons, house smaller and to the left, a flower added.
    static func houseAgain() -> RGBA8Image {
        var im = RGBA8Image(width: width, height: height)
        rect(&im, 0, 255, 400, 300, green)
        disc(&im, 330, 60, 32, yellow)
        rect(&im, 40, 160, 160, 255, red)
        for k in stride(from: 0, to: 60, by: 2) { rect(&im, 40 + k, 160 - k, 160 - k, 162 - k, brown) }
        rect(&im, 85, 205, 115, 255, ink)
        line(&im, 200, 40, 260, 30, blue)
        line(&im, 210, 70, 280, 60, blue)
        disc(&im, 280, 210, 25, pink)
        return im
    }

    static func treeAndCar() -> RGBA8Image {
        var im = RGBA8Image(width: width, height: height)
        rect(&im, 0, 260, 400, 300, green)
        disc(&im, 60, 55, 30, yellow)
        rect(&im, 185, 120, 215, 260, brown)
        disc(&im, 200, 100, 70, green)
        rect(&im, 260, 215, 370, 250, red)
        disc(&im, 285, 252, 12, ink)
        disc(&im, 345, 252, 12, ink)
        line(&im, 280, 40, 360, 30, blue)
        return im
    }

    static func family() -> RGBA8Image {
        var im = RGBA8Image(width: width, height: height)
        disc(&im, 330, 60, 32, yellow)
        let people: [(Int, RGB)] = [(80, red), (160, blue), (240, pink), (310, orange)]
        for (i, person) in people.enumerated() {
            let x = person.0, big = i < 2
            let top = big ? 110 : 122, r = big ? 18 : 12, half = big ? 18 : 12, body = big ? 60 : 42
            disc(&im, x, top, r, ink)
            disc(&im, x, top, r - 3, skin)
            rect(&im, x - half, top + r, x + half, top + r + body, person.1)
            line(&im, x - 8, top + r + body, x - 12, 270, ink)
            line(&im, x + 8, top + r + body, x + 12, 270, ink)
        }
        return im
    }

    // MARK: Re-shoot changes

    /// Dimmer, warmer light with a little sensor noise (what's left after whitening).
    static func relit(_ im: RGBA8Image) -> RGBA8Image {
        var out = im
        var seed: UInt32 = 12345
        let gains: [Double] = [0.93, 0.9, 0.84]
        for y in 0..<im.height {
            for x in 0..<im.width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Double(Int(seed >> 29) - 3) * 0.67
                let i = (y * im.width + x) * 4
                for c in 0..<3 {
                    let v = pow(Double(im.pixels[i + c]) / 255, 1.15) * gains[c] + 0.03
                    out.pixels[i + c] = UInt8(max(0, min(255, (v * 255 + noise).rounded())))
                }
            }
        }
        return out
    }

    static func shifted(_ im: RGBA8Image, _ dx: Int, _ dy: Int) -> RGBA8Image {
        var out = RGBA8Image(width: im.width, height: im.height)
        for y in 0..<im.height {
            let sy = y - dy
            guard sy >= 0, sy < im.height else { continue }
            for x in 0..<im.width {
                let sx = x - dx
                guard sx >= 0, sx < im.width else { continue }
                for c in 0..<4 { out.pixels[(y * im.width + x) * 4 + c] = im.pixels[(sy * im.width + sx) * 4 + c] }
            }
        }
        return out
    }

    /// Nearest-neighbour rotation about the centre; corners that come in are white paper.
    static func rotated(_ im: RGBA8Image, degrees: Double) -> RGBA8Image {
        var out = RGBA8Image(width: im.width, height: im.height)
        let a = degrees * Double.pi / 180, ca = cos(a), sa = sin(a)
        let cx = Double(im.width) / 2, cy = Double(im.height) / 2
        for y in 0..<im.height {
            for x in 0..<im.width {
                let fx = Double(x) - cx, fy = Double(y) - cy
                let sx = Int((ca * fx + sa * fy + cx).rounded()), sy = Int((-sa * fx + ca * fy + cy).rounded())
                guard sx >= 0, sx < im.width, sy >= 0, sy < im.height else { continue }
                for c in 0..<4 { out.pixels[(y * im.width + x) * 4 + c] = im.pixels[(sy * im.width + sx) * 4 + c] }
            }
        }
        return out
    }

    /// Trims pixels off each side (a slightly different paper crop).
    static func cropped(_ im: RGBA8Image, left: Int, top: Int, right: Int, bottom: Int) -> RGBA8Image {
        let w = im.width - left - right, h = im.height - top - bottom
        var out = RGBA8Image(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<4 { out.pixels[(y * w + x) * 4 + c] = im.pixels[((y + top) * im.width + x + left) * 4 + c] }
            }
        }
        return out
    }

    /// Every other pixel (a lower-resolution copy, like the thumbnail vs. the editor preview).
    static func halved(_ im: RGBA8Image) -> RGBA8Image {
        let w = (im.width + 1) / 2, h = (im.height + 1) / 2
        var out = RGBA8Image(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<4 { out.pixels[(y * w + x) * 4 + c] = im.pixels[((2 * y) * im.width + 2 * x) * 4 + c] }
            }
        }
        return out
    }

    static func cgImage(_ im: RGBA8Image) -> CGImage? {
        var copy = im
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let w = im.width, h = im.height
        return copy.pixels.withUnsafeMutableBytes { raw -> CGImage? in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            return ctx?.makeImage()
        }
    }
}

/// Synthetic craft renders, built like ImageProcessor.composeCraft: the cut-out on its bounding box plus a 16 % margin
/// (2.3 margins in total vertically), on one of the four backgrounds — 柔光漸層 is the radial gradient (white at 45 %
/// height to #D9DDE3 at 0.75 × the long side, interpolated in linear light) — with the two synthetic contact shadows
/// (the mask squashed onto its bottom line, blurred, tinted dark). A re-shoot is a new cut-out of the same piece:
/// smaller, turned, seen a little flatter, or under other light.
enum CraftSketch {
    typealias RGB = (Double, Double, Double)

    enum Background: CaseIterable {
        case white, warm, gray, gradient

        var center: RGB {
            switch self {
            case .white, .gradient: (255, 255, 255)
            case .warm: (241, 239, 233)
            case .gray: (230, 233, 238)
            }
        }
        var edge: RGB { self == .gradient ? (217, 221, 227) : center }
    }

    enum Piece: CaseIterable {
        /// Red paper cup with a white band, wider at the top · red ball with a blue stripe · gray-headed blue robot
        /// with yellow eyes · green triangle tree on a brown trunk.
        case cup, ball, robot, tree

        var aspect: Double {
            switch self {
            case .cup, .tree: 0.8
            case .ball: 1.0
            case .robot: 0.75
            }
        }

        func color(_ u: Double, _ v: Double) -> RGB? {
            let red: RGB = (215, 45, 50), blue: RGB = (45, 90, 210)
            switch self {
            case .cup:
                if abs(u - 0.5) > 0.5 - 0.14 * v { return nil }
                return v > 0.35 && v < 0.47 ? (245, 245, 240) : red
            case .ball:
                if (u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5) > 0.25 { return nil }
                return abs(v - 0.5) < 0.08 ? blue : red
            case .robot:
                if v < 0.32 {
                    if abs(u - 0.5) > 0.3 { return nil }
                    if v > 0.12 && v < 0.2 && (abs(u - 0.38) < 0.05 || abs(u - 0.62) < 0.05) { return (245, 205, 40) }
                    return (150, 150, 160)
                }
                return blue
            case .tree:
                if v > 0.8 { return abs(u - 0.5) < 0.1 ? (130, 80, 45) : nil }
                return abs(u - 0.5) < 0.5 * v / 0.8 ? (50, 160, 70) : nil
            }
        }
    }

    struct Cutout {
        var width: Int
        var height: Int
        var rgb: [Double]
        var mask: [Bool]
    }

    /// The piece's cut-out, cropped to its bounding box.
    static func cutout(_ piece: Piece, height: Int = 160, degrees: Double = 0, squash: Double = 1,
                       gain: RGB = (1, 1, 1)) -> Cutout {
        let bh = Double(height), bw = (Double(height) * piece.aspect).rounded()
        let side = Int(max(bw, bh) * 1.6)
        let a = degrees * Double.pi / 180, ca = cos(a), sa = sin(a), c = Double(side) / 2
        var rgb = [Double](repeating: 0, count: side * side * 3)
        var mask = [Bool](repeating: false, count: side * side)
        var x0 = side, y0 = side, x1 = -1, y1 = -1
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
                let u = (ca * dx + sa * dy) / bw + 0.5, v = (-sa * dx + ca * dy) / squash / bh + 0.5
                guard u >= 0, u < 1, v >= 0, v < 1, let col = piece.color(u, v) else { continue }
                let i = y * side + x
                mask[i] = true
                rgb[i * 3] = min(255, col.0 * gain.0)
                rgb[i * 3 + 1] = min(255, col.1 * gain.1)
                rgb[i * 3 + 2] = min(255, col.2 * gain.2)
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var out = Cutout(width: w, height: h, rgb: [Double](repeating: 0, count: w * h * 3),
                         mask: [Bool](repeating: false, count: w * h))
        for y in 0..<h {
            for x in 0..<w {
                let s = (y + y0) * side + x + x0, d = y * w + x
                out.mask[d] = mask[s]
                for k in 0..<3 { out.rgb[d * 3 + k] = rgb[s * 3 + k] }
            }
        }
        return out
    }

    private static func toLinear(_ c: Double) -> Double {
        let v = c / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func toSRGB(_ l: Double) -> Double {
        (l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055) * 255
    }

    static func render(_ cut: Cutout, on background: Background) -> RGBA8Image {
        let bw = cut.width, bh = cut.height
        let mg = Int((Double(max(bw, bh)) * 0.16).rounded())
        let cw = bw + 2 * mg, ch = bh + Int((Double(mg) * 2.3).rounded())
        var out = [Double](repeating: 0, count: cw * ch * 3)
        let c0 = background.center, c1 = background.edge
        let l0 = [toLinear(c0.0), toLinear(c0.1), toLinear(c0.2)], l1 = [toLinear(c1.0), toLinear(c1.1), toLinear(c1.2)]
        let cx = Double(cw) / 2, cy = Double(ch) * 0.45, radius = 0.75 * Double(max(cw, ch))
        for y in 0..<ch {
            for x in 0..<cw {
                let i = (y * cw + x) * 3
                if background == .gradient {
                    let t = min(1, hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) / radius)
                    for k in 0..<3 { out[i + k] = toSRGB(l0[k] * (1 - t) + l1[k] * t) }
                } else {
                    out[i] = c0.0; out[i + 1] = c0.1; out[i + 2] = c0.2
                }
            }
        }
        var full = [Float](repeating: 0, count: cw * ch)
        for y in 0..<bh { for x in 0..<bw where cut.mask[y * bw + x] { full[(y + mg) * cw + x + mg] = 1 } }
        let bottom = Double(mg + bh)
        let shadows: [(squash: Double, blur: Double, drop: Double, opacity: Double)] = [(0.22, 0.05, 0.01, 0.28),
                                                                                        (0.06, 0.015, 0.002, 0.55)]
        for s in shadows {
            var squashed = [Float](repeating: 0, count: cw * ch)
            for y in 0..<ch {
                let src = Int((bottom - (bottom - (Double(y) - s.drop * Double(ch))) / s.squash + 0.5).rounded(.down))
                guard src >= 0, src < ch else { continue }
                for x in 0..<cw { squashed[y * cw + x] = full[src * cw + x] }
            }
            let radius = max(1, Int((s.blur * Double(cw) + 0.5).rounded(.down)))
            let blurred = ImageOps.blur3(squashed, cw, ch, radius)
            for p in 0..<(cw * ch) {
                let alpha = min(1, max(0, Double(blurred[p]) * s.opacity))
                out[p * 3] = out[p * 3] * (1 - alpha) + 38 * alpha
                out[p * 3 + 1] = out[p * 3 + 1] * (1 - alpha) + 34 * alpha
                out[p * 3 + 2] = out[p * 3 + 2] * (1 - alpha) + 30 * alpha
            }
        }
        for y in 0..<bh {
            for x in 0..<bw where cut.mask[y * bw + x] {
                let d = ((y + mg) * cw + x + mg) * 3, s = (y * bw + x) * 3
                for k in 0..<3 { out[d + k] = cut.rgb[s + k] }
            }
        }
        var image = RGBA8Image(width: cw, height: ch)
        for p in 0..<(cw * ch) {
            for k in 0..<3 { image.pixels[p * 4 + k] = UInt8(max(0, min(255, (out[p * 3 + k] + 0.5).rounded(.down)))) }
        }
        return image
    }

    static func image(_ piece: Piece, on background: Background, height: Int = 160, degrees: Double = 0,
                      squash: Double = 1, gain: RGB = (1, 1, 1)) -> RGBA8Image {
        render(cutout(piece, height: height, degrees: degrees, squash: squash, gain: gain), on: background)
    }
}

/// 這張好像收過了 for crafts. NumPy port of the same renders (threshold 0.40):
/// different crafts 0.53 and up on every background (closest: the red cup vs. the red ball; the gradient is no closer
/// than the plain backgrounds), re-shoots 0.33 at most, the same piece on another background ≤ 0.07.
struct CraftFingerprintTests {
    private func fp(_ im: RGBA8Image) throws -> ArtFingerprint {
        try #require(ArtFingerprint.make(im))
    }

    @Test func differentCraftsDoNotMatchOnAnyBackground() throws {
        let pieces = CraftSketch.Piece.allCases
        for background in CraftSketch.Background.allCases {
            let prints = try pieces.map { try fp(CraftSketch.image($0, on: background)) }
            for i in 0..<pieces.count {
                for j in 0..<pieces.count where j != i {
                    let score = prints[i].score(against: prints[j])
                    #expect(!prints[i].isLikelyDuplicate(of: prints[j]),
                            "\(background): \(pieces[i]) vs \(pieces[j]): \(String(describing: score))")
                }
            }
        }
    }

    @Test func reshotCraftMatches() throws {
        for background in [CraftSketch.Background.white, .gradient] {
            for piece in CraftSketch.Piece.allCases {
                let original = try fp(CraftSketch.image(piece, on: background))
                let reshoots: [(String, RGBA8Image)] = [
                    ("smaller", CraftSketch.image(piece, on: background, height: 120)),
                    ("turned 4°", CraftSketch.image(piece, on: background, degrees: 4)),
                    ("turned -6°", CraftSketch.image(piece, on: background, degrees: -6)),
                    ("relit", CraftSketch.image(piece, on: background, gain: (0.92, 0.9, 0.84))),
                    ("all at once", CraftSketch.image(piece, on: background, height: 130, degrees: -3, squash: 0.94,
                                                      gain: (0.95, 0.93, 0.88))),
                ]
                for (name, image) in reshoots {
                    let b = try fp(image)
                    let score = original.score(against: b)
                    #expect(original.isLikelyDuplicate(of: b), "\(background) \(piece) \(name): \(String(describing: score))")
                }
            }
        }
    }

    /// Switching the background (純白 → 柔光漸層 / 淺灰) keeps it the same piece.
    @Test func sameCraftOnAnotherBackgroundMatches() throws {
        for piece in CraftSketch.Piece.allCases {
            let white = try fp(CraftSketch.image(piece, on: .white))
            let gradient = try fp(CraftSketch.image(piece, on: .gradient))
            let gray = try fp(CraftSketch.image(piece, on: .gray))
            #expect(white.isLikelyDuplicate(of: gradient), "\(piece) white vs gradient")
            #expect(white.isLikelyDuplicate(of: gray), "\(piece) white vs gray")
        }
    }
}

/// 這張好像收過了: the fingerprint and the matcher. (Scores were checked against a NumPy port of ArtFingerprint:
/// re-shoots score 0.02–0.27, different drawings 0.72 and up; the threshold is 0.40.)
struct ArtFingerprintTests {
    private func fp(_ im: RGBA8Image) throws -> ArtFingerprint {
        try #require(ArtFingerprint.make(im))
    }

    @Test func encodingRoundTrips() throws {
        let a = try fp(Sketch.house())
        let data = a.encoded
        #expect(data.count == ArtFingerprint.encodedCount)
        #expect(ArtFingerprint(data: data) == a)
        #expect(ArtFingerprint(data: nil) == nil)
        #expect(ArtFingerprint(data: Data([1, 2, 3])) == nil)
        var otherVersion = [UInt8](data)
        otherVersion[0] = ArtFingerprint.version &+ 1
        #expect(ArtFingerprint(data: Data(otherVersion)) == nil)
    }

    @Test func sameImageScoresZero() throws {
        let a = try fp(Sketch.house())
        #expect(a.score(against: a) == 0)
        #expect(a.isLikelyDuplicate(of: a))
    }

    @Test func reshotDrawingMatches() throws {
        let original = Sketch.house()
        let a = try fp(original)
        let reshoots: [(String, RGBA8Image)] = [
            ("relit", Sketch.relit(original)),
            ("shifted", Sketch.shifted(original, 12, 8)),
            ("rotated", Sketch.rotated(original, degrees: 3)),
            ("rotated back", Sketch.rotated(original, degrees: -2)),
            ("cropped", Sketch.cropped(original, left: 16, top: 12, right: 8, bottom: 6)),
            ("half size", Sketch.halved(original)),
            ("all at once", Sketch.relit(Sketch.rotated(Sketch.shifted(
                Sketch.cropped(original, left: 10, top: 0, right: 0, bottom: 8), -6, 4), degrees: 2))),
        ]
        for (name, image) in reshoots {
            let b = try fp(image)
            let score = a.score(against: b)
            #expect(a.isLikelyDuplicate(of: b), "\(name): \(String(describing: score))")
            #expect(b.isLikelyDuplicate(of: a), "\(name) (reversed)")
        }
    }

    @Test func differentDrawingsBySameKidDoNotMatch() throws {
        let drawings: [(String, RGBA8Image)] = [
            ("house", Sketch.house()),
            ("house again", Sketch.houseAgain()),
            ("tree and car", Sketch.treeAndCar()),
            ("family", Sketch.family()),
        ]
        let prints = try drawings.map { try fp($0.1) }
        for i in 0..<prints.count {
            for j in 0..<prints.count where j != i {
                let score = prints[i].score(against: prints[j])
                #expect(!prints[i].isLikelyDuplicate(of: prints[j]),
                        "\(drawings[i].0) vs \(drawings[j].0): \(String(describing: score))")
            }
        }
        // Still apart under different light.
        let relitAgain = try fp(Sketch.relit(Sketch.houseAgain()))
        #expect(!prints[0].isLikelyDuplicate(of: relitAgain))
    }

    @Test func emptySheetsAreNeverDuplicates() throws {
        let blank = try fp(RGBA8Image(width: 400, height: 300))
        #expect(!blank.isLikelyDuplicate(of: blank))
        let house = try fp(Sketch.house())
        #expect(!blank.isLikelyDuplicate(of: house))
    }

    @Test func differentShapeIsNotADuplicate() throws {
        let landscape = try fp(Sketch.house())
        let portrait = try fp(Sketch.cropped(Sketch.house(), left: 125, top: 0, right: 125, bottom: 0))  // 150×300
        #expect(landscape.score(against: portrait) == nil)
    }

    /// The real path: the stored JPEG thumbnail decoded by ImageIO at ≤ 128 px vs. the editor preview drawn with CG.
    @Test func thumbnailAndPreviewPathsAgree() throws {
        let image = try #require(Sketch.cgImage(Sketch.house()))
        let jpeg = try #require(ImageEncoding.jpegData(image, quality: 0.8))
        let fromThumbnail = try #require(ArtFingerprint.make(fromImageData: jpeg))
        let fromPreview = try #require(ArtFingerprint.make(cgImage: image))
        #expect(fromThumbnail.isLikelyDuplicate(of: fromPreview))
        let direct = try fp(Sketch.house())
        #expect(fromPreview.isLikelyDuplicate(of: direct))
        let otherImage = try #require(Sketch.cgImage(Sketch.treeAndCar()))
        let other = try #require(ArtFingerprint.make(cgImage: otherImage))
        #expect(!fromThumbnail.isLikelyDuplicate(of: other))
    }

    @Test func sameChildWinsOverACloserMatch() throws {
        let original = Sketch.house()
        let capture = try fp(Sketch.relit(original))
        let mia = UUID(), leo = UUID()
        let exactPrint = try fp(original)
        let shiftedPrint = try fp(Sketch.shifted(original, 12, 8))
        let familyPrint = try fp(Sketch.family())
        let exact = DuplicateFinder.Candidate(id: UUID(), childID: leo, fingerprint: exactPrint)
        let shifted = DuplicateFinder.Candidate(id: UUID(), childID: mia, fingerprint: shiftedPrint)
        let unrelated = DuplicateFinder.Candidate(id: UUID(), childID: mia, fingerprint: familyPrint)

        #expect(DuplicateFinder.bestMatch(for: capture, childID: mia, among: [exact, shifted, unrelated]) == shifted.id)
        #expect(DuplicateFinder.bestMatch(for: capture, childID: leo, among: [exact, shifted, unrelated]) == exact.id)
        // No child picked: simply the closest.
        #expect(DuplicateFinder.bestMatch(for: capture, childID: nil, among: [shifted, exact, unrelated]) == exact.id)
        #expect(DuplicateFinder.bestMatch(for: capture, childID: mia, among: [unrelated]) == nil)
        #expect(DuplicateFinder.bestMatch(for: capture, childID: mia, among: []) == nil)
    }

    /// A few thousand stored fingerprints: comparing must stay instant (most are rejected by the cheap parts).
    @Test func comparingAgainstThousandsIsCheap() throws {
        let drawings = [Sketch.houseAgain(), Sketch.treeAndCar(), Sketch.family()]
        let prints = try drawings.map { try fp($0) }
        let candidates = (0..<3000).map { i in
            DuplicateFinder.Candidate(id: UUID(), childID: nil, fingerprint: prints[i % prints.count])
        }
        let capture = try fp(Sketch.house())
        let start = Date()
        #expect(DuplicateFinder.bestMatch(for: capture, childID: nil, among: candidates) == nil)
        #expect(Date().timeIntervalSince(start) < 2)   // debug build on a CI simulator; release is ~100× faster
    }
}

/// The SwiftData side: which artworks are compared, and the launch backfill.
@MainActor
struct DuplicateLookupTests {
    private func makeArtwork(_ kind: ArtworkKind = .flat, kept: Bool = true, sample: Bool = false,
                             fingerprint: ArtFingerprint?, child: Child? = nil, in context: ModelContext) -> Artwork {
        let a = Artwork(kind: kind, child: child, capturedAt: day(2026, 10, 28), originalImageData: Data([0, 1, 2]))
        a.isKept = kept
        a.isSample = sample
        a.fingerprintData = fingerprint?.encoded
        context.insert(a)
        return a
    }

    @Test func onlyKeptMuseumArtworksOfTheSameKindAreCompared() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let house = try #require(ArtFingerprint.make(Sketch.house()))
        let capture = try #require(ArtFingerprint.make(Sketch.relit(Sketch.house())))
        let pending = makeArtwork(kept: false, fingerprint: house, in: context)
        _ = makeArtwork(sample: true, fingerprint: house, in: context)
        _ = makeArtwork(.craft, fingerprint: house, in: context)
        _ = makeArtwork(fingerprint: nil, in: context)
        try context.save()

        #expect(app.likelyDuplicate(of: capture, kind: .flat, childID: nil, excluding: pending.id, context: context) == nil)

        let kept = makeArtwork(fingerprint: house, in: context)
        let family = try #require(ArtFingerprint.make(Sketch.family()))
        _ = makeArtwork(fingerprint: family, in: context)
        try context.save()
        let found = app.likelyDuplicate(of: capture, kind: .flat, childID: nil, excluding: pending.id, context: context)
        #expect(found?.id == kept.id)
        // The artwork itself is never its own duplicate.
        #expect(app.likelyDuplicate(of: capture, kind: .flat, childID: nil, excluding: kept.id, context: context) == nil)
    }

    @Test func backfillFingerprintsArtworksFromTheirThumbnails() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let image = try #require(Sketch.cgImage(Sketch.house()))
        let old = makeArtwork(fingerprint: nil, in: context)
        old.thumbnailData = ImageEncoding.jpegData(image, quality: 0.8)
        let pendingOld = makeArtwork(kept: false, fingerprint: nil, in: context)
        pendingOld.thumbnailData = old.thumbnailData
        let noThumbnail = makeArtwork(fingerprint: nil, in: context)
        try context.save()
        // The stored thumbnail survives the save and decodes (so a failure below is the backfill itself).
        let thumbnail = try #require(old.thumbnailData)
        #expect(ArtFingerprint.make(fromImageData: thumbnail) != nil)

        await app.backfillFingerprints(context: context)

        let stored = try #require(ArtFingerprint(data: old.fingerprintData))
        let direct = try #require(ArtFingerprint.make(Sketch.house()))
        #expect(stored.isLikelyDuplicate(of: direct))
        #expect(ArtFingerprint(data: pendingOld.fingerprintData) != nil)
        #expect(noThumbnail.fingerprintData == nil)
    }
}
