import Foundation
import CoreGraphics

// MARK: - Public result types

/// One separate part of a craft cut-out (a Vision foreground instance, or a connected piece of the colour mask).
struct CutoutPart: Identifiable, Sendable, Hashable {
    /// Stable within one PreviewResult (re-derived on every render; use `seed` to remember a part).
    let id: Int
    /// Normalized in the OUTPUT image. Removed parts may extend outside 0...1.
    let bounds: CGRect
    /// Normalized in the ORIGINAL (upright) photo: the innermost point of the part.
    let seed: CGPoint
    var isRemoved: Bool
    /// Normalized in the ORIGINAL photo.
    let originalBounds: CGRect
    /// The part runs off the photo's edge.
    let touchesEdge: Bool
    /// The largest part.
    let isMain: Bool
}

/// Maps points between the rendered output and the original photo / brush-stroke space.
/// Output → base is an affine map in pixels (undoes turning and, for crafts, the crop/scale); for flat work the base is
/// the perspective-corrected sheet and `quad` maps it back into the photo.
struct OutputMapping: Sendable, Hashable {
    let outputWidth: Int
    let outputHeight: Int
    /// Pixel size of the base (flat: corrected sheet before turning; craft: the processing copy of the photo).
    let baseWidth: Int
    let baseHeight: Int
    /// Output pixel (top-left origin) → base pixel.
    let outputToBase: Affine2D
    /// Flat only: sheet corners in the original photo (base-normalized → original-normalized). nil for crafts.
    let quad: Quad?

    static func identity(width: Int, height: Int) -> OutputMapping {
        OutputMapping(outputWidth: width, outputHeight: height, baseWidth: width, baseHeight: height, outputToBase: .identity, quad: nil)
    }

    /// Output-normalized → stroke space (flat: unturned sheet; craft: original photo), normalized.
    func toStrokeSpace(_ p: CGPoint) -> CGPoint {
        let b = outputToBase.apply(NormPoint(x: Double(p.x) * Double(outputWidth), y: Double(p.y) * Double(outputHeight)))
        return CGPoint(x: b.x / Double(max(1, baseWidth)), y: b.y / Double(max(1, baseHeight)))
    }

    /// Output-normalized → original-photo-normalized (respects turning, crop and the perspective warp).
    func toOriginal(_ p: CGPoint) -> CGPoint {
        let s = toStrokeSpace(p)
        guard let quad, let h = Homography(from: Quad.full.points, to: quad.points) else { return s }
        let o = h.apply(NormPoint(x: Double(s.x), y: Double(s.y)))
        return CGPoint(x: o.x, y: o.y)
    }

    /// Original-photo-normalized → output-normalized; nil when the map cannot be inverted.
    func fromOriginal(_ p: CGPoint) -> CGPoint? {
        var b = NormPoint(x: Double(p.x), y: Double(p.y))
        if let quad {
            guard let h = Homography(from: quad.points, to: Quad.full.points) else { return nil }
            b = h.apply(b)
        }
        guard let inv = outputToBase.inverted else { return nil }
        let o = inv.apply(NormPoint(x: b.x * Double(baseWidth), y: b.y * Double(baseHeight)))
        return CGPoint(x: o.x / Double(max(1, outputWidth)), y: o.y / Double(max(1, outputHeight)))
    }

    /// A brush radius given as a fraction of the output's long edge → fraction of the stroke space's long edge.
    func strokeRadius(fromOutputRadius r: Double) -> Double {
        let scale = (abs(outputToBase.a * outputToBase.d - outputToBase.b * outputToBase.c)).squareRoot()   // base px per output px
        return r * Double(max(outputWidth, outputHeight)) * scale / Double(max(1, max(baseWidth, baseHeight)))
    }
}

// MARK: - Part analysis (port of the prototype's craftParts / autoPick / pickDrops / partAt)

/// Coarse label grid over the processing copy of the photo (≤ 320 cells on the long edge).
struct PartMap: Sendable, Equatable {
    /// Source pixels per cell.
    let cell: Double
    let gridWidth: Int
    let gridHeight: Int
    /// Part id per cell after the 2-cell rim growth (0 = none).
    let labels: [Int32]
    let sourceWidth: Int
    let sourceHeight: Int

