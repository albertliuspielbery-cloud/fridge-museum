import Foundation

/// Port of the prototype's `flatten()` light estimate.
/// Input: block-averaged warped image at low resolution (≈128 px long edge), RGBA float, sRGB-encoded 0...1,
/// row 0 = top. Output: same-size RGBA float map of the *paper's* color/light at each block.
/// The GPU then divides the full-resolution image by the (bilinearly upsampled) map.
enum IlluminationEstimator {
    /// Block size used to downsample an image of the given size (same rule as the prototype).
    static func blockSize(width: Int, height: Int) -> Int { max(1, Int((Double(max(width, height)) / 128).rounded(.up))) }

    static func backgroundMap(rgba: [Float], width sw: Int, height sh: Int) -> [Float] {
        let n = sw * sh
        precondition(rgba.count == n * 4)
        var R = [Float](repeating: 0, count: n), G = R, B = R, L = R
        for i in 0..<n {
            R[i] = rgba[i * 4].clamped(0, 1)
            G[i] = rgba[i * 4 + 1].clamped(0, 1)
            B[i] = rgba[i * 4 + 2].clamped(0, 1)
            L[i] = 0.299 * R[i] + 0.587 * G[i] + 0.114 * B[i]
        }
        let thr = L.sorted()[min(n - 1, Int(Double(n) * 0.7))]
        var pr = [Float](), pg = [Float](), pb = [Float]()
        for i in 0..<n where L[i] >= thr { pr.append(R[i]); pg.append(G[i]); pb.append(B[i]) }
        let P = [ImageOps.median(pr), ImageOps.median(pg), ImageOps.median(pb)]
        let PL = 0.299 * P[0] + 0.587 * P[1] + 0.114 * P[2]
        let Ps = P[0] + P[1] + P[2] + 1e-4

        // Paper-like blocks: near the local max brightness, not too dark, paper-colored.
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
                let cd = abs(R[i] / s - P[0] / Ps) + abs(G[i] / s - P[1] / Ps) + abs(B[i] / s - P[2] / Ps)
                M[i] = (L[i] >= 0.85 * mx && L[i] > 0.4 * PL && cd < 0.07) ? 1 : 0
            }
        }

        // Normalized convolution: average of paper blocks only.
        func nconv(_ r: Int) -> (r: [Float], g: [Float], b: [Float], m: [Float]) {
            var mr = [Float](repeating: 0, count: n), mg = mr, mb = mr
            for i in 0..<n { mr[i] = R[i] * M[i]; mg[i] = G[i] * M[i]; mb[i] = B[i] * M[i] }
            return (ImageOps.blur3(mr, sw, sh, r), ImageOps.blur3(mg, sw, sh, r), ImageOps.blur3(mb, sw, sh, r), ImageOps.blur3(M, sw, sh, r))
        }
        let r1 = max(2, Int((Double(max(sw, sh)) * 0.05).rounded()))
        let fine = nconv(r1), coarse = nconv(r1 * 3)

        var out = [Float](repeating: 1, count: n * 4)
        for i in 0..<n {
            let wc = smoothStep(Float(0.005), 0.03, coarse.m[i])
            let cm = max(coarse.m[i], 1e-6)
            let cr = wc > 0 ? coarse.r[i] / cm : P[0]
            let cg = wc > 0 ? coarse.g[i] / cm : P[1]
            let cb = wc > 0 ? coarse.b[i] / cm : P[2]
            let c2r = cr * wc + P[0] * (1 - wc), c2g = cg * wc + P[1] * (1 - wc), c2b = cb * wc + P[2] * (1 - wc)
            let wf = smoothStep(Float(0.02), 0.08, fine.m[i])
            let fm = max(fine.m[i], 1e-6)
            let fr = wf > 0 ? fine.r[i] / fm : 0, fg = wf > 0 ? fine.g[i] / fm : 0, fb = wf > 0 ? fine.b[i] / fm : 0
            out[i * 4] = (fr * wf + c2r * (1 - wf)).clamped(0.45 * P[0], 1)
            out[i * 4 + 1] = (fg * wf + c2g * (1 - wf)).clamped(0.45 * P[1], 1)
            out[i * 4 + 2] = (fb * wf + c2b * (1 - wf)).clamped(0.45 * P[2], 1)
            out[i * 4 + 3] = 1
        }
        return out
    }
}
