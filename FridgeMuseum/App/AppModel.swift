import Foundation
import Observation
import SwiftData
import UIKit

struct ToastMessage: Identifiable, Equatable {
    enum Style: Equatable {
        case info
        /// 已掛上冰箱！ — Bibi cheers, crayon headline, light haptic.
        case hung(count: Int)
        case problem
    }

    let id = UUID()
    var text: String
    var style: Style = .info
    /// Crayon headline for celebratory toasts (已掛上冰箱！).
    var headline: String?

    var isCelebration: Bool {
        if case .hung = style { return true }
        return false
    }
}

/// Why the paywall is up, and what to do once the parent unlocks (or restores).
struct PaywallRequest: Identifiable, Equatable {
    enum Action: Equatable {
        case keep
        case save
        /// Opened from Settings — nothing pending.
        case browse
    }

    let id = UUID()
    var kind: ArtworkKind
    var artworkID: UUID?
    var action: Action
}

/// App-wide state and the capture → edit → keep/save workflow. Lives on the main actor;
/// pixel work is delegated to `ImageProcessor` (an actor) with Sendable inputs/outputs only.
@MainActor
@Observable
final class AppModel {
    var captureKind: ArtworkKind = .flat
    var currentChildID: UUID?
    /// Artworks hung on the fridge during this visit (這次收的作品), oldest first.
    var sessionArtworkIDs: [UUID] = []
    var processingIDs: Set<UUID> = []
    var toast: ToastMessage?
    var paywall: PaywallRequest?
    /// Navigation requests from places that don't own the NavigationStack (camera cover, paywall, demo seeding).
    var pendingRoute: Route?
    var popToRoot = 0
    /// Bumped to open the camera from elsewhere (重拍 in the editor).
    var cameraRequest = 0

    let processor = ImageProcessor.shared
    let photos = PhotoLibrarySaver()
    let store = StoreBridge()

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Background processing per artwork, so deleting (重拍, a replaced sample) can cancel it first.
    @ObservationIgnored private var processTasks: [UUID: Task<Void, Never>] = [:]
    /// Artworks whose full-size export is running right now (any caller), so nobody starts a second one.
    @ObservationIgnored private var renderingIDs: Set<UUID> = []
    /// Artworks open in an editor. While any editor is open, background exports wait (the editor renders its own
    /// previews; two heavy renders at once make the phone warm).
    @ObservationIgnored private var editingIDs: Set<UUID> = []
    /// Fresh captures about to open in the editor (claimed at ingest, before the editor appears).
    @ObservationIgnored private var claimedIDs: Set<UUID> = []
    /// Background exports held back while an editor was open; they run when the last editor closes.
    @ObservationIgnored private var deferredIDs: Set<UUID> = []
    /// Photos access was refused and we already explained it once (Settings button); later refusals only toast.
    var photosDeniedAlert = false
    /// Short explanation shown right before the first full-access (album) request.
    var photosPrimer: PhotosPrimer?

    struct PhotosPrimer: Identifiable, Equatable {
        let id = UUID()
        let artworkID: UUID
    }

    /// The artwork still exists in a context (not deleted by 重拍 / a replaced sample / the trash button).
    static func isAlive(_ artwork: Artwork) -> Bool {
        !artwork.isDeleted && artwork.modelContext != nil
    }

    enum Keys {
        static let captureKind = "captureKind"
        static let currentChild = "currentChildID"
        /// Per-child Photos album on save (needs full Photos access; falls back to Recents).
        static let useAlbums = "useAlbums"
        static let photosDeniedExplained = "photosDeniedExplained"
    }

    init() {
        let defaults = UserDefaults.standard
        captureKind = ArtworkKind(rawValue: defaults.string(forKey: Keys.captureKind) ?? "") ?? .flat
        currentChildID = defaults.string(forKey: Keys.currentChild).flatMap(UUID.init(uuidString:))
        defaults.register(defaults: [Keys.useAlbums: true])
    }

    /// Remembers the camera mode and selected child across launches.
    func persistPreferences() {
        guard !DemoMode.isActive else { return }
        UserDefaults.standard.set(captureKind.rawValue, forKey: Keys.captureKind)
        UserDefaults.standard.set(currentChildID?.uuidString, forKey: Keys.currentChild)
    }

    // MARK: Toast

