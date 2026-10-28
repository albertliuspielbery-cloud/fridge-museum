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
    @discardableResult
    func ingest(_ data: Data, kind: ArtworkKind, child: Child?, capturedAt: Date, context: ModelContext,
                isSample: Bool = false) -> Artwork {
        let artwork = Artwork(kind: kind, child: child, capturedAt: capturedAt, originalImageData: data)
        artwork.isKept = false
        artwork.isSample = isSample
        context.insert(artwork)
        try? context.save()
        Task { await autoProcess(artwork, context: context) }
        return artwork
    }

    /// Opens one of the bundled sample photos (看範例) in the editor. Samples never count toward the quota.
    func openSample(_ kind: ArtworkKind, context: ModelContext) -> Artwork? {
        guard let url = Bundle.main.url(forResource: kind == .flat ? "sample-flat" : "sample-craft", withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else { return nil }
        let existing = try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { $0.isSample && !$0.isKept }))
        for old in existing ?? [] where old.kind == kind {
            context.delete(old)
        }
        let a = ingest(data, kind: kind, child: nil, capturedAt: Date(), context: context, isSample: true)
        a.title = kind == .flat ? String(localized: "氣球派對") : String(localized: "國旗勞作")
        return a
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
    func saveToPhotos(_ artwork: Artwork, context: ModelContext, quiet: Bool = false) async -> Bool {
        guard admit(artwork, action: .save) else { return false }
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
            show(String(localized: "沒有照片權限，請到「設定 › 冰箱美術館」開啟"), style: .problem, seconds: 4)
            return false
        } catch {
            if !quiet { show(String(localized: "儲存失敗"), style: .problem) }
            return false
        }
    }

    func saveAll(_ artworks: [Artwork], context: ModelContext) async {
        var ok = 0
        for a in artworks {
            if await saveToPhotos(a, context: context, quiet: true) { ok += 1 }
        }
        show(String(localized: "已存 \(ok) 張到照片"))
    }

    func delete(_ artwork: Artwork, context: ModelContext) {
        let id = artwork.id
        sessionArtworkIDs.removeAll { $0 == id }
        context.delete(artwork)
        try? context.save()
        Task { await processor.evict(id: id) }
    }
}
