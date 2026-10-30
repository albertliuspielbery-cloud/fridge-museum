import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// CGImage is immutable; wrapping it lets rendered results cross from the processor actor to the UI.
struct RenderedImage: @unchecked Sendable {
    let cgImage: CGImage
    var width: Int { cgImage.width }
    var height: Int { cgImage.height }
}

struct PreviewResult: Sendable {
    var output: RenderedImage
    /// "Before" image for the compare slider (flat: warped original; craft: same crop of the source), turned like the output.
    var before: RenderedImage?
    var specksRemoved: Int
    /// DEPRECATED (use `mapping`): craft only, where the output sits inside the upright source (normalized).
    /// Only set when the result is not turned.
    var outputToSource: NormRect?
    /// Craft: the significant parts of the cut-out (removed ones included, flagged). Empty for flat / fallback.
    var parts: [CutoutPart] = []
    /// What the automatic processing could not do well, most important first.
    var notes: [ProcessingNote] = []
    /// Flat only.
    var paperMode: PaperMode?
    var mapping: OutputMapping
    /// Craft: coarse part labels for hit testing.
    var partMap: PartMap?

    /// Show the 點一下選主體 chip.
    var canPickParts: Bool { parts.count >= 2 }

    /// The (significant) part under a point given in output-normalized coordinates.
    func partID(atOutputPoint p: CGPoint, toleranceCells: Int = 1) -> Int? {
        partID(atOriginalPoint: mapping.toOriginal(p), toleranceCells: toleranceCells)
    }

    /// The (significant) part under a point given in original-normalized coordinates.
    func partID(atOriginalPoint p: CGPoint, toleranceCells: Int = 1) -> Int? {
        guard let partMap else { return nil }
        let L = partMap.label(atOriginal: p, radius: max(0, toleranceCells))
        return parts.contains(where: { $0.id == L }) ? L : nil
    }
}

struct ExportResult: Sendable {
    var imageData: Data
    var thumbnailData: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var specksRemoved: Int
    var notes: [ProcessingNote] = []
}

struct PaperDetection: Sendable, Hashable {
    enum Method: String, Sendable { case vision, detector, none }
    var quad: Quad
    /// Nothing convincing was found; `quad` is the whole photo.
    var isGuess: Bool
    var method: Method
}

enum ProcessingError: Error {
    case decodeFailed
    case renderFailed
    case encodeFailed
}

