import Foundation

/// Low-resolution craft mask (port of the prototype's `craftMask`, v0.9).
struct CraftMask: Sendable {
    var mask: [Float]
    var width: Int
    var height: Int
    var centers: [SIMD3<Float>]
    var threshold: Float
    /// The mask came from the outline rescue (watershed); its edge is blended softly instead of by colour.
    var soft: Bool = false
    /// Nothing believable was found: the caller keeps the plain photo (`ProcessingNote.cutoutFallback`).
    var fallback: Bool = false
    /// The cut-out touches the frame edge (`ProcessingNote.touchesEdge`).
    var touchesEdge: Bool = false
}

/// Shape check of a cut-out (prototype `maskCheck`).
struct MaskCheck: Sendable, Equatable {
    var areaFraction: Double
    var touchedSides: Int
    var pieces: Int
    var bad: Bool
}

/// Fallback subject lifting when Vision's foreground instance mask is unavailable (Simulator, older devices, or Vision
/// finds nothing). Models the table from the border, keeps what is far from it, grows into differently-hued parts,
/// and when that is not believable grows the middle and the border towards each other (outline rescue).
enum CraftMaskEstimator {
    @inline(__always)
    static func feature(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> { ImageOps.feature(r, g, b) }

    @inline(__always)
    static func distanceToBackground(_ f: SIMD3<Float>, _ cs: [SIMD3<Float>]) -> Float { ImageOps.nearest(f, cs) }

    /// Is this cut-out believable? Too small or nearly everything, touching 3+ sides, or in many pieces.
    static func check(_ keep: [UInt8], _ w: Int, _ h: Int) -> MaskCheck {
        var area = 0
        for v in keep where v != 0 { area += 1 }
        var side = [0, 0, 0, 0]
        for x in 0..<w { side[0] += Int(keep[x]); side[2] += Int(keep[(h - 1) * w + x]) }
        for y in 0..<h { side[3] += Int(keep[y * w]); side[1] += Int(keep[y * w + w - 1]) }
        var touch = 0
        for i in 0..<4 where Double(side[i]) > Double(i % 2 == 1 ? h : w) * 0.08 { touch += 1 }
        let cc = ImageOps.components(keep, w, h)
        var big = 0
        if cc.count > 0 { for k in 1...cc.count { big = max(big, cc.area[k]) } }
        var pieces = 0
        if cc.count > 0 { for k in 1...cc.count where Double(cc.area[k]) >= Double(big) * 0.15 { pieces += 1 } }
        let af = Double(area) / Double(max(1, w * h))
        let bad = af < 0.012 || af > 0.85 || touch >= 3 || pieces > 4 || Double(big) < Double(area) * 0.5
        return MaskCheck(areaFraction: af, touchedSides: touch, pieces: pieces, bad: bad)
    }

    /// Fill enclosed holes, except big ones that look like table (the space between legs or inside a handle).
    static func fillHolesLike(_ keep: [UInt8], _ D: [Float], _ T: Float, _ w: Int, _ h: Int) -> [UInt8] {
        let n = w * h
        let all = ImageOps.fillHoles(keep, w, h)
        var hole = [UInt8](repeating: 0, count: n)
        var area = 0
        for i in 0..<n {
            hole[i] = (all[i] != 0 && keep[i] == 0) ? 1 : 0
            area += Int(keep[i])
        }
        let cc = ImageOps.components(hole, w, h)
        var sum = [Double](repeating: 0, count: cc.count + 1)
        for i in 0..<n where cc.labels[i] != 0 { sum[Int(cc.labels[i])] += Double(D[i]) }
        var o = keep
        for i in 0..<n {
            let l = Int(cc.labels[i])
            if l != 0 && (Double(cc.area[l]) < Double(area) * 0.02 || sum[l] / Double(cc.area[l]) > Double(T) * 0.6) { o[i] = 1 }
        }
        return o
    }

    /// `small` should be ≈256 px long edge. `sensitivity` 0...1 (去背範圍).
    static func estimate(_ small: RGBA8Image, sensitivity sens: Double) -> CraftMask {
        let w = small.width, h = small.height, n = w * h
        let F = ImageOps.features(small)
        let ring = max(2, Int((Double(min(w, h)) * 0.05).rounded()))
        let bm = ImageOps.borderModel(F, w, h, ring: ring)
        let cs = bm.centers
        guard !cs.isEmpty else {
            return CraftMask(mask: [Float](repeating: 1, count: n), width: w, height: h, centers: [], threshold: 1, fallback: true)
        }
        let D = ImageOps.distances(F, cs)
        var maxD = ImageOps.quantile(D, 0.99)
        if maxD <= 0 { maxD = 1 }
        var hist = [Double](repeating: 0, count: 256)
        for i in 0..<n { hist[min(255, Int(D[i] / maxD * 255))] += 1 }
        let gainS = Float(0.55 + sens * 0.9)
        let T = max(6, Float(ImageOps.otsu(hist, total: Double(n))) / 255 * maxD * gainS)
        var bin = [UInt8](repeating: 0, count: n)
        for i in 0..<n { bin[i] = D[i] > T ? 1 : 0 }
        // Otsu splits the loudest colour from everything else; grow into neighbouring pixels that are clearly unlike
        // every table colour AND of a different hue (shadows and patterns of the table keep its hue).
        var rd = [Float]()
        for i in stride(from: 0, to: n, by: 2) where bm.bgOK[i] != 0 { rd.append(D[i]) }
        if rd.count > 50 {
            let lo = max(8, ImageOps.quantile(rd, 0.99) * 1.8) * gainS
            func hueOff(_ i: Int) -> Bool {
                let a = F[i].y, b = F[i].z, pc = (a * a + b * b).squareRoot()
                for c in cs {
                    let cc = (c.y * c.y + c.z * c.z).squareRoot()
                    if cc < 6 {
                        if pc - cc < 12 { return false }
                    } else if pc < 8 || (a * c.y + b * c.z) / (pc * cc) > 0.82 {
                        return false
                    }
                }
                return true
            }
            if lo < T {
                var st = [Int]()
                for i in 0..<n where bin[i] != 0 { st.append(i) }
                while let p = st.popLast() {
                    let x = p % w
                    for j in [x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, p - w, p + w]
                    where j >= 0 && j < n && bin[j] == 0 && D[j] > lo && hueOff(j) {
                        bin[j] = 1
                        st.append(j)
                    }
                }
            }
        }
        bin = ImageOps.morph(ImageOps.morph(bin, w, h, 1, dilate: true), w, h, 1, dilate: false)
        let cc = ImageOps.components(bin, w, h)
        var big = 0
        if cc.count > 0 { for k in 1...cc.count where cc.area[k] > big { big = cc.area[k] } }
        var keep = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let l = Int(cc.labels[i])
            keep[i] = (l > 0 && Double(cc.area[l]) >= Double(big) * 0.15 && cc.area[l] > 12) ? 1 : 0
        }
        keep = fillHolesLike(keep, D, T, w, h)
        var info = check(keep, w, h)
        var soft = false
        if info.bad, let rescued = rescue(small, keep: keep, info: info, bgOK: bm.bgOK) {
            keep = rescued.keep
            info = rescued.info
            soft = true
        }
        let mf = keep.map { Float($0) }
        return CraftMask(mask: ImageOps.boxBlur(mf, w, h, 1), width: w, height: h, centers: cs, threshold: T,
                         soft: soft, fallback: info.bad, touchesEdge: !info.bad && info.touchedSides > 0)
    }

