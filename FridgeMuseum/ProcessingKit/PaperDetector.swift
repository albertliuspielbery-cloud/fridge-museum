import Foundation

/// Port of the prototype's `detectPaper` (v0.9). Several candidate paper masks (bright and unsaturated / unlike the
/// table along the frame border / grown from the middle up to the strongest surrounding edge / the first and third
/// opened with a wide square). Each becomes a quadrilateral (convex hull → largest 4-corner shape → each side snapped
/// to the strongest straight edge nearby) and is scored by how well the mask fills it and how much the colour changes
/// across its sides. If nothing scores well the whole photo is kept and the result is marked as a guess.
///
/// Native order (ImageProcessor): Vision document segmentation first, refined with `refine(_:in:)`;
/// this detector is the fallback. Input should be small (≈360 px long edge).
enum PaperDetector {
    typealias P = SIMD2<Double>

    struct Result: Sendable, Equatable {
        var quad: Quad
        var isGuess: Bool
        var score: Double
    }

    struct Candidate {
        var q: [P]
        var fit: Double
        var con: Double
        var af: Double
        var score: Double
    }

    /// Planes used by the edge measurements (box-blurred colour channels of the small image).
    struct Planes {
        var R: [Float], G: [Float], B: [Float]
        var w: Int, h: Int

        init(_ img: RGBA8Image) {
            w = img.width
            h = img.height
            let n = w * h
            var r = [Float](repeating: 0, count: n), g = r, b = r
            for i in 0..<n {
                r[i] = Float(img.pixels[i * 4]); g[i] = Float(img.pixels[i * 4 + 1]); b[i] = Float(img.pixels[i * 4 + 2])
            }
            R = ImageOps.boxBlur(r, w, h, 1)
            G = ImageOps.boxBlur(g, w, h, 1)
            B = ImageOps.boxBlur(b, w, h, 1)
        }
    }

    /// Old entry point (tests): the quad only.
    static func detect(_ img: RGBA8Image) -> Quad { detectFull(img).quad }