/// All pixel work happens here, off the main actor, with one shared CIContext.
actor ImageProcessor {
    static let shared = ImageProcessor()

    static let previewMaxEdge = 1600
    static let exportMaxEdge = 2400
    /// Save to Photos / Share: drawings render at up to 4096 px (or the original size if smaller); crafts at 3072
    /// (Vision masks + several full-size buffers). Never cached — the 2400 px working copy stays the cached one.
    static func finalExportMaxEdge(for kind: ArtworkKind) -> Int { kind == .flat ? 4096 : 3072 }
    /// Long edge of the decoded working copy (prototype MAX_SRC). Inputs of 12–48 MP are subsampled on decode.
    static let sourceMaxEdge = 2400
    static let thumbnailMaxEdge = 480
    /// Long edge of the copy used for paper detection and edge fill (prototype `smallOf`).
    static let detectionEdge = 360

    private let context: CIContext
    private let srgb: CGColorSpace
    private let kernels: ProcessingKernels?

    /// Craft mask before part picking and brushes.
    private struct CraftBase {
        var raw: [UInt8]
        var width: Int
        var height: Int
        var fromVision: Bool
        var sensitivity: Double
        var labels: [UInt8] = []
        var labelWidth = 0
        var labelHeight = 0
        var fallback = false
        var touchesEdge = false
    }

    private struct FlatEntry {
        var model: FlattenModel
        var fill: EdgeFillMask?
    }

    private var decoded: [String: CIImage] = [:]
    private var decodedOrder: [String] = []
    private var focal: [String: Double] = [:]
    private var sourceCache: [String: CIImage] = [:]
    private var sourceOrder: [String] = []
    private var flatCache: [String: FlatEntry] = [:]
    private var flatOrder: [String] = []
    private var maskCache: [String: CraftBase] = [:]
    private var partsCache: [String: (sensitivity: Double, analysis: PartAnalysis?)] = [:]
    private var detections: [String: PaperDetection] = [:]
    private var smallCache: [String: RGBA8Image] = [:]
    /// Upright check per artwork + sheet: the intake queue and the editor may both ask; Vision runs once.
    private var orientationCache: [String: AutoOrientation] = [:]
    private var orientationTasks: [String: Task<AutoOrientation, Never>] = [:]

    init() {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        srgb = space
        // Non-linear sRGB working space so thresholds match the prototype; half-float keeps values > 1 between kernels.
        context = CIContext(options: [
            .workingColorSpace: space,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: false,
        ])
        kernels = ProcessingKernels.load()
    }

    // MARK: - Public API

    /// Auto-detects paper corners: Vision document segmentation first (refined to the strongest nearby edges),
    /// then the prototype's multi-candidate detector.
    func detectCorners(id: UUID, originalData: Data) async -> Quad {
        await detectPaper(id: id, originalData: originalData).quad
    }

    func detectPaper(id: UUID, originalData: Data) async -> PaperDetection {
        #if FM_SWIFT_VISION
        if detections[id.uuidString] == nil, let q = await SwiftVisionPaths.detectDocument(in: originalData), q.isPlausible {
            let small = (try? smallImage(id: id, data: originalData))
            let refined = small.map { PaperDetector.refine(q, in: $0).quad } ?? q
            let d = PaperDetection(quad: refined, isGuess: false, method: .vision)
            detections[id.uuidString] = d
            return d
        }
        #endif
        return detectPaperSync(id: id, data: originalData)
    }

    /// Which quarter turn makes a flat artwork upright (`AutoOrienter`), judged on a small perspective-corrected copy
    /// of the sheet inside `corners` (nil = detect). Only the small warp happens on this actor (it reuses the cached
    /// 1600 px working copy); the Vision passes run in a detached task, so previews and slider renders don't queue
    /// behind them. Cached per artwork + sheet, and a second caller while it runs awaits the same task.
    func estimateOrientation(id: UUID, originalData: Data, corners: Quad?) async -> AutoOrientation {
        let quad = (corners ?? detectPaperSync(id: id, data: originalData).quad).clampedToUnit()
        let key = "\(id.uuidString)|\(quad.hashValue)"
        if let cached = orientationCache[key] { return cached }
        if let running = orientationTasks[key] { return await running.value }
        guard let image = orientationImage(id: id, originalData: originalData, quad: quad) else { return .none }
        let task = Task.detached(priority: .userInitiated) { AutoOrienter.estimate(cgImage: image.cgImage) }
        orientationTasks[key] = task
        let result = await task.value
        orientationTasks[key] = nil
        if orientationCache.count >= 16 { orientationCache.removeAll() }
        orientationCache[key] = result
        return result
    }

    /// The sheet, perspective-corrected, at ≤ AutoOrienter.visionEdge.
    private func orientationImage(id: UUID, originalData: Data, quad: Quad) -> RenderedImage? {
        guard let src = try? source(id: id, data: originalData, maxEdge: Self.previewMaxEdge) else { return nil }
        let focalPx = focalPixels(id: id, data: originalData, width: Double(src.extent.width), height: Double(src.extent.height))
        let warped = perspectiveCorrect(src, quad: quad, maxEdge: AutoOrienter.visionEdge, focalPixels: focalPx)
        guard let cg = context.createCGImage(warped, from: warped.extent, format: .RGBA8, colorSpace: srgb) else { return nil }
        return RenderedImage(cgImage: cg)
    }

    /// Upright original (for the crop tool).
    func sourcePreview(id: UUID, originalData: Data, maxEdge: Int = ImageProcessor.previewMaxEdge) throws -> RenderedImage {
        let src = try source(id: id, data: originalData, maxEdge: maxEdge)
        guard let cg = context.createCGImage(src, from: src.extent, format: .RGBA8, colorSpace: srgb) else {
            throw ProcessingError.renderFailed
        }
        return RenderedImage(cgImage: cg)
    }

    func preview(id: UUID, originalData: Data, recipe: ProcessingRecipe,
                 maxEdge: Int = ImageProcessor.previewMaxEdge, includeBefore: Bool = true) throws -> PreviewResult {
        try render(id: id, data: originalData, recipe: recipe, maxEdge: maxEdge, includeBefore: includeBefore)
    }

    func export(id: UUID, originalData: Data, recipe: ProcessingRecipe,
                maxEdge: Int = ImageProcessor.exportMaxEdge) throws -> ExportResult {
        let r = try render(id: id, data: originalData, recipe: recipe, maxEdge: maxEdge, includeBefore: false)
        defer { if maxEdge > Self.sourceMaxEdge { dropHighResCaches(id: id) } }
        guard let jpeg = ImageEncoding.jpegData(r.output.cgImage, quality: 0.92) else { throw ProcessingError.encodeFailed }
        let thumbCI = scaleToFit(CIImage(cgImage: r.output.cgImage), maxEdge: Self.thumbnailMaxEdge)
        guard let thumbCG = context.createCGImage(thumbCI, from: thumbCI.extent, format: .RGBA8, colorSpace: srgb),
              let thumb = ImageEncoding.jpegData(thumbCG, quality: 0.8) else { throw ProcessingError.encodeFailed }
        return ExportResult(imageData: jpeg, thumbnailData: thumb, pixelWidth: r.output.width,
                            pixelHeight: r.output.height, specksRemoved: r.specksRemoved, notes: r.notes)
    }

    /// The part under a tap (output-normalized point), or nil.
    nonisolated func partID(atOutputPoint p: CGPoint, in result: PreviewResult) -> Int? {
        result.partID(atOutputPoint: p)
    }

    /// Output-normalized point → original-normalized point (a seed), respecting turning, crop and warp.
    nonisolated func originalPoint(fromOutputPoint p: CGPoint, in result: PreviewResult) -> CGPoint {
        result.mapping.toOriginal(p)
    }

    /// Drops cached intermediates for an artwork (call when leaving the editor).
    func evict(id: UUID) {
        let prefix = id.uuidString
        decoded = decoded.filter { !$0.key.hasPrefix(prefix) }
        decodedOrder.removeAll { $0.hasPrefix(prefix) }
        sourceCache = sourceCache.filter { !$0.key.hasPrefix(prefix) }
        sourceOrder.removeAll { $0.hasPrefix(prefix) }
        flatCache = flatCache.filter { !$0.key.hasPrefix(prefix) }
        flatOrder.removeAll { $0.hasPrefix(prefix) }
        maskCache = maskCache.filter { !$0.key.hasPrefix(prefix) }
        partsCache = partsCache.filter { !$0.key.hasPrefix(prefix) }
        detections = detections.filter { !$0.key.hasPrefix(prefix) }
        smallCache = smallCache.filter { !$0.key.hasPrefix(prefix) }
        orientationCache = orientationCache.filter { !$0.key.hasPrefix(prefix) }
        focal = focal.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Paper detection

    private func detectPaperSync(id: UUID, data: Data) -> PaperDetection {
        let key = id.uuidString
        if let d = detections[key] { return d }
        let none = PaperDetection(quad: .full, isGuess: true, method: .none)
        guard let src = try? source(id: id, data: data, maxEdge: Self.previewMaxEdge),
              let small = try? smallImage(id: id, data: data) else { return none }
        var visionQuad: Quad?
        if let cg = context.createCGImage(src, from: src.extent),
           let q = VisionPaths.detectDocument(cgImage: cg), q.isPlausible {
            visionQuad = q
        }
        let det = PaperDetector.detectFull(small)
        let result: PaperDetection
        if let vq = visionQuad {
            let refined = PaperDetector.refine(vq, in: small)
            // Vision's outline has (almost) no edge under it – e.g. a featureless table, or a quad lying on the frame
            // edge: defer to the ported detector (which keeps the whole photo and reports .paperNotFound when unsure).
            if refined.contrast < 5 || (refined.contrast < 8 && !det.isGuess && det.score > 0.6) {
                result = det.isGuess ? none : PaperDetection(quad: det.quad, isGuess: false, method: .detector)
            } else {
                result = PaperDetection(quad: refined.quad, isGuess: false, method: .vision)
            }
        } else if det.isGuess {
            result = none
        } else {
            result = PaperDetection(quad: det.quad, isGuess: false, method: .detector)
        }
        detections[key] = result
        return result
    }

    /// Small upright copy for paper detection and edge fill.
    private func smallImage(id: UUID, data: Data) throws -> RGBA8Image {
        let key = id.uuidString
        if let s = smallCache[key] { return s }
        let src = try source(id: id, data: data, maxEdge: Self.previewMaxEdge)
        let s = renderRGBA8(scaleToFit(src, maxEdge: Self.detectionEdge))
        smallCache = smallCache.filter { $0.key.hasPrefix(key) }
        smallCache[key] = s
        return s
    }

    // MARK: - Render

    private func render(id: UUID, data: Data, recipe: ProcessingRecipe, maxEdge: Int, includeBefore: Bool) throws -> PreviewResult {
        switch recipe.kind {
        case .flat: return try renderFlat(id: id, data: data, recipe: recipe, maxEdge: maxEdge, includeBefore: includeBefore)
        case .craft: return try renderCraft(id: id, data: data, recipe: recipe, maxEdge: maxEdge, includeBefore: includeBefore)
        }
    }

    // MARK: Flat pipeline: perspective (true aspect) → light flatten (paper mode) → whitening → edge fill → specks
    //                      → brush → turn

    private func renderFlat(id: UUID, data: Data, recipe: ProcessingRecipe, maxEdge: Int, includeBefore: Bool) throws -> PreviewResult {
        let src = try source(id: id, data: data, maxEdge: min(max(Self.sourceMaxEdge, maxEdge), Int(Double(maxEdge) * 1.25)))
        let quad = (recipe.corners ?? detectPaperSync(id: id, data: data).quad).clampedToUnit()
        let focalPx = focalPixels(id: id, data: data, width: Double(src.extent.width), height: Double(src.extent.height))
        let warped = perspectiveCorrect(src, quad: quad, maxEdge: maxEdge, focalPixels: focalPx)
        let W = Int(warped.extent.width), H = Int(warped.extent.height)

        let cacheKey = "\(id.uuidString)|\(maxEdge)|\(quad.hashValue)"
        let entry: FlatEntry
        if let cached = flatCache[cacheKey] {
            entry = cached
        } else {
            let warpedRGBA = renderRGBA8(warped, width: W, height: H)
            // Cast-shadow removal only on a found / user-set sheet: with the whole photo, table or wall would look
            // like a shadow.
            let model = IlluminationEstimator.model(warpedRGBA, shadows: quad != .full)
            let fill = (try? smallImage(id: id, data: data)).flatMap { EdgeFill.detect(warped: warpedRGBA, small: $0, quad: quad) }
            entry = FlatEntry(model: model, fill: fill)
            flatCache[cacheKey] = entry
            flatOrder.append(cacheKey)
            while flatOrder.count > 3 { flatCache[flatOrder.removeFirst()] = nil }
        }
        let model = entry.model
        let background = lightMap(model, extent: warped.extent)
        let flattened = model.shadow.flatMap { divideShadow(warped, light: background, layers: $0, model: model) }
            ?? divide(warped, by: background, gain: model.gain)
        let whitened = whiten(flattened, recipe: recipe, push: model.mode != .colored)

        var rgba = renderRGBA8(whitened, width: W, height: H)
        let paper255 = model.mode == .colored ? model.paper * 255 : SIMD3<Float>(255, 255, 255)
        if let fill = entry.fill { EdgeFill.apply(fill, to: &rgba, rgb: paper255) }
        var specks = 0, pattern = false
        if recipe.removeSpecks && model.mode != .colored {
            let o = SpeckRemover.clean(&rgba)
            specks = o.removed
            pattern = o.keptAsPattern
        }
        guard let cg = makeCGImage(&rgba, whiteStrokes: recipe.activeStrokes) else { throw ProcessingError.renderFailed }

        var notes: [ProcessingNote] = []
        if let det = detections[id.uuidString], det.isGuess, quad == .full { notes.append(.paperNotFound) }
        if model.mode == .colored { notes.append(.notWhitePaper) }
        if pattern { notes.append(.dotsKeptAsPattern) }

        let deg = recipe.turnDegrees
        let paperColor = RGBColor(r: Double(paper255.x) / 255, g: Double(paper255.y) / 255, b: Double(paper255.z) / 255)
        let turned = turn(CIImage(cgImage: cg), degrees: deg, fill: paperColor)
        let output: CGImage
        if deg == 0 {
            output = cg
        } else {
            guard let t = context.createCGImage(turned.image, from: turned.image.extent, format: .RGBA8, colorSpace: srgb) else {
                throw ProcessingError.renderFailed
            }
            output = t
        }
        var before: RenderedImage?
        if includeBefore {
            let b = turn(warped, degrees: deg, fill: Self.beforeGray).image
            if let bcg = context.createCGImage(b, from: b.extent, format: .RGBA8, colorSpace: srgb) { before = RenderedImage(cgImage: bcg) }
        }
        let mapping = OutputMapping(outputWidth: output.width, outputHeight: output.height, baseWidth: W, baseHeight: H,
                                    outputToBase: turned.outputToBase, quad: quad)
        return PreviewResult(output: RenderedImage(cgImage: output), before: before, specksRemoved: specks, outputToSource: nil,
                             parts: [], notes: notes, paperMode: model.mode, mapping: mapping, partMap: nil)
    }

    private func perspectiveCorrect(_ src: CIImage, quad q: Quad, maxEdge: Int, focalPixels: Double?) -> CIImage {
        let w = src.extent.width, h = src.extent.height
        func ci(_ p: NormPoint) -> CGPoint { CGPoint(x: p.x * w, y: (1 - p.y) * h) }   // CI origin is lower-left
        let size = q.outputSize(imageWidth: Double(w), imageHeight: Double(h), maxEdge: maxEdge, focalPixels: focalPixels)
        var out: CIImage
        if q == .full {
            out = src
        } else {
            let f = CIFilter.perspectiveCorrection()
            f.inputImage = src.clampedToExtent()
            f.topLeft = ci(q.topLeft)
            f.topRight = ci(q.topRight)
            f.bottomRight = ci(q.bottomRight)
            f.bottomLeft = ci(q.bottomLeft)
            out = f.outputImage ?? src
        }
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        let sx = CGFloat(size.width) / max(out.extent.width, 1)
        let sy = CGFloat(size.height) / max(out.extent.height, 1)
        out = out.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return out
    }

    /// The low-res light map upsampled (cell centres at (i + ½)·k, top rows aligned with the image's top).
    private func lightMap(_ m: FlattenModel, extent: CGRect) -> CIImage {
        lightMap(m.map, model: m, extent: extent)
    }

    /// Any RGBA-float grid laid out like `FlattenModel.map`, upsampled the same way.
    private func lightMap(_ grid: [Float], model m: FlattenModel, extent: CGRect) -> CIImage {
        let sw = m.width, sh = m.height, k = CGFloat(m.blockSize)
        let mapData = grid.withUnsafeBytes { Data($0) }
        let mapImage = CIImage(bitmapData: mapData, bytesPerRow: sw * 16,
                               size: CGSize(width: sw, height: sh), format: .RGBAf, colorSpace: srgb)
        let topOffset = extent.height - CGFloat(sh) * k
        return mapImage.clampedToExtent()
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: 0, y: topOffset)))
            .cropped(to: extent)
    }

    /// Divide with cast-shadow layers (`fmFlattenDivideShadow`). The guide is a small morphological closing of the
    /// image (max then min), which removes thin ink lines but keeps the shadow's edge. nil without the kernel; the
    /// caller then divides by `light` (the shadow-aware map), which only leaves a narrow band at hard edges.
    private func divideShadow(_ image: CIImage, light: CIImage, layers: ShadowLayers, model: FlattenModel) -> CIImage? {
        guard let k = kernels?.flattenDivideShadow else { return nil }
        let extent = image.extent
        let radius = Float(max(2, (4 * Double(max(extent.width, extent.height)) / 1600).rounded()))
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = image.clampedToExtent()
        dilate.radius = radius
        let erode = CIFilter.morphologyMinimum()
        erode.inputImage = dilate.outputImage
        erode.radius = radius
        guard let closedOut = erode.outputImage else { return nil }
        let closed = closedOut.cropped(to: extent)
        let high = lightMap(layers.high, model: model, extent: extent)
        let low = lightMap(layers.low, model: model, extent: extent)
        return k.apply(extent: extent, arguments: [image, closed, light, high, low, model.gain])
    }

    private func divide(_ image: CIImage, by background: CIImage, gain: Float) -> CIImage {
        if let k = kernels?.flattenDivide,
           let out = k.apply(extent: image.extent, arguments: [image, background, gain]) {
            return out
        }
        // Fallback: built-in divide blend (result = background / input), then the prototype's gain.
        let f = CIFilter.divideBlendMode()
        f.inputImage = background
        f.backgroundImage = image
        let g = CGFloat(gain)
        let m = CIFilter.colorMatrix()
        m.inputImage = f.outputImage ?? image
        m.rVector = CIVector(x: g, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: g, w: 0)
        return (m.outputImage ?? image).cropped(to: image.extent)
    }

    /// Chroma-protected whitening; `push == false` (coloured paper) keeps the paper's colour and only applies vivid.
    private func whiten(_ image: CIImage, recipe p: ProcessingRecipe, push: Bool) -> CIImage {
        let knee = push ? 0.94 - 0.22 * p.strength : 2.0
        if let k = kernels?.whiten,
           let out = k.apply(extent: image.extent,
                             arguments: [image, Float(knee), Float(p.protect), Float(p.vivid * 0.45)]) {
            return out
        }
        // Fallback approximation without chroma protection: highlight tone curve + saturation.
        var img = image
        if push {
            let curve = CIFilter.toneCurve()
            curve.inputImage = image
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.3, y: 0.3)
            curve.point2 = CGPoint(x: 0.6, y: 0.6)
            curve.point3 = CGPoint(x: knee, y: min(1, knee + 0.04))
            curve.point4 = CGPoint(x: min(1, knee + 0.07), y: 1)
            img = curve.outputImage ?? image
        }
        let sat = CIFilter.colorControls()
        sat.inputImage = img
        sat.saturation = Float(1 + p.vivid * 0.45)
        sat.brightness = 0
        sat.contrast = 1
        return (sat.outputImage ?? img).cropped(to: image.extent)
    }

    /// Makes the final CGImage from the RGBA buffer, painting flat-mode brush strokes white.
    private func makeCGImage(_ rgba: inout RGBA8Image, whiteStrokes: [BrushStroke]) -> CGImage? {
        let W = rgba.width, H = rgba.height
        let space = srgb
        return rgba.pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            let long = Double(max(W, H))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for s in whiteStrokes where s.mode == .paintWhite {
                let r = s.radius * long
                // CGContext user space has a lower-left origin; recipe points are top-left.
                let pts = s.points.map { CGPoint(x: $0.x * Double(W), y: (1 - $0.y) * Double(H)) }
                if pts.count == 1, let p = pts.first {
                    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                } else if pts.count > 1 {
                    ctx.setLineWidth(2 * r)
                    ctx.beginPath()
                    ctx.addLines(between: pts)
                    ctx.strokePath()
                }
            }
            return ctx.makeImage()
        }
    }

    // MARK: Craft pipeline: foreground mask (Vision instances → colour method → outline rescue → plain photo)
    //                       → parts (tap-to-keep, auto drop) → brush → turn + crop with margin → background + shadow

    private func renderCraft(id: UUID, data: Data, recipe: ProcessingRecipe, maxEdge: Int, includeBefore: Bool) throws -> PreviewResult {
        let src = try source(id: id, data: data, maxEdge: min(max(Self.sourceMaxEdge, maxEdge), maxEdge))
        let W = Int(src.extent.width), H = Int(src.extent.height)
        let base = craftBase(id: id, src: src, width: W, height: H, sensitivity: recipe.sensitivity, maxEdge: maxEdge)
        let strokes = recipe.activeStrokes
        if base.fallback && strokes.isEmpty {
            return try plainCraft(src: src, recipe: recipe, maxEdge: maxEdge, includeBefore: includeBefore)
        }
        var alpha = shapedAlpha(base, sensitivity: recipe.sensitivity)

        // 點一下選主體 first, then the brushes
        var analysis: PartAnalysis?
        var drops = Set<Int>()
        var autoApplied = false
        if !base.fallback {
            let key = "\(id.uuidString)|\(maxEdge)"
            if let c = partsCache[key], c.sensitivity == recipe.sensitivity {
                analysis = c.analysis
            } else {
                let instances: (labels: [UInt8], width: Int, height: Int)? = base.labels.isEmpty ? nil : (base.labels, base.labelWidth, base.labelHeight)
                analysis = CutoutParts.analyze(alpha: alpha, width: W, height: H, instances: instances)
                partsCache[key] = (recipe.sensitivity, analysis)
            }
            if let a = analysis {
                var seeds = recipe.removedPartSeeds
                var autoSeeds: [CGPoint] = []
                if !recipe.partsEdited {
                    autoSeeds = CutoutParts.autoDropSeeds(a)
                    seeds += autoSeeds
                }
                drops = CutoutParts.drops(a, seeds: seeds)
                autoApplied = !autoSeeds.isEmpty && !drops.isEmpty
                CutoutParts.apply(drops: drops, a, to: &alpha, width: W, height: H)
            }
        }
        AlphaBrush.apply(strokes: strokes, to: &alpha, width: W, height: H)

        let composed = try composeCraft(src: src, alpha: alpha, width: W, height: H, recipe: recipe, maxEdge: maxEdge,
                                        includeBefore: includeBefore, shadow: recipe.shadow && !base.fallback)
        var parts: [CutoutPart] = []
        var touches = base.touchesEdge
        if let a = analysis {
            touches = a.parts.contains { $0.significant && !drops.contains($0.id) && $0.edge >= 2 }
            for p in a.parts where p.significant {
                let ob = a.originalBounds(of: p)
                parts.append(CutoutPart(id: p.id, bounds: outputBounds(ob, composed.mapping), seed: a.seed(of: p),
                                        isRemoved: drops.contains(p.id), originalBounds: ob,
                                        touchesEdge: p.touches, isMain: p.id == a.main))
            }
        }
        var notes: [ProcessingNote] = []
        if autoApplied { notes.append(.autoDroppedEdgeParts) }
        if touches && !base.fallback { notes.append(.touchesEdge) }
        return PreviewResult(output: composed.output, before: composed.before, specksRemoved: 0,
                             outputToSource: composed.outputToSource, parts: parts, notes: notes, paperMode: nil,
                             mapping: composed.mapping, partMap: analysis?.map)
    }

    private func outputBounds(_ r: CGRect, _ m: OutputMapping) -> CGRect {
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].compactMap { m.fromOriginal($0) }
        guard let f = corners.first else { return .zero }
        var x0 = f.x, y0 = f.y, x1 = f.x, y1 = f.y
        for c in corners { x0 = min(x0, c.x); y0 = min(y0, c.y); x1 = max(x1, c.x); y1 = max(y1, c.y) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private struct Composed {
        var output: RenderedImage
        var before: RenderedImage?
        var mapping: OutputMapping
        var outputToSource: NormRect?
    }

    /// Port of `composeCraft`: the object turned about the middle of its box; its turned extent sets the margins.
    private func composeCraft(src: CIImage, alpha: [UInt8], width W: Int, height H: Int, recipe: ProcessingRecipe,
                              maxEdge: Int, includeBefore: Bool, shadow: Bool) throws -> Composed {
        let box = AlphaBrush.boundingBox(alpha, width: W, height: H) ?? (0, 0, W - 1, H - 1)
        let deg = recipe.turnDegrees
        let (co, si) = Turning.cosSin(deg)
        let mx = Double(box.x0 + box.x1 + 1) / 2, my = Double(box.y0 + box.y1 + 1) / 2
        var rx0 = Double(box.x0) - mx, rx1 = Double(box.x1 + 1) - mx
        var ry0 = Double(box.y0) - my, ry1 = Double(box.y1 + 1) - my
        if deg != 0 {
            var a0 = Double.greatestFiniteMagnitude, a1 = -Double.greatestFiniteMagnitude, b0 = a0, b1 = a1
            alpha.withUnsafeBufferPointer { al in
                for y in stride(from: box.y0, through: box.y1, by: 2) {
                    for x in stride(from: box.x0, through: box.x1, by: 2) where al[y * W + x] > 128 {
                        let dx = Double(x) - mx, dy = Double(y) - my
                        let u = dx * co - dy * si, v = dx * si + dy * co
                        a0 = min(a0, u); a1 = max(a1, u); b0 = min(b0, v); b1 = max(b1, v)
                    }
                }
            }
            if a1 >= a0 { rx0 = a0; rx1 = a1; ry0 = b0; ry1 = b1 }
        }
        let bw = max(1, Int((rx1 - rx0).rounded(.up))), bh = max(1, Int((ry1 - ry0).rounded(.up)))
        let mg = Int((Double(max(bw, bh)) * 0.16).rounded())
        let cw = bw + mg * 2, ch = bh + Int((Double(mg) * 2.3).rounded())
        // photo pixel → layer pixel (top-left origin)
        let place = Affine2D.translation(-mx, -my)
            .then(.rotation(degrees: deg))
            .then(.translation(Double(mg) - rx0, Double(mg) - ry0))
        let ciPlace = cgTransform(place.coreImage(sourceHeight: Double(H), destinationHeight: Double(ch)))
        let rect = CGRect(x: 0, y: 0, width: cw, height: ch)

        let mask = CIImage(bitmapData: Data(alpha), bytesPerRow: W, size: CGSize(width: W, height: H), format: .L8, colorSpace: nil)
            .transformed(by: ciPlace)
        let layer = src.transformed(by: ciPlace)
        var bg = background(recipe.background, in: rect)
        if shadow {
            let bottom = CGFloat(ch - (mg + bh))
            bg = addShadow(to: bg, mask: mask, bottom: bottom, cropWidth: CGFloat(cw), cropHeight: CGFloat(ch),
                           squash: 0.22, blur: 0.05, drop: 0.01, opacity: 0.28)
            bg = addShadow(to: bg, mask: mask, bottom: bottom, cropWidth: CGFloat(cw), cropHeight: CGFloat(ch),
                           squash: 0.06, blur: 0.015, drop: 0.002, opacity: 0.55)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = layer
        blend.backgroundImage = bg
        blend.maskImage = mask
        let composed = (blend.outputImage ?? bg).cropped(to: rect)

        let scale = min(1, Double(maxEdge) / Double(max(cw, ch)))
        let out = scaleToFit(composed, scale: scale)
        guard let cg = context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: srgb) else {
            throw ProcessingError.renderFailed
        }
        var before: RenderedImage?
        if includeBefore {
            let gray = CIImage(color: color(Self.beforeGray)).cropped(to: rect)
            let b = layer.composited(over: gray).cropped(to: rect)
            let bs = scaleToFit(b, scale: scale)
            if let bcg = context.createCGImage(bs, from: bs.extent, format: .RGBA8, colorSpace: srgb) {
                before = RenderedImage(cgImage: bcg)
            }
        }
        let toBase = Affine2D.scale(1 / scale, 1 / scale).then(place.inverted ?? .identity)
        let mapping = OutputMapping(outputWidth: cg.width, outputHeight: cg.height, baseWidth: W, baseHeight: H,
                                    outputToBase: toBase, quad: nil)
        var rectInSource: NormRect?
        if deg == 0 {
            rectInSource = NormRect(x: Double(box.x0 - mg) / Double(W), y: Double(box.y0 - mg) / Double(H),
                                    width: Double(cw) / Double(W), height: Double(ch) / Double(H))
        }
        return Composed(output: RenderedImage(cgImage: cg), before: before, mapping: mapping, outputToSource: rectInSource)
    }

    /// Prototype `plainCraft`: when the object could not be separated, the photo itself, brightened a little if dim.
    private func plainCraft(src: CIImage, recipe: ProcessingRecipe, maxEdge: Int, includeBefore: Bool) throws -> PreviewResult {
        let W = Double(src.extent.width), H = Double(src.extent.height)
        let sc = min(1, Double(maxEdge) / max(W, H))
        let scaled = scaleToFit(src, scale: sc)
        // 99th-percentile luminance → gain up to 1.3 so the brightest part reaches 245
        let probe = renderRGBA8(scaleToFit(src, maxEdge: 256))
        var hist = [Double](repeating: 0, count: 256)
        var tot = 0.0
        for i in 0..<(probe.width * probe.height) {
            let pr = Double(probe.pixels[i * 4]), pg = Double(probe.pixels[i * 4 + 1]), pb = Double(probe.pixels[i * 4 + 2])
            let l: Double = 0.299 * pr + 0.587 * pg + 0.114 * pb
            hist[min(255, Int(l))] += 1
            tot += 1
        }
        var acc = 0.0, hi = 255
        for v in stride(from: 255, through: 0, by: -1) {
            acc += hist[v]
            if acc > tot * 0.01 { hi = v; break }
        }
        let g = (245 / Double(max(hi, 1))).clamped(1, 1.3)
        var img = scaled
        if g > 1.01 {
            let m = CIFilter.colorMatrix()
            m.inputImage = scaled
            m.rVector = CIVector(x: g, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: g, w: 0)
            img = (m.outputImage ?? scaled).cropped(to: scaled.extent)
        }
        let deg = recipe.turnDegrees
        let fill = recipe.background == .gradient ? RGBColor(r: 1, g: 1, b: 1) : recipe.background.color
        let turned = turn(img, degrees: deg, fill: fill)
        guard let cg = context.createCGImage(turned.image, from: turned.image.extent, format: .RGBA8, colorSpace: srgb) else {
            throw ProcessingError.renderFailed
        }
        var before: RenderedImage?
        if includeBefore {
            let b = turn(scaled, degrees: deg, fill: Self.beforeGray).image
            if let bcg = context.createCGImage(b, from: b.extent, format: .RGBA8, colorSpace: srgb) { before = RenderedImage(cgImage: bcg) }
        }
        let toBase = turned.outputToBase.then(.scale(1 / sc, 1 / sc))
        let mapping = OutputMapping(outputWidth: cg.width, outputHeight: cg.height, baseWidth: Int(W), baseHeight: Int(H),
                                    outputToBase: toBase, quad: nil)
        return PreviewResult(output: RenderedImage(cgImage: cg), before: before, specksRemoved: 0,
                             outputToSource: deg == 0 ? NormRect(x: 0, y: 0, width: 1, height: 1) : nil,
                             parts: [], notes: [.cutoutFallback], paperMode: nil, mapping: mapping, partMap: nil)
    }

    /// Mask before part picking and brushes: Vision foreground instances, else the prototype's colour method
    /// (with its outline rescue); `fallback` when neither found anything believable.
    private func craftBase(id: UUID, src: CIImage, width W: Int, height H: Int, sensitivity: Double, maxEdge: Int) -> CraftBase {
        let key = "\(id.uuidString)|\(maxEdge)"
        if let e = maskCache[key], e.fromVision || e.sensitivity == sensitivity { return e }
        var entry: CraftBase?
        if maskCache[key] == nil, let cg = context.createCGImage(src, from: src.extent),
           let v = VisionPaths.foregroundInstances(cgImage: cg, width: W, height: H) {
            var on = 0
            for a in v.alpha where a > 128 { on += 1 }
            if Double(on) > Double(W * H) * 0.003 {
                entry = CraftBase(raw: v.alpha, width: W, height: H, fromVision: true, sensitivity: sensitivity,
                                  labels: v.labels, labelWidth: v.labelWidth, labelHeight: v.labelHeight)
            }
        }
        if entry == nil {
            let small = renderRGBA8(scaleToFit(src, maxEdge: 256))
            let m = CraftMaskEstimator.estimate(small, sensitivity: sensitivity)
            let full = renderRGBA8(src, width: W, height: H)
            entry = CraftBase(raw: CraftMaskEstimator.alpha(full: full, mask: m), width: W, height: H, fromVision: false,
                              sensitivity: sensitivity, fallback: m.fallback, touchesEdge: m.touchesEdge)
        }
        let e = entry ?? CraftBase(raw: [UInt8](repeating: 255, count: W * H), width: W, height: H, fromVision: false,
                                   sensitivity: sensitivity, fallback: true)
        maskCache = maskCache.filter { $0.key.hasPrefix(id.uuidString) }
        maskCache[key] = e
        partsCache[key] = nil
        return e
    }

    /// Vision masks are shaped by the sensitivity slider (0.5 = as-is; higher keeps more of the soft edge).
    private func shapedAlpha(_ e: CraftBase, sensitivity: Double) -> [UInt8] {
        guard e.fromVision else { return e.raw }
        let center = 0.5 - (sensitivity - 0.5) * 0.6
        let lo = (center - 0.15).clamped(0.01, 0.98), hi = (center + 0.15).clamped(lo + 0.01, 0.99)
        var lut = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { lut[i] = UInt8((smoothStep(lo, hi, Double(i) / 255) * 255).rounded()) }
        return e.raw.map { lut[Int($0)] }
    }

    private func background(_ bg: CraftBackground, in rect: CGRect) -> CIImage {
        if bg == .gradient {
            let g = CIFilter.radialGradient()
            g.center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.55)
            g.radius0 = 0
            g.radius1 = Float(max(rect.width, rect.height) * 0.75)
            g.color0 = color(bg.color)
            g.color1 = color(bg.edgeColor)
            return (g.outputImage ?? CIImage(color: color(bg.color))).cropped(to: rect)
        }
        return CIImage(color: color(bg.color)).cropped(to: rect)
    }

    /// Synthetic contact shadow: the mask squashed about the object's bottom line, blurred, tinted dark.
    private func addShadow(to bg: CIImage, mask: CIImage, bottom b: CGFloat, cropWidth cw: CGFloat, cropHeight ch: CGFloat,
                           squash: CGFloat, blur: CGFloat, drop: CGFloat, opacity: CGFloat) -> CIImage {
        let t = CGAffineTransform(translationX: 0, y: -b)
            .concatenating(CGAffineTransform(scaleX: 1, y: squash))
            .concatenating(CGAffineTransform(translationX: 0, y: b - drop * ch))
        let g = CIFilter.gaussianBlur()
        g.inputImage = mask.transformed(by: t)
        g.radius = Float(max(1, blur * cw))
        let cm = CIFilter.colorMatrix()
        cm.inputImage = g.outputImage ?? mask
        cm.rVector = CIVector(x: opacity, y: 0, z: 0, w: 0)
        cm.gVector = CIVector(x: 0, y: opacity, z: 0, w: 0)
        cm.bVector = CIVector(x: 0, y: 0, z: opacity, w: 0)
        let dark = CIImage(color: color(RGBColor(r: 38 / 255, g: 34 / 255, b: 30 / 255))).cropped(to: bg.extent)
        let f = CIFilter.blendWithMask()
        f.inputImage = dark
        f.backgroundImage = bg
        f.maskImage = cm.outputImage
        return (f.outputImage ?? bg).cropped(to: bg.extent)
    }

    // MARK: - Turning

    static let beforeGray = RGBColor(r: 0x8A / 255.0, g: 0x8F / 255.0, b: 0x98 / 255.0)

    /// Turns an origin-anchored image by `degrees` (clockwise) about its centre onto a `fill` background
    /// (prototype rotCanvas). Returns the turned image (origin-anchored) and the output→input pixel map.
    private func turn(_ image: CIImage, degrees: Double, fill: RGBColor) -> (image: CIImage, outputToBase: Affine2D) {
        guard degrees != 0 else { return (image, .identity) }
        let w = Double(image.extent.width), h = Double(image.extent.height)
        let size = Turning.turnedSize(width: w, height: h, degrees: degrees)
        let fwd = Turning.forward(width: w, height: h, degrees: degrees)
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let t = image.transformed(by: cgTransform(fwd.coreImage(sourceHeight: h, destinationHeight: Double(size.height))))
        let out = t.composited(over: CIImage(color: color(fill)).cropped(to: rect)).cropped(to: rect)
        return (out, fwd.inverted ?? .identity)
    }

    private func cgTransform(_ t: Affine2D) -> CGAffineTransform {
        CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
    }

    // MARK: - Helpers

    private func focalPixels(id: UUID, data: Data, width: Double, height: Double) -> Double? {
        let key = id.uuidString
        let f35: Double
        if let cached = focal[key] {
            f35 = cached
        } else {
            f35 = ImageMetadata.focalLength35mm(of: data) ?? 0
            focal[key] = f35
        }
        return PaperAspect.focalPixels(focal35mm: f35, imageWidth: width, imageHeight: height)
    }

    /// Upright working copy, decoded once per artwork with the long edge ≤ sourceMaxEdge.
    private func decodedSource(id: UUID, data: Data) throws -> CIImage {
        let key = id.uuidString
        if let d = decoded[key] { return d }
        let image: CIImage
        if let cg = ImageMetadata.uprightThumbnail(of: data, maxPixelSize: Self.sourceMaxEdge) {
            image = CIImage(cgImage: cg)
        } else if let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            image = scaleToFit(ci, maxEdge: Self.sourceMaxEdge)
        } else {
            throw ProcessingError.decodeFailed
        }
        let s = scaleToFit(image, maxEdge: Self.sourceMaxEdge)
        decoded[key] = s
        decodedOrder.append(key)
        while decodedOrder.count > 2 { decoded[decodedOrder.removeFirst()] = nil }
        return s
    }

    /// Frees the big buffers a final (> working size) export left in the per-artwork caches.
    private func dropHighResCaches(id: UUID) {
        let prefix = id.uuidString
        for key in maskCache.keys where key.hasPrefix(prefix) {
            if let edge = Int(key.split(separator: "|").last ?? ""), edge > Self.sourceMaxEdge { maskCache[key] = nil }
        }
        for key in partsCache.keys where key.hasPrefix(prefix) {
            if let edge = Int(key.split(separator: "|").last ?? ""), edge > Self.sourceMaxEdge { partsCache[key] = nil }
        }
    }

    private func source(id: UUID, data: Data, maxEdge: Int) throws -> CIImage {
        if maxEdge > Self.sourceMaxEdge {
            // Final export above the working size: decode straight from the original, uncached.
            if let cg = ImageMetadata.uprightThumbnail(of: data, maxPixelSize: maxEdge) {
                return scaleToFit(CIImage(cgImage: cg), maxEdge: maxEdge)
            }
            return try decodedSource(id: id, data: data)
        }
        let key = "\(id.uuidString)|src|\(maxEdge)"
        if let s = sourceCache[key] { return s }
        let s = scaleToFit(try decodedSource(id: id, data: data), maxEdge: maxEdge)
        sourceCache[key] = s
        sourceOrder.append(key)
        while sourceOrder.count > 4 {
            let old = sourceOrder.removeFirst()
            sourceCache[old] = nil
        }
        return s
    }

    /// Moves the extent to the origin and Lanczos-downscales so the long edge ≤ maxEdge. Integral extent.
    private func scaleToFit(_ image: CIImage, maxEdge: Int) -> CIImage {
        let e = image.extent
        let s = min(1, Double(maxEdge) / Double(max(e.width, e.height, 1)))
        return scaleToFit(image, scale: s)
    }

    private func scaleToFit(_ image: CIImage, scale s: Double) -> CIImage {
        var img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let w = max(1, (img.extent.width * s).rounded(.down)), h = max(1, (img.extent.height * s).rounded(.down))
        if s < 0.999 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = img.clampedToExtent()
            f.scale = Float(s)
            f.aspectRatio = 1
            img = f.outputImage ?? img
        }
        return img.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func renderRGBA8(_ image: CIImage) -> RGBA8Image {
        renderRGBA8(image, width: Int(image.extent.width), height: Int(image.extent.height))
    }

    /// Renders an origin-anchored image into 8-bit sRGB RGBA, row 0 = top.
    private func renderRGBA8(_ image: CIImage, width: Int, height: Int) -> RGBA8Image {
        var px = [UInt8](repeating: 255, count: max(1, width * height * 4))
        px.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                context.render(image, toBitmap: base, rowBytes: width * 4,
                               bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: srgb)
            }
        }
        return RGBA8Image(width: width, height: height, pixels: px)
    }

    private func color(_ c: RGBColor) -> CIColor {
        CIColor(red: c.r, green: c.g, blue: c.b, alpha: 1, colorSpace: srgb)
            ?? CIColor(red: c.r, green: c.g, blue: c.b)
    }
}
