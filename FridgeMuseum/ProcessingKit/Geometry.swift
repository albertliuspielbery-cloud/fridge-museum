import Foundation

// Pure geometry helpers (Foundation only, unit-tested).
// Convention everywhere in the recipe: normalized coordinates in 0...1,
// origin at the TOP-LEFT of the upright image, y grows downward.

extension Comparable {
    @inline(__always)
    func clamped(_ lo: Self, _ hi: Self) -> Self { self < lo ? lo : (self > hi ? hi : self) }
}

/// Hermite smoothstep, same as the prototype's `smooth(e0, e1, x)` (works for e0 > e1 too).
@inline(__always)
func smoothStep<T: BinaryFloatingPoint>(_ e0: T, _ e1: T, _ x: T) -> T {
    let t = ((x - e0) / (e1 - e0)).clamped(0, 1)
    return t * t * (3 - 2 * t)
}

struct NormPoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    func distance(to o: NormPoint) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
    func clampedToUnit() -> NormPoint { NormPoint(x: x.clamped(0, 1), y: y.clamped(0, 1)) }
}

struct NormRect: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Maps a point normalized to this rect into the parent's normalized space.
    func toParent(_ p: NormPoint) -> NormPoint { NormPoint(x: x + p.x * width, y: y + p.y * height) }
}

/// Four paper corners, normalized, top-left origin.
struct Quad: Codable, Sendable, Hashable {
    var topLeft: NormPoint
    var topRight: NormPoint
    var bottomRight: NormPoint
    var bottomLeft: NormPoint

    static let full = Quad(topLeft: .init(x: 0, y: 0), topRight: .init(x: 1, y: 0),
                           bottomRight: .init(x: 1, y: 1), bottomLeft: .init(x: 0, y: 1))

    static func inset(_ f: Double) -> Quad {
        Quad(topLeft: .init(x: f, y: f), topRight: .init(x: 1 - f, y: f),
             bottomRight: .init(x: 1 - f, y: 1 - f), bottomLeft: .init(x: f, y: 1 - f))
    }

    /// Clockwise on screen: TL, TR, BR, BL.
    var points: [NormPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    init(topLeft: NormPoint, topRight: NormPoint, bottomRight: NormPoint, bottomLeft: NormPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    subscript(i: Int) -> NormPoint {
        get { points[i] }
        set {
            switch i {
            case 0: topLeft = newValue
            case 1: topRight = newValue
            case 2: bottomRight = newValue
            default: bottomLeft = newValue
            }
        }
    }

    func clampedToUnit() -> Quad {
        Quad(topLeft: topLeft.clampedToUnit(), topRight: topRight.clampedToUnit(),
             bottomRight: bottomRight.clampedToUnit(), bottomLeft: bottomLeft.clampedToUnit())
    }

    /// Shoelace area in normalized units (aspect-independent fraction of the image).
    var area: Double {
        let p = points
        var s = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /// True when the 4 points form a convex polygon in TL→TR→BR→BL order.
    var isConvex: Bool {
        let p = points
        var sign = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-9 { return false }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }

    /// A detection worth trusting: convex, covers at least 12% of the frame.
    var isPlausible: Bool { isConvex && area >= 0.12 }

    /// Output pixel size like the prototype's `warp()`: longest opposite edges, corrected to the sheet's true
    /// aspect (PaperAspect, snapped to common sheets), capped at maxEdge.
    /// `focalPixels`: the lens focal length in pixels of this image (from EXIF), used instead of the 26 mm guess.
    func outputSize(imageWidth w: Double, imageHeight h: Double, maxEdge: Int, focalPixels: Double? = nil) -> (width: Int, height: Int) {
        func d(_ a: NormPoint, _ b: NormPoint) -> Double {
            let dx = (a.x - b.x) * w, dy = (a.y - b.y) * h
            return (dx * dx + dy * dy).squareRoot()
        }
        var W = max(d(topLeft, topRight), d(bottomLeft, bottomRight))
        var H = max(d(topLeft, bottomLeft), d(topRight, bottomRight))
        if W > 0, H > 0 {
            let px = points.map { NormPoint(x: $0.x * w, y: $0.y * h) }
            let r = PaperAspect.estimate(px, imageWidth: w, imageHeight: h, focalPixels: focalPixels)
            if r > 0, abs(r / (W / H) - 1) > 0.03 {
                W = max(W, H * r)
                H = W / r
            }
        }
        let s = min(1, Double(maxEdge) / max(W, H, 1))
        W = max(8, (W * s).rounded())
        H = max(8, (H * s).rounded())
        return (Int(W), Int(H))
    }
}

enum CornerOrdering {
    /// Orders 4 arbitrary points into TL, TR, BR, BL (top-left origin, y down).
    /// Sorts by angle around the centroid (clockwise on screen), then starts at the point with the smallest x+y.
    static func order(_ pts: [NormPoint]) -> Quad? {
        guard pts.count == 4 else { return nil }
        let cx = pts.reduce(0) { $0 + $1.x } / 4
        let cy = pts.reduce(0) { $0 + $1.y } / 4
        let sorted = pts.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
        guard let start = sorted.indices.min(by: { sorted[$0].x + sorted[$0].y < sorted[$1].x + sorted[$1].y }) else { return nil }
        let r = (0..<4).map { sorted[(start + $0) % 4] }
        return Quad(topLeft: r[0], topRight: r[1], bottomRight: r[2], bottomLeft: r[3])
    }
}

/// 3x3 projective transform solved from 4 point pairs (port of the prototype's `homography`).
struct Homography: Sendable, Equatable {
    /// Row-major h0...h8 with h8 == 1.
    var m: [Double]

    init?(from: [NormPoint], to: [NormPoint]) {
        guard from.count == 4, to.count == 4 else { return nil }
        var A = [[Double]]()
        var B = [Double]()
        for i in 0..<4 {
            let x = from[i].x, y = from[i].y, u = to[i].x, v = to[i].y
            A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); B.append(u)
            A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); B.append(v)
        }
        for c in 0..<8 {
            var p = c
            for r in (c + 1)..<8 where abs(A[r][c]) > abs(A[p][c]) { p = r }
            A.swapAt(c, p); B.swapAt(c, p)
            guard abs(A[c][c]) > 1e-12 else { return nil }
            for r in 0..<8 where r != c {
                let f = A[r][c] / A[c][c]
                if f == 0 { continue }
                for k in c..<8 { A[r][k] -= f * A[c][k] }
                B[r] -= f * B[c]
            }
        }
        var h = (0..<8).map { B[$0] / A[$0][$0] }
        h.append(1)
        m = h
    }

    func apply(_ p: NormPoint) -> NormPoint {
        let den = m[6] * p.x + m[7] * p.y + m[8]
        return NormPoint(x: (m[0] * p.x + m[1] * p.y + m[2]) / den, y: (m[3] * p.x + m[4] * p.y + m[5]) / den)
    }
}

/// True width/height of a sheet from its four corners in a perspective photo (port of the prototype's `paperAspect`,
/// after Zhang & He, "Whiteboard scanning and image enhancement"). With the principal point at the image center the two
/// vanishing points give the focal length, and the focal length turns the corner geometry into the real side ratio.
/// One rectangle is a weak focal estimate (unusable when a pair of sides is nearly parallel), so it is only trusted when
/// both pairs clearly converge and it agrees with a phone lens; otherwise the lens focal length from EXIF, or the typical
/// phone main camera (26 mm equivalent: f = 0.75 × long edge), is used. Results near a common sheet snap to it.
enum PaperAspect {
    /// A4/A3 (√2), Letter, 4:3, square, 台灣八開, 四開.
    static let sheetRatios: [Double] = [Double(2).squareRoot(), 1.294, 4.0 / 3.0, 1, 1.443, 1.383]