    static func detectFull(_ img: RGBA8Image) -> Result {
        let w = img.width, h = img.height, n = w * h
        let guess = Result(quad: .full, isGuess: true, score: 0)
        guard w > 8, h > 8 else { return guess }
        var L = [UInt8](repeating: 0, count: n)
        var hist = [Double](repeating: 0, count: 256)
        img.pixels.withUnsafeBufferPointer { d in
            for i in 0..<n {
                let r = Double(d[i * 4]), g = Double(d[i * 4 + 1]), b = Double(d[i * 4 + 2])
                // brightness minus saturation: paper in shadow still scores above a coloured table
                let v = Int(((0.299 * r + 0.587 * g + 0.114 * b) - 1.5 * (max(r, g, b) - min(r, g, b))).clamped(0, 255))
                L[i] = UInt8(v)
                hist[v] += 1
            }
        }
        let planes = Planes(img)
        let Gm = ImageOps.gradMag(planes.R, planes.G, planes.B, w, h)
        let T = ImageOps.otsu(hist, total: Double(n))
        func clean(_ bin: [UInt8]) -> [UInt8] {
            let c = ImageOps.morph(ImageOps.morph(bin, w, h, 3, dilate: true), w, h, 3, dilate: false)
            return ImageOps.morph(ImageOps.morph(c, w, h, 1, dilate: false), w, h, 1, dilate: true)
        }
        var masks: [[UInt8]] = []
        // A: bright and unsaturated
        var a = [UInt8](repeating: 0, count: n)
        for i in 0..<n { a[i] = Int(L[i]) > T ? 1 : 0 }
        a = clean(a)
        masks.append(a)
        // B: unlike the table colours along the frame border (coloured, black or painted paper)
        let F = ImageOps.features(img)
        let ring = max(2, Int((Double(min(w, h)) * 0.03).rounded()))
        let Dd = ImageOps.distances(F, ImageOps.borderModel(F, w, h, ring: ring).centers)
        var sample = [Float]()
        sample.reserveCapacity(n / 4)
        for i in 0..<(n >> 2) { sample.append(Dd[i * 4]) }
        var maxD = ImageOps.quantile(sample, 0.99)
        if maxD <= 0 { maxD = 1 }
        var hd = [Double](repeating: 0, count: 256)
        for i in 0..<n { hd[min(255, Int(Dd[i] / maxD * 255))] += 1 }
        let TD = max(6, Float(ImageOps.otsu(hd, total: Double(n))) / 255 * maxD)
        var c = [UInt8](repeating: 0, count: n)
        for i in 0..<n { c[i] = Dd[i] > TD ? 1 : 0 }
        masks.append(clean(c))
        // is the frame border mostly bright paper (sheet filling the photo)... and does it have the paper's colour?
        var bp = 0
        for x in 0..<w { bp += Int(a[x]) + Int(a[n - w + x]) }
        for y in 0..<h { bp += Int(a[y * w]) + Int(a[y * w + w - 1]) }
        var bc = [Int](), br = [Int]()
        for y in ImageOps.span(h, 0.35, 0.65, step: 2) {
            for x in ImageOps.span(w, 0.35, 0.65, step: 2) where Int(L[y * w + x]) > T { bc.append(y * w + x) }
        }
        for x in stride(from: 0, to: w, by: 2) { br.append(x); br.append(n - w + x) }
        for y in stride(from: 0, to: h, by: 2) { br.append(y * w); br.append(y * w + w - 1) }
        br = br.filter { a[$0] != 0 }
        // compared as chromaticity, so darker corners (vignetting, falling light) still match the paper
        func medC(_ ix: [Int]) -> SIMD3<Double> {
            let r = Double(ImageOps.median(ix.map { planes.R[$0] }))
            let g = Double(ImageOps.median(ix.map { planes.G[$0] }))
            let b = Double(ImageOps.median(ix.map { planes.B[$0] }))
            let s = r + g + b + 1
            return SIMD3(r / s, g / s, b / s)
        }
        var cdiff = 0.0
        if !br.isEmpty, !bc.isEmpty {
            let d = medC(br) - medC(bc)
            cdiff = (abs(d.x) + abs(d.y) + abs(d.z)) * 1000
        }
        let borderIsPaper = Double(bp) / Double(2 * (w + h)) > 0.5 && cdiff < 25
        // C: grown from bright smooth pixels in the middle until it meets the strongest edge towards the frame border
        var lab = [UInt8](repeating: 0, count: n)
        var box = [Float]()
        for y in ImageOps.span(h, 0.3, 0.7) { for x in ImageOps.span(w, 0.3, 0.7) { box.append(Float(L[y * w + x])) } }
        let lb = ImageOps.quantile(box, 0.5)
        for y in ImageOps.span(h, 0.3, 0.7) {
            for x in ImageOps.span(w, 0.3, 0.7) {
                let i = y * w + x
                if Float(L[i]) >= lb && Gm[i] < 12 { lab[i] = 1 }
            }
        }
        for x in 0..<w { lab[x] = 2; lab[n - w + x] = 2 }
        for y in 0..<h { lab[y * w] = 2; lab[y * w + w - 1] = 2 }
        ImageOps.flood(Gm, w, h, &lab)
        var dm = [UInt8](repeating: 0, count: n)
        for i in 0..<n { dm[i] = lab[i] == 1 ? 1 : 0 }
        masks.append(ImageOps.morph(dm, w, h, 1, dilate: false))
        // D, E: A and C opened with a wide square, cutting off pieces of a patterned cloth stuck to the sheet
        let openR = max(3, Int((Double(max(w, h)) * 0.016).rounded()))
        func open(_ bin: [UInt8]) -> [UInt8] {
            ImageOps.morph(ImageOps.morph(bin, w, h, openR, dilate: false), w, h, openR, dilate: true)
        }
        masks.append(open(a))
        masks.append(open(masks[2]))

        var best: Candidate?
        for (j, mk) in masks.enumerated() {
            guard let m = largest(mk, w, h), var cq = quadCandidate(m, planes) else { continue }
            // B and C assume the frame border shows table: distrust them when they claim nearly the whole frame,
            // or when the border looks like paper and their shape is not clean
            if (j == 1 || j == 2 || j == 4) && (cq.af > 0.9 || (borderIsPaper && cq.fit < 0.95)) { cq.score *= 0.5 }
            if best == nil || cq.score > best!.score + 0.02 { best = cq }
        }
        // second look at a winner whose mask did not fill its shape well: let each side move further (up to 8 %)
        // to the straight edge that runs its whole length (glare, a shadow or a stone table bit into the mask)
        if var b = best, b.af < 0.96, b.fit < 0.95 {
            let r0 = edgeFit(b.q, planes, snap: false, range: 0, robust: true).con
            let wq = orderQuad(edgeFit(b.q, planes, snap: true, range: 0.08, robust: true).q, landscape: w >= h)
            let r1 = edgeFit(wq, planes, snap: false, range: 0, robust: true).con
            let ratio = polyArea(wq) / max(1, polyArea(b.q))
            if r1 > r0 * 1.15 && ratio > 0.8 && ratio < 1.3 {
                b.q = orderQuad(edgeFit(wq, planes, snap: true).q, landscape: w >= h)
                best = b
            }
        }
        guard let b = best, b.score >= 0.4, b.af <= 0.96 else { return guess }
        return Result(quad: normalize(b.q, w, h, shrink: 0.994), isGuess: false, score: b.score)
    }

