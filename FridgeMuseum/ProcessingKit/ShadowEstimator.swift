import Foundation

/// Light layers for a sheet with a cast shadow (phone or hand), on the same cell grid as `FlattenModel.map`.
/// The GPU picks `light` per pixel, and near a light step (shadow edge) moves between `low` and `high` according to
/// the pixel's own brightness (see `fmFlattenDivideShadow` in Kernels.metal).
struct ShadowLayers: Sendable, Equatable {
    /// RGBA float, sRGB-encoded 0...1, row 0 = top (same layout as `FlattenModel.map`): the paper's light.
    var light: [Float]
    /// Brightest / darkest paper light within ±3 cells (the two sides of a shadow edge).
    var high: [Float]
    var low: [Float]
    /// Number of cells that were recognised as shadowed paper (diagnostics / tests).
    var shadowCells: Int
}

/// Cast-shadow step of the light estimate (1.0.1).
///
/// The v0.9 estimate fills the light under a shadow from lit paper (dark shadows fail its brightness, chroma and
/// clamp rules) or blurs lit and shadowed paper together (soft shadows), leaving dark blocks or grey ghosts.
/// Here shadowed paper is found explicitly – smooth, darker, one consistent level and tint per region – then grown
/// over crayon, print and ink using the brightest pixels of each block. Shadowed cells keep their own light
/// (edge-preserving smoothing), the rest of the shadow region gets the shadow's per-channel transmission times the
/// lit light, so the tint of the shadow light divides out too. Grid work only (~128 × 96 cells).
enum ShadowEstimator {
    // Lit paper: near the max over a wide window, and not much darker than the paper colour.
    static let litWindowK: Float = 0.88
    static let litWindowRadius = 3          // × r1
    static let litAbsoluteK: Float = 0.6
    // Shadow seeds.
    static let rhoMax: Float = 0.88
    static let rhoMin: Float = 0.06
    static let seedTexture: Float = 0.02
    static let seedChroma: Float = 0.06
    static let minRegionFraction = 0.004
    static let regionRhoMax: Float = 0.85
    static let regionRhoMin: Float = 0.12
    /// One shadow level per region: neighbours differ by less than this in ln(ratio).
    static let stepLog: Float = 0.12
    /// …and by less than this in chromaticity (sum of |r/Σ − r'/Σ'|).
    static let tintTolerance: Float = 0.05
    // Growth over textured cells (bright-pixel stats).
    static let growChroma: Float = 0.07
    static let growTexture: Float = 0.30
    static let growSeedLog: Float = 0.35
    static let growRounds = 40
    // Layers.
    static let closeRadius = 2
    static let bilateralRadius = 2
    static let bilateralSigma: Float = 0.08
    static let rangeRadius = 3
    static let floorK: Float = 0.08
    static let litLow: Float = 0.3

    @inline(__always) static func lum(_ r: Float, _ g: Float, _ b: Float) -> Float { 0.299 * r + 0.587 * g + 0.114 * b }