    /// `q`: TL, TR, BR, BL in PIXELS. Returns width / height of the real sheet.
    static func estimate(_ q: [NormPoint], imageWidth iw: Double, imageHeight ih: Double,
                         focalPixels: Double? = nil, snap: Bool = true) -> Double {
        guard q.count == 4 else { return 1 }
        func v3(_ p: NormPoint) -> SIMD3<Double> { SIMD3(p.x, p.y, 1) }
        func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
        // prototype naming: m1 = TL, m2 = TR, m3 = BL, m4 = BR
        let m1 = v3(q[0]), m2 = v3(q[1]), m4 = v3(q[2]), m3 = v3(q[3])
        let sides = (q[0].distance(to: q[1]) + q[3].distance(to: q[2])) / (q[0].distance(to: q[3]) + q[1].distance(to: q[2]))
        let k2 = dot(cross(m1, m4), m3) / dot(cross(m2, m4), m3)
        let k3 = dot(cross(m1, m4), m2) / dot(cross(m3, m4), m2)
        var r = Double.nan
        if k2.isFinite && k3.isFinite {
            let n2 = k2 * m2 - m1, n3 = k3 * m3 - m1
            let u0 = iw / 2, v0 = ih / 2, L = max(iw, ih)
            func angle(_ a: NormPoint, _ b: NormPoint, _ c: NormPoint, _ e: NormPoint) -> Double {
                let t1 = atan2(b.y - a.y, b.x - a.x), t2 = atan2(e.y - c.y, e.x - c.x)
                let dd = (abs(t1 - t2) * 180 / Double.pi).truncatingRemainder(dividingBy: 180)
                return min(dd, 180 - dd)
            }
            let conv = min(angle(q[0], q[1], q[3], q[2]), angle(q[0], q[3], q[1], q[2]))
            let num = (n2.x * n3.x - (n2.x * n3.z + n2.z * n3.x) * u0 + n2.z * n3.z * u0 * u0)
                + (n2.y * n3.y - (n2.y * n3.z + n2.z * n3.y) * v0 + n2.z * n3.z * v0 * v0)
            var f2 = -num / (n2.z * n3.z)
            let trusted = conv > 3 && f2.isFinite && f2 > (0.55 * L) * (0.55 * L) && f2 < (1.6 * L) * (1.6 * L)
            if !trusted {
                let f = focalPixels.flatMap { $0 > 0.3 * L && $0 < 4 * L ? $0 : nil } ?? 0.75 * L
                f2 = f * f
            }
            func nn(_ n: SIMD3<Double>) -> Double {
                let a = n.x - u0 * n.z, b = n.y - v0 * n.z
                return a * a / f2 + b * b / f2 + n.z * n.z
            }
            r = (nn(n2) / nn(n3)).squareRoot()
        }
        if !r.isFinite || r <= 0 { r = sides }
        if !r.isFinite || r <= 0 { r = 1 }
        r = r.clamped(0.25, 4)
        guard snap else { return r }
        // A4 wins within 4.5 %, the others (in list order) within 3.5 %: 8K/4K are only 2 % from A4
        let lr = r >= 1 ? r : 1 / r
        var best: Double? = sheetRatios.first { abs(lr / $0 - 1) < ($0 == sheetRatios[0] ? 0.045 : 0.035) }
        if best == nil {
            var bd = 0.06
            for s in sheetRatios {
                let e = abs(lr / s - 1)
                if e < bd { bd = e; best = s }
            }
        }
        if let b = best { r = r >= 1 ? b : 1 / b }
        return r
    }