    func show(_ text: String, style: ToastMessage.Style = .info, headline: String? = nil, seconds: Double = 2.6) {
        toast = ToastMessage(text: text, style: style, headline: headline)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Intake

    /// Creates the artwork right away (the original is never lost) as *pending* — it joins the museum once the parent
    /// taps 收進這次 or 存到手機 — then processes it in the background.
    /// `opensEditor`: the caller opens this artwork in the editor next. Its full-size export then waits for the editor
    /// to close (EditView.commit renders it once) instead of running alongside the editor's previews.
    @discardableResult
    func ingest(_ data: Data, kind: ArtworkKind, child: Child?, capturedAt: Date, context: ModelContext,
                isSample: Bool = false, opensEditor: Bool = false) -> Artwork {
        let artwork = Artwork(kind: kind, child: child, capturedAt: capturedAt, originalImageData: data)
        artwork.isKept = false
        artwork.isSample = isSample
        context.insert(artwork)
        try? context.save()
        if opensEditor { claimEditor(artwork.id, context: context) }
        startProcessing(artwork, context: context)
        return artwork
    }

    private func startProcessing(_ artwork: Artwork, context: ModelContext) {
        let id = artwork.id
        processTasks[id] = Task { [weak self] in
            await self?.autoProcess(artwork, context: context)
            self?.processTasks[id] = nil
        }
    }

    // MARK: Editor bookkeeping (one heavy render at a time)

    /// True while an editor is open (or about to open on a fresh capture).
    var isEditorBusy: Bool { !editingIDs.isEmpty || !claimedIDs.isEmpty || importHolds > 0 }

    /// A library import is loading its photos (its first one opens in the editor afterwards).
    @ObservationIgnored private var importHolds = 0

    /// Holds background exports while a library import loads (it can take longer than the editor claim lasts).
    func beginImport() {
        importHolds += 1
    }

    /// The import finished loading. `opening`: the artwork it opens in the editor next, claimed like a fresh capture
    /// so the hold carries over until the editor appears.
    func endImport(opening id: UUID?, context: ModelContext) {
        if let id { claimEditor(id, context: context) }
        importHolds = max(0, importHolds - 1)
        runDeferred(context: context)
    }

    /// Marks a fresh capture as "the editor is about to open it". Released by `beginEditing`, or after a few seconds
    /// if the editor never shows up, so background exports are never held back forever.
    private func claimEditor(_ id: UUID, context: ModelContext) {
        claimedIDs.insert(id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.claimedIDs.remove(id) != nil else { return }
            self.runDeferred(context: context)
        }
    }

    /// The editor appeared for this artwork.
    func beginEditing(_ id: UUID) {
        claimedIDs.remove(id)
        editingIDs.insert(id)
    }

    /// The editor closed. Its own artwork is rendered by EditView.commit; other held-back exports run now.
    func endEditing(_ id: UUID, context: ModelContext) {
        editingIDs.remove(id)
        claimedIDs.remove(id)
        deferredIDs.remove(id)
        runDeferred(context: context)
    }

    /// The artwork has no full-size render yet and nothing is producing one.
    func needsRender(_ artwork: Artwork) -> Bool {
        Self.isAlive(artwork) && artwork.renderedImageData == nil
            && !processingIDs.contains(artwork.id) && !renderingIDs.contains(artwork.id)
    }

    private func runDeferred(context: ModelContext) {
        guard !isEditorBusy, !deferredIDs.isEmpty else { return }
        let ids = deferredIDs
        deferredIDs = []
        for id in ids where processTasks[id] == nil {
            guard let artwork = try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { $0.id == id })).first,
                  needsRender(artwork) else { continue }
            startProcessing(artwork, context: context)
        }
    }

    /// At launch: artworks whose processing never finished (app closed mid-render, or while an editor was open).
    func processUnfinished(context: ModelContext) {
        guard !DemoMode.isActive else { return }
        let done = ProcessingState.done.rawValue
        let failed = ProcessingState.failed.rawValue
        let descriptor = FetchDescriptor<Artwork>(predicate: #Predicate { $0.processingStateRaw != done && $0.processingStateRaw != failed })
        for artwork in (try? context.fetch(descriptor)) ?? [] where processTasks[artwork.id] == nil && needsRender(artwork) {
            startProcessing(artwork, context: context)
        }
    }

    /// Opens one of the bundled sample photos (看範例) in the editor. Samples never count toward the quota.
    func openSample(_ kind: ArtworkKind, context: ModelContext) -> Artwork? {
        guard let url = Bundle.main.url(forResource: kind == .flat ? "sample-flat" : "sample-craft", withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else { return nil }
        let existing = try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { $0.isSample && !$0.isKept }))
        for old in existing ?? [] where old.kind == kind {
            delete(old, context: context)
        }
        let a = ingest(data, kind: kind, child: nil, capturedAt: Date(), context: context, isSample: true, opensEditor: true)
        a.title = kind == .flat ? String(localized: "氣球派對") : String(localized: "國旗勞作")
        return a
    }

    /// Finds the paper corners (cheap), then exports the full-size render — unless an editor is open: then the export
    /// waits (the editor's own artwork is rendered once by EditView.commit when it closes; others run after that).
    func autoProcess(_ artwork: Artwork, context: ModelContext) async {
        guard Self.isAlive(artwork), let data = artwork.originalImageData else { return }
        let id = artwork.id
        let startVersion = artwork.renderVersion
        processingIDs.insert(id)
        defer { processingIDs.remove(id) }
        if artwork.recipe.kind == .flat && artwork.recipe.corners == nil {
            let corners = await processor.detectCorners(id: id, originalData: data)
            guard !Task.isCancelled, Self.isAlive(artwork) else { return }
            // Re-read: the editor may have written its recipe while the corners were being found.
            var recipe = artwork.recipe
            if recipe.kind == .flat && recipe.corners == nil {
                recipe.corners = corners
                artwork.recipe = recipe
            }
        }
        // The editor already rendered it (or is rendering it): nothing left to do.
        if renderingIDs.contains(id) || artwork.renderVersion != startVersion { return }
        if isEditorBusy {
            deferredIDs.insert(id)
            try? context.save()
            return
        }
        artwork.processingState = .processing
        await rerender(artwork, context: context)
    }

    /// Full-resolution render from the original + recipe; stores rendered JPEG + thumbnail.
    func rerender(_ artwork: Artwork, context: ModelContext) async {
        guard Self.isAlive(artwork), let data = artwork.originalImageData else { return }
        let id = artwork.id
        let recipe = artwork.recipe
        renderingIDs.insert(id)
        defer { renderingIDs.remove(id) }
        do {
            let out = try await processor.export(id: id, originalData: data, recipe: recipe)
            // The artwork may have been deleted (重拍) while the render ran: never write to a deleted model.
            guard !Task.isCancelled, Self.isAlive(artwork) else { return }
            artwork.renderedImageData = out.imageData
            artwork.thumbnailData = out.thumbnailData
            artwork.pixelWidth = out.pixelWidth
            artwork.pixelHeight = out.pixelHeight
            artwork.renderVersion += 1
            artwork.processingState = .done
        } catch {
            guard Self.isAlive(artwork) else { return }
            artwork.processingState = .failed
        }
        try? context.save()
    }

    // MARK: Keep (收進這次) — quota-gated at keep/save time, never mid-edit.

    /// Hangs the artwork on the fridge. Returns false when the paywall was shown instead.
    @discardableResult
    func keep(_ artwork: Artwork, context: ModelContext) -> Bool {
        guard admit(artwork, action: .keep) else { return false }
        markKept(artwork, context: context)
        let count = sessionArtworkIDs.count
        show(count > 1 ? String(localized: "這是第 \(count) 張，按快門拍下一張。") : String(localized: "按快門，再拍下一張。"),
             style: .hung(count: count), headline: String(localized: "已掛上冰箱！"), seconds: 3.2)
        return true
    }

    /// Quota check shared by keep + save. Already-kept artworks and samples pass freely (idempotent per artwork).
    private func admit(_ artwork: Artwork, action: PaywallRequest.Action) -> Bool {
        if artwork.isSample || artwork.isKept { return true }
        if store.canKeep(kind: artwork.kind, artworkID: artwork.id, isSample: artwork.isSample) { return true }
        paywall = PaywallRequest(kind: artwork.kind, artworkID: artwork.id, action: action)
        return false
    }

    private func markKept(_ artwork: Artwork, context: ModelContext) {
        if !artwork.isKept, !artwork.isSample {
            store.recordKeep(kind: artwork.kind, artworkID: artwork.id)
        }
        if !artwork.isKept {
            artwork.isKept = true
            artwork.keptAt = Date()
        }
        if !sessionArtworkIDs.contains(artwork.id) { sessionArtworkIDs.append(artwork.id) }
        try? context.save()
    }

    /// Called by the paywall after a successful unlock/restore: finish what the parent was doing.
    func resumeAfterUnlock(_ request: PaywallRequest, context: ModelContext) {
        guard let id = request.artworkID,
              let artwork = try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { $0.id == id })).first else { return }
        switch request.action {
        case .keep:
            if keep(artwork, context: context) { popToRoot += 1 }
        case .save:
            Task {
                if await saveToPhotos(artwork, context: context) { popToRoot += 1 }
            }
        case .browse:
            break
        }
    }

    // MARK: Save / share

    /// The parent answered the album explanation: `albums` = 建立相簿 (ask iOS for full access) or 只存到照片.
    func continueSave(after primer: PhotosPrimer, albums: Bool, context: ModelContext) {
        photosPrimer = nil
        if !albums { UserDefaults.standard.set(false, forKey: Keys.useAlbums) }
        let id = primer.artworkID
        guard let artwork = try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { $0.id == id })).first else { return }
        let wasPending = !artwork.isKept
        Task {
            if await saveToPhotos(artwork, context: context, primed: true), wasPending { popToRoot += 1 }
        }
    }

    /// The exported JPEG including the optional caption band.
    /// Rendered fresh at the final export size (up to 4096 px, see ImageProcessor.finalExportMaxEdge); falls back to
    /// the stored 2400 px render if that fails (e.g. memory pressure).
    func finalJPEG(for artwork: Artwork, context: ModelContext) async -> Data? {
        guard Self.isAlive(artwork) else { return nil }
        let id = artwork.id
        // A fresh capture saved straight from the editor has no working copy yet: keep a downscaled copy of this
        // export instead of running a second (2400 px) render. Marked as rendering so nobody starts one meanwhile.
        let storeCopy = needsRender(artwork)
        if storeCopy { renderingIDs.insert(id) }
        defer { if storeCopy { renderingIDs.remove(id) } }
        var jpeg: Data?
        if let data = artwork.originalImageData {
            let recipe = artwork.recipe
            jpeg = try? await processor.export(id: id, originalData: data, recipe: recipe,
                                               maxEdge: ImageProcessor.finalExportMaxEdge(for: recipe.kind)).imageData
            if storeCopy, let raw = jpeg {
                let copy = await Task.detached(priority: .userInitiated) {
                    StoredRenderCopy.make(fromFinalJPEG: raw)
                }.value
                // Only if nothing changed meanwhile (deleted, re-rendered, or the recipe edited).
                if let copy, Self.isAlive(artwork), artwork.renderedImageData == nil, artwork.recipe == recipe {
                    artwork.renderedImageData = copy.imageData
                    artwork.thumbnailData = copy.thumbnailData
                    artwork.pixelWidth = copy.pixelWidth
                    artwork.pixelHeight = copy.pixelHeight
                    artwork.renderVersion += 1
                    artwork.processingState = .done
                    try? context.save()
                }
            }
        }
        if jpeg == nil {
            if artwork.renderedImageData == nil || artwork.processingState != .done {
                await rerender(artwork, context: context)
            }
            jpeg = artwork.renderedImageData
        }
        guard Self.isAlive(artwork), let jpeg else { return nil }
        guard artwork.recipe.caption else { return jpeg }
        let bg = captionBackground(artwork.recipe)
        return CaptionComposer.composeJPEG(jpeg, title: captionTitle(artwork), detail: captionDetail(artwork), background: bg) ?? jpeg
    }

    func captionBackground(_ r: ProcessingRecipe) -> RGBColor {
        r.kind == .craft && r.background != .gradient ? r.background.color : RGBColor(r: 1, g: 1, b: 1)
    }

    func captionTitle(_ a: Artwork) -> String {
        if !a.title.isEmpty { return a.title }
        return a.child?.name.isEmpty == false ? (a.child?.name ?? "") : String(localized: "我的作品")
    }

    func captionDetail(_ a: Artwork) -> String {
        var parts: [String] = []
        if !a.title.isEmpty, let n = a.child?.name, !n.isEmpty { parts.append(n) }
        if let age = a.ageAtCreation { parts.append(age.localizedLabel) }
        parts.append(AppLanguage.placardDate(a.capturedAt))
        return parts.joined(separator: " · ")
    }

    /// Saves to Photos (per-child album when full access is granted). Counts as keeping the artwork.
    func saveToPhotos(_ artwork: Artwork, context: ModelContext, quiet: Bool = false, primed: Bool = false) async -> Bool {
        guard admit(artwork, action: .save) else { return false }
        // First album save: explain why full Photos access is useful before iOS asks (PhotosPrimerAlert).
        if !primed, UserDefaults.standard.bool(forKey: Keys.useAlbums), PhotoLibrarySaver.needsAlbumPrimer {
            photosPrimer = PhotosPrimer(artworkID: artwork.id)
            return false
        }
        guard let jpeg = await finalJPEG(for: artwork, context: context) else {
            if !quiet { show(String(localized: "處理失敗，請重試"), style: .problem) }
            return false
        }
        let useAlbums = UserDefaults.standard.bool(forKey: Keys.useAlbums)
        let album = useAlbums ? (artwork.child?.albumTitle ?? String(localized: "冰箱美術館")) : nil
        do {
            let outcome = try await photos.save(jpeg: jpeg, albumTitle: album, creationDate: artwork.capturedAt)
            artwork.lastSavedToPhotosAt = Date()
            markKept(artwork, context: context)
            if !quiet {
                let albumName = album ?? ""
                let detail = outcome.savedToAlbum && !albumName.isEmpty
                    ? String(localized: "已存到相簿「\(albumName)」，也掛上冰箱了。")
                    : String(localized: "已存到照片，也掛上冰箱了。")
                show(detail, style: .hung(count: sessionArtworkIDs.count), headline: String(localized: "已存到手機！"), seconds: 3.2)
            }
            return true
        } catch PhotoSaveError.denied {
            if UserDefaults.standard.bool(forKey: Keys.photosDeniedExplained) {
                show(String(localized: "沒有照片權限，請到「設定 › 冰箱美術館」開啟"), style: .problem, seconds: 4)
            } else {
                UserDefaults.standard.set(true, forKey: Keys.photosDeniedExplained)
                photosDeniedAlert = true
            }
            return false
        } catch {
            if !quiet { show(String(localized: "儲存失敗"), style: .problem) }
            return false
        }
    }

    /// Saves several artworks; stops at the first one the free quota blocks (the paywall shows once).
    func saveAll(_ artworks: [Artwork], context: ModelContext) async {
        var ok = 0
        for a in artworks where Self.isAlive(a) {
            if await saveToPhotos(a, context: context, quiet: true) {
                ok += 1
            } else if paywall != nil || photosDeniedAlert || photosPrimer != nil {
                break
            }
        }
        if ok > 0 { show(String(localized: "已存 \(ok) 張到照片")) }
    }

    func delete(_ artwork: Artwork, context: ModelContext) {
        let id = artwork.id
        processTasks.removeValue(forKey: id)?.cancel()
        deferredIDs.remove(id)
        sessionArtworkIDs.removeAll { $0 == id }
        context.delete(artwork)
        try? context.save()
        Task { await processor.evict(id: id) }
    }

    /// Captures that were never kept (the home sticky note). Samples are left alone.
    func pendingArtworks(context: ModelContext) -> [Artwork] {
        let all = (try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { !$0.isKept && !$0.isSample }))) ?? []
        return all.filter { Self.isAlive($0) }
    }

    /// 不要了 / 全部不要: deletes every pending (captured, never kept) artwork. Returns how many were deleted.
    @discardableResult
    func discardPending(context: ModelContext) -> Int {
        let pending = pendingArtworks(context: context)
        for artwork in pending { delete(artwork, context: context) }
        return pending.count
    }
}

/// The stored working copy (≤ 2400 px JPEG + 480 px thumbnail, same sizes and qualities as ImageProcessor.export)
/// made from a larger final export, so 存到手機 on a fresh capture doesn't render twice.
struct StoredRenderCopy: Sendable {
    var imageData: Data
    var thumbnailData: Data
    var pixelWidth: Int
    var pixelHeight: Int

    static func make(fromFinalJPEG jpeg: Data) -> StoredRenderCopy? {
        guard let image = ImageMetadata.uprightThumbnail(of: jpeg, maxPixelSize: ImageProcessor.exportMaxEdge),
              let imageData = ImageEncoding.jpegData(image, quality: 0.92),
              let thumb = ImageMetadata.uprightThumbnail(of: jpeg, maxPixelSize: ImageProcessor.thumbnailMaxEdge),
              let thumbnailData = ImageEncoding.jpegData(thumb, quality: 0.8) else { return nil }
        return StoredRenderCopy(imageData: imageData, thumbnailData: thumbnailData,
                                pixelWidth: image.width, pixelHeight: image.height)
    }
}
