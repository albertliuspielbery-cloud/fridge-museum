import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Share sheet item: renders a fresh full-size JPEG (plus optional caption) only when the user actually shares.
struct ShareableArtwork: Transferable, Sendable {
    let id: UUID
    let originalData: Data
    let recipe: ProcessingRecipe
    let captionTitle: String
    let captionDetail: String
    let captionBackground: RGBColor

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { item in
            try await item.jpeg()
        }
        .suggestedFileName("冰箱美術館.jpg")
    }

    func jpeg() async throws -> Data {
        let out = try await ImageProcessor.shared.export(id: id, originalData: originalData, recipe: recipe)
        guard recipe.caption else { return out.imageData }
        let composed = await CaptionComposer.composeJPEG(out.imageData, title: captionTitle, detail: captionDetail,
                                                         background: captionBackground)
        return composed ?? out.imageData
    }
}
