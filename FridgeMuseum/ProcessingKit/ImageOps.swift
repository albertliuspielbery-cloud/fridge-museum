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
}
