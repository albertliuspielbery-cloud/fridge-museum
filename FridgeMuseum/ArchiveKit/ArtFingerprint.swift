import CoreGraphics
import Foundation
import ImageIO

/// A tiny perceptual fingerprint of a finished artwork (the processed, cropped, whitened image), used to notice when
/// a new capture is the same physical drawing or craft as one already in the museum (這張好像收過了). Made from the
/// 480 px thumbnail or the editor preview scaled to ≤ 128 px — never from the full-size image.
///
/// Three parts, all from a 64×64 box-averaged copy whose white point is normalized per channel (so a re-shoot
/// under warmer / dimmer light lines up again):
/// - `hash`: 64-bit pHash (8×8 low-frequency DCT of 32×32 luminance vs. the median) — layout of light and dark.
/// - `grid`: 16×16 RGB, 3×3-blurred — compared with a ±1 cell shift search, so a slightly shifted, cropped or
///   rotated re-shoot still lines up; normalized by the amount of "ink" so mostly-white sheets aren't all alike.
/// - `hues`: 12-bin hue histogram of the coloured cells (fraction of the sheet) — tells apart drawings with a
///   similar layout but different crayons.
/// The tuning (threshold 0.40) is in `score(against:)`; synthetic cases are in DuplicateDetectionTests.
struct ArtFingerprint: Sendable, Equatable {
    static let version: UInt8 = 1
    static let gridSide = 16
    static let hueBins = 12
    /// Score at or below which two fingerprints are "likely the same artwork".
    static let matchThreshold: Float = 0.40
    /// Long edge the image is scaled to before fingerprinting.
    static let workingEdge = 128

    var hash: UInt64
    /// gridSide × gridSide × RGB, 0...255.
    var grid: [UInt8]
    /// Fraction of the sheet in each hue bin, 0...255 (= 0...1).
    var hues: [UInt8]
    /// Width / height × 1000.
    var aspect: UInt16

    // MARK: Encoding — [version][hash 8 LE][aspect 2 LE][hues 12][grid 768]

    static let encodedCount = 1 + 8 + 2 + hueBins + gridSide * gridSide * 3

