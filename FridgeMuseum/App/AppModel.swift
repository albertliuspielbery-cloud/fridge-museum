import Foundation
import Observation
import SwiftData

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

/// App-wide state and the capture → process → save workflow. Lives on the main actor;
/// pixel work is delegated to `ImageProcessor` (an actor) with Sendable inputs/outputs only.
@MainActor
@Observable
final class AppModel {
    var captureKind: ArtworkKind = .flat
    var currentChildID: UUID?
    /// Artworks captured in this batch (這次), oldest first.
    var sessionArtworkIDs: [UUID] = []
    var processingIDs: Set<UUID> = []
    var toast: ToastMessage?

    let processor = ImageProcessor.shared
    let photos = PhotoLibrarySaver()

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    enum Keys {
        static let captureKind = "captureKind"
        static let currentChild = "currentChildID"
        /// Per-child Photos album on save (needs full Photos access; falls back to Recents).
        static let useAlbums = "useAlbums"
    }

    init() {
        let defaults = UserDefaults.standard
        captureKind = ArtworkKind(rawValue: defaults.string(forKey: Keys.captureKind) ?? "") ?? .flat
        currentChildID = defaults.string(forKey: Keys.currentChild).flatMap(UUID.init(uuidString:))
        defaults.register(defaults: [Keys.useAlbums: true])
    }

    /// Remembers the camera mode and selected child across launches (called from CaptureView.onChange).
    func persistPreferences() {
        UserDefaults.standard.set(captureKind.rawValue, forKey: Keys.captureKind)
        UserDefaults.standard.set(currentChildID?.uuidString, forKey: Keys.currentChild)
    }

    // MARK: Toast

    func show(_ text: String) {
        toast = ToastMessage(text: text)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Intake

    /// Creates the artwork right away (the original is never lost), then processes it in the background.
    @discardableResult
    func ingest(_ data: Data, kind: ArtworkKind, child: Child?, capturedAt: Date, context: ModelContext) -> Artwork {
        let artwork = Artwork(kind: kind, child: child, capturedAt: capturedAt, originalImageData: data)
        context.insert(artwork)
        try? context.save()
        sessionArtworkIDs.append(artwork.id)
        Task { await autoProcess(artwork, context: context) }
        return artwork
    }

    func autoProcess(_ artwork: Artwork, context: ModelContext) async {
        guard let data = artwork.originalImageData else { return }
        let id = artwork.id
        processingIDs.insert(id)
        artwork.processingState = .processing
        defer { processingIDs.remove(id) }
        var recipe = artwork.recipe
        if recipe.kind == .flat && recipe.corners == nil {
            recipe.corners = await processor.detectCorners(id: id, originalData: data)
        }
        artwork.recipe = recipe
        await rerender(artwork, context: context)
    }

    /// Full-resolution render from the original + recipe; stores rendered JPEG + thumbnail.
    func rerender(_ artwork: Artwork, context: ModelContext) async {
        guard let data = artwork.originalImageData else { return }
        let id = artwork.id
        let recipe = artwork.recipe
        do {
            let out = try await processor.export(id: id, originalData: data, recipe: recipe)
            artwork.renderedImageData = out.imageData
            artwork.thumbnailData = out.thumbnailData
            artwork.pixelWidth = out.pixelWidth
            artwork.pixelHeight = out.pixelHeight
            artwork.renderVersion += 1
            artwork.processingState = .done
        } catch {
            artwork.processingState = .failed
        }
        try? context.save()
    }

    // MARK: Save / share

    /// The exported JPEG including the optional caption band.
    func finalJPEG(for artwork: Artwork, context: ModelContext) async -> Data? {
        if artwork.renderedImageData == nil || artwork.processingState != .done {
            await rerender(artwork, context: context)
        }
        guard let jpeg = artwork.renderedImageData else { return nil }
        guard artwork.recipe.caption else { return jpeg }
        let bg = captionBackground(artwork.recipe)
        return CaptionComposer.composeJPEG(jpeg, title: captionTitle(artwork), detail: captionDetail(artwork), background: bg) ?? jpeg
    }

    func captionBackground(_ r: ProcessingRecipe) -> RGBColor {
        r.kind == .craft && r.background != .gradient ? r.background.color : RGBColor(r: 1, g: 1, b: 1)
    }

    func captionTitle(_ a: Artwork) -> String {
        if !a.title.isEmpty { return a.title }
        return a.child?.name.isEmpty == false ? (a.child?.name ?? "") : "我的作品"
    }

    func captionDetail(_ a: Artwork) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        var parts: [String] = []
        if !a.title.isEmpty, let n = a.child?.name, !n.isEmpty { parts.append(n) }
        if let age = a.ageAtCreation { parts.append(age.label) }
        parts.append(f.string(from: a.capturedAt))
        return parts.joined(separator: " · ")
    }

    func saveToPhotos(_ artwork: Artwork, context: ModelContext, quiet: Bool = false) async -> Bool {
        guard let jpeg = await finalJPEG(for: artwork, context: context) else {
            if !quiet { show("處理失敗，請重試") }
            return false
        }
        let useAlbums = UserDefaults.standard.bool(forKey: Keys.useAlbums)
        let album = useAlbums ? (artwork.child?.albumTitle ?? "冰箱美術館") : nil
        do {
            let outcome = try await photos.save(jpeg: jpeg, albumTitle: album, creationDate: artwork.capturedAt)
            artwork.lastSavedToPhotosAt = Date()
            try? context.save()
            if !quiet {
                show(outcome.savedToAlbum ? "已存到相簿「\(album ?? "")」" : "已存到照片")
            }
            return true
        } catch PhotoSaveError.denied {
            show("沒有照片權限，請到「設定 › 冰箱美術館」開啟")
            return false
        } catch {
            if !quiet { show("儲存失敗") }
            return false
        }
    }

    func saveAll(_ artworks: [Artwork], context: ModelContext) async {
        var ok = 0
        for a in artworks {
            if await saveToPhotos(a, context: context, quiet: true) { ok += 1 }
        }
        show("已存 \(ok) 張到照片")
    }

    func delete(_ artwork: Artwork, context: ModelContext) {
        let id = artwork.id
        sessionArtworkIDs.removeAll { $0 == id }
        context.delete(artwork)
        try? context.save()
        Task { await processor.evict(id: id) }
    }
}
