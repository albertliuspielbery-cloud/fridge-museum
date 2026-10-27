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
    /// "Before" image for the compare slider (flat: warped original; craft: same crop of the source).
    var before: RenderedImage?
    var specksRemoved: Int
    /// Craft only: where the output sits inside the upright source (normalized), to map brush strokes back.
    var outputToSource: NormRect?
}

struct ExportResult: Sendable {
    var imageData: Data
    var thumbnailData: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var specksRemoved: Int
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
    static let exportMaxEdge = 3000
    static let thumbnailMaxEdge = 480

    private let context: CIContext
    private let srgb: CGColorSpace
    private let kernels: ProcessingKernels?

    private struct MaskEntry {
        var values: [UInt8]
        var width: Int
        var height: Int
        var fromVision: Bool
        var sensitivity: Double
    }

    private var sourceCache: [String: CIImage] = [:]
    private var sourceOrder: [String] = []
    private var illuminationCache: [String: CIImage] = [:]
    private var maskCache: [String: MaskEntry] = [:]

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

    /// Auto-detects paper corners: Vision document segmentation first, then the prototype's detector.
    func detectCorners(id: UUID, originalData: Data) async -> Quad {
        #if FM_SWIFT_VISION
        if let q = await SwiftVisionPaths.detectDocument(in: originalData), q.isPlausible { return q }
        #endif
        guard let src = try? source(id: id, data: originalData, maxEdge: 1600) else { return .full }
        if let cg = context.createCGImage(src, from: src.extent),
           let q = VisionPaths.detectDocument(cgImage: cg), q.isPlausible {
            return q
        }
        let small = scaleToFit(src, maxEdge: 360)
        let rgba = renderRGBA8(small)
        return PaperDetector.detect(rgba)
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

    func export(id: UUID, originalData: Data, recipe: ProcessingRecipe) throws -> ExportResult {
        let r = try render(id: id, data: originalData, recipe: recipe, maxEdge: Self.exportMaxEdge, includeBefore: false)
        guard let jpeg = ImageEncoding.jpegData(r.output.cgImage, quality: 0.92) else { throw ProcessingError.encodeFailed }
        let thumbCI = scaleToFit(CIImage(cgImage: r.output.cgImage), maxEdge: Self.thumbnailMaxEdge)
        guard let thumbCG = context.createCGImage(thumbCI, from: thumbCI.extent, format: .RGBA8, colorSpace: srgb),
              let thumb = ImageEncoding.jpegData(thumbCG, quality: 0.8) else { throw ProcessingError.encodeFailed }
        return ExportResult(imageData: jpeg, thumbnailData: thumb, pixelWidth: r.output.width,
                            pixelHeight: r.output.height, specksRemoved: r.specksRemoved)
    }

    /// Drops cached intermediates for an artwork (call when leaving the editor).
    func evict(id: UUID) {
        let prefix = id.uuidString
        sourceCache = sourceCache.filter { !$0.key.hasPrefix(prefix) }
        sourceOrder.removeAll { $0.hasPrefix(prefix) }
        illuminationCache = illuminationCache.filter { !$0.key.hasPrefix(prefix) }
        maskCache = maskCache.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Render

    private func render(id: UUID, data: Data, recipe: ProcessingRecipe, maxEdge: Int, includeBefore: Bool) throws -> PreviewResult {
        switch recipe.kind {
        case .flat: return try renderFlat(id: id, data: data, recipe: recipe, maxEdge: maxEdge, includeBefore: includeBefore)
        case .craft: return try renderCraft(id: id, data: data, recipe: recipe, maxEdge: maxEdge, includeBefore: includeBefore)
        }
    }

    // MARK: Flat pipeline: perspective → illumination flatten → chroma-protected whitening → specks → brush

    private func renderFlat(id: UUID, data: Data, recipe: ProcessingRecipe, maxEdge: Int, includeBefore: Bool) throws -> PreviewResult {
        let src = try source(id: id, data: data, maxEdge: Int(Double(maxEdge) * 1.25))
        let quad = (recipe.corners ?? .full).clampedToUnit()
        let warped = perspectiveCorrect(src, quad: quad, maxEdge: maxEdge)
        let W = Int(warped.extent.width), H = Int(warped.extent.height)

        let cacheKey = "\(id.uuidString)|\(maxEdge)|\(quad.hashValue)"
        let background: CIImage
        if let cached = illuminationCache[cacheKey] {
            background = cached
        } else {
            background = illuminationMap(for: warped)
            illuminationCache[cacheKey] = background
        }
        let flattened = divide(warped, by: background)
        let whitened = whiten(flattened, recipe: recipe)

        var rgba = renderRGBA8(whitened, width: W, height: H)
        let specks = recipe.removeSpecks ? SpeckRemover.remove(in: &rgba) : 0
        guard let cg = makeCGImage(&rgba, whiteStrokes: recipe.activeStrokes) else { throw ProcessingError.renderFailed }

        var before: RenderedImage?
        if includeBefore, let b = context.createCGImage(warped, from: warped.extent, format: .RGBA8, colorSpace: srgb) {
            before = RenderedImage(cgImage: b)
        }
        return PreviewResult(output: RenderedImage(cgImage: cg), before: before, specksRemoved: specks, outputToSource: nil)
    }

    private func perspectiveCorrect(_ src: CIImage, quad q: Quad, maxEdge: Int) -> CIImage {
        let w = src.extent.width, h = src.extent.height
        func ci(_ p: NormPoint) -> CGPoint { CGPoint(x: p.x * w, y: (1 - p.y) * h) }   // CI origin is lower-left
        let size = q.outputSize(imageWidth: Double(w), imageHeight: Double(h), maxEdge: maxEdge)
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

    /// Low-res paper light estimate (CPU, IlluminationEstimator) upsampled back to full size.
    private func illuminationMap(for warped: CIImage) -> CIImage {
        let W = Int(warped.extent.width), H = Int(warped.extent.height)
        let k = IlluminationEstimator.blockSize(width: W, height: H)
        let sw = Int((Double(W) / Double(k)).rounded(.up)), sh = Int((Double(H) / Double(k)).rounded(.up))
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = warped.clampedToExtent()
        lanczos.scale = Float(1.0 / Double(k))
        lanczos.aspectRatio = 1
        let small = (lanczos.outputImage ?? warped).cropped(to: CGRect(x: 0, y: 0, width: sw, height: sh))

        var buf = [Float](repeating: 0, count: sw * sh * 4)
        buf.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                context.render(small, toBitmap: base, rowBytes: sw * 16,
                               bounds: CGRect(x: 0, y: 0, width: sw, height: sh), format: .RGBAf, colorSpace: srgb)
            }
        }
        let map = IlluminationEstimator.backgroundMap(rgba: buf, width: sw, height: sh)
        let mapData = map.withUnsafeBytes { Data($0) }
        let mapImage = CIImage(bitmapData: mapData, bytesPerRow: sw * 16,
                               size: CGSize(width: sw, height: sh), format: .RGBAf, colorSpace: srgb)
        return mapImage.clampedToExtent()
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(k), y: CGFloat(k)))
            .cropped(to: warped.extent)
    }

    private func divide(_ image: CIImage, by background: CIImage) -> CIImage {
        if let k = kernels?.flattenDivide,
           let out = k.apply(extent: image.extent, arguments: [image, background]) {
            return out
        }
        // Fallback: built-in divide blend (result = background / input), then the prototype's 0.97 gain.
        let f = CIFilter.divideBlendMode()
        f.inputImage = background
        f.backgroundImage = image
        let m = CIFilter.colorMatrix()
        m.inputImage = f.outputImage ?? image
        m.rVector = CIVector(x: 0.97, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: 0.97, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: 0.97, w: 0)
        return (m.outputImage ?? image).cropped(to: image.extent)
    }

    private func whiten(_ image: CIImage, recipe p: ProcessingRecipe) -> CIImage {
        let knee = 0.94 - 0.22 * p.strength
        if let k = kernels?.whiten,
           let out = k.apply(extent: image.extent,
                             arguments: [image, Float(knee), Float(p.protect), Float(p.vivid * 0.45)]) {
            return out
        }
        // Fallback approximation without chroma protection: highlight tone curve + saturation.
        let curve = CIFilter.toneCurve()
        curve.inputImage = image
        curve.point0 = CGPoint(x: 0, y: 0)
        curve.point1 = CGPoint(x: 0.3, y: 0.3)
        curve.point2 = CGPoint(x: 0.6, y: 0.6)
        curve.point3 = CGPoint(x: knee, y: min(1, knee + 0.04))
        curve.point4 = CGPoint(x: min(1, knee + 0.07), y: 1)
        let sat = CIFilter.colorControls()
        sat.inputImage = curve.outputImage ?? image
        sat.saturation = Float(1 + p.vivid * 0.45)
        sat.brightness = 0
        sat.contrast = 1
        return (sat.outputImage ?? image).cropped(to: image.extent)
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

    // MARK: Craft pipeline: foreground mask → brush → crop with margin → background + soft shadow

    private func renderCraft(id: UUID, data: Data, recipe: ProcessingRecipe, maxEdge: Int, includeBefore: Bool) throws -> PreviewResult {
        let src = try source(id: id, data: data, maxEdge: maxEdge)
        let W = Int(src.extent.width), H = Int(src.extent.height)
        var alpha = baseAlpha(id: id, src: src, width: W, height: H, sensitivity: recipe.sensitivity, maxEdge: maxEdge)
        AlphaBrush.apply(strokes: recipe.activeStrokes, to: &alpha, width: W, height: H)

        let box = AlphaBrush.boundingBox(alpha, width: W, height: H) ?? (0, 0, W - 1, H - 1)
        let bw = box.x1 - box.x0 + 1, bh = box.y1 - box.y0 + 1
        let mg = Int((Double(max(bw, bh)) * 0.16).rounded())
        let x0 = box.x0 - mg, y0 = box.y0 - mg
        let cw = bw + mg * 2, ch = bh + Int((Double(mg) * 2.3).rounded())
        // Top-left pixel rect → Core Image (lower-left origin) rect.
        let crop = CGRect(x: x0, y: H - (y0 + ch), width: cw, height: ch)
        let objectBottom = CGFloat(H - (box.y1 + 1))

        let alphaData = Data(alpha)
        let mask = CIImage(bitmapData: alphaData, bytesPerRow: W, size: CGSize(width: W, height: H), format: .L8, colorSpace: nil)

        var bg = background(recipe.background, in: crop)
        if recipe.shadow {
            bg = addShadow(to: bg, mask: mask, bottom: objectBottom, cropWidth: CGFloat(cw), cropHeight: CGFloat(ch),
                           squash: 0.22, blur: 0.05, drop: 0.01, opacity: 0.28)
            bg = addShadow(to: bg, mask: mask, bottom: objectBottom, cropWidth: CGFloat(cw), cropHeight: CGFloat(ch),
                           squash: 0.06, blur: 0.015, drop: 0.002, opacity: 0.55)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = src
        blend.backgroundImage = bg
        blend.maskImage = mask
        let composed = (blend.outputImage ?? bg).cropped(to: crop)

        let scale = min(1, Double(maxEdge) / Double(max(cw, ch)))
        let out = scaleToFit(composed.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)),
                             scale: scale)
        guard let cg = context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: srgb) else {
            throw ProcessingError.renderFailed
        }

        var before: RenderedImage?
        if includeBefore {
            let gray = CIImage(color: color(RGBColor(hex: "#8A8F98")!)).cropped(to: crop)
            let b = src.composited(over: gray).cropped(to: crop)
            let bs = scaleToFit(b.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)), scale: scale)
            if let bcg = context.createCGImage(bs, from: bs.extent, format: .RGBA8, colorSpace: srgb) {
                before = RenderedImage(cgImage: bcg)
            }
        }
        let rect = NormRect(x: Double(x0) / Double(W), y: Double(y0) / Double(H),
                            width: Double(cw) / Double(W), height: Double(ch) / Double(H))
        return PreviewResult(output: RenderedImage(cgImage: cg), before: before, specksRemoved: 0, outputToSource: rect)
    }

    /// Mask before brush strokes: Vision subject lifting (shaped by the sensitivity slider), else the prototype's estimator.
    private func baseAlpha(id: UUID, src: CIImage, width W: Int, height H: Int, sensitivity: Double, maxEdge: Int) -> [UInt8] {
        let key = "\(id.uuidString)|\(maxEdge)"
        var entry = maskCache[key]
        if entry == nil || (entry?.fromVision == false && entry?.sensitivity != sensitivity) {
            if entry == nil, let cg = context.createCGImage(src, from: src.extent),
               let v = VisionPaths.foregroundMask(cgImage: cg, width: W, height: H) {
                entry = MaskEntry(values: v, width: W, height: H, fromVision: true, sensitivity: sensitivity)
            } else {
                let small = renderRGBA8(scaleToFit(src, maxEdge: 256))
                let m = CraftMaskEstimator.estimate(small, sensitivity: sensitivity)
                let full = renderRGBA8(src, width: W, height: H)
                entry = MaskEntry(values: CraftMaskEstimator.alpha(full: full, mask: m), width: W, height: H,
                                  fromVision: false, sensitivity: sensitivity)
            }
            maskCache[key] = entry
        }
        guard let e = entry else { return [UInt8](repeating: 255, count: W * H) }
        guard e.fromVision else { return e.values }
        // Sensitivity 0.5 = Vision as-is; higher keeps more of the soft edge, lower trims it.
        let center = 0.5 - (sensitivity - 0.5) * 0.6
        let lo = (center - 0.15).clamped(0.01, 0.98), hi = (center + 0.15).clamped(lo + 0.01, 0.99)
        var lut = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { lut[i] = UInt8((smoothStep(lo, hi, Double(i) / 255) * 255).rounded()) }
        return e.values.map { lut[Int($0)] }
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

    // MARK: - Helpers

    private func source(id: UUID, data: Data, maxEdge: Int) throws -> CIImage {
        let key = "\(id.uuidString)|src|\(maxEdge)"
        if let s = sourceCache[key] { return s }
        guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw ProcessingError.decodeFailed
        }
        let s = scaleToFit(decoded, maxEdge: maxEdge)
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
