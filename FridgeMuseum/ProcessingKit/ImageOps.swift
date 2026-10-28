import Foundation

/// 8-bit RGBA, row-major, row 0 = TOP of the image (same as CGImage / CIContext bitmap output).
struct RGBA8Image: Sendable, Equatable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8) = (255, 255, 255)) {
        self.width = width
        self.height = height
        var p = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            p[i * 4] = fill.0; p[i * 4 + 1] = fill.1; p[i * 4 + 2] = fill.2
        }
        pixels = p
    }

    mutating func set(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        let i = (y * width + x) * 4
        pixels[i] = c.0; pixels[i + 1] = c.1; pixels[i + 2] = c.2; pixels[i + 3] = 255
    }
}

/// Connected-component labelling result (4-connected). Index 0 is "background"; labels start at 1.
struct Components {
    var labels: [Int32]
    var count: Int
    var area: [Int]
    var x0: [Int]
    var y0: [Int]
    var x1: [Int]
    var y1: [Int]
}

/// Ports of the prototype's small image helpers. Pure Swift, unit-tested.
enum ImageOps {
    static func boxBlur(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        guard w > 0, h > 0, r > 0 else { return a }
        var t = [Float](repeating: 0, count: w * h)
        var o = [Float](repeating: 0, count: w * h)
        let inv = 1 / Float(2 * r + 1)
        for y in 0..<h {
            let row = y * w
            var acc: Float = 0
            for k in -r...r { acc += a[row + k.clamped(0, w - 1)] }
            for x in 0..<w {
                t[row + x] = acc * inv
                acc += a[row + min(x + r + 1, w - 1)] - a[row + max(x - r, 0)]
            }
        }
        for x in 0..<w {
            var acc: Float = 0
            for k in -r...r { acc += t[k.clamped(0, h - 1) * w + x] }
            for y in 0..<h {
                o[y * w + x] = acc * inv
                acc += t[min(y + r + 1, h - 1) * w + x] - t[max(y - r, 0) * w + x]
            }
        }
        return o
    }

    static func blur3(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        boxBlur(boxBlur(boxBlur(a, w, h, r), w, h, r), w, h, r)
    }