    /// The part under a point (normalized original coords), searching `radius` cells around it (nearest first).
    func label(atOriginal p: CGPoint, radius r: Int) -> Int {
        let gx = Int((Double(p.x) * Double(sourceWidth) / cell).rounded(.down)).clamped(0, gridWidth - 1)
        let gy = Int((Double(p.y) * Double(sourceHeight) / cell).rounded(.down)).clamped(0, gridHeight - 1)
        var best = 0, bd = Int.max
        for dy in -r...r {
            for dx in -r...r {
                let x = gx + dx, y = gy + dy
                if x < 0 || y < 0 || x >= gridWidth || y >= gridHeight { continue }
                let L = Int(labels[y * gridWidth + x]), d = dx * dx + dy * dy
                if L != 0 && d < bd { bd = d; best = L }
            }
        }
        return best
    }

    /// Cell index of a source pixel.
    @inline(__always) func cellIndex(x: Int, y: Int) -> Int {
        min(gridHeight - 1, Int(Double(y) / cell)) * gridWidth + min(gridWidth - 1, Int(Double(x) / cell))
    }
}

struct PartInfo: Sendable, Equatable {
    let id: Int
    /// On-cells.
    var area = 0
    /// On-cells on the grid border.
    var edge = 0
    var seedCell = -1
    var best: Float = -1
    var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
    var significant = false

    init(id: Int) { self.id = id }
    var touches: Bool { edge > 0 }
}

struct PartAnalysis: Sendable, Equatable {
    let map: PartMap
    /// Indexed by id − 1.
    let parts: [PartInfo]
    let on: [UInt8]
    let main: Int
    var significantCount: Int { parts.filter(\.significant).count }

    func part(_ id: Int) -> PartInfo? { id >= 1 && id <= parts.count ? parts[id - 1] : nil }

    /// Seed of a part, normalized in the original.
    func seed(of p: PartInfo) -> CGPoint {
        let gx = p.seedCell % map.gridWidth, gy = p.seedCell / map.gridWidth
        return CGPoint(x: min(1, (Double(gx) + 0.5) * map.cell / Double(map.sourceWidth)),
                       y: min(1, (Double(gy) + 0.5) * map.cell / Double(map.sourceHeight)))
    }

