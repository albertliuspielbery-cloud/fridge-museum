import Foundation

/// The paper's light, estimated at low resolution (port of the prototype's `flatten()`, v0.9).
/// The GPU divides the full-resolution image by the bilinearly upsampled `map` and multiplies by `gain`.
struct FlattenModel: Sendable, Equatable {
    /// RGBA float, sRGB-encoded 0...1, cell grid sw×sh, row 0 = top. For `.colored` the map is grey (light only).
    var map: [Float]
    var width: Int
    var height: Int
    /// Source pixels per cell.
    var blockSize: Int
    var mode: PaperMode
    /// Fraction of cells that look like bare paper.
    var cover: Double
    /// Median paper colour (0...1).
    var paper: SIMD3<Float>
    /// 0.97 for white / paint-covered paper (prototype), 1 for coloured paper.
    var gain: Float
}

/// Port of the prototype's light estimate.
/// - white: white paper, mapped to white.
/// - paintCovered ("sparse"): paint covers most of the sheet, so only a gentle, coarse correction.
/// - colored ("keep"): coloured or dark paper; only the light is evened out and the paper keeps its colour.
enum IlluminationEstimator {
    /// Block size used to downsample an image of the given size (same rule as the prototype).
    static func blockSize(width: Int, height: Int) -> Int { max(1, Int((Double(max(width, height)) / 128).rounded(.up))) }

    /// Block statistics of an RGBA8 image: mean R, G, B (0...1) and the standard deviation of luminance per block.
    static func blockStats(_ img: RGBA8Image) -> (R: [Float], G: [Float], B: [Float], Q: [Float], sw: Int, sh: Int, k: Int) {
        let W = img.width, H = img.height
        let k = blockSize(width: W, height: H)
        let sw = Int((Double(W) / Double(k)).rounded(.up)), sh = Int((Double(H) / Double(k)).rounded(.up)), n = sw * sh
        var R = [Float](repeating: 0, count: n), G = R, B = R, Q = R, C = R
        img.pixels.withUnsafeBufferPointer { d in
            for y in 0..<H {
                let sy = (y / k) * sw
                for x in 0..<W {
                    let si = sy + x / k, i = (y * W + x) * 4
                    let r = Float(d[i]), g = Float(d[i + 1]), b = Float(d[i + 2])
                    let l = 0.299 * r + 0.587 * g + 0.114 * b
                    R[si] += r; G[si] += g; B[si] += b; Q[si] += l * l; C[si] += 1
                }
            }
        }
        for i in 0..<n {
            let c = max(C[i], 1)
            R[i] /= c * 255; G[i] /= c * 255; B[i] /= c * 255
            let L = 0.299 * R[i] + 0.587 * G[i] + 0.114 * B[i]
            Q[i] = max(0, Q[i] / (c * 65025) - L * L).squareRoot()
        }
        return (R, G, B, Q, sw, sh, k)
    }

    static func model(_ img: RGBA8Image) -> FlattenModel {
        let s = blockStats(img)
        return estimate(R: s.R, G: s.G, B: s.B, Q: s.Q, width: s.sw, height: s.sh, blockSize: s.k)
    }

    /// Old entry point: map from block-averaged RGBA float (no texture information).
    static func backgroundMap(rgba: [Float], width sw: Int, height sh: Int) -> [Float] {
        let n = sw * sh
        precondition(rgba.count == n * 4)
        var R = [Float](repeating: 0, count: n), G = R, B = R
        for i in 0..<n { R[i] = rgba[i * 4]; G[i] = rgba[i * 4 + 1]; B[i] = rgba[i * 4 + 2] }
        return estimate(R: R, G: G, B: B, Q: [Float](repeating: 0, count: n), width: sw, height: sh, blockSize: 1).map
    }