    /// Second try: grow the middle of the photo (plus confident pieces) and the frame border towards each other; they
    /// meet at the strongest outline, which also works for a white object on a white table. Trusted only if the outline
    /// is a clearly stronger edge than the table's own texture, and not ragged.
    static func rescue(_ small: RGBA8Image, keep: [UInt8], info: MaskCheck, bgOK: [UInt8]) -> (keep: [UInt8], info: MaskCheck)? {
        let w = small.width, h = small.height, n = w * h
        var R = [Float](repeating: 0, count: n), G = R, B = R
        for i in 0..<n {
            R[i] = Float(small.pixels[i * 4]); G[i] = Float(small.pixels[i * 4 + 1]); B[i] = Float(small.pixels[i * 4 + 2])
        }
        let Gm = ImageOps.gradMag(ImageOps.boxBlur(R, w, h, 1), ImageOps.boxBlur(G, w, h, 1), ImageOps.boxBlur(B, w, h, 1), w, h)
        var lab = [UInt8](repeating: 0, count: n)
        let core = ImageOps.morph(keep, w, h, 2, dilate: false)
        let rr = Double(min(w, h)) * 0.08
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let dx = Double(x) - Double(w) / 2, dy = Double(y) - Double(h) / 2
                if (core[i] != 0 && !info.bad) || (dx * dx + dy * dy).squareRoot() < rr { lab[i] = 1 }
            }
        }
        func edgeSeed(_ i: Int) { if bgOK[i] != 0 { lab[i] = 2 } }
        for x in 0..<w { edgeSeed(x); edgeSeed(n - w + x) }
        for y in 0..<h { edgeSeed(y * w); edgeSeed(y * w + w - 1) }
        ImageOps.flood(Gm, w, h, &lab)
        var k2 = [UInt8](repeating: 0, count: n)
        for i in 0..<n { k2[i] = lab[i] == 1 ? 1 : 0 }
        k2 = ImageOps.fillHoles(ImageOps.morph(ImageOps.morph(k2, w, h, 1, dilate: false), w, h, 1, dilate: true), w, h)
        var ge = 0.0, ne = 0.0, gb = 0.0, nb = 0.0, ar = 0.0
        if w > 2 && h > 2 {
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    ar += Double(k2[i])
                    if k2[i] != 0 && (k2[i - 1] == 0 || k2[i + 1] == 0 || k2[i - w] == 0 || k2[i + w] == 0) {
                        ge += Double(Gm[i]); ne += 1
                    } else if k2[i] == 0 {
                        gb += Double(Gm[i]); nb += 1
                    }
                }
            }
        }
        let i2 = check(k2, w, h)
        let edge = (ge / max(1, ne)) / (gb / max(1, nb) + 2)
        let round = ne * ne / (4 * Double.pi * max(1, ar))
        guard !i2.bad && edge > 2.5 && round < 4 else { return nil }
        return (k2, i2)
    }

    /// Full-resolution alpha (port of `craftAlpha`): bilinear mask, refined at the edges by colour distance
    /// (or a soft ramp for a rescued outline). A fallback mask keeps everything.
    static func alpha(full src: RGBA8Image, mask m: CraftMask) -> [UInt8] {
        let W = src.width, H = src.height
        if m.fallback { return [UInt8](repeating: 255, count: W * H) }
        var a = [UInt8](repeating: 0, count: W * H)
        let kx = Double(m.width) / Double(W), ky = Double(m.height) / Double(H)
        let T = m.threshold
        m.mask.withUnsafeBufferPointer { M in
            src.pixels.withUnsafeBufferPointer { px in
                for y in 0..<H {
                    let fy = ((Double(y) + 0.5) * ky - 0.5).clamped(0, Double(m.height - 1))
                    let y0 = Int(fy), y1 = min(y0 + 1, m.height - 1)
                    let wy = Float(fy - Double(y0))
                    for x in 0..<W {
                        let fx = ((Double(x) + 0.5) * kx - 0.5).clamped(0, Double(m.width - 1))
                        let x0 = Int(fx), x1 = min(x0 + 1, m.width - 1)
                        let wx = Float(fx - Double(x0))
                        let top = M[y0 * m.width + x0] * (1 - wx) + M[y0 * m.width + x1] * wx
                        let bot = M[y1 * m.width + x0] * (1 - wx) + M[y1 * m.width + x1] * wx
                        let v = top * (1 - wy) + bot * wy
                        let i = y * W + x
                        if v >= 0.98 {
                            a[i] = 255
                        } else if v <= 0.02 {
                            a[i] = 0
                        } else if m.soft {
                            a[i] = UInt8((smoothStep(Float(0.25), 0.75, v) * 255).clamped(0, 255))
                        } else {
                            let f = feature(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2]))
                            let ad = smoothStep(T * 0.7, T * 1.25, distanceToBackground(f, m.centers))
                            a[i] = UInt8(((ad * 0.65 + v * 0.35) * 255).clamped(0, 255))
                        }
                    }
                }
            }
        }
        return a
    }
}
