import Foundation
import CoreGraphics
import Testing
@testable import FridgeMuseum

// MARK: - Helpers

/// Pinhole projection of a W×H sheet (metres) lying on a table, seen at `pitch` (degrees from straight down),
/// turned by `yaw` / `roll`, focal length `f` pixels, principal point at the image centre. Returns TL, TR, BR, BL pixels.
private func projectSheet(width sw: Double, height sh: Double, pitch: Double, yaw: Double, roll: Double,
                          focal f: Double, imageWidth iw: Double, imageHeight ih: Double, distance: Double = 0.5) -> [NormPoint] {
    let p = pitch * .pi / 180, y = yaw * .pi / 180, r = roll * .pi / 180
    func mul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }
    let Rx = [[1, 0, 0], [0, cos(p), -sin(p)], [0, sin(p), cos(p)]]
    let Ry = [[cos(y), 0, sin(y)], [0, 1, 0], [-sin(y), 0, cos(y)]]
    let Rz = [[cos(r), -sin(r), 0], [sin(r), cos(r), 0], [0, 0, 1]]
    let R = mul(mul(Rz, Ry), Rx)
    let corners = [(-sw / 2, -sh / 2), (sw / 2, -sh / 2), (sw / 2, sh / 2), (-sw / 2, sh / 2)]
    return corners.map { X, Y in
        let px = R[0][0] * X + R[0][1] * Y, py = R[1][0] * X + R[1][1] * Y, pz = R[2][0] * X + R[2][1] * Y + distance
        return NormPoint(x: f * px / pz + iw / 2, y: f * py / pz + ih / 2)
    }
}

private func tinyImage() -> RenderedImage {
    let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return RenderedImage(cgImage: ctx.makeImage()!)
}

private func close(_ a: CGPoint, _ b: CGPoint, _ tol: Double = 1e-6) -> Bool {
    abs(Double(a.x - b.x)) < tol && abs(Double(a.y - b.y)) < tol
}

// MARK: - Paper aspect (Zhang & He) with synthetic homographies

struct PaperAspectTests {
    static let iw = 4000.0, ih = 3000.0, L = 4000.0

    /// A4 photographed 30–45° off straight-down, phone main camera (26 mm ≈ 0.75 × long edge).
    @Test(arguments: [30.0, 35.0, 40.0, 45.0])
    func a4AtPitchWithMainCamera(pitch: Double) {
        for (yaw, roll) in [(0.0, 0.0), (0.0, 5.0), (0.0, -20.0), (10.0, 0.0), (-15.0, 5.0), (12.0, -20.0)] {
            for landscape in [true, false] {
                let (w, h) = landscape ? (0.297, 0.21) : (0.21, 0.297)
                let q = projectSheet(width: w, height: h, pitch: pitch, yaw: yaw, roll: roll, focal: 0.75 * Self.L,
                                     imageWidth: Self.iw, imageHeight: Self.ih)
                let r = PaperAspect.estimate(q, imageWidth: Self.iw, imageHeight: Self.ih)
                let truth = landscape ? 2.0.squareRoot() : 1 / 2.0.squareRoot()
                #expect(abs(r / truth - 1) < 0.03, "pitch \(pitch) yaw \(yaw) roll \(roll) landscape \(landscape): \(r)")
            }
        }
    }

    /// When both side pairs converge the focal length is estimated from the corners (other lenses work too).
    @Test(arguments: [30.0, 35.0, 40.0, 45.0])
    func a4AtPitchEstimatesFocal(pitch: Double) {
        for f in [0.75, 1.0, 1.2] {
            for yaw in [10.0, -15.0] {
                let q = projectSheet(width: 0.297, height: 0.21, pitch: pitch, yaw: yaw, roll: 5, focal: f * Self.L,
                                     imageWidth: Self.iw, imageHeight: Self.ih)
                let raw = PaperAspect.estimate(q, imageWidth: Self.iw, imageHeight: Self.ih, snap: false)
                #expect(abs(raw / 2.0.squareRoot() - 1) < 0.03, "f \(f) yaw \(yaw): \(raw)")
            }
        }
    }