    /// Snaps a quad from Vision to the strongest straight edges nearby (±2 % of the long edge) when that clearly
    /// raises the edge contrast. Returns the (possibly unchanged) quad and the robust edge contrast of the result.
    static func refine(_ quad: Quad, in img: RGBA8Image) -> (quad: Quad, contrast: Double) {
        let w = img.width, h = img.height
        guard w > 8, h > 8 else { return (quad, -1) }
        let planes = Planes(img)
        let q0 = quad.points.map { P($0.x * Double(w), $0.y * Double(h)) }
        let c0 = edgeFit(q0, planes, snap: false, range: 0, robust: true).con
        let q1 = orderQuad(edgeFit(q0, planes, snap: true).q, landscape: w >= h)
        let c1 = edgeFit(q1, planes, snap: false, range: 0, robust: true).con
        let ratio = polyArea(q1) / max(1, polyArea(q0))
        if c1 > c0 * 1.05, ratio > 0.9, ratio < 1.1 {
            let r = normalize(q1, w, h, shrink: 1)
            if r.isConvex { return (r, c1) }
        }
        return (quad, c0)
    }

    // MARK: - Pieces (ports)

    static func normalize(_ q: [P], _ w: Int, _ h: Int, shrink: Double) -> Quad {
        let c = q.reduce(P.zero, +) / 4
        let pts = q.map { p -> NormPoint in
            let s = c + (p - c) * shrink
            return NormPoint(x: (s.x / Double(w)).clamped(0, 1), y: (s.y / Double(h)).clamped(0, 1))
        }
        return Quad(topLeft: pts[0], topRight: pts[1], bottomRight: pts[2], bottomLeft: pts[3])
    }

    static func polyArea(_ q: [P]) -> Double {
        guard q.count == 4 else { return 0 }
        return abs((q[2].x - q[0].x) * (q[3].y - q[1].y) - (q[3].x - q[1].x) * (q[2].y - q[0].y)) / 2
    }

    @inline(__always) static func dist(_ a: P, _ b: P) -> Double { ((a - b) * (a - b)).sum().squareRoot() }

    static func largest(_ bin: [UInt8], _ w: Int, _ h: Int) -> [UInt8]? {
        let cc = ImageOps.components(bin, w, h)
        var best = 0
        if cc.count > 0 { for k in 1...cc.count where cc.area[k] > cc.area[best] { best = k } }
        guard best > 0 else { return nil }
        let label = Int32(best)
        var m = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { m[i] = cc.labels[i] == label ? 1 : 0 }
        return ImageOps.fillHoles(m, w, h)
    }

    static func convexHull(_ input: [P]) -> [P] {
        let pts = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count >= 3 else { return pts }
        func cr(_ o: P, _ a: P, _ b: P) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lo = [P](), up = [P]()
        for p in pts {
            while lo.count >= 2 && cr(lo[lo.count - 2], lo[lo.count - 1], p) <= 0 { lo.removeLast() }
            lo.append(p)
        }
        for p in pts.reversed() {
            while up.count >= 2 && cr(up[up.count - 2], up[up.count - 1], p) <= 0 { up.removeLast() }
            up.append(p)
        }
        return Array(lo.dropLast()) + Array(up.dropLast())
    }

    @inline(__always) static func triArea(_ a: P, _ b: P, _ c: P) -> Double {
        abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
    }

