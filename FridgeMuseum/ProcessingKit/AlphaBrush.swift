import Foundation

/// Brush math for the craft alpha mask (port of `stampCircle` / `applyAlphaStroke`). Pure Swift.
enum AlphaBrush {
    /// Calls `stamp` at evenly spaced points along the polyline (spacing r/3).
    static func stampPath(_ pts: [(x: Double, y: Double)], radius r: Double, _ stamp: (Double, Double) -> Void) {
        guard !pts.isEmpty else { return }
        for i in 0..<pts.count {
            let a = pts[i], b = pts[min(i + 1, pts.count - 1)]
            let len = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            let steps = max(1, Int((len / max(r / 3, 0.5)).rounded(.up)))
            for s in 0...steps {
                let t = Double(s) / Double(steps)
                stamp(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            }
        }
    }

    /// Applies one stroke (pixel coordinates, row 0 = top) with a soft edge.
    static func apply(to alpha: inout [UInt8], width W: Int, height H: Int,
                      points: [(x: Double, y: Double)], radius r: Double, restore: Bool) {
        guard r > 0 else { return }
        let target: Double = restore ? 255 : 0
        alpha.withUnsafeMutableBufferPointer { al in
            stampPath(points, radius: r) { cx, cy in
                let ya = max(0, Int((cy - r).rounded(.down))), yb = min(H - 1, Int((cy + r).rounded(.up)))
                let xa = max(0, Int((cx - r).rounded(.down))), xb = min(W - 1, Int((cx + r).rounded(.up)))
                guard ya <= yb, xa <= xb else { return }
                for y in ya...yb {
                    for x in xa...xb {
                        let dx = Double(x) - cx, dy = Double(y) - cy
                        let dd = (dx * dx + dy * dy).squareRoot()
                        if dd > r { continue }
                        let f = smoothStep(r, r * 0.7, dd)
                        let i = y * W + x
                        let cur = Double(al[i])
                        al[i] = UInt8((cur + (target - cur) * f).rounded().clamped(0, 255))
                    }
                }
            }
        }
    }

    /// Applies normalized strokes (erase / restore) to a mask of size W×H.
    static func apply(strokes: [BrushStroke], to alpha: inout [UInt8], width W: Int, height H: Int) {
        let long = Double(max(W, H))
        for s in strokes where s.mode != .paintWhite {
            let pts = s.points.map { (x: $0.x * Double(W), y: $0.y * Double(H)) }
            apply(to: &alpha, width: W, height: H, points: pts, radius: s.radius * long, restore: s.mode == .restore)
        }
    }

    /// Bounding box (inclusive pixel coords) of alpha > threshold, or nil if empty.
    static func boundingBox(_ alpha: [UInt8], width W: Int, height H: Int, threshold: UInt8 = 128) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        var x0 = W, y0 = H, x1 = -1, y1 = -1
        alpha.withUnsafeBufferPointer { a in
            for y in 0..<H {
                let row = y * W
                for x in 0..<W where a[row + x] > threshold {
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                    if y < y0 { y0 = y }
                    if y > y1 { y1 = y }
                }
            }
        }
        return x1 < 0 ? nil : (x0, y0, x1, y1)
    }
}