    /// Focal length in pixels from the EXIF 35 mm-equivalent focal length (defined on the 43.27 mm diagonal).
    static func focalPixels(focal35mm: Double, imageWidth w: Double, imageHeight h: Double) -> Double? {
        guard focal35mm > 0 else { return nil }
        return focal35mm * (w * w + h * h).squareRoot() / 43.27
    }
}

/// 2-D affine map, CGAffineTransform layout: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
/// Used in top-left-origin pixel space (y down), where a positive rotation angle turns clockwise on screen.
struct Affine2D: Sendable, Hashable {
    var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    static let identity = Affine2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    static func translation(_ x: Double, _ y: Double) -> Affine2D { Affine2D(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y) }
    static func scale(_ sx: Double, _ sy: Double) -> Affine2D { Affine2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0) }
    /// Clockwise on screen (y down) for positive degrees. Exact for multiples of 90°.
    static func rotation(degrees: Double) -> Affine2D {
        let (co, si) = Turning.cosSin(degrees)
        return Affine2D(a: co, b: si, c: -si, d: co, tx: 0, ty: 0)
    }

    func apply(_ p: NormPoint) -> NormPoint { NormPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty) }

    /// First self, then t.
    func then(_ t: Affine2D) -> Affine2D {
        Affine2D(a: t.a * a + t.c * b, b: t.b * a + t.d * b,
                 c: t.a * c + t.c * d, d: t.b * c + t.d * d,
                 tx: t.a * tx + t.c * ty + t.tx, ty: t.b * tx + t.d * ty + t.ty)
    }

    var inverted: Affine2D? {
        let det = a * d - b * c
        guard abs(det) > 1e-12 else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return Affine2D(a: ia, b: ib, c: ic, d: id, tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }

    /// The same map expressed in Core Image space (y up) for a source of height `srcH` and a destination of height `dstH`.
    func coreImage(sourceHeight srcH: Double, destinationHeight dstH: Double) -> Affine2D {
        Affine2D(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: srcH).then(self).then(Affine2D(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: dstH))
    }
}

/// Turning a result by quarter turns + straighten (port of the prototype's rotCanvas / unturnFn).
enum Turning {
    /// cos / sin of an angle in degrees, exact for multiples of 90°.
    static func cosSin(_ degrees: Double) -> (Double, Double) {
        let q = degrees / 90
        if q == q.rounded() {
            switch ((Int(q) % 4) + 4) % 4 {
            case 0: return (1, 0)
            case 1: return (0, 1)
            case 2: return (-1, 0)
            default: return (0, -1)
            }
        }
        let r = degrees * Double.pi / 180
        return (cos(r), sin(r))
    }

    /// Pixel size of a W×H image turned by `degrees` (bounding box, rounded like the prototype).
    static func turnedSize(width w: Double, height h: Double, degrees: Double) -> (width: Int, height: Int) {
        let (co, si) = cosSin(degrees)
        let W = (w * abs(co) + h * abs(si)).rounded(), H = (w * abs(si) + h * abs(co)).rounded()
        return (max(1, Int(W)), max(1, Int(H)))
    }

    /// Unturned pixel → turned pixel (top-left origin), turning about the centers.
    static func forward(width w: Double, height h: Double, degrees: Double) -> Affine2D {
        let s = turnedSize(width: w, height: h, degrees: degrees)
        return Affine2D.translation(-w / 2, -h / 2)
            .then(.rotation(degrees: degrees))
            .then(.translation(Double(s.width) / 2, Double(s.height) / 2))
    }

    /// Maps a NORMALIZED point of the unturned image to the normalized turned image (quarter turns are exact).
    static func turnNormalized(_ p: NormPoint, width w: Double, height h: Double, degrees: Double) -> NormPoint {
        let s = turnedSize(width: w, height: h, degrees: degrees)
        let o = forward(width: w, height: h, degrees: degrees).apply(NormPoint(x: p.x * w, y: p.y * h))
        return NormPoint(x: o.x / Double(s.width), y: o.y / Double(s.height))
    }
}
