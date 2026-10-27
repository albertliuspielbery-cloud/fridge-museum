import Foundation

/// Port of the prototype's `removeSpecks`: removes small, gray, isolated dots on the paper.
/// Dots near other marks (part of the drawing) are left alone.
enum SpeckRemover {
    @discardableResult
    static func remove(in img: inout RGBA8Image) -> Int {
        let W = img.width, H = img.height, n = W * H
        guard n > 0 else { return 0 }
        var ink = [UInt8](repeating: 0, count: n)
        img.pixels.withUnsafeBufferPointer { d in
            for i in 0..<n {
                let r = Int(d[i * 4]), g = Int(d[i * 4 + 1]), b = Int(d[i * 4 + 2])
                let lum = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
                ink[i] = (lum < 205 || max(r, g, b) - min(r, g, b) > 38) ? 1 : 0
            }
        }
        let cc = ImageOps.components(ink, W, H)
        guard cc.count > 0 else { return 0 }
        let small = max(12.0, Double(n) * 0.00012)
        let gap = max(6, Int((Double(max(W, H)) * 0.012).rounded()))
        var removed = 0
        img.pixels.withUnsafeMutableBufferPointer { d in
            for k in 1...cc.count {
                if Double(cc.area[k]) > small { continue }
                let label = Int32(k)
                var csum = 0, cnt = 0
                for y in cc.y0[k]...cc.y1[k] {
                    for x in cc.x0[k]...cc.x1[k] {
                        let i = y * W + x
                        if cc.labels[i] != label { continue }
                        let r = Int(d[i * 4]), g = Int(d[i * 4 + 1]), b = Int(d[i * 4 + 2])
                        csum += max(r, g, b) - min(r, g, b)
                        cnt += 1
                    }
                }
                if cnt == 0 || Double(csum) / Double(cnt) > 45 { continue }   // colored dot: keep
                let xa = max(0, cc.x0[k] - gap), xb = min(W - 1, cc.x1[k] + gap)
                let ya = max(0, cc.y0[k] - gap), yb = min(H - 1, cc.y1[k] + gap)
                var lonely = true
                outer: for y in ya...yb {
                    for x in xa...xb {
                        let i = y * W + x
                        if ink[i] != 0 && cc.labels[i] != label { lonely = false; break outer }
                    }
                }
                if !lonely { continue }
                for y in max(0, cc.y0[k] - 2)...min(H - 1, cc.y1[k] + 2) {
                    for x in max(0, cc.x0[k] - 2)...min(W - 1, cc.x1[k] + 2) {
                        let i = (y * W + x) * 4
                        d[i] = 255; d[i + 1] = 255; d[i + 2] = 255
                    }
                }
                removed += 1
            }
        }
        return removed
    }
}
