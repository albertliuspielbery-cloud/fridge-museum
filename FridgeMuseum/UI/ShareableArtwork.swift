import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Share sheet item. Cheap to create on every render: it only carries ids + the recipe; the original photo is read
/// (from the store, on a background context) and the final-size JPEG rendered only when the person actually shares.
struct ShareableArtwork: Transferable, Sendable {
    let id: UUID
    let persistentID: PersistentIdentifier
    let container: ModelContainer
    let recipe: ProcessingRecipe
    let captionTitle: String
    let captionDetail: String
    let captionBackground: RGBColor

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { item in
            try await item.jpeg()
        }
        .suggestedFileName(String(localized: "冰箱美術館") + ".jpg")
    }

    /// The original, and whether the one-time upright check is still owed (never rendered, not a sample).
    private func originalData() throws -> (data: Data, owesUprightCheck: Bool) {
        let context = ModelContext(container)
        guard let artwork = context.model(for: persistentID) as? Artwork, let data = artwork.originalImageData else {
            throw ProcessingError.decodeFailed
        }
        return (data, artwork.renderedImageData == nil && !artwork.isSample)
    }

    func jpeg() async throws -> Data {
        let (data, owes) = try originalData()
        let recipe = await ProcessingRecipe.settlingUpright(self.recipe, owed: owes, id: id, originalData: data)
        let out = try await ImageProcessor.shared.export(id: id, originalData: data, recipe: recipe,
                                                         maxEdge: ImageProcessor.finalExportMaxEdge(for: recipe.kind))
        guard recipe.caption else { return out.imageData }
        let composed = await CaptionComposer.composeJPEG(out.imageData, title: captionTitle, detail: captionDetail,
                                                         background: captionBackground)
        return composed ?? out.imageData
    }
}

extension ShareableArtwork {
    @MainActor
    init?(artwork: Artwork, recipe: ProcessingRecipe, app: AppModel) {
        guard let container = artwork.modelContext?.container else { return nil }
        self.init(id: artwork.id, persistentID: artwork.persistentModelID, container: container, recipe: recipe,
                  captionTitle: app.captionTitle(artwork), captionDetail: app.captionDetail(artwork),
                  captionBackground: app.captionBackground(recipe))
    }
}
