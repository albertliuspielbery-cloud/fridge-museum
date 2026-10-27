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

    /// Output pixel size like the prototype's `warp()`: longest opposite edges, capped at maxEdge.
    func outputSize(imageWidth w: Double, imageHeight h: Double, maxEdge: Int) -> (width: Int, height: Int) {
        func d(_ a: NormPoint, _ b: NormPoint) -> Double {
            let dx = (a.x - b.x) * w, dy = (a.y - b.y) * h
            return (dx * dx + dy * dy).squareRoot()
        }
        var W = max(d(topLeft, topRight), d(bottomLeft, bottomRight))
        var H = max(d(topLeft, bottomLeft), d(topRight, bottomRight))
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