    /// Largest-area quadrilateral whose corners are hull points (hull first thinned to ≤ 40 points).
    static func hullQuad(_ hull: [P]) -> [P]? {
        var H = hull
        while H.count > 40 {
            var bi = 0, bv = Double.greatestFiniteMagnitude
            for i in 0..<H.count {
                let v = triArea(H[(i + H.count - 1) % H.count], H[i], H[(i + 1) % H.count])
                if v < bv { bv = v; bi = i }
            }
            H.remove(at: bi)
        }
        let n = H.count
        guard n >= 4 else { return nil }
        var best = -1.0
        var bq: [P]?
        for i in 0..<n {
            for k in (i + 2)..<max(i + 2, n) {
                var b1 = -1.0, j1 = -1, b2 = -1.0, l1 = -1
                for j in (i + 1)..<k {
                    let v = triArea(H[i], H[j], H[k])
                    if v > b1 { b1 = v; j1 = j }
                }
                if k + 1 < n + i {
                    for l in (k + 1)..<(n + i) {
                        let L = l % n
                        let v = triArea(H[i], H[k], H[L])
                        if v > b2 { b2 = v; l1 = L }
                    }
                }
                if j1 >= 0 && l1 >= 0 && b1 + b2 > best { best = b1 + b2; bq = [H[i], H[j1], H[k], H[l1]] }
            }
        }
        return bq
    }

    /// Clockwise from the top-left corner. The top side is the one facing most upward; for a sheet turned about 45°
    /// pick the one that keeps the photo's own orientation (landscape photo → landscape sheet).
    static func orderQuad(_ input: [P], landscape: Bool) -> [P] {
        guard input.count == 4 else { return input }
        let c = input.reduce(P.zero, +) / 4
        let q = input.sorted { atan2($0.y - c.y, $0.x - c.x) < atan2($1.y - c.y, $1.x - c.x) }
        let up = (0..<4).map { i -> Double in
            let a = q[i], b = q[(i + 1) % 4]
            let d = dist(a, b)
            return (b.x - a.x) / (d > 0 ? d : 1)
        }
        let ord = (0..<4).sorted { up[$0] != up[$1] ? up[$0] > up[$1] : $0 < $1 }
        var s = ord[0]
        if up[ord[0]] - up[ord[1]] < 0.17 {
            func wide(_ i: Int) -> Bool { dist(q[i], q[(i + 1) % 4]) >= dist(q[(i + 1) % 4], q[(i + 2) % 4]) }
            if wide(ord[1]) == landscape && wide(ord[0]) != landscape { s = ord[1] }
        }
        return (0..<4).map { q[(s + $0) % 4] }
    }

    static func lineIntersection(_ a: P, _ b: P, _ c: P, _ d: P) -> P? {
        let r = b - a, s = d - c
        let den = r.x * s.y - r.y * s.x
        guard abs(den) >= 1e-9 else { return nil }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / den
        return a + r * t
    }