    static func estimate(R inR: [Float], G inG: [Float], B inB: [Float], Q: [Float], width sw: Int, height sh: Int, blockSize k: Int) -> FlattenModel {
        let n = sw * sh
        let R = inR.map { $0.clamped(0, 1) }, G = inG.map { $0.clamped(0, 1) }, B = inB.map { $0.clamped(0, 1) }
        var L = [Float](repeating: 0, count: n)
        for i in 0..<n { L[i] = 0.299 * R[i] + 0.587 * G[i] + 0.114 * B[i] }
        let thr = ImageOps.quantile(L, 0.7)
        var pr = [Float](), pg = [Float](), pb = [Float]()
        for i in 0..<n where L[i] >= thr { pr.append(R[i]); pg.append(G[i]); pb.append(B[i]) }
        let P = SIMD3<Float>(ImageOps.median(pr), ImageOps.median(pg), ImageOps.median(pb))
        let PL = 0.299 * P.x + 0.587 * P.y + 0.114 * P.z
        let Ps = P.x + P.y + P.z + 1e-4

        // Paper-like cells: near the local max brightness, paper-coloured, and darker cells only when smooth
        // (pencil shading is grainy, a shadow is not).
        var M = [Float](repeating: 0, count: n)
        for y in 0..<sh {
            for x in 0..<sw {
                var mx: Float = 0
                for dy in -3...3 {
                    let yy = (y + dy).clamped(0, sh - 1) * sw
                    for dx in -3...3 {
                        let v = L[yy + (x + dx).clamped(0, sw - 1)]
                        if v > mx { mx = v }
                    }
                }
                let i = y * sw + x
                let s = R[i] + G[i] + B[i] + 1e-4
                let cd = abs(R[i] / s - P.x / Ps) + abs(G[i] / s - P.y / Ps) + abs(B[i] / s - P.z / Ps)
                let paper = L[i] >= 0.85 * mx && L[i] > 0.28 * PL && L[i] < 1.5 * PL && cd < 0.07 && (L[i] > 0.6 * PL || Q[i] < 0.025)
                M[i] = paper ? 1 : 0
            }
        }
        var cover: Double = 0
        for v in M { cover += Double(v) }
        cover /= Double(max(1, n))
        let mxP = max(P.x, P.y, P.z, 1e-3)
        let Pc = (mxP - min(P.x, P.y, P.z)) / mxP, ga = (P.x - P.y) / mxP, gb = (P.y - P.z) / mxP
        // how much tint can the light explain? warm lamp light (r > g > b) quite a lot, cool or other tints little
        let lightTint: Float = (ga >= -0.02 && gb >= -0.02) ? 0.3 : (ga <= 0.02 && gb <= 0.02) ? 0.15 : 0.1
        let mode: PaperMode = (PL < 0.42 || Pc > lightTint) ? .colored : cover < 0.2 ? .paintCovered : .white

        func nconv(_ r: Int) -> (r: [Float], g: [Float], b: [Float], m: [Float]) {
            var mr = [Float](repeating: 0, count: n), mg = mr, mb = mr
            for i in 0..<n { mr[i] = R[i] * M[i]; mg[i] = G[i] * M[i]; mb[i] = B[i] * M[i] }
            return (ImageOps.blur3(mr, sw, sh, r), ImageOps.blur3(mg, sw, sh, r), ImageOps.blur3(mb, sw, sh, r), ImageOps.blur3(M, sw, sh, r))
        }
        let r1 = max(2, Int((Double(max(sw, sh)) * 0.05).rounded()))
        let fine = mode == .paintCovered ? nil : nconv(r1)
        let coarse = nconv(r1 * 3)
        let lo: Float = mode == .paintCovered ? 0.75 : 0.3

        var out = [Float](repeating: 1, count: n * 4)
        for i in 0..<n {
            let wc = smoothStep(Float(0.005), 0.03, coarse.m[i])
            let cm = max(coarse.m[i], 1e-6)
            let cr = wc > 0 ? coarse.r[i] / cm : P.x
            let cg = wc > 0 ? coarse.g[i] / cm : P.y
            let cb = wc > 0 ? coarse.b[i] / cm : P.z
            let c2r = cr * wc + P.x * (1 - wc), c2g = cg * wc + P.y * (1 - wc), c2b = cb * wc + P.z * (1 - wc)
            var fr: Float = 0, fg: Float = 0, fb: Float = 0, wf: Float = 0
            if let fine {
                wf = smoothStep(Float(0.02), 0.08, fine.m[i])
                let fm = max(fine.m[i], 1e-6)
                if wf > 0 { fr = fine.r[i] / fm; fg = fine.g[i] / fm; fb = fine.b[i] / fm }
            }
            var br = (fr * wf + c2r * (1 - wf)).clamped(lo * P.x, 1)
            var bg = (fg * wf + c2g * (1 - wf)).clamped(lo * P.y, 1)
            var bb = (fb * wf + c2b * (1 - wf)).clamped(lo * P.z, 1)
            if mode == .colored {
                let lum = max(0.299 * br + 0.587 * bg + 0.114 * bb, 1e-4)
                let g = (PL / lum).clamped(0.7, 1.6)
                br = 1 / g; bg = 1 / g; bb = 1 / g
            }
            out[i * 4] = br
            out[i * 4 + 1] = bg
            out[i * 4 + 2] = bb
            out[i * 4 + 3] = 1
        }
        return FlattenModel(map: out, width: sw, height: sh, blockSize: k, mode: mode, cover: cover, paper: P,
                            gain: mode == .colored ? 1 : 0.97)
    }
}
