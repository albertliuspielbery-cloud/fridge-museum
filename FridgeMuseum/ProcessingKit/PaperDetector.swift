import Foundation

/// Port of the prototype's `detectPaper`: finds the largest bright, low-saturation blob (the paper)
/// and returns its 4 extreme corners. Used as the fallback when Vision's document segmentation
/// finds nothing plausible. Input should be small (≈360 px long edge).
enum PaperDetector {
    static func detect(_ img: RGBA8Image) -> Quad {
        let w = img.width, h = img.height, n = w * h
        guard w > 8, h > 8 else { return .inset(0.05) }
        var L = [UInt8](repeating: 0, count: n)
        var hist = [Double](repeating: 0, count: 256)
        img.pixels.withUnsafeBufferPointer { d in
            for i in 0..<n {
                let r = Double(d[i * 4]), g = Double(d[i * 4 + 1]), b = Double(d[i * 4 + 2])
                // brightness minus saturation: paper in shadow still scores above a colored table
                let v = (0.299 * r + 0.587 * g + 0.114 * b) - 1.5 * (max(r, g, b) - min(r, g, b))
                let q = Int(v.clamped(0, 255))
                L[i] = UInt8(q)
                hist[q] += 1
            }
        }
        let T = ImageOps.otsu(hist, total: Double(n))
        var bin = [UInt8](repeating: 0, count: n)
        for i in 0..<n { bin[i] = Int(L[i]) > T ? 1 : 0 }
        bin = ImageOps.morph(ImageOps.morph(bin, w, h, 3, dilate: true), w, h, 3, dilate: false)
        bin = ImageOps.morph(ImageOps.morph(bin, w, h, 1, dilate: false), w, h, 1, dilate: true)
        let cc = ImageOps.components(bin, w, h)
        var best = 0
        if cc.count > 0 {
            for k in 1...cc.count where cc.area[k] > cc.area[best] { best = k }
        }
        if best == 0 { return .inset(0.05) }
        var m = [UInt8](repeating: 0, count: n)
        let bestLabel = Int32(best)
        for i in 0..<n { m[i] = cc.labels[i] == bestLabel ? 1 : 0 }
        m = ImageOps.fillHoles(m, w, h)

        var area = 0
        var tl = (0, 0, Int.max), tr = (0, 0, Int.min), br = (0, 0, Int.min), bl = (0, 0, Int.max)
        for y in 0..<h {
            for x in 0..<w where m[y * w + x] != 0 {
                area += 1
                let s = x + y, d = x - y
                if s < tl.2 { tl = (x, y, s) }
                if s > br.2 { br = (x + 1, y + 1, s) }
                if d > tr.2 { tr = (x + 1, y, d) }
                if d < bl.2 { bl = (x, y + 1, d) }
            }
        }
        let ratio = Double(area) / Double(n)
        if ratio > 0.97 { return .full }
        if ratio < 0.12 { return .inset(0.05) }
        let raw = [tl, tr, br, bl].map { NormPoint(x: Double($0.0) / Double(w), y: Double($0.1) / Double(h)) }
        let cx = raw.reduce(0) { $0 + $1.x } / 4, cy = raw.reduce(0) { $0 + $1.y } / 4
        let q = raw.map { NormPoint(x: (cx + ($0.x - cx) * 0.992).clamped(0, 1), y: (cy + ($0.y - cy) * 0.992).clamped(0, 1)) }
        return Quad(topLeft: q[0], topRight: q[1], bottomRight: q[2], bottomLeft: q[3])
    }
}