    /// Straight pitch with a non-main lens: one side pair stays parallel, so the EXIF focal length is needed.
    @Test func exifFocalFixesParallelSides() {
        for pitch in [30.0, 45.0] {
            let f = 1.2 * Self.L
            let q = projectSheet(width: 0.297, height: 0.21, pitch: pitch, yaw: 0, roll: 0, focal: f,
                                 imageWidth: Self.iw, imageHeight: Self.ih)
            let r = PaperAspect.estimate(q, imageWidth: Self.iw, imageHeight: Self.ih, focalPixels: f)
            #expect(abs(r / 2.0.squareRoot() - 1) < 0.03)
        }
        // 26 mm on a 4:3 frame is the 0.75 × long-edge guess.
        let fp = PaperAspect.focalPixels(focal35mm: 26, imageWidth: 4000, imageHeight: 3000) ?? 0
        #expect(abs(fp / 3000 - 1) < 0.01)
        #expect(PaperAspect.focalPixels(focal35mm: 0, imageWidth: 4000, imageHeight: 3000) == nil)
    }

    @Test func snapsToCommonSheets() {
        func rect(_ r: Double) -> [NormPoint] {
            [.init(x: 100, y: 100), .init(x: 100 + 1000 * r, y: 100), .init(x: 100 + 1000 * r, y: 1100), .init(x: 100, y: 1100)]
        }
        #expect(PaperAspect.estimate(rect(1.39), imageWidth: 4000, imageHeight: 3000) == 2.0.squareRoot())
        #expect(PaperAspect.estimate(rect(1.0 / 1.39), imageWidth: 4000, imageHeight: 3000) == 1 / 2.0.squareRoot())
        #expect(PaperAspect.estimate(rect(1.02), imageWidth: 4000, imageHeight: 3000) == 1)
        #expect(abs(PaperAspect.estimate(rect(1.9), imageWidth: 4000, imageHeight: 3000) - 1.9) < 1e-9)   // nothing near: kept
    }

    @Test func outputSizeUsesTrueAspect() {
        let px = projectSheet(width: 0.297, height: 0.21, pitch: 40, yaw: 10, roll: 0, focal: 0.75 * Self.L,
                              imageWidth: Self.iw, imageHeight: Self.ih)
        let n = px.map { NormPoint(x: $0.x / Self.iw, y: $0.y / Self.ih) }
        let q = Quad(topLeft: n[0], topRight: n[1], bottomRight: n[2], bottomLeft: n[3])
        let s = q.outputSize(imageWidth: Self.iw, imageHeight: Self.ih, maxEdge: 1600)
        #expect(abs(Double(s.width) / Double(s.height) / 2.0.squareRoot() - 1) < 0.01)
        #expect(max(s.width, s.height) <= 1600)
    }
}

// MARK: - Specks: dotted patterns are kept

struct SpeckPatternTests {
    private func dots(_ count: Int, edgeDot: Bool = false) -> RGBA8Image {
        var img = RGBA8Image(width: 400, height: 400)
        var placed = 0
        outer: for gy in 0..<6 {
            for gx in 0..<6 {
                if placed == count { break outer }
                let x = 40 + gx * 60, y = 40 + gy * 60
                for yy in y..<(y + 2) { for xx in x..<(x + 2) { img.set(xx, yy, (90, 90, 90)) } }
                placed += 1
            }
        }
        if edgeDot { for yy in 200..<202 { for xx in 0..<2 { img.set(xx, yy, (90, 90, 90)) } } }
        return img
    }

    @Test func fewDotsAreDust() {
        var img = dots(5)
        let o = SpeckRemover.clean(&img)
        #expect(o.removed == 5)
        #expect(!o.keptAsPattern)
        #expect(img.pixels[(40 * 400 + 40) * 4] == 255)
    }

    @Test func manyDotsAreAPattern() {
        var img = dots(20, edgeDot: true)
        let o = SpeckRemover.clean(&img)
        #expect(o.keptAsPattern)
        #expect(o.removed == 0)
        #expect(img.pixels[(40 * 400 + 40) * 4] == 90)        // inner dot kept
        #expect(img.pixels[(200 * 400 + 0) * 4] == 255)       // bit on the sheet edge always cleaned
    }

