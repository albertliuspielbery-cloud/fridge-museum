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

/// 這張好像收過了: the fingerprint and the matcher. (Scores were checked against a NumPy port of ArtFingerprint:
/// re-shoots score 0.02–0.33, different drawings 0.67 and up; the threshold is 0.40.)
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