    /// Bounds of a part's on-cells, normalized in the original.
    func originalBounds(of p: PartInfo) -> CGRect {
        guard p.x1 >= p.x0, p.y1 >= p.y0 else { return .zero }
        let sx = map.cell / Double(map.sourceWidth), sy = map.cell / Double(map.sourceHeight)
        let x0 = Double(p.x0) * sx, y0 = Double(p.y0) * sy
        let x1 = min(1, Double(p.x1 + 1) * sx), y1 = min(1, Double(p.y1 + 1) * sy)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

enum CutoutParts {
    static let pickGrid = 320

    /// Splits a cut-out (alpha > 50 %) into parts on a coarse grid. With `instances` (a low-res Vision instance label
    /// image, 0 = background) cells of one instance form one part and different instances never join; without it,
    /// parts are 8-connected pieces (thin sticks stay in one piece because a cell is on when any pixel in it is).
    static func analyze(alpha: [UInt8], width W: Int, height H: Int,
                        instances: (labels: [UInt8], width: Int, height: Int)? = nil) -> PartAnalysis? {
        guard W > 0, H > 0, alpha.count == W * H else { return nil }
        let k = max(1, Double(max(W, H)) / Double(pickGrid))
        let gw = max(1, Int((Double(W) / k).rounded(.up))), gh = max(1, Int((Double(H) / k).rounded(.up))), n = gw * gh
        var cx = [Int](repeating: 0, count: W), cy = [Int](repeating: 0, count: H)
        for x in 0..<W { cx[x] = min(gw - 1, Int(Double(x) / k)) }
        for y in 0..<H { cy[y] = min(gh - 1, Int(Double(y) / k)) * gw }
        var on = [UInt8](repeating: 0, count: n)
        alpha.withUnsafeBufferPointer { al in
            for y in 0..<H {
                let r = cy[y], o = y * W
                for x in 0..<W where al[o + x] > 128 { on[r + cx[x]] = 1 }
            }
        }
        // instance label per cell (sampled at the cell centre)
        var group = [Int32](repeating: 0, count: n)
        if let ins = instances, ins.width > 0, ins.height > 0, ins.labels.count == ins.width * ins.height {
            for gy in 0..<gh {
                for gx in 0..<gw where on[gy * gw + gx] != 0 {
                    let sx = min(ins.width - 1, Int((Double(gx) + 0.5) * k / Double(W) * Double(ins.width)))
                    let sy = min(ins.height - 1, Int((Double(gy) + 0.5) * k / Double(H) * Double(ins.height)))
                    group[gy * gw + gx] = Int32(ins.labels[sy * ins.width + sx])
                }
            }
        }
        // 8-connected components that never cross between groups
        var comp = [Int32](repeating: 0, count: n)
        var compGroup: [Int32] = [0]
        var stack = [Int]()
        for i0 in 0..<n where on[i0] != 0 && comp[i0] == 0 {
            let L = Int32(compGroup.count)
            compGroup.append(group[i0])
            comp[i0] = L
            stack.append(i0)
            while let q = stack.popLast() {
                let x = q % gw, y = q / gw
                for dy in -1...1 {
                    for dx in -1...1 {
                        let X = x + dx, Y = y + dy
                        if X < 0 || Y < 0 || X >= gw || Y >= gh { continue }
                        let j = Y * gw + X
                        if on[j] != 0 && comp[j] == 0 && group[j] == group[q] { comp[j] = L; stack.append(j) }
                    }
                }
            }
        }
        // part ids: one per instance, one per instance-less component
        var partOfComp = [Int32](repeating: 0, count: compGroup.count)
        var partOfGroup: [Int32: Int32] = [:]
        var count: Int32 = 0
        for c in 1..<max(1, compGroup.count) {
            let g = compGroup[c]
            if g > 0, let p = partOfGroup[g] {
                partOfComp[c] = p
            } else {
                count += 1
                partOfComp[c] = count
                if g > 0 { partOfGroup[g] = count }
            }
        }
        var lab = [Int32](repeating: 0, count: n)
        for i in 0..<n where comp[i] != 0 { lab[i] = partOfComp[Int(comp[i])] }
        let core = lab
        // labels reach 2 cells past each part, so its soft rim goes with it
        for _ in 0..<2 {
            let prev = lab
            for i in 0..<n where prev[i] == 0 {
                let x = i % gw
                var L: Int32 = 0
                if x > 0 && prev[i - 1] != 0 { L = prev[i - 1] }
                else if x < gw - 1 && prev[i + 1] != 0 { L = prev[i + 1] }
                else if i >= gw && prev[i - gw] != 0 { L = prev[i - gw] }
                else if i + gw < n && prev[i + gw] != 0 { L = prev[i + gw] }
                if L != 0 { lab[i] = L }
            }
        }
        // the most inward cell of each part is its seed
        let D = ImageOps.chamfer(on, gw, gh)
        var parts = (1...max(1, Int(count))).map { PartInfo(id: $0) }
        if count == 0 { parts = [] }
        for i in 0..<n where on[i] != 0 {
            let L = Int(core[i])
            guard L >= 1 && L <= parts.count else { continue }
            let x = i % gw, y = i / gw
            parts[L - 1].area += 1
            if x == 0 || y == 0 || x == gw - 1 || y == gh - 1 { parts[L - 1].edge += 1 }
            if D[i] > parts[L - 1].best { parts[L - 1].best = D[i]; parts[L - 1].seedCell = i }
            parts[L - 1].x0 = min(parts[L - 1].x0, x); parts[L - 1].x1 = max(parts[L - 1].x1, x)
            parts[L - 1].y0 = min(parts[L - 1].y0, y); parts[L - 1].y1 = max(parts[L - 1].y1, y)
        }
        var big = 0, main = 0
        for p in parts where p.area > big { big = p.area; main = p.id }
        for i in parts.indices {
            parts[i].significant = parts[i].area > 0 && Double(parts[i].area) >= max(6, Double(big) * 0.01)
        }
        let map = PartMap(cell: k, gridWidth: gw, gridHeight: gh, labels: lab, sourceWidth: W, sourceHeight: H)
        return PartAnalysis(map: map, parts: parts, on: on, main: main)
    }

    /// Automatic default (prototype `autoPick`): one part clearly dominates (≥ 4× the next) and every other part runs
    /// off the photo's edge → those are other things on the table (a folder, a fan). A part near the main one is kept.
    static func autoDropSeeds(_ a: PartAnalysis) -> [CGPoint] {
        guard a.significantCount >= 2, let M = a.part(a.main) else { return [] }
        let others = a.parts.filter { $0.significant && $0.id != a.main }
        guard let biggest = others.map(\.area).max(), M.area >= 4 * biggest, others.allSatisfy({ $0.edge >= 2 }) else { return [] }
        let gw = a.map.gridWidth, gh = a.map.gridHeight, n = gw * gh
        var near = [UInt8](repeating: 0, count: n)
        for i in 0..<n where a.on[i] != 0 && Int(a.map.labels[i]) == a.main { near[i] = 1 }
        let gap = ImageOps.morph(near, gw, gh, max(3, Int((Double(max(gw, gh)) * 0.015).rounded())), dilate: true)
        var close = Set<Int>()
        for i in 0..<n where gap[i] != 0 && a.on[i] != 0 { close.insert(Int(a.map.labels[i])) }
        return others.filter { !close.contains($0.id) && $0.seedCell >= 0 }.map { a.seed(of: $0) }
    }

    /// Removed part ids for the given seeds (prototype `pickDrops`). Nothing is removed if no significant part would
    /// be left. (The prototype also ignored a seed whose part grew much bigger; seeds carry no size natively.)
    static func drops(_ a: PartAnalysis, seeds: [CGPoint]) -> Set<Int> {
        var f = Set<Int>()
        for s in seeds {
            let L = a.map.label(atOriginal: s, radius: 3)
            if L != 0 { f.insert(L) }
        }
        let left = a.parts.filter { $0.significant && !f.contains($0.id) }.count
        return left == 0 ? [] : f
    }

    /// Clears the removed parts from a full-resolution alpha of the analysed size.
    static func apply(drops: Set<Int>, _ a: PartAnalysis, to alpha: inout [UInt8], width W: Int, height H: Int) {
        guard !drops.isEmpty, W == a.map.sourceWidth, H == a.map.sourceHeight else { return }
        let gw = a.map.gridWidth, gh = a.map.gridHeight, k = a.map.cell
        var cx = [Int](repeating: 0, count: W)
        for x in 0..<W { cx[x] = min(gw - 1, Int(Double(x) / k)) }
        var drop = [Bool](repeating: false, count: a.parts.count + 1)
        for d in drops where d >= 1 && d <= a.parts.count { drop[d] = true }
        let labels = a.map.labels
        alpha.withUnsafeMutableBufferPointer { al in
            for y in 0..<H {
                let r = min(gh - 1, Int(Double(y) / k)) * gw, o = y * W
                for x in 0..<W where al[o + x] != 0 && drop[Int(labels[r + cx[x]])] { al[o + x] = 0 }
            }
        }
    }
}

// MARK: - Tap-to-keep helpers (pure; the UI calls them and stores the new recipe)

enum PartPicking {
    /// Toggles the part `partID` of `result`. Returns nil when that would remove the last kept part.
    static func toggle(partID: Int, in result: PreviewResult, recipe: ProcessingRecipe) -> ProcessingRecipe? {
        toggle(partID: partID, parts: result.parts, recipe: recipe)
    }

    static func toggle(partID: Int, parts: [CutoutPart], recipe: ProcessingRecipe) -> ProcessingRecipe? {
        guard let part = parts.first(where: { $0.id == partID }) else { return nil }
        var removed = parts.filter { $0.isRemoved && $0.id != partID }.map(\.seed)
        if !part.isRemoved {
            guard parts.contains(where: { !$0.isRemoved && $0.id != partID }) else { return nil }
            removed.append(part.seed)
        }
        var r = recipe
        r.removedPartSeeds = removed
        r.partsEdited = true
        return r
    }

    /// 全部保留: no removed parts, and no automatic drop.
    static func keepAll(_ recipe: ProcessingRecipe) -> ProcessingRecipe {
        var r = recipe
        r.removedPartSeeds = []
        r.partsEdited = true
        return r
    }
}
