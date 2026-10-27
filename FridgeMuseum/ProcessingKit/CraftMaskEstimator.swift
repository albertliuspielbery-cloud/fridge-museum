import Foundation

/// Low-resolution craft mask (port of the prototype's `craftMask`).
struct CraftMask: Sendable {
    var mask: [Float]
    var width: Int
    var height: Int
    var centers: [SIMD3<Float>]
    var threshold: Float
}

/// Fallback subject lifting when Vision's foreground instance mask is unavailable
/// (e.g. Simulator, or Vision finds no salient object). Models the table from the border
/// with 4 k-means color clusters and keeps what is far from all of them.
enum CraftMaskEstimator {
    @inline(__always)
    static func feature(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        let L = (r + g + b) / 3, s = 90 / (L + 25)
        return SIMD3(L * 0.35, (r - g) * s, ((r + g) / 2 - b) * s)
    }

    @inline(__always)
    static func distanceToBackground(_ f: SIMD3<Float>, _ cs: [SIMD3<Float>]) -> Float {
        var m = Float.greatestFiniteMagnitude
        for c in cs {
            let d = f - c
            let v = (d * d).sum()
            if v < m { m = v }
        }
        return m.squareRoot()
    }

    /// `small` should be ≈256 px long edge. `sensitivity` 0...1 (去背範圍).
    static func estimate(_ small: RGBA8Image, sensitivity: Double) -> CraftMask {
        let w = small.width, h = small.height, n = w * h
        var F = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            F[i] = feature(Float(small.pixels[i * 4]), Float(small.pixels[i * 4 + 1]), Float(small.pixels[i * 4 + 2]))
        }
        let ring = max(2, Int((Double(min(w, h)) * 0.05).rounded()))
        var border = [SIMD3<Float>]()
        for y in 0..<h {
            for x in 0..<w where x < ring || y < ring || x >= w - ring || y >= h - ring { border.append(F[y * w + x]) }
        }
        guard !border.isEmpty else {
            return CraftMask(mask: [Float](repeating: 1, count: n), width: w, height: h, centers: [], threshold: 1)
        }
        var cs = [0.0, 0.25, 0.5, 0.75].map { border[Int($0 * Double(border.count))] }
        for _ in 0..<10 {
            var acc = [SIMD3<Float>](repeating: .zero, count: cs.count)
            var cnt = [Int](repeating: 0, count: cs.count)
            for f in border {
                var bi = 0
                var bv = Float.greatestFiniteMagnitude
                for (j, c) in cs.enumerated() {
                    let d = f - c
                    let v = (d * d).sum()
                    if v < bv { bv = v; bi = j }
                }
                acc[bi] += f
                cnt[bi] += 1
            }
            cs = cs.indices.map { cnt[$0] > 0 ? acc[$0] / Float(cnt[$0]) : cs[$0] }
        }
        var D = [Float](repeating: 0, count: n)
        for i in 0..<n { D[i] = distanceToBackground(F[i], cs) }
        let sortedD = D.sorted()
        var maxD = sortedD[min(n - 1, Int(Double(n) * 0.99))]
        if maxD <= 0 { maxD = 1 }
        var hist = [Double](repeating: 0, count: 256)
        for i in 0..<n { hist[min(255, Int(D[i] / maxD * 255))] += 1 }
        let T = max(6, Float(ImageOps.otsu(hist, total: Double(n))) / 255 * maxD * Float(0.55 + sensitivity * 0.9))
        var bin = [UInt8](repeating: 0, count: n)
        for i in 0..<n { bin[i] = D[i] > T ? 1 : 0 }
        bin = ImageOps.morph(ImageOps.morph(bin, w, h, 1, dilate: true), w, h, 1, dilate: false)
        let cc = ImageOps.components(bin, w, h)
        var big = 0
        if cc.count > 0 { for k in 1...cc.count where cc.area[k] > big { big = cc.area[k] } }
        var keep = [UInt8](repeating: 0, count: n)
        if big > 0 {
            for i in 0..<n {
                let l = Int(cc.labels[i])
                keep[i] = (l > 0 && Double(cc.area[l]) >= Double(big) * 0.15 && cc.area[l] > 12) ? 1 : 0
            }
        } else {
            for y in 0..<h {
                for x in 0..<w {
                    let dx = Double(x) / Double(w) - 0.5, dy = Double(y) / Double(h) - 0.5
                    keep[y * w + x] = dx * dx + dy * dy < 0.08 ? 1 : 0
                }
            }
        }
        keep = ImageOps.fillHoles(keep, w, h)
        let mf = keep.map { Float($0) }
        return CraftMask(mask: ImageOps.boxBlur(mf, w, h, 1), width: w, height: h, centers: cs, threshold: T)
    }

    /// Full-resolution alpha (port of `craftAlpha`): bilinear mask, refined at the edges by color distance.
    static func alpha(full src: RGBA8Image, mask m: CraftMask) -> [UInt8] {
        let W = src.width, H = src.height
        var a = [UInt8](repeating: 0, count: W * H)
        let kx = Double(m.width) / Double(W), ky = Double(m.height) / Double(H)
        let T = m.threshold
        for y in 0..<H {
            let fy = ((Double(y) + 0.5) * ky - 0.5).clamped(0, Double(m.height - 1))
            let y0 = Int(fy), y1 = min(y0 + 1, m.height - 1)
            let wy = Float(fy - Double(y0))
            for x in 0..<W {
                let fx = ((Double(x) + 0.5) * kx - 0.5).clamped(0, Double(m.width - 1))
                let x0 = Int(fx), x1 = min(x0 + 1, m.width - 1)
                let wx = Float(fx - Double(x0))
                let M = m.mask
                let top = M[y0 * m.width + x0] * (1 - wx) + M[y0 * m.width + x1] * wx
                let bot = M[y1 * m.width + x0] * (1 - wx) + M[y1 * m.width + x1] * wx
                let v = top * (1 - wy) + bot * wy
                let i = y * W + x
                if v >= 0.98 {
                    a[i] = 255
                } else if v <= 0.02 {
                    a[i] = 0
                } else {
                    let f = feature(Float(src.pixels[i * 4]), Float(src.pixels[i * 4 + 1]), Float(src.pixels[i * 4 + 2]))
                    let ad = smoothStep(T * 0.7, T * 1.25, distanceToBackground(f, m.centers))
                    a[i] = UInt8(((ad * 0.65 + v * 0.35) * 255).clamped(0, 255))
                }
            }
        }
        return a
    }
}