    @Test func ruleBoundary() {
        #expect(!SpeckRemover.isPattern(innerDots: 14))
        #expect(SpeckRemover.isPattern(innerDots: 15))
        var img = dots(14)
        #expect(SpeckRemover.clean(&img).removed == 14)
    }
}

// MARK: - Edge fill: table showing in a torn corner

struct EdgeFillTests {
    private let table: (UInt8, UInt8, UInt8) = (150, 100, 60)

    private func photo() -> RGBA8Image {
        var small = RGBA8Image(width: 240, height: 180, fill: table)
        for y in 27..<153 { for x in 36..<204 { small.set(x, y, (242, 240, 236)) } }
        return small
    }

    private func sheet(tornCorner: Bool) -> RGBA8Image {
        var img = RGBA8Image(width: 600, height: 450, fill: (242, 240, 236))
        if tornCorner { for y in 0..<60 { for x in 0..<(60 - y) { img.set(x, y, table) } } }
        for x in 100..<500 { for y in 224..<227 { img.set(x, y, (30, 30, 30)) } }
        return img
    }

    @Test func fillsTornCornerWithPaper() throws {
        var img = sheet(tornCorner: true)
        let ef = try #require(EdgeFill.detect(warped: img, small: photo(), quad: .inset(0.15)))
        #expect(ef.area > 0 && ef.area < 0.12)
        EdgeFill.apply(ef, to: &img, rgb: SIMD3<Float>(255, 255, 255))
        let corner = (5 * 600 + 5) * 4
        #expect(img.pixels[corner] > 230 && img.pixels[corner + 2] > 230)
        #expect(img.pixels[(225 * 600 + 300) * 4] == 30)   // the stroke is untouched
        #expect(img.pixels[(100 * 600 + 300) * 4] == 242)  // the paper is untouched
    }

    @Test func cleanSheetNeedsNoFill() {
        #expect(EdgeFill.detect(warped: sheet(tornCorner: false), small: photo(), quad: .inset(0.15)) == nil)
    }
}

// MARK: - Turning and output ↔ original mapping

struct TurningTests {
    @Test func quarterTurnsMoveSeedsLikeTheImage() {
        let p = NormPoint(x: 0.2, y: 0.1)
        let t90 = Turning.turnNormalized(p, width: 400, height: 300, degrees: 90)
        let t180 = Turning.turnNormalized(p, width: 400, height: 300, degrees: 180)
        let t270 = Turning.turnNormalized(p, width: 400, height: 300, degrees: 270)
        #expect(abs(t90.x - 0.9) < 1e-12 && abs(t90.y - 0.2) < 1e-12)     // clockwise: (1 − y, x)
        #expect(abs(t180.x - 0.8) < 1e-12 && abs(t180.y - 0.9) < 1e-12)
        #expect(abs(t270.x - 0.1) < 1e-12 && abs(t270.y - 0.8) < 1e-12)
        let s = Turning.turnedSize(width: 400, height: 300, degrees: 90)
        #expect(s.width == 300 && s.height == 400)
        let tilt = Turning.turnedSize(width: 400, height: 300, degrees: 10)
        #expect(tilt.width > 400 && tilt.height > 300)
    }

    @Test func recipeTurnHelpers() {
        var r = ProcessingRecipe(kind: .flat)
        r.rotateCounterClockwise()
        #expect(r.quarterTurns == 3)
        r.rotateClockwise()
        r.rotateClockwise()
        #expect(r.quarterTurns == 1)
        r.straightenDegrees = -4.5
        #expect(r.turnDegrees == 85.5)
    }

