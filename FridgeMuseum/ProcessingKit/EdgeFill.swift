import Foundation

/// Table left in the corners of the straightened sheet (port of the prototype's `edgeFill` / `applyEdgeFill`).
/// A torn, folded or cut corner (or a sliver along an edge) leaves table inside the sheet. Regions that look like the
/// table just outside the sheet (and not like the paper), touch the border and stay near it are painted with the paper
/// colour. Strokes are never table-coloured and paper-like pixels are never touched.
struct EdgeFillMask: Sendable, Equatable {
    var alpha: [Float]
    var width: Int
    var height: Int
    /// Image pixels per cell.
    var blockSize: Int
    /// Fraction of cells filled.
    var area: Double
}

enum EdgeFill {
    /// - Parameters:
    ///   - warped: the perspective-corrected sheet (before whitening).
    ///   - small: a small copy of the upright photo (≈360 px, the one used for paper detection).
    ///   - quad: the sheet's corners, normalized in the photo.
    static func detect(warped img: RGBA8Image, small: RGBA8Image, quad: Quad) -> EdgeFillMask? {
        let W = img.width, H = img.height
        guard W > 4, H > 4, small.width > 4, small.height > 4 else { return nil }
        let k = max(1, Int((Double(max(W, H)) / 220).rounded(.up)))
        let sw = Int((Double(W) / Double(k)).rounded(.up)), sh = Int((Double(H) / Double(k)).rounded(.up)), n = sw * sh
        var R = [Float](repeating: 0, count: n), G = R, B = R, C = R
        img.pixels.withUnsafeBufferPointer { d in
            for y in stride(from: 0, to: H, by: 2) {
                let sy = (y / k) * sw
                for x in stride(from: 0, to: W, by: 2) {
                    let si = sy + x / k, i = (y * W + x) * 4
                    R[si] += Float(d[i]); G[si] += Float(d[i + 1]); B[si] += Float(d[i + 2]); C[si] += 1
                }
            }
        }
        for i in 0..<n {
            let c = max(C[i], 1)
            R[i] /= c; G[i] /= c; B[i] /= c
        }
        // table samples just outside the sheet in the photo
        let s = small, sW = Double(s.width), sH = Double(s.height), diag = (sW * sW + sH * sH).squareRoot()
        let q = quad.points.map { SIMD2<Double>($0.x * sW, $0.y * sH) }
        let cen = q.reduce(SIMD2<Double>.zero, +) / 4
        var tab = [SIMD3<Float>]()
        for e in 0..<4 {
            let a = q[e], b = q[(e + 1) % 4]
            var nrm = SIMD2<Double>(b.y - a.y, a.x - b.x)
            let ln = (nrm * nrm).sum().squareRoot()
            nrm /= (ln > 0 ? ln : 1)
            if (((a + b) / 2 - cen) * nrm).sum() < 0 { nrm = -nrm }
            var t = 0.05
            while t < 0.96 {
                for o in [0.02, 0.035, 0.05] {
                    let p = a + (b - a) * t + nrm * o * diag
                    let x = Int(p.x.rounded()), y = Int(p.y.rounded())
                    if x < 1 || y < 1 || x >= s.width - 1 || y >= s.height - 1 { continue }
                    let i = (y * s.width + x) * 4
                    tab.append(SIMD3(Float(s.pixels[i]), Float(s.pixels[i + 1]), Float(s.pixels[i + 2])))
                }
                t += 0.05
            }
        }
        guard tab.count >= 24 else { return nil }
        // paper: bright cells in the middle of the sheet
        var mid = [Int]()
        for y in ImageOps.span(sh, 0.2, 0.8) { for x in ImageOps.span(sw, 0.2, 0.8) { mid.append(y * sw + x) } }
        guard !mid.isEmpty else { return nil }
        let ml = ImageOps.quantile(mid.map { R[$0] + G[$0] + B[$0] }, 0.6)
        let pm = mid.filter { R[$0] + G[$0] + B[$0] >= ml }
        let P = SIMD3<Float>(ImageOps.median(pm.map { R[$0] }), ImageOps.median(pm.map { G[$0] }), ImageOps.median(pm.map { B[$0] }))
        // compare colours with brightness partly factored out (light falls off)
        func nrmC(_ c: SIMD3<Float>) -> SIMD4<Float> {
            let l = (c.x + c.y + c.z) / 3 + 1
            return SIMD4(c.x / l * 60, c.y / l * 60, c.z / l * 60, l * 0.5)
        }
        func dd(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { ((a - b) * (a - b)).sum().squareRoot() }
        let T0 = tab.map(nrmC), Pn = nrmC(P)
        // two kinds of table colour are enough near the sheet (5 starting picks like the prototype)
        var T = [0.0, 0.2, 0.4, 0.6, 0.8].map { T0[min(T0.count - 1, Int($0 * Double(T0.count)))] }
        for _ in 0..<6 {
            var acc = [SIMD4<Float>](repeating: .zero, count: T.count)
            var cnt = [Int](repeating: 0, count: T.count)
            for a in T0 {
                var bi = 0
                var bv = Float.greatestFiniteMagnitude
                for (j, c) in T.enumerated() {
                    let v = dd(a, c)
                    if v < bv { bv = v; bi = j }
                }
                acc[bi] += a
                cnt[bi] += 1
            }
            T = T.indices.map { cnt[$0] > 0 ? acc[$0] / Float(cnt[$0]) : T[$0] }
        }
        let tSpread = ImageOps.median(T0.map { a in T.map { dd(a, $0) }.min() ?? 0 })
        if ImageOps.median(T0.map { dd($0, Pn) }) < 18 { return nil }   // table looks like the paper
        var like = [UInt8](repeating: 0, count: n)
        let band = Double(max(sw, sh)) * 0.15, tl = max(10, tSpread * 4)
        for y in 0..<sh {
            for x in 0..<sw {
                if Double(min(x, y, sw - 1 - x, sh - 1 - y)) > band { continue }
                let i = y * sw + x
                let c = nrmC(SIMD3(R[i], G[i], B[i]))
                var dt = Float.greatestFiniteMagnitude
                for t in T { dt = min(dt, dd(c, t)) }
                like[i] = (dt < tl && dt < 0.5 * dd(c, Pn)) ? 1 : 0
            }
        }
        // keep only what is reachable from the border through table-like cells
        var m = [UInt8](repeating: 0, count: n)
        var st = [Int]()
        func push(_ i: Int) { if like[i] != 0 && m[i] == 0 { m[i] = 1; st.append(i) } }
        for x in 0..<sw { push(x); push((sh - 1) * sw + x) }
        for y in 0..<sh { push(y * sw); push(y * sw + sw - 1) }
        while let p = st.popLast() {
            let x = p % sw
            if x > 0 { push(p - 1) }
            if x < sw - 1 { push(p + 1) }
            if p >= sw { push(p - sw) }
            if p < n - sw { push(p + sw) }
        }
        var area = 0
        for v in m where v != 0 { area += 1 }
        if area == 0 || Double(area) > Double(n) * 0.12 { return nil }
        // grow one cell over the soft paper edge / shadow line, but never onto dark or colourful marks
        let g = ImageOps.morph(m, sw, sh, 1, dilate: true)
        let Pl = (P.x + P.y + P.z) / 3
        for i in 0..<n where g[i] != 0 && m[i] == 0 {
            let l = (R[i] + G[i] + B[i]) / 3, ch = max(R[i], G[i], B[i]) - min(R[i], G[i], B[i])
            if l > 0.55 * Pl && ch < 60 { m[i] = 1 }
        }
        let a = m.map { Float($0) }
        return EdgeFillMask(alpha: ImageOps.boxBlur(a, sw, sh, 1), width: sw, height: sh, blockSize: k, area: Double(area) / Double(n))
    }

    /// Paints the filled regions with `rgb` (0...255) in an image of the size the mask was made for.
    static func apply(_ ef: EdgeFillMask, to img: inout RGBA8Image, rgb: SIMD3<Float>) {
        let W = img.width, H = img.height, sw = ef.width, sh = ef.height, k = Double(ef.blockSize)
        let a = ef.alpha
        img.pixels.withUnsafeMutableBufferPointer { o in
            for y in 0..<H {
                let fy = ((Double(y) + 0.5) / k - 0.5).clamped(0, Double(sh - 1))
                let y0 = Int(fy), y1 = min(y0 + 1, sh - 1), wy = Float(fy - Double(y0))
                for x in 0..<W {
                    let fx = ((Double(x) + 0.5) / k - 0.5).clamped(0, Double(sw - 1))
                    let x0 = Int(fx), x1 = min(x0 + 1, sw - 1), wx = Float(fx - Double(x0))
                    let top = a[y0 * sw + x0] * (1 - wx) + a[y0 * sw + x1] * wx
                    let bot = a[y1 * sw + x0] * (1 - wx) + a[y1 * sw + x1] * wx
                    let v = top * (1 - wy) + bot * wy
                    if v < 0.02 { continue }
                    let w = smoothStep(Float(0.1), 0.6, v), i = (y * W + x) * 4
                    for ch in 0..<3 {
                        let cur = Float(o[i + ch])
                        o[i + ch] = UInt8((cur + (rgb[ch] - cur) * w).rounded().clamped(0, 255))
                    }
                }
            }
        }
    }
}