    /// - Returns: nil when no shadow region is found (the caller keeps the v0.9 model unchanged).
    static func layers(_ a: IlluminationEstimator.Analysis, Q: [Float], width w: Int, height h: Int,
                       bright: () -> (R: [Float], G: [Float], B: [Float])) -> ShadowLayers? {
        let n = w * h
        guard n > 0, a.mode != .paintCovered else { return nil }
        let R = a.R, G = a.G, B = a.B, L = a.L, P = a.P, PL = a.PL
        let Pa: [Float] = [P.x, P.y, P.z]
        let r1 = max(2, Int((Double(max(w, h)) * 0.05).rounded()))

        // 1. strict lit mask and the lit light
        let wideMax = maxFilter(L, w, h, litWindowRadius * r1)
        var lit0 = [Float](repeating: 0, count: n)
        for i in 0..<n where a.M[i] > 0 && L[i] >= litWindowK * wideMax[i] && L[i] >= litAbsoluteK * PL { lit0[i] = 1 }
        let Mlit = lit0
        let litFirst = fill([R, G, B], mask: Mlit, w, h, r1, fallback: Pa)
        var rho = [Float](repeating: 1, count: n), logRho = rho
        for i in 0..<n {
            rho[i] = L[i] / max(lum(litFirst[0][i], litFirst[1][i], litFirst[2][i]), 1e-3)
            logRho[i] = log(max(rho[i], 1e-3))
        }

        // 2. shadow seeds: darker than the lit light, smooth, grey-ish; one level and tint per region
        let Pch = max(P.x, P.y, P.z) - min(P.x, P.y, P.z)
        var cand = [Bool](repeating: false, count: n)
        var tint = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            let chroma = max(R[i], G[i], B[i]) - min(R[i], G[i], B[i])
            cand[i] = rho[i] < rhoMax && rho[i] > rhoMin && Q[i] < seedTexture && chroma - rho[i] * Pch < seedChroma
            tint[i] = chromaticity(R[i], G[i], B[i])
        }
        let regions = labelSimilar(cand, logRho, tint, w, h)
        let minSize = max(20, Int(minRegionFraction * Double(n)))
        var inSeed = [Bool](repeating: false, count: n)
        var seedRho = [Float](repeating: 0, count: n)
        var seedTint = [SIMD3<Float>](repeating: .zero, count: n)
        var accepted: [(cells: [Int], rho: Float, tint: SIMD3<Float>)] = []
        for cells in regions where cells.count >= minSize {
            let md = ImageOps.median(cells.map { rho[$0] })
            guard md >= regionRhoMin && md < regionRhoMax else { continue }
            let t = SIMD3<Float>(ImageOps.median(cells.map { tint[$0].x }), ImageOps.median(cells.map { tint[$0].y }),
                                 ImageOps.median(cells.map { tint[$0].z }))
            accepted.append((cells: cells, rho: md, tint: t))
        }
        // A smaller region at the same level but with another tint right next to a bigger one is a colour patch
        // lying in the shadow (pale marker, smooth crayon), not a second shadow: drop it.
        var owner = [Int](repeating: -1, count: n)
        for (ri, reg) in accepted.enumerated() { for c in reg.cells { owner[c] = ri } }
        var dropped = Set<Int>()
        for (ri, reg) in accepted.enumerated() {
            var touching = Set<Int>()
            for c in reg.cells {
                let x = c % w, y = c / w
                for yy in max(0, y - 2)...min(h - 1, y + 2) {
                    for xx in max(0, x - 2)...min(w - 1, x + 2) {
                        let o = owner[yy * w + xx]
                        if o >= 0 && o != ri { touching.insert(o) }
                    }
                }
            }
            for o in touching {
                let other = accepted[o]
                if abs(log(reg.rho / other.rho)) < growSeedLog, tintDistance(reg.tint, other.tint) >= tintTolerance,
                   reg.cells.count < other.cells.count {
                    dropped.insert(ri)
                }
            }
        }
        var anySeed = false
        for (ri, reg) in accepted.enumerated() where !dropped.contains(ri) {
            let lmd = log(reg.rho)
            // cells that drifted away from the region's tint / level (chained through mixed edge cells) are not seeds
            for c in reg.cells where tintDistance(tint[c], reg.tint) < tintTolerance && abs(logRho[c] - lmd) < growSeedLog {
                inSeed[c] = true; seedRho[c] = reg.rho; seedTint[c] = reg.tint
                anySeed = true
            }
        }
        guard anySeed else { return nil }