    /// Flat: output → (unturn) → sheet → (homography) → photo, and back.
    @Test(arguments: [0.0, 90.0, 180.0, 270.0, 97.5, -12.0])
    func flatMappingRoundTrips(degrees: Double) {
        let quad = Quad(topLeft: .init(x: 0.12, y: 0.1), topRight: .init(x: 0.9, y: 0.15),
                        bottomRight: .init(x: 0.85, y: 0.92), bottomLeft: .init(x: 0.08, y: 0.85))
        let W = 1000, H = 700
        let size = degrees == 0 ? (width: W, height: H) : Turning.turnedSize(width: Double(W), height: Double(H), degrees: degrees)
        let toBase = degrees == 0 ? Affine2D.identity : (Turning.forward(width: Double(W), height: Double(H), degrees: degrees).inverted ?? .identity)
        let m = OutputMapping(outputWidth: size.width, outputHeight: size.height, baseWidth: W, baseHeight: H, outputToBase: toBase, quad: quad)
        // the sheet's centre maps to the turned output's centre
        let c = m.toStrokeSpace(CGPoint(x: 0.5, y: 0.5))
        #expect(abs(Double(c.x) - 0.5) < 1e-3 && abs(Double(c.y) - 0.5) < 1e-3)
        for p in [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.6, y: 0.7)] {
            let o = m.toOriginal(p)
            let back = m.fromOriginal(o)
            #expect(back != nil && close(back!, p, 1e-6))
        }
        // a sheet corner maps to the photo corner
        if degrees == 0 { #expect(close(m.toOriginal(CGPoint(x: 0, y: 0)), CGPoint(x: 0.12, y: 0.1), 1e-9)) }
        if degrees == 90 { #expect(close(m.toOriginal(CGPoint(x: 1, y: 0)), CGPoint(x: 0.12, y: 0.1), 1e-9)) }
        // brush radius: same pixel size in both spaces
        let r = m.strokeRadius(fromOutputRadius: 0.01)
        #expect(abs(r * Double(max(W, H)) - 0.01 * Double(max(size.width, size.height))) < 1e-6)
    }

    /// Craft: the crop/turn map keeps seeds where they are in the original, whatever the turn.
    @Test(arguments: [0.0, 90.0, 270.0, 8.0])
    func craftSeedsSurviveTurning(degrees: Double) {
        let W = 800, H = 600, scale = 0.5
        let place = Affine2D.translation(-400, -300).then(.rotation(degrees: degrees)).then(.translation(260, 250))
        let toBase = Affine2D.scale(1 / scale, 1 / scale).then(place.inverted!)
        let m = OutputMapping(outputWidth: 260, outputHeight: 250, baseWidth: W, baseHeight: H, outputToBase: toBase, quad: nil)
        let seed = CGPoint(x: 0.45, y: 0.55)
        let out = m.fromOriginal(seed)!
        #expect(close(m.toOriginal(out), seed, 1e-9))
        #expect(close(m.toStrokeSpace(out), seed, 1e-9))
        let centre = m.fromOriginal(CGPoint(x: 0.5, y: 0.5))!
        #expect(close(centre, CGPoint(x: 0.5, y: 0.5), 1e-9))   // turned about the object's middle
    }
}

// MARK: - Craft parts: analysis, auto drop, hit testing, tap-to-keep

struct CutoutPartTests {
    static let W = 320, H = 240