    /// Mean colour change across each side of q (sides on the frame edge are skipped); optionally snaps each side to the
    /// best edge within ±range of the long edge. robust: a side scores by its 30th-percentile sample, so only an edge
    /// that runs the whole side counts.
    static func edgeFit(_ q: [P], _ pl: Planes, snap: Bool, range: Double = 0.02, robust: Bool = false) -> (q: [P], con: Double, sides: Int) {
        let w = pl.w, h = pl.h
        func at(_ A: [Float], _ x0: Double, _ y0: Double) -> Double {
            let x = x0.clamped(0, Double(w) - 1.001), y = y0.clamped(0, Double(h) - 1.001)
            let xi = Int(x), yi = Int(y), fx = x - Double(xi), fy = y - Double(yi), i = yi * w + xi
            let top = Double(A[i]) * (1 - fx) + Double(A[i + 1]) * fx
            let bot = Double(A[i + w]) * (1 - fx) + Double(A[i + w + 1]) * fx
            return top * (1 - fy) + bot * fy
        }
        let c = q.reduce(P.zero, +) / 4
        func sideScore(_ a: P, _ b: P, _ nrm: P) -> Double {
            var s = 0.0, cnt = 0
            var vs = [Double]()
            var t = 0.08
            while t < 0.93 {
                let p = a + (b - a) * t
                let o = p + nrm * 1.5, ii = p - nrm * 1.5
                t += 0.035
                if o.x < 0.5 || o.y < 0.5 || o.x > Double(w) - 1.5 || o.y > Double(h) - 1.5 { continue }
                let v = abs(at(pl.R, o.x, o.y) - at(pl.R, ii.x, ii.y)) + abs(at(pl.G, o.x, o.y) - at(pl.G, ii.x, ii.y))
                    + abs(at(pl.B, o.x, o.y) - at(pl.B, ii.x, ii.y))
                s += v
                cnt += 1
                if robust { vs.append(v) }
            }
            if cnt < 8 { return -1 }
            if robust { return vs.sorted()[Int(Double(cnt) * 0.3)] }
            return s / Double(cnt)
        }
        var lines = [(P, P)](), cons = [Double]()
        for k in 0..<4 {
            let a = q[k], b = q[(k + 1) % 4]
            var nrm = P(b.y - a.y, a.x - b.x)
            let ln = dist(nrm, .zero)
            nrm /= (ln > 0 ? ln : 1)
            if (((a + b) / 2 - c) * nrm).sum() < 0 { nrm = -nrm }
            var best = sideScore(a, b, nrm)
            var ba = 0.0, bb = 0.0
            if snap && best >= 0 {
                let Rr = max(3, Int((Double(max(w, h)) * range).rounded()))
                let st = Rr > 10 ? 2 : 1
                func tryAt(_ da: Double, _ db: Double) {
                    let v = sideScore(a + nrm * da, b + nrm * db, nrm)
                    if v > best * 1.02 { best = v; ba = da; bb = db }
                }
                for da in stride(from: -Rr, through: Rr, by: st) {
                    for db in stride(from: -Rr, through: Rr, by: st) { tryAt(Double(da), Double(db)) }
                }
                if st > 1 {
                    let ca = ba, cb = bb
                    for da in stride(from: ca - 1, through: ca + 1, by: 1) {
                        for db in stride(from: cb - 1, through: cb + 1, by: 1) { tryAt(da, db) }
                    }
                }
            }
            lines.append((a + nrm * ba, b + nrm * bb))
            cons.append(best)
        }
        var out = q
        if snap {
            let lim = Double(max(w, h)) * max(0.06, range * 2)
            out = (0..<4).map { k in
                let l0 = lines[(k + 3) % 4], l1 = lines[k]
                if let p = lineIntersection(l0.0, l0.1, l1.0, l1.1), dist(p, q[k]) < lim { return p }
                return q[k]
            }
        }
        let v = cons.filter { $0 >= 0 }
        return (out, v.isEmpty ? -1 : v.reduce(0, +) / Double(v.count), v.count)
    }

    static func inQuadMask(_ q: [P], _ w: Int, _ h: Int) -> [UInt8] {
        var m = [UInt8](repeating: 0, count: w * h)
        func cr(_ a: P, _ b: P, _ x: Double, _ y: Double) -> Double { (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x) }
        for y in 0..<h {
            for x in 0..<w {
                let X = Double(x) + 0.5, Y = Double(y) + 0.5
                let s0 = cr(q[0], q[1], X, Y), s1 = cr(q[1], q[2], X, Y), s2 = cr(q[2], q[3], X, Y), s3 = cr(q[3], q[0], X, Y)
                let inside = (s0 >= 0 && s1 >= 0 && s2 >= 0 && s3 >= 0) || (s0 <= 0 && s1 <= 0 && s2 <= 0 && s3 <= 0)
                m[y * w + x] = inside ? 1 : 0
            }
        }
        return m
    }

    static func quadCandidate(_ m: [UInt8], _ pl: Planes) -> Candidate? {
        let w = pl.w, h = pl.h
        var pts = [P]()
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if m[i] == 0 { continue }
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 || m[i - 1] == 0 || m[i + 1] == 0 || m[i - w] == 0 || m[i + w] == 0 {
                    pts.append(P(Double(x) + 0.5, Double(y) + 0.5))
                }
            }
        }
        guard pts.count >= 8, let hq = hullQuad(convexHull(pts)) else { return nil }
        let e = edgeFit(orderQuad(hq, landscape: w >= h), pl, snap: true)
        let q = orderQuad(e.q, landscape: w >= h)
        let Q = inQuadMask(q, w, h)
        var I = 0, U = 0, A = 0
        for i in 0..<(w * h) {
            let mi = m[i] != 0, qi = Q[i] != 0
            if mi && qi { I += 1 }
            if mi || qi { U += 1 }
            if qi { A += 1 }
        }
        let af = Double(A) / Double(w * h), fit = Double(I) / Double(max(1, U))
        let con = edgeFit(q, pl, snap: false, range: 0, robust: true).con
        let score = fit * (con < 0 ? 0.75 : smoothStep(5, 28, con)) * smoothStep(0.04, 0.12, af)
        return Candidate(q: q, fit: fit, con: con, af: af, score: score)
    }
}