    /// Separable square dilate / erode on a 0/1 mask.
    static func morph(_ bin: [UInt8], _ w: Int, _ h: Int, _ r: Int, dilate: Bool) -> [UInt8] {
        var t = [UInt8](repeating: 0, count: w * h)
        var o = [UInt8](repeating: 0, count: w * h)
        let hit: UInt8 = dilate ? 1 : 0
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = dilate ? 0 : 1
                for k in -r...r {
                    let b = bin[y * w + (x + k).clamped(0, w - 1)]
                    if (dilate && b != 0) || (!dilate && b == 0) { v = hit; break }
                }
                t[y * w + x] = v
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = dilate ? 0 : 1
                for k in -r...r {
                    let b = t[(y + k).clamped(0, h - 1) * w + x]
                    if (dilate && b != 0) || (!dilate && b == 0) { v = hit; break }
                }
                o[y * w + x] = v
            }
        }
        return o
    }

    static func components(_ bin: [UInt8], _ w: Int, _ h: Int) -> Components {
        let n = w * h
        var lab = [Int32](repeating: 0, count: n)
        var stack = [Int32](repeating: 0, count: max(n, 1))
        var area = [0], x0s = [0], y0s = [0], x1s = [0], y1s = [0]
        var count = 0
        lab.withUnsafeMutableBufferPointer { L in
            stack.withUnsafeMutableBufferPointer { S in
                bin.withUnsafeBufferPointer { B in
                    for i in 0..<n {
                        if B[i] == 0 || L[i] != 0 { continue }
                        count += 1
                        let label = Int32(count)
                        var sp = 0
                        var a = 0, mnx = w, mny = h, mxx = 0, mxy = 0
                        S[sp] = Int32(i); sp += 1
                        L[i] = label
                        while sp > 0 {
                            sp -= 1
                            let p = Int(S[sp])
                            a += 1
                            let x = p % w, y = p / w
                            if x < mnx { mnx = x }
                            if x > mxx { mxx = x }
                            if y < mny { mny = y }
                            if y > mxy { mxy = y }
                            if x > 0, B[p - 1] != 0, L[p - 1] == 0 { L[p - 1] = label; S[sp] = Int32(p - 1); sp += 1 }
                            if x < w - 1, B[p + 1] != 0, L[p + 1] == 0 { L[p + 1] = label; S[sp] = Int32(p + 1); sp += 1 }
                            if y > 0, B[p - w] != 0, L[p - w] == 0 { L[p - w] = label; S[sp] = Int32(p - w); sp += 1 }
                            if y < h - 1, B[p + w] != 0, L[p + w] == 0 { L[p + w] = label; S[sp] = Int32(p + w); sp += 1 }
                        }
                        area.append(a); x0s.append(mnx); y0s.append(mny); x1s.append(mxx); y1s.append(mxy)
                    }
                }
            }
        }
        return Components(labels: lab, count: count, area: area, x0: x0s, y0: y0s, x1: x1s, y1: y1s)
    }

    /// Fills enclosed holes (pixels not reachable from the border through background).
    static func fillHoles(_ bin: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        let n = w * h
        var reach = [UInt8](repeating: 0, count: n)
        var stack = [Int]()
        stack.reserveCapacity(n / 4)
        func push(_ p: Int) {
            if bin[p] == 0 && reach[p] == 0 { reach[p] = 1; stack.append(p) }
        }
        for x in 0..<w { push(x); push((h - 1) * w + x) }
        for y in 0..<h { push(y * w); push(y * w + w - 1) }
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            if x > 0 { push(p - 1) }
            if x < w - 1 { push(p + 1) }
            if y > 0 { push(p - w) }
            if y < h - 1 { push(p + w) }
        }
        var o = [UInt8](repeating: 0, count: n)
        for i in 0..<n { o[i] = (bin[i] != 0 || reach[i] == 0) ? 1 : 0 }
        return o
    }

    /// Otsu threshold on a 256-bin histogram.
    static func otsu(_ hist: [Double], total: Double) -> Int {
        var sum = 0.0
        for i in 0..<256 { sum += Double(i) * hist[i] }
        var sumB = 0.0, wB = 0.0, best = 0.0, th = 128
        for i in 0..<256 {
            wB += hist[i]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(i) * hist[i]
            let mB = sumB / wB, mF = (sum - sumB) / wF
            let v = wB * wF * (mB - mF) * (mB - mF)
            if v > best { best = v; th = i }
        }
        return th
    }

    static func median(_ arr: [Float]) -> Float {
        guard !arr.isEmpty else { return 0.9 }
        let s = arr.sorted()
        return s[s.count >> 1]
    }

    static func median(_ arr: [Double]) -> Double {
        guard !arr.isEmpty else { return 0.9 }
        let s = arr.sorted()
        return s[s.count >> 1]
    }

    /// Value at fraction f of the sorted array (prototype: `sorted[floor(n * f)]`).
    static func quantile(_ arr: [Float], _ f: Double) -> Float {
        guard !arr.isEmpty else { return 0 }
        let s = arr.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count) * f)))]
    }

    /// Integer range [floor(n·lo), n·hi) like the prototype's `for (y = (h * lo) | 0; y < h * hi; y += step)`.
    static func span(_ n: Int, _ lo: Double, _ hi: Double, step: Int = 1) -> StrideTo<Int> {
        let a = Int(Double(n) * lo)
        let b = Int((Double(n) * hi).rounded(.up))
        return stride(from: a, to: max(a, b), by: step)
    }

    /// Largest per-channel central difference (prototype `gradMag`), 0...255.
    static func gradMag(_ R: [Float], _ G: [Float], _ B: [Float], _ w: Int, _ h: Int) -> [UInt8] {
        var g = [UInt8](repeating: 0, count: w * h)
        guard w > 2, h > 2 else { return g }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                var m: Float = 0
                for A in [R, G, B] {
                    let v = abs(A[i + 1] - A[i - 1]) + abs(A[i + w] - A[i - w])
                    if v > m { m = v }
                }
                g[i] = UInt8(min(255, m * 1.5))
            }
        }
        return g
    }

    /// Marker watershed (prototype `flood`): grows labelled seeds across the image, always along the weakest edge first.
    static func flood(_ G: [UInt8], _ w: Int, _ h: Int, _ lab: inout [UInt8]) {
        let n = w * h
        var q = [[Int32]](repeating: [], count: 256)
        for i in 0..<n where lab[i] != 0 { q[Int(G[i])].append(Int32(i)) }
        for lv in 0..<256 {
            var t = 0
            while t < q[lv].count {
                let p = Int(q[lv][t])
                t += 1
                let x = p % w, l = lab[p]
                @inline(__always) func go(_ j: Int) {
                    if lab[j] == 0 {
                        lab[j] = l
                        q[max(lv, Int(G[j]))].append(Int32(j))
                    }
                }
                if x > 0 { go(p - 1) }
                if x < w - 1 { go(p + 1) }
                if p >= w { go(p - w) }
                if p < n - w { go(p + w) }
            }
            q[lv] = []
        }
    }

    /// Two-pass chamfer distance (1, √2) to the nearest 0 cell; 0 cells stay 0.
    static func chamfer(_ on: [UInt8], _ w: Int, _ h: Int) -> [Float] {
        var D = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) where on[i] != 0 { D[i] = 1e6 }
        func g(_ x: Int, _ y: Int) -> Float { (x < 0 || y < 0 || x >= w || y >= h) ? 0 : D[y * w + x] }
        for y in 0..<h {
            for x in 0..<w where D[y * w + x] != 0 {
                D[y * w + x] = min(D[y * w + x], g(x - 1, y) + 1, g(x, y - 1) + 1, g(x - 1, y - 1) + 1.414, g(x + 1, y - 1) + 1.414)
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) where D[y * w + x] != 0 {
                D[y * w + x] = min(D[y * w + x], g(x + 1, y) + 1, g(x, y + 1) + 1, g(x + 1, y + 1) + 1.414, g(x - 1, y + 1) + 1.414)
            }
        }
        return D
    }

    /// Prototype colour feature: brightness plus two chroma axes scaled up in the dark.
    @inline(__always)
    static func feature(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        let L = (r + g + b) / 3, s = 90 / (L + 25)
        return SIMD3(L * 0.35, (r - g) * s, ((r + g) / 2 - b) * s)
    }

    static func features(_ img: RGBA8Image) -> [SIMD3<Float>] {
        let n = img.width * img.height
        var F = [SIMD3<Float>](repeating: .zero, count: n)
        img.pixels.withUnsafeBufferPointer { d in
            for i in 0..<n { F[i] = feature(Float(d[i * 4]), Float(d[i * 4 + 1]), Float(d[i * 4 + 2])) }
        }
        return F
    }

    @inline(__always)
    static func nearest(_ f: SIMD3<Float>, _ cs: [SIMD3<Float>]) -> Float {
        var m = Float.greatestFiniteMagnitude
        for c in cs {
            let d = f - c
            let v = (d * d).sum()
            if v < m { m = v }
        }
        return m.squareRoot()
    }

    static func distances(_ F: [SIMD3<Float>], _ cs: [SIMD3<Float>]) -> [Float] {
        F.map { nearest($0, cs) }
    }

    /// k-means with fixed initial picks at 0, ¼, ½, ¾ of the list (prototype).
    static func kmeans4(_ pts: [SIMD3<Float>], iterations: Int = 10) -> [SIMD3<Float>] {
        guard !pts.isEmpty else { return [] }
        var cs = [0.0, 0.25, 0.5, 0.75].map { pts[min(pts.count - 1, Int($0 * Double(pts.count)))] }
        for _ in 0..<iterations {
            var acc = [SIMD3<Float>](repeating: .zero, count: cs.count)
            var cnt = [Int](repeating: 0, count: cs.count)
            for f in pts {
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
        return cs
    }

    /// Table colours from the frame border (prototype `borderModel`). Border stretches unlike the rest (an object or sheet
    /// running off the edge) are ignored. Returns 4 cluster centers and the border pixels that count as table.
    static func borderModel(_ F: [SIMD3<Float>], _ w: Int, _ h: Int, ring: Int) -> (centers: [SIMD3<Float>], bgOK: [UInt8]) {
        let NS = 24
        var sum = [SIMD3<Double>](repeating: .zero, count: NS)
        var cnt = [Int](repeating: 0, count: NS)
        var seg = [Int](), idx = [Int]()
        for y in 0..<h {
            for x in 0..<w where x < ring || y < ring || x >= w - ring || y >= h - ring {
                let a = atan2((Double(y) - Double(h) / 2) / Double(h), (Double(x) - Double(w) / 2) / Double(w))
                let s = min(NS - 1, Int((a + Double.pi) / (2 * Double.pi) * Double(NS)))
                let i = y * w + x
                let f = F[i]
                sum[s] += SIMD3(Double(f.x), Double(f.y), Double(f.z))
                cnt[s] += 1
                seg.append(s)
                idx.append(i)
            }
        }
        var bgOK = [UInt8](repeating: 0, count: w * h)
        guard !idx.isEmpty else { return ([], bgOK) }
        let mu: [SIMD3<Float>?] = (0..<NS).map { k -> SIMD3<Float>? in
            guard cnt[k] > 0 else { return nil }
            let m = sum[k] / Double(cnt[k])
            return SIMD3<Float>(Float(m.x), Float(m.y), Float(m.z))
        }
        func dist(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double { Double(((a - b) * (a - b)).sum().squareRoot()) }
        let md: [Double] = (0..<NS).map { i in
            guard let a = mu[i] else { return 0 }
            var ds = [Double]()
            for j in 0..<NS where j != i { if let b = mu[j] { ds.append(dist(a, b)) } }
            return median(ds)
        }
        var present = [Double]()
        for k in 0..<NS where mu[k] != nil { present.append(md[k]) }
        let M = median(present)
        let lim = max(12, M * 2.5)
        let okSeg = (0..<NS).map { mu[$0] != nil && md[$0] <= lim }
        let use = Double(okSeg.filter { $0 }.count) >= Double(NS) * 0.4
        var refs = [SIMD3<Float>]()
        for k in 0..<NS where !use || okSeg[k] { if let m = mu[k] { refs.append(m) } }
        var dref = [Double](repeating: 0, count: idx.count)
        var own = [Double]()
        for j in 0..<idx.count {
            let f = F[idx[j]]
            var m = 1e9
            for c in refs { m = min(m, dist(f, c)) }
            dref[j] = m
            if j % 7 == 0, let ms = mu[seg[j]] { own.append(dist(f, ms)) }
        }
        var okd = [Float]()
        for j in stride(from: 0, to: idx.count, by: 3) where !use || okSeg[seg[j]] { okd.append(Float(dref[j])) }
        let pl = max(lim, 3 * median(own), okd.isEmpty ? 0 : Double(quantile(okd, 0.85)))
        var border = [SIMD3<Float>]()
        let step = max(1, idx.count / 3000)
        for j in 0..<idx.count where (!use || okSeg[seg[j]]) && dref[j] <= pl {
            bgOK[idx[j]] = 1
            if j % step == 0 { border.append(F[idx[j]]) }
        }
        if border.count < 50 {
            for j in stride(from: 0, to: idx.count, by: step) {
                bgOK[idx[j]] = 1
                border.append(F[idx[j]])
            }
        }
        return (kmeans4(border), bgOK)
    }

    /// Fraction of `bin` that is on.
    static func coverage(_ bin: [UInt8]) -> Double {
        guard !bin.isEmpty else { return 0 }
        var a = 0
        for v in bin where v != 0 { a += 1 }
        return Double(a) / Double(bin.count)
    }
}