    private func alpha(_ rects: [(Int, Int, Int, Int)]) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: Self.W * Self.H)
        for (x0, y0, x1, y1) in rects { for y in y0..<y1 { for x in x0..<x1 { a[y * Self.W + x] = 255 } } }
        return a
    }

    /// Big object in the middle, two small things running off the right and bottom edges.
    private var clutter: [UInt8] { alpha([(100, 60, 220, 180), (300, 20, 320, 50), (20, 225, 60, 240)]) }

    @Test func splitsIntoParts() throws {
        let a = try #require(CutoutParts.analyze(alpha: clutter, width: Self.W, height: Self.H))
        #expect(a.parts.count == 3)
        #expect(a.significantCount == 3)
        let main = try #require(a.part(a.main))
        #expect(main.area > 10000)
        #expect(!main.touches)
        let seed = a.seed(of: main)
        #expect(abs(Double(seed.x) - 0.5) < 0.03 && abs(Double(seed.y) - 0.5) < 0.03)
    }

    @Test func autoDropsEdgeClutterFarFromTheObject() throws {
        let a = try #require(CutoutParts.analyze(alpha: clutter, width: Self.W, height: Self.H))
        let seeds = CutoutParts.autoDropSeeds(a)
        #expect(seeds.count == 2)
        let drops = CutoutParts.drops(a, seeds: seeds)
        #expect(drops.count == 2 && !drops.contains(a.main))
        var al = clutter
        CutoutParts.apply(drops: drops, a, to: &al, width: Self.W, height: Self.H)
        #expect(al[35 * Self.W + 310] == 0)
        #expect(al[120 * Self.W + 160] == 255)
    }

    @Test func keepsThingsNearTheObjectOrNotAtTheEdge() throws {
        // a small piece touching the object's side, and one in the open: nothing is auto-dropped
        let near = try #require(CutoutParts.analyze(alpha: alpha([(100, 60, 220, 180), (222, 100, 240, 120)]), width: Self.W, height: Self.H))
        #expect(CutoutParts.autoDropSeeds(near).isEmpty)
        let inside = try #require(CutoutParts.analyze(alpha: alpha([(100, 60, 220, 180), (20, 20, 40, 40)]), width: Self.W, height: Self.H))
        #expect(CutoutParts.autoDropSeeds(inside).isEmpty)
    }

    @Test func instancesDefineParts() throws {
        // two blobs of one Vision instance are one part; two touching blobs of different instances are two
        var labels = [UInt8](repeating: 0, count: 32 * 24)
        for y in 0..<24 { for x in 0..<32 { labels[y * 32 + x] = x < 16 ? 1 : 2 } }
        let a = try #require(CutoutParts.analyze(alpha: alpha([(20, 20, 60, 60), (80, 20, 120, 60), (140, 100, 300, 200)]),
                                                 width: Self.W, height: Self.H, instances: (labels, 32, 24)))
        #expect(a.parts.count == 2)
        let b = try #require(CutoutParts.analyze(alpha: alpha([(100, 60, 220, 180)]), width: Self.W, height: Self.H,
                                                 instances: (labels, 32, 24)))
        #expect(b.parts.count == 2)
    }

    @Test func neverRemovesEverything() throws {
        let a = try #require(CutoutParts.analyze(alpha: alpha([(100, 60, 220, 180)]), width: Self.W, height: Self.H))
        #expect(CutoutParts.drops(a, seeds: [a.seed(of: a.parts[0])]).isEmpty)
    }

    private func result(for a: PartAnalysis, drops: Set<Int>) -> PreviewResult {
        let mapping = OutputMapping.identity(width: Self.W, height: Self.H)
        let parts = a.parts.filter(\.significant).map {
            CutoutPart(id: $0.id, bounds: a.originalBounds(of: $0), seed: a.seed(of: $0), isRemoved: drops.contains($0.id),
                       originalBounds: a.originalBounds(of: $0), touchesEdge: $0.touches, isMain: $0.id == a.main)
        }
        return PreviewResult(output: tinyImage(), before: nil, specksRemoved: 0, outputToSource: nil, parts: parts,
                             notes: [], paperMode: nil, mapping: mapping, partMap: a.map)
    }

    @Test func hitTestingAndTapToKeep() throws {
        let a = try #require(CutoutParts.analyze(alpha: clutter, width: Self.W, height: Self.H))
        let auto = CutoutParts.drops(a, seeds: CutoutParts.autoDropSeeds(a))
        let res = result(for: a, drops: auto)
        #expect(res.canPickParts)
        #expect(res.partID(atOutputPoint: CGPoint(x: 0.5, y: 0.5)) == a.main)
        #expect(ImageProcessor.shared.partID(atOutputPoint: CGPoint(x: 0.5, y: 0.5), in: res) == a.main)
        #expect(res.partID(atOutputPoint: CGPoint(x: 0.1, y: 0.4)) == nil)
        let edgeID = try #require(res.partID(atOutputPoint: CGPoint(x: 310.0 / 320, y: 35.0 / 240)))
        #expect(edgeID != a.main)
        // the rim belongs to its part (soft edge), one cell outside still hits
        #expect(res.partID(atOutputPoint: CGPoint(x: 222.0 / 320, y: 0.5)) == a.main)

        // tap an auto-dropped part → it comes back, the other stays dropped, auto drop is off from now on
        var recipe = ProcessingRecipe(kind: .craft)
        recipe = try #require(PartPicking.toggle(partID: edgeID, in: res, recipe: recipe))
        #expect(recipe.partsEdited)
        #expect(recipe.removedPartSeeds.count == 1)
        #expect(CutoutParts.drops(a, seeds: recipe.removedPartSeeds).count == 1)
        #expect(!CutoutParts.drops(a, seeds: recipe.removedPartSeeds).contains(edgeID))

        // removing the only kept part is refused
        let single = result(for: a, drops: Set(a.parts.map(\.id)).subtracting([a.main]))
        #expect(PartPicking.toggle(partID: a.main, in: single, recipe: recipe) == nil)
        #expect(PartPicking.keepAll(recipe).removedPartSeeds.isEmpty)
    }
}

