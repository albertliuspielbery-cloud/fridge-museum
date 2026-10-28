import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import FridgeMuseum

/// 不要了 / 全部不要 on the home sticky note, and the "one heavy render at a time" bookkeeping (1.0.1).
@MainActor
struct PendingArtworkTests {
    private func makeArtwork(_ kind: ArtworkKind = .flat, kept: Bool = false, sample: Bool = false,
                             in context: ModelContext) -> Artwork {
        let a = Artwork(kind: kind, child: nil, capturedAt: day(2026, 10, 28), originalImageData: Data([0, 1, 2]))
        a.isKept = kept
        a.isSample = sample
        context.insert(a)
        return a
    }

    @Test func discardPendingDeletesOnlyUnkeptCaptures() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let pending1 = makeArtwork(in: context)
        let pending2 = makeArtwork(.craft, in: context)
        let kept = makeArtwork(kept: true, in: context)
        let sample = makeArtwork(sample: true, in: context)
        try context.save()
        let keptID = kept.id, sampleID = sample.id

        #expect(app.pendingArtworks(context: context).count == 2)
        let deleted = app.discardPending(context: context)

        #expect(deleted == 2)
        #expect(!AppModel.isAlive(pending1))
        #expect(!AppModel.isAlive(pending2))
        let left = try context.fetch(FetchDescriptor<Artwork>())
        #expect(Set(left.map(\.id)) == Set([keptID, sampleID]))
        #expect(app.pendingArtworks(context: context).isEmpty)
    }

    @Test func discardPendingWithNothingPendingIsANoOp() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        _ = makeArtwork(kept: true, in: context)
        try context.save()

        #expect(app.discardPending(context: context) == 0)
        let remaining = try context.fetch(FetchDescriptor<Artwork>())
        #expect(remaining.count == 1)
    }

    @Test func discardPendingRemovesItFromThisVisit() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let pending = makeArtwork(in: context)
        try context.save()
        app.sessionArtworkIDs = [pending.id]

        app.discardPending(context: context)
        #expect(app.sessionArtworkIDs.isEmpty)
    }

    @Test func needsRenderOnlyWithoutARender() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let fresh = makeArtwork(in: context)
        let rendered = makeArtwork(in: context)
        rendered.renderedImageData = Data([9])
        try context.save()

        #expect(app.needsRender(fresh))
        #expect(!app.needsRender(rendered))
        app.delete(fresh, context: context)
        #expect(!app.needsRender(fresh))
    }

    /// While an editor is open, a background capture keeps its original but does not export yet.
    @Test func backgroundExportWaitsWhileAnEditorIsOpen() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let open = makeArtwork(.craft, kept: true, in: context)
        let background = makeArtwork(.craft, in: context)   // craft: no corner detection, straight to the export step
        try context.save()

        app.beginEditing(open.id)
        #expect(app.isEditorBusy)
        await app.autoProcess(background, context: context)

        #expect(background.renderedImageData == nil)
        #expect(background.renderVersion == 0)
        #expect(background.processingState == .pending)
        #expect(!app.processingIDs.contains(background.id))

        app.endEditing(open.id, context: context)
        #expect(!app.isEditorBusy)
    }

    /// A library import holds background exports until it has loaded; with nothing to open they are released.
    @Test func importHoldsBackgroundExportsUntilItEnds() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let imported = makeArtwork(.craft, in: context)
        try context.save()

        app.beginImport()
        #expect(app.isEditorBusy)
        await app.autoProcess(imported, context: context)
        #expect(imported.renderedImageData == nil)
        #expect(imported.processingState == .pending)

        app.endImport(opening: nil, context: context)
        #expect(!app.isEditorBusy)
    }

    /// The import's first photo stays claimed for the editor after loading, so the hold carries over.
    @Test func importClaimsTheArtworkItOpens() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let first = makeArtwork(in: context)
        try context.save()

        app.beginImport()
        app.endImport(opening: first.id, context: context)
        #expect(app.isEditorBusy)
        app.beginEditing(first.id)
        app.endEditing(first.id, context: context)
        #expect(!app.isEditorBusy)
    }

    private func decoded(_ jpeg: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// 存到手機 keeps a downscaled copy of the final export: same size limits as a normal render.
    @Test func storedCopyOfAFinalExportMatchesTheWorkingSizes() throws {
        let ctx = try #require(CGContext(data: nil, width: 4096, height: 3072, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.4, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4096, height: 3072))
        let image = try #require(ctx.makeImage())
        let finalJPEG = try #require(ImageEncoding.jpegData(image, quality: 0.92))

        let copy = try #require(StoredRenderCopy.make(fromFinalJPEG: finalJPEG))
        #expect(copy.pixelWidth == ImageProcessor.exportMaxEdge)
        #expect(copy.pixelHeight == 1800)
        let thumb = try decoded(copy.thumbnailData)
        #expect(max(thumb.width, thumb.height) == ImageProcessor.thumbnailMaxEdge)
        let stored = try decoded(copy.imageData)
        #expect(stored.width == copy.pixelWidth && stored.height == copy.pixelHeight)
    }
}
