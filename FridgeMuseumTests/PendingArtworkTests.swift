import Foundation
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
}
