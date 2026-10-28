import Foundation
import CoreGraphics
import Testing
@testable import FridgeMuseum

/// End-to-end through ImageProcessor with synthetic photos (Core Image runs in the Simulator; Vision may or may not,
/// so the expectations hold for both the Vision and the ported fallback paths).
struct ProcessingPipelineTests {
    /// Draws a photo: table colour, then filled rects (top-left origin), encoded as JPEG.
    private func jpeg(width: Int, height: Int, table: (CGFloat, CGFloat, CGFloat),
                      rects: [(CGRect, (CGFloat, CGFloat, CGFloat))]) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: table.0, green: table.1, blue: table.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (r, c) in rects {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height))
        }
        let image = try #require(ctx.makeImage())
        return try #require(ImageEncoding.jpegData(image, quality: 0.9))
    }

    private var sheetPhoto: Data {
        get throws {
            // A4 landscape sheet (600 × 424) on a wooden table, with a drawing on it
            try jpeg(width: 1200, height: 900, table: (0.55, 0.38, 0.22), rects: [
                (CGRect(x: 300, y: 238, width: 600, height: 424), (0.95, 0.94, 0.91)),
                (CGRect(x: 450, y: 400, width: 300, height: 12), (0.15, 0.3, 0.7)),
            ])
        }
    }

    @Test func flatSheetEndToEnd() async throws {
        let p = ImageProcessor()
        let id = UUID(), data = try sheetPhoto
        let det = await p.detectPaper(id: id, originalData: data)
        #expect(!det.isGuess)
        #expect(abs(det.quad.topLeft.x - 0.25) < 0.03 && abs(det.quad.topLeft.y - 238.0 / 900) < 0.03)
        #expect(abs(det.quad.bottomRight.x - 0.75) < 0.03 && abs(det.quad.bottomRight.y - 662.0 / 900) < 0.03)

        var recipe = ProcessingRecipe(kind: .flat)
        recipe.corners = det.quad
        let r = try await p.preview(id: id, originalData: data, recipe: recipe, includeBefore: true)
        #expect(abs(Double(r.output.width) / Double(r.output.height) / Double(2).squareRoot() - 1) < 0.03)
        #expect(r.paperMode == .white)
        #expect(r.notes.isEmpty)
        #expect(r.before?.width == r.output.width)

        recipe.quarterTurns = 1
        let t = try await p.preview(id: id, originalData: data, recipe: recipe, includeBefore: true)
        #expect(t.output.width == r.output.height && t.output.height == r.output.width)
        #expect(t.before?.width == t.output.width)
        // the turned output's top-right corner is the sheet's top-left corner in the photo
        let tl = t.mapping.toOriginal(CGPoint(x: 1, y: 0))
        #expect(abs(Double(tl.x) - det.quad.topLeft.x) < 0.01 && abs(Double(tl.y) - det.quad.topLeft.y) < 0.01)

        recipe.straightenDegrees = 5
        let s = try await p.preview(id: id, originalData: data, recipe: recipe, includeBefore: false)
        #expect(s.output.width > t.output.width)
    }

    @Test func emptyTableNotesPaperNotFound() async throws {
        let p = ImageProcessor()
        let id = UUID()
        let data = try jpeg(width: 800, height: 600, table: (0.45, 0.3, 0.2), rects: [])
        let r = try await p.preview(id: id, originalData: data, recipe: ProcessingRecipe(kind: .flat), includeBefore: false)
        #expect(r.notes.first == .paperNotFound)
    }

    @Test func craftEndToEnd() async throws {
        let p = ImageProcessor()
        let id = UUID()
        let data = try jpeg(width: 1200, height: 900, table: (0.72, 0.7, 0.66), rects: [
            (CGRect(x: 420, y: 280, width: 360, height: 340), (0.15, 0.35, 0.8)),
            (CGRect(x: 1140, y: 60, width: 60, height: 120), (0.85, 0.15, 0.1)),
        ])
        var recipe = ProcessingRecipe(kind: .craft)
        let r = try await p.preview(id: id, originalData: data, recipe: recipe, includeBefore: true)
        #expect(r.output.width > 0 && r.before?.width == r.output.width)
        guard !r.notes.contains(.cutoutFallback) else { return }
        // the object's centre is a part and maps back to the photo
        let centre = try #require(r.mapping.fromOriginal(CGPoint(x: 0.5, y: 0.5)))
        #expect(r.partID(atOutputPoint: centre) != nil)
        let back = r.mapping.toOriginal(centre)
        #expect(abs(Double(back.x) - 0.5) < 1e-6 && abs(Double(back.y) - 0.5) < 1e-6)
        if r.parts.count >= 2 {
            #expect(r.notes.contains(.autoDroppedEdgeParts))
            let dropped = try #require(r.parts.first { $0.isRemoved })
            let kept = try #require(PartPicking.toggle(partID: dropped.id, in: r, recipe: recipe))
            let r2 = try await p.preview(id: id, originalData: data, recipe: kept, includeBefore: false)
            #expect(r2.parts.allSatisfy { !$0.isRemoved })
            #expect(!r2.notes.contains(.autoDroppedEdgeParts))
        }
        // turning keeps the object's centre where it is in the photo
        recipe.quarterTurns = 1
        let t = try await p.preview(id: id, originalData: data, recipe: recipe, includeBefore: false)
        let c2 = try #require(t.mapping.fromOriginal(CGPoint(x: 0.5, y: 0.5)))
        #expect(t.partID(atOutputPoint: c2) != nil)
    }

    @Test func largePhotoIsDownscaled() async throws {
        let p = ImageProcessor()
        let id = UUID()
        let data = try jpeg(width: 4032, height: 3024, table: (0.55, 0.38, 0.22), rects: [
            (CGRect(x: 1000, y: 800, width: 2000, height: 1414), (0.95, 0.94, 0.91)),
        ])
        let src = try await p.sourcePreview(id: id, originalData: data)
        #expect(abs(max(src.width, src.height) - ImageProcessor.previewMaxEdge) <= 1)
        var recipe = ProcessingRecipe(kind: .flat)
        recipe.corners = await p.detectCorners(id: id, originalData: data)
        let out = try await p.export(id: id, originalData: data, recipe: recipe)
        #expect(max(out.pixelWidth, out.pixelHeight) <= ImageProcessor.exportMaxEdge)
        #expect(!out.imageData.isEmpty)
    }
}