        // 3. grow over crayon / print / ink with the bright-pixel stats (paper between the strokes)
        let br = bright()
        var ratios = [Float]()
        for i in 0..<n where Mlit[i] > 0 {
            ratios.append(lum(br.R[i], br.G[i], br.B[i]) / max(L[i], 1e-3))
        }
        let kappa = ratios.isEmpty ? 1 : max(ImageOps.median(ratios), 1e-3)
        var Rb = br.R, Gb = br.G, Bb = br.B
        var okGrow = [Bool](repeating: false, count: n)
        var growLog = logRho
        var growTint = tint
        for i in 0..<n {
            Rb[i] /= kappa; Gb[i] /= kappa; Bb[i] /= kappa
            let rb = lum(Rb[i], Gb[i], Bb[i]) / max(lum(litFirst[0][i], litFirst[1][i], litFirst[2][i]), 1e-3)
            let chb = max(Rb[i], Gb[i], Bb[i]) - min(Rb[i], Gb[i], Bb[i])
            okGrow[i] = rb < rhoMax && rb > rhoMin && chb - rb * Pch < growChroma && Q[i] < growTexture
            if !inSeed[i] { growLog[i] = log(max(rb, 1e-3)) }
            growTint[i] = chromaticity(Rb[i], Gb[i], Bb[i])
        }
        var shadowPaper = inSeed
        for _ in 0..<growRounds {
            let before = shadowPaper
            var added = false
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    if before[i] || !okGrow[i] { continue }
                    for j in neighbours4(x, y, w, h) where before[j] {
                        if abs(growLog[i] - growLog[j]) < stepLog,
                           abs(growLog[i] - log(max(seedRho[j], 1e-3))) < growSeedLog,
                           tintDistance(growTint[i], seedTint[j]) < tintTolerance {
                            shadowPaper[i] = true; seedRho[i] = seedRho[j]; seedTint[i] = seedTint[j]
                            added = true
                            break
                        }
                    }
                }
            }
            if !added { break }
        }

        // 4. shadow region: closed and hole-filled, plus non-paper cells nearer to shadow paper than to lit paper
        let sp: [UInt8] = shadowPaper.map { $0 ? UInt8(1) : UInt8(0) }
        let closed = ImageOps.morph(ImageOps.morph(sp, w, h, closeRadius, dilate: true), w, h, closeRadius, dilate: false)
        var region = [UInt8](repeating: 0, count: n)
        for i in 0..<n { region[i] = (closed[i] != 0 || sp[i] != 0) ? 1 : 0 }
        region = ImageOps.fillHoles(region, w, h)
        let dShadow = chessboardDistance(sp, w, h, cap: r1 + 1)
        let dLit = chessboardDistance(Mlit.map { $0 > 0 ? UInt8(1) : UInt8(0) }, w, h, cap: r1 + 1)
        for i in 0..<n where !shadowPaper[i] && Mlit[i] == 0 && dShadow[i] < dLit[i] && dShadow[i] <= r1 { region[i] = 1 }

        // 5. lit layer without anything near the shadow; shadow layer = per-channel transmission × lit light
        let near = ImageOps.morph(region, w, h, 1, dilate: true)
        var Mlit2 = Mlit
        for i in 0..<n where near[i] != 0 { Mlit2[i] = 0 }
        var lit = fill([R, G, B], mask: Mlit2, w, h, r1, fallback: Pa)
        for c in 0..<3 { for i in 0..<n { lit[c][i] = lit[c][i].clamped(litLow * Pa[c], 1) } }
        let ownR = (0..<n).map { inSeed[$0] ? R[$0] : Rb[$0] }
        let ownG = (0..<n).map { inSeed[$0] ? G[$0] : Gb[$0] }
        let ownB = (0..<n).map { inSeed[$0] ? B[$0] : Bb[$0] }
        let own = [ownR, ownG, ownB]
        var T = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        var Tmed: [Float] = [0, 0, 0]
        let spMask: [Float] = shadowPaper.map { $0 ? Float(1) : Float(0) }
        for c in 0..<3 {
            var sel = [Float]()
            for i in 0..<n {
                T[c][i] = (own[c][i] / max(lit[c][i], 1e-3)).clamped(0, 1.2)
                if shadowPaper[i] { sel.append(T[c][i]) }
            }
            Tmed[c] = ImageOps.median(sel)
        }
        let Tf = fill(T, mask: spMask, w, h, max(2, r1 / 2), fallback: Tmed)
        let smoothOwn = bilateral(own, mask: shadowPaper, w, h)

        var E = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        for c in 0..<3 {
            let floor = floorK * Pa[c]
            for i in 0..<n {
                if shadowPaper[i] {
                    E[c][i] = min(max(smoothOwn[c][i], floor), lit[c][i])
                } else if region[i] != 0 {
                    E[c][i] = min(max(lit[c][i] * Tf[c][i], floor), lit[c][i])
                } else {
                    E[c][i] = lit[c][i]
                }
            }
        }

        // 6. light range from known cells (lit paper and shadow paper), for the per-pixel step
        var LE = [Float](repeating: 0, count: n)
        for i in 0..<n { LE[i] = lum(E[0][i], E[1][i], E[2][i]) }
        var hiIdx = Array(0..<n), loIdx = Array(0..<n)
        let rr = rangeRadius
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var hL = LE[i], lL = LE[i]
                for yy in max(0, y - rr)...min(h - 1, y + rr) {
                    for xx in max(0, x - rr)...min(w - 1, x + rr) {
                        let j = yy * w + xx
                        guard shadowPaper[j] || Mlit2[j] > 0 else { continue }
                        if LE[j] > hL { hL = LE[j]; hiIdx[i] = j }
                        if LE[j] < lL { lL = LE[j]; loIdx[i] = j }
                    }
                }
            }
        }

        var light = [Float](repeating: 1, count: n * 4), high = light, low = light
        for i in 0..<n {
            for c in 0..<3 {
                light[i * 4 + c] = E[c][i]
                high[i * 4 + c] = E[c][hiIdx[i]]
                low[i * 4 + c] = E[c][loIdx[i]]
            }
        }
        if a.mode == .colored {
            // coloured paper: light only, as grey gain maps (like the v0.9 colored map)
            func grey(_ m: inout [Float]) {
                for i in 0..<n {
                    let l = max(lum(m[i * 4], m[i * 4 + 1], m[i * 4 + 2]), 1e-4)
                    let v = 1 / (PL / l).clamped(0.7, 1 / floorK)
                    m[i * 4] = v; m[i * 4 + 1] = v; m[i * 4 + 2] = v
                }
            }
            grey(&light); grey(&high); grey(&low)
        }
        return ShadowLayers(light: light, high: high, low: low, shadowCells: shadowPaper.reduce(0) { $0 + ($1 ? 1 : 0) })
    }

    // MARK: - Grid helpers

    @inline(__always) static func chromaticity(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        let s = max(r + g + b, 1e-3)
        return SIMD3<Float>(r / s, g / s, b / s)
    }

    @inline(__always) static func tintDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return abs(d.x) + abs(d.y) + abs(d.z)
    }

    static func neighbours4(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [Int] {
        var o = [Int]()
        o.reserveCapacity(4)
        if x + 1 < w { o.append(y * w + x + 1) }
        if x > 0 { o.append(y * w + x - 1) }
        if y + 1 < h { o.append((y + 1) * w + x) }
        if y > 0 { o.append((y - 1) * w + x) }
        return o
    }

    /// Separable max filter, window (2r+1)², edges clamped.
    static func maxFilter(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var t = a, o = a
        for y in 0..<h {
            for x in 0..<w {
                var m = -Float.greatestFiniteMagnitude
                for k in max(0, x - r)...min(w - 1, x + r) { m = max(m, a[y * w + k]) }
                t[y * w + x] = m
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var m = -Float.greatestFiniteMagnitude
                for k in max(0, y - r)...min(h - 1, y + r) { m = max(m, t[k * w + x]) }
                o[y * w + x] = m
            }
        }
        return o
    }

    /// Masked normalized convolution at r1 and 3·r1 with the v0.9 weights; `fallback` where no mask is near.
    static func fill(_ vals: [[Float]], mask: [Float], _ w: Int, _ h: Int, _ r1: Int, fallback: [Float]) -> [[Float]] {
        let n = w * h
        let fw = ImageOps.blur3(mask, w, h, r1), cw = ImageOps.blur3(mask, w, h, r1 * 3)
        var out = [[Float]]()
        for (c, v) in vals.enumerated() {
            var mv = [Float](repeating: 0, count: n)
            for i in 0..<n { mv[i] = v[i] * mask[i] }
            let fv = ImageOps.blur3(mv, w, h, r1), cv = ImageOps.blur3(mv, w, h, r1 * 3)
            let f = fallback[c]
            var o = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let wf = smoothStep(Float(0.02), 0.08, fw[i]), wc = smoothStep(Float(0.005), 0.03, cw[i])
                var cc: Float = cw[i] > 1e-6 ? cv[i] / max(cw[i], 1e-6) : f
                cc = cc * wc + f * (1 - wc)
                let fi: Float = fw[i] > 1e-6 ? fv[i] / max(fw[i], 1e-6) : 0
                o[i] = fi * wf + cc * (1 - wf)
            }
            out.append(o)
        }
        return out
    }

    /// Mean over masked cells in a 5×5 window weighted by similarity of ln(luminance): never averages across a
    /// light step (two shadow levels, shadow and lit).
    static func bilateral(_ vals: [[Float]], mask: [Bool], _ w: Int, _ h: Int) -> [[Float]] {
        let n = w * h
        var lg = [Float](repeating: 0, count: n)
        for i in 0..<n { lg[i] = log(max(lum(vals[0][i], vals[1][i], vals[2][i]), 1e-3)) }
        var out = vals
        let r = bilateralRadius
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var acc = SIMD3<Float>(repeating: 0), ws: Float = 0
                for yy in max(0, y - r)...min(h - 1, y + r) {
                    for xx in max(0, x - r)...min(w - 1, x + r) {
                        let j = yy * w + xx
                        guard mask[j] else { continue }
                        let d = (lg[j] - lg[i]) / bilateralSigma
                        let wt = exp(-d * d)
                        acc += SIMD3<Float>(vals[0][j], vals[1][j], vals[2][j]) * wt
                        ws += wt
                    }
                }
                if ws > 1e-6 {
                    out[0][i] = acc.x / ws; out[1][i] = acc.y / ws; out[2][i] = acc.z / ws
                }
            }
        }
        return out
    }

    /// 4-connected regions of `mask` whose neighbours differ by < `stepLog` in `v` and < `tintTolerance` in tint.
    static func labelSimilar(_ mask: [Bool], _ v: [Float], _ tint: [SIMD3<Float>], _ w: Int, _ h: Int) -> [[Int]] {
        var seen = [Bool](repeating: false, count: w * h)
        var regions = [[Int]]()
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            seen[start] = true
            var cells = [start], stack = [start]
            while let p = stack.popLast() {
                for q in neighbours4(p % w, p / w, w, h) where mask[q] && !seen[q] {
                    if abs(v[q] - v[p]) < stepLog && tintDistance(tint[q], tint[p]) < tintTolerance {
                        seen[q] = true
                        cells.append(q)
                        stack.append(q)
                    }
                }
            }
            regions.append(cells)
        }
        return regions
    }

    /// Chessboard distance to the nearest set cell (8-connected BFS), capped.
    static func chessboardDistance(_ on: [UInt8], _ w: Int, _ h: Int, cap: Int) -> [Int] {
        var d = [Int](repeating: cap, count: w * h)
        var frontier = [Int]()
        for i in 0..<(w * h) where on[i] != 0 { d[i] = 0; frontier.append(i) }
        var dist = 0
        while !frontier.isEmpty && dist < cap {
            dist += 1
            var next = [Int]()
            for p in frontier {
                let x = p % w, y = p / w
                for yy in max(0, y - 1)...min(h - 1, y + 1) {
                    for xx in max(0, x - 1)...min(w - 1, x + 1) {
                        let q = yy * w + xx
                        if d[q] > dist { d[q] = dist; next.append(q) }
                    }
                }
            }
            frontier = next
        }
        return d
    }
}