    var encoded: Data {
        var bytes: [UInt8] = [Self.version]
        bytes.reserveCapacity(Self.encodedCount)
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: hash >> UInt64(8 * i))) }
        bytes.append(UInt8(truncatingIfNeeded: aspect))
        bytes.append(UInt8(truncatingIfNeeded: aspect >> 8))
        bytes.append(contentsOf: hues)
        bytes.append(contentsOf: grid)
        return Data(bytes)
    }

    /// nil for missing data or an older / unknown version (it is then recomputed).
    init?(data: Data?) {
        guard let data, data.count == Self.encodedCount else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == Self.version else { return nil }
        var h: UInt64 = 0
        for i in 0..<8 { h |= UInt64(bytes[1 + i]) << UInt64(8 * i) }
        hash = h
        aspect = UInt16(bytes[9]) | (UInt16(bytes[10]) << 8)
        let huesStart = 11
        let gridStart = huesStart + Self.hueBins
        hues = Array(bytes[huesStart..<gridStart])
        grid = Array(bytes[gridStart..<Self.encodedCount])
    }

    init(hash: UInt64, grid: [UInt8], hues: [UInt8], aspect: UInt16) {
        self.hash = hash
        self.grid = grid
        self.hues = hues
        self.aspect = aspect
    }

    // MARK: Making one

    /// From encoded image data (the stored thumbnail): ImageIO decodes straight to ≤ 128 px.
    static func make(fromImageData data: Data) -> ArtFingerprint? {
        guard let image = ImageMetadata.uprightThumbnail(of: data, maxPixelSize: workingEdge) else { return nil }
        return make(cgImage: image)
    }

    /// From a decoded image (the editor preview): drawn into a ≤ 128 px buffer over white.
    static func make(cgImage: CGImage) -> ArtFingerprint? {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        let s = min(1, Double(workingEdge) / Double(max(w, h)))
        let W = max(1, Int((Double(w) * s).rounded()))
        let H = max(1, Int((Double(h) * s).rounded()))
        var image = RGBA8Image(width: W, height: H)   // opaque white: transparent parts count as paper
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = image.pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard drawn else { return nil }
        return make(image)
    }

    /// The fingerprint of an RGBA buffer (premultiplied; transparent pixels count as white paper). Pure Swift.
    static func make(_ image: RGBA8Image) -> ArtFingerprint? {
        let W = image.width, H = image.height
        guard W > 0, H > 0, image.pixels.count == W * H * 4 else { return nil }

        // 1. Box-average to 64×64 RGB in 0...1.
        let n = 64
        var g = [Float](repeating: 0, count: n * n * 3)
        let px = image.pixels
        for cy in 0..<n {
            let y0 = cy * H / n, y1 = max(y0 + 1, (cy + 1) * H / n)
            for cx in 0..<n {
                let x0 = cx * W / n, x1 = max(x0 + 1, (cx + 1) * W / n)
                var r: Float = 0, gr: Float = 0, b: Float = 0
                for y in y0..<y1 {
                    var i = (y * W + x0) * 4
                    for _ in x0..<x1 {
                        let clear = 255 - Float(px[i + 3])
                        r += min(255, Float(px[i]) + clear)
                        gr += min(255, Float(px[i + 1]) + clear)
                        b += min(255, Float(px[i + 2]) + clear)
                        i += 4
                    }
                }
                let inv = 1 / (Float((y1 - y0) * (x1 - x0)) * 255)
                let o = (cy * n + cx) * 3
                g[o] = r * inv
                g[o + 1] = gr * inv
                g[o + 2] = b * inv
            }
        }

        // 2. White point per channel: the 90th percentile cell becomes white (never more than ×3.3).
        for c in 0..<3 {
            var channel = [Float](repeating: 0, count: n * n)
            for i in 0..<(n * n) { channel[i] = g[i * 3 + c] }
            channel.sort()
            let white = max(0.3, channel[3685])
            for i in 0..<(n * n) { g[i * 3 + c] = min(1, g[i * 3 + c] / white) }
        }

        // 3. pHash: 32×32 luminance → 8×8 low-frequency DCT → bit = coefficient above the median of the 63 AC ones.
        let m = 32
        var lum = [Float](repeating: 0, count: m * m)
        func luma(_ x: Int, _ y: Int) -> Float {
            let o = (y * n + x) * 3
            return 0.299 * g[o] + 0.587 * g[o + 1] + 0.114 * g[o + 2]
        }
        for y in 0..<m {
            for x in 0..<m {
                lum[y * m + x] = (luma(2 * x, 2 * y) + luma(2 * x, 2 * y + 1) + luma(2 * x + 1, 2 * y) + luma(2 * x + 1, 2 * y + 1)) / 4
            }
        }
        var cosines = [Float](repeating: 0, count: 8 * m)
        for u in 0..<8 {
            for x in 0..<m {
                cosines[u * m + x] = Float(cos(Double.pi * Double(2 * x + 1) * Double(u) / Double(2 * m)))
            }
        }
        var rows = [Float](repeating: 0, count: 8 * m)          // rows[v][x] = Σy cos(v, y) · lum[y][x]
        for v in 0..<8 {
            for y in 0..<m {
                let c = cosines[v * m + y]
                for x in 0..<m { rows[v * m + x] += c * lum[y * m + x] }
            }
        }
        var dct = [Float](repeating: 0, count: 64)              // dct[v][u] = Σx rows[v][x] · cos(u, x)
        for v in 0..<8 {
            for u in 0..<8 {
                var s: Float = 0
                for x in 0..<m { s += rows[v * m + x] * cosines[u * m + x] }
                dct[v * 8 + u] = s
            }
        }
        let median = dct[1...].sorted()[31]
        var hash: UInt64 = 0
        for i in 0..<64 where dct[i] > median { hash |= UInt64(1) << UInt64(i) }

        // 4. Colour grid: 16×16 (4×4 blocks of the 64 grid), then a 3×3 blur (edges clamped).
        let k = gridSide, block = n / k
        var coarse = [Float](repeating: 0, count: k * k * 3)
        for y in 0..<k {
            for x in 0..<k {
                for c in 0..<3 {
                    var s: Float = 0
                    for yy in 0..<block {
                        for xx in 0..<block { s += g[((y * block + yy) * n + x * block + xx) * 3 + c] }
                    }
                    coarse[(y * k + x) * 3 + c] = s / Float(block * block)
                }
            }
        }
        var grid = [UInt8](repeating: 255, count: k * k * 3)
        for y in 0..<k {
            for x in 0..<k {
                for c in 0..<3 {
                    var s: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let yy = min(k - 1, max(0, y + dy)), xx = min(k - 1, max(0, x + dx))
                            s += coarse[(yy * k + xx) * 3 + c]
                        }
                    }
                    grid[(y * k + x) * 3 + c] = UInt8(max(0, min(255, (s / 9 * 255).rounded())))
                }
            }
        }

        // 5. Hue histogram of clearly coloured cells (soft-assigned to the two nearest of 12 bins).
        var hist = [Float](repeating: 0, count: hueBins)
        for i in 0..<(n * n) {
            let r = g[i * 3], gr = g[i * 3 + 1], b = g[i * 3 + 2]
            let hi = max(r, gr, b), lo = min(r, gr, b), d = hi - lo
            if d < 0.15 || d < 0.3 * hi { continue }
            var hue: Float
            if hi == r {
                hue = (gr - b) / d
            } else if hi == gr {
                hue = (b - r) / d + 2
            } else {
                hue = (r - gr) / d + 4
            }
            if hue < 0 { hue += 6 }
            let pos = hue * 2 - 0.5
            let floorPos = pos.rounded(.down)
            let f = pos - floorPos
            let i0 = Int(floorPos)
            hist[((i0 % hueBins) + hueBins) % hueBins] += 1 - f
            hist[(((i0 + 1) % hueBins) + hueBins) % hueBins] += f
        }
        let cells = Float(n * n)
        let hues = hist.map { UInt8(max(0, min(255, (min(1, $0 / cells) * 255).rounded()))) }

        let aspect = UInt16(max(1, min(65535, (Double(W) / Double(H) * 1000).rounded())))
        return ArtFingerprint(hash: hash, grid: grid, hues: hues, aspect: aspect)
    }

    // MARK: Comparing

    /// 0 = identical; ≤ `matchThreshold` = likely the same artwork. nil when the two can't be the same piece
    /// (very different shape) or there is too little on either sheet to compare.
    ///   score = gridDistance + hamming(hash) / 64 + 0.6 · hueDistance
    /// `cutoff`: stop early (returning nil) once the cheap parts alone exceed it.
    func score(against other: ArtFingerprint, cutoff: Float = .greatestFiniteMagnitude) -> Float? {
        guard aspect > 0, other.aspect > 0, hues.count == Self.hueBins, other.hues.count == Self.hueBins else { return nil }
        if abs(log(Double(aspect) / Double(other.aspect))) > 0.3 { return nil }
        let hamming = Float((hash ^ other.hash).nonzeroBitCount)
        var diff: Float = 0, total: Float = 0
        for i in 0..<Self.hueBins {
            let a = Float(hues[i]) / 255, b = Float(other.hues[i]) / 255
            diff += abs(a - b)
            total += a + b
        }
        let cheap = hamming / 64 + 0.6 * diff / max(total, 0.1)
        if cheap > cutoff { return nil }
        guard let grid = gridDistance(other) else { return nil }
        return cheap + grid
    }

    func isLikelyDuplicate(of other: ArtFingerprint) -> Bool {
        guard let s = score(against: other, cutoff: Self.matchThreshold) else { return false }
        return s <= Self.matchThreshold
    }

    /// Σ|a − b| / Σ(ink a + ink b) over the overlap, best of the 9 one-cell shifts. 0 = same, 1 = nothing in common.
    private func gridDistance(_ other: ArtFingerprint) -> Float? {
        let k = Self.gridSide, count = k * k * 3
        guard grid.count == count, other.grid.count == count else { return nil }
        var inkA: Float = 0, inkB: Float = 0
        for i in 0..<count {
            inkA += 255 - Float(grid[i])
            inkB += 255 - Float(other.grid[i])
        }
        let minInk = 0.01 * 255 * Float(count)
        if inkA < minInk || inkB < minInk { return nil }
        var best = Float.greatestFiniteMagnitude
        for dy in -1...1 {
            for dx in -1...1 {
                var num: Float = 0, den: Float = 0
                for y in max(0, -dy)..<min(k, k - dy) {
                    for x in max(0, -dx)..<min(k, k - dx) {
                        let ia = (y * k + x) * 3, ib = ((y + dy) * k + x + dx) * 3
                        for c in 0..<3 {
                            let a = Float(grid[ia + c]), b = Float(other.grid[ib + c])
                            num += abs(a - b)
                            den += 510 - a - b
                        }
                    }
                }
                best = min(best, num / max(den, 0.001 * 255))
            }
        }
        return best
    }
}

/// Picks the kept artwork a new capture most likely repeats. Pure (no SwiftData), so it is unit-tested.
enum DuplicateFinder {
    struct Candidate: Sendable {
        var id: UUID
        var childID: UUID?
        var fingerprint: ArtFingerprint
    }

    /// The best likely duplicate: a match by the same child wins over a closer match by another child.
    static func bestMatch(for fingerprint: ArtFingerprint, childID: UUID?, among candidates: [Candidate]) -> UUID? {
        var best: (id: UUID, sameChild: Bool, score: Float)?
        for c in candidates {
            guard let s = fingerprint.score(against: c.fingerprint, cutoff: ArtFingerprint.matchThreshold),
                  s <= ArtFingerprint.matchThreshold else { continue }
            let same = childID != nil && c.childID == childID
            if let b = best {
                if b.sameChild && !same { continue }
                if b.sameChild == same && b.score <= s { continue }
            }
            best = (c.id, same, s)
        }
        return best?.id
    }
}