// MARK: - Flatten paper modes

struct PaperModeTests {
    private func grid(_ f: (Int, Int) -> (Float, Float, Float)) -> FlattenModel {
        let sw = 50, sh = 40
        var R = [Float](), G = [Float](), B = [Float]()
        for y in 0..<sh { for x in 0..<sw { let c = f(x, y); R.append(c.0); G.append(c.1); B.append(c.2) } }
        return IlluminationEstimator.estimate(R: R, G: G, B: B, Q: [Float](repeating: 0, count: sw * sh), width: sw, height: sh, blockSize: 4)
    }

    @Test func whitePaper() {
        let m = grid { x, y in (x == 25 && y > 5) ? (0.2, 0.2, 0.2) : (0.86, 0.84, 0.8) }
        #expect(m.mode == .white)
        #expect(m.gain == 0.97)
    }

    @Test func colouredPaperKeepsItsColour() {
        let m = grid { _, _ in (0.35, 0.55, 0.86) }
        #expect(m.mode == .colored)
        #expect(m.gain == 1)
        #expect(abs(m.map[0] - m.map[2]) < 1e-6)   // grey light map: only the light is evened out
    }

    @Test func blackPaper() {
        #expect(grid { _, _ in (0.12, 0.12, 0.13) }.mode == .colored)
    }

    @Test func paintCoveredSheet() {
        let m = grid { x, _ in
            if x < 9 { return (0.95, 0.95, 0.93) }
            let t = Float(x - 9) / 40
            return (0.15 + 0.4 * t, 0.25 + 0.4 * t, 0.55 + 0.3 * t)
        }
        #expect(m.mode == .paintCovered)
        #expect(m.cover < 0.2)
    }
}

// MARK: - Paper detection and craft fallback

struct DetectorPortTests {
    @Test func findsTurnedSheet() {
        var img = RGBA8Image(width: 300, height: 225, fill: (120, 80, 50))
        let c = (150.0, 112.0), a = 12.0 * Double.pi / 180, hw = 90.0, hh = 64.0
        for y in 0..<225 {
            for x in 0..<300 {
                let dx = Double(x) + 0.5 - c.0, dy = Double(y) + 0.5 - c.1
                let u = dx * cos(a) + dy * sin(a), v = -dx * sin(a) + dy * cos(a)
                if abs(u) < hw && abs(v) < hh { img.set(x, y, (240, 238, 232)) }
            }
        }
        let r = PaperDetector.detectFull(img)
        #expect(!r.isGuess)
        func corner(_ su: Double, _ sv: Double) -> NormPoint {
            let u = su * hw, v = sv * hh
            return NormPoint(x: (c.0 + u * cos(a) - v * sin(a)) / 300, y: (c.1 + u * sin(a) + v * cos(a)) / 225)
        }
        let expected = [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)]
        for (got, want) in zip(r.quad.points, expected) {
            #expect(abs(got.x - want.x) < 0.03 && abs(got.y - want.y) < 0.03, "\(got) vs \(want)")
        }
    }

    @Test func colouredSheetOnTable() {
        var img = RGBA8Image(width: 240, height: 180, fill: (170, 160, 150))
        for y in 40..<140 { for x in 50..<190 { img.set(x, y, (60, 110, 200)) } }
        let r = PaperDetector.detectFull(img)
        #expect(!r.isGuess)
        #expect(abs(r.quad.topLeft.x - 50.0 / 240) < 0.03 && abs(r.quad.bottomRight.y - 140.0 / 180) < 0.03)
    }

    @Test func emptyTableIsAGuess() {
        let r = PaperDetector.detectFull(RGBA8Image(width: 200, height: 150, fill: (120, 80, 50)))
        #expect(r.isGuess && r.quad == .full)
    }

    @Test func craftOnEmptyTableFallsBack() {
        let m = CraftMaskEstimator.estimate(RGBA8Image(width: 64, height: 48, fill: (180, 170, 150)), sensitivity: 0.5)
        #expect(m.fallback)
        let alpha = CraftMaskEstimator.alpha(full: RGBA8Image(width: 32, height: 24), mask: m)
        #expect(alpha.allSatisfy { $0 == 255 })
    }

    @Test func craftTouchingEdgeIsReported() {
        var img = RGBA8Image(width: 64, height: 48, fill: (180, 170, 150))
        for y in 14..<48 { for x in 22..<42 { img.set(x, y, (40, 90, 200)) } }
        let m = CraftMaskEstimator.estimate(img, sensitivity: 0.5)
        #expect(!m.fallback)
        #expect(m.touchesEdge)
    }

    @Test func maskCheckRules() {
        let w = 20, h = 20
        var tiny = [UInt8](repeating: 0, count: w * h)
        tiny[210] = 1
        #expect(CraftMaskEstimator.check(tiny, w, h).bad)          // < 1.2 %
        #expect(CraftMaskEstimator.check([UInt8](repeating: 1, count: w * h), w, h).bad)   // everything
        var ok = [UInt8](repeating: 0, count: w * h)
        for y in 5..<15 { for x in 5..<15 { ok[y * w + x] = 1 } }
        #expect(!CraftMaskEstimator.check(ok, w, h).bad)
    }
}

// MARK: - Recipe: backward compatibility of stored JSON

struct RecipeCompatTests {
    /// A recipe as stored by the first TestFlight build (no turning / parts keys).
    let v1 = #"""
    {"background":"warm","caption":true,"corners":{"bottomLeft":{"x":0.1,"y":0.9},"bottomRight":{"x":0.9,"y":0.9},"topLeft":{"x":0.1,"y":0.1},"topRight":{"x":0.9,"y":0.1}},"kind":"flat","protect":0.85,"removeSpecks":true,"sensitivity":0.5,"shadow":true,"strength":0.6,"strokes":[{"mode":"paintWhite","points":[{"x":0.5,"y":0.5}],"radius":0.02}],"version":1,"vivid":0.15}
    """#

    @Test func oldJSONDecodesWithDefaults() throws {
        let r = try ProcessingRecipe.decode(Data(v1.utf8))
        #expect(r.background == .warm && r.caption && r.strokes.count == 1)
        #expect(r.corners?.topLeft == NormPoint(x: 0.1, y: 0.1))
        #expect(r.quarterTurns == 0 && r.straightenDegrees == 0)
        #expect(r.removedPartSeeds.isEmpty && !r.partsEdited)
        // and it re-encodes / decodes to the same value
        #expect(try ProcessingRecipe.decode(r.encoded()) == r)
    }

    @Test func newFieldsRoundTrip() throws {
        var r = ProcessingRecipe(kind: .craft)
        r.quarterTurns = 3
        r.straightenDegrees = -7.5
        r.removedPartSeeds = [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.9, y: 0.1)]
        r.partsEdited = true
        let back = try ProcessingRecipe.decode(r.encoded())
        #expect(back == r)
    }

    @Test func toleratesOddValues() throws {
        let r = try ProcessingRecipe.decode(Data(#"{"kind":"craft","quarterTurns":5,"straightenDegrees":40,"removedPartSeeds":[[0.25,0.5]]}"#.utf8))
        #expect(r.quarterTurns == 1)
        #expect(r.straightenDegrees == 15)
        #expect(r.removedPartSeeds == [CGPoint(x: 0.25, y: 0.5)])
        let bad = try ProcessingRecipe.decode(Data(#"{"quarterTurns":"x","straightenDegrees":null,"removedPartSeeds":"?","partsEdited":3}"#.utf8))
        #expect(bad.quarterTurns == 0 && bad.straightenDegrees == 0 && bad.removedPartSeeds.isEmpty && !bad.partsEdited)
        #expect(try ProcessingRecipe.decode(Data(#"{"quarterTurns":-1}"#.utf8)).quarterTurns == 3)
    }

    @Test func noteKeys() {
        #expect(ProcessingNote.paperNotFound.localizationKey == "processing.note.paperNotFound")
        #expect(ProcessingNote.allCases.count == 6)
    }
}
