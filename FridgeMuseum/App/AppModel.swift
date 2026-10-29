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

    /// 全部存到照片 / a museum batch save in progress (the backup card shows it).
    struct SaveAllProgress: Equatable {
        var done: Int
        var total: Int
    }

    var saveAllProgress: SaveAllProgress?
    /// A save-all that stopped at the album explanation: continueSave carries on with these once it is answered.
    @ObservationIgnored private var saveAllResume: (ids: [UUID], addsToSession: Bool)?
    /// The last saveToPhotos failed for lack of Photos access (saveAll stops instead of rendering the rest for nothing).
    @ObservationIgnored private var lastSaveDenied = false
    /// One final (4096 px) export at a time, first come first served (saveToPhotos).
    let exportGate = ExportGate()

    /// When this launch started (備份提醒 never nags about artworks kept during the very first visit).
    let launchedAt = Date()
    /// 之後再說 on the backup card: hidden until this date.
    var backupSnoozedUntil: Date?

    /// 連拍: the camera is taking shots in a row without opening the editor (CameraScreen).
    @ObservationIgnored private(set) var isBursting = false
    /// 繼續 on the sticky note with several pending: after each 收進這次 / 存到手機 / 不要這張 the next one opens.
    @ObservationIgnored private(set) var isWalkingPending = false

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
        /// 備份提醒「之後再說」: the date the card may show again.
        static let backupSnoozedUntil = "backupSnoozedUntil"
    }

    init() {
        let defaults = UserDefaults.standard
        captureKind = ArtworkKind(rawValue: defaults.string(forKey: Keys.captureKind) ?? "") ?? .flat
        currentChildID = defaults.string(forKey: Keys.currentChild).flatMap(UUID.init(uuidString:))
        defaults.register(defaults: [Keys.useAlbums: true])
        backupSnoozedUntil = defaults.object(forKey: Keys.backupSnoozedUntil) as? Date
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

    /// True while an editor is open (or about to open on a fresh capture), a library import is loading, or the
    /// camera is in 連拍. Background exports wait meanwhile and then run one at a time (runDeferred).
    var isEditorBusy: Bool { !editingIDs.isEmpty || !claimedIDs.isEmpty || importHolds > 0 || isBursting }

    /// 連拍 started: shots are ingested without the editor. Each still gets its paper corners found right away
    /// (autoProcess), but its export is held like an import's until the burst ends.
    func beginBurst() {
        isBursting = true
    }

    /// 連拍 ended (完成, the toggle turned off, or the camera closed): held exports run, one at a time.
    func endBurst(context: ModelContext) {
        guard isBursting else { return }
        isBursting = false
        runDeferred(context: context)
    }

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
        // A render owed from an earlier step (renderLater) stays queued: this editor only renders if it was edited.
        if !staleIDs.contains(id) { deferredIDs.remove(id) }
        runDeferred(context: context)
    }

    /// Edited while stepping through pending captures; their full-size render waits in the queue (renderLater).
    @ObservationIgnored private var staleIDs: Set<UUID> = []

    /// Stepping through pending captures (繼續): the closed editor's full-size render waits in the queue — it runs
    /// once no editor is open — instead of alongside the next editor's previews. `stale`: the recipe was edited, so
    /// it renders even if an (outdated) render exists. Until then the fridge shows its spinner / old thumbnail.
    func renderLater(_ artwork: Artwork, context: ModelContext, stale: Bool) {
        guard Self.isAlive(artwork) else { return }
        if stale {
            staleIDs.insert(artwork.id)
            // Persisted too: if iOS closes the app before the queue gets to it, the next launch (processUnfinished)
            // sees an unfinished artwork that has a render — i.e. an outdated one — and re-renders it.
            artwork.processingState = .pending
            try? context.save()
        }
        guard stale || needsRender(artwork) else { return }
        deferredIDs.insert(artwork.id)
        runDeferred(context: context)
    }

    /// The artwork has no full-size render yet and nothing is producing one.
    func needsRender(_ artwork: Artwork) -> Bool {
        Self.isAlive(artwork) && artwork.renderedImageData == nil
            && !processingIDs.contains(artwork.id) && !renderingIDs.contains(artwork.id)
    }

    /// A drain of held-back exports is running (runDeferred).
    @ObservationIgnored private var isDrainingDeferred = false

    /// Runs the held-back exports one at a time, oldest capture first (a burst can leave dozens), and pauses again —
    /// the rest stay held — as soon as an editor opens or a burst / import starts.
    private func runDeferred(context: ModelContext) {
        guard !isEditorBusy, !deferredIDs.isEmpty, !isDrainingDeferred else { return }
        isDrainingDeferred = true
        Task { [weak self] in
            await self?.drainDeferred(context: context)
        }
    }

    private func drainDeferred(context: ModelContext) async {
        defer { isDrainingDeferred = false }
        while !isEditorBusy, let artwork = nextDeferred(context: context) {
            let id = artwork.id
            deferredIDs.remove(id)
            let due = staleIDs.contains(id)
                ? Self.isAlive(artwork) && !processingIDs.contains(id) && !renderingIDs.contains(id)
                : needsRender(artwork)
            guard processTasks[id] == nil, due else { continue }
            startProcessing(artwork, context: context)
            if let task = processTasks[id] { await task.value }
        }
    }

    /// The oldest held-back artwork that still exists (ids of deleted ones are dropped).
    private func nextDeferred(context: ModelContext) -> Artwork? {
        var alive: [Artwork] = []
        for id in deferredIDs {
            if let artwork = fetchArtwork(id, context: context), Self.isAlive(artwork) {
                alive.append(artwork)
            } else {
                deferredIDs.remove(id)
            }
        }
        return alive.min { $0.createdAt < $1.createdAt }
    }

    private func fetchArtwork(_ id: UUID, context: ModelContext) -> Artwork? {
        try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { $0.id == id })).first
    }

    /// At launch: artworks whose processing never finished (app closed mid-render, or while an editor was open).
    func processUnfinished(context: ModelContext) {
        guard !DemoMode.isActive else { return }
        let done = ProcessingState.done.rawValue
        let failed = ProcessingState.failed.rawValue
        let descriptor = FetchDescriptor<Artwork>(predicate: #Predicate { $0.processingStateRaw != done && $0.processingStateRaw != failed })
        // Through the same queue as held exports (oldest first, one at a time, paused while an editor is open): a
        // burst cut short by the app closing can leave dozens, and starting them all at once heats the phone.
        // Corners are found in the queue too, right before each export.
        // Unfinished but already rendered = the recipe changed after that render (edited while stepping through
        // pending captures — renderLater — or the app closed mid-render): re-render it from the current recipe.
        for artwork in (try? context.fetch(descriptor)) ?? [] where processTasks[artwork.id] == nil && Self.isAlive(artwork) {
            let id = artwork.id
            guard !processingIDs.contains(id), !renderingIDs.contains(id) else { continue }
            if artwork.renderedImageData != nil { staleIDs.insert(id) }
            deferredIDs.insert(id)
        }
        runDeferred(context: context)
        Task { [weak self] in await self?.backfillFingerprints(context: context) }
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
            // One-time upright check, written together with the corners (EditModel.autoOrientIfNeeded mirrors it).
            var upright: AutoOrientation?
            if artwork.recipe.autoTurns == nil && !artwork.isSample && !DemoMode.isActive {
                upright = await processor.estimateOrientation(id: id, originalData: data, corners: corners)
            }
            guard !Task.isCancelled, Self.isAlive(artwork) else { return }
            // Re-read: the editor may have written its recipe while the corners were being found.
            var recipe = artwork.recipe
            if recipe.kind == .flat && recipe.corners == nil {
                recipe.corners = corners
                if let upright { recipe = recipe.applyingAutoOrientation(upright) }
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
        // This render uses the current recipe, so a render owed by renderLater is paid.
        staleIDs.remove(id)
        do {
            let out = try await processor.export(id: id, originalData: data, recipe: recipe)
            let thumbnail = out.thumbnailData
            let fingerprint = await Task.detached(priority: .utility) {
                ArtFingerprint.make(fromImageData: thumbnail)?.encoded
            }.value
            // The artwork may have been deleted (重拍) while the render ran: never write to a deleted model.
            guard !Task.isCancelled, Self.isAlive(artwork) else { return }
            artwork.renderedImageData = out.imageData
            artwork.thumbnailData = out.thumbnailData
            artwork.fingerprintData = fingerprint
            artwork.pixelWidth = out.pixelWidth
            artwork.pixelHeight = out.pixelHeight
            artwork.renderVersion += 1
            // Edited while this render ran: the result is already out of date, so keep it owed (.pending) in case
            // the app is closed before the queued re-render runs.
            artwork.processingState = artwork.recipe == recipe ? .done : .pending
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
        let left = isWalkingPending ? pendingArtworks(context: context).count : 0
        let text = left > 0 ? String(localized: "還有 \(left) 張，接著看下一張。")
            : count > 1 ? String(localized: "這是第 \(count) 張，按快門拍下一張。") : String(localized: "按快門，再拍下一張。")
        show(text, style: .hung(count: count), headline: String(localized: "已掛上冰箱！"), seconds: 3.2)
        return true
    }

    /// Quota check shared by keep + save. Already-kept artworks and samples pass freely (idempotent per artwork).
    private func admit(_ artwork: Artwork, action: PaywallRequest.Action) -> Bool {
        if artwork.isSample || artwork.isKept { return true }
        if store.canKeep(kind: artwork.kind, artworkID: artwork.id, isSample: artwork.isSample) { return true }
        paywall = PaywallRequest(kind: artwork.kind, artworkID: artwork.id, action: action)
        return false
    }

    /// `addToSession: false` — 全部存到照片 on old museum artworks doesn't put them on 這次收的作品.
    private func markKept(_ artwork: Artwork, context: ModelContext, addToSession: Bool = true) {
        if !artwork.isKept, !artwork.isSample {
            store.recordKeep(kind: artwork.kind, artworkID: artwork.id)
        }
        if !artwork.isKept {
            artwork.isKept = true
            artwork.keptAt = Date()
        }
        if addToSession, !sessionArtworkIDs.contains(artwork.id) { sessionArtworkIDs.append(artwork.id) }
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
        let resume = saveAllResume
        saveAllResume = nil
        // A 全部存到照片 was waiting on this answer: carry on with this artwork and the rest.
        if let resume, resume.ids.first == id {
            let rest = resume.ids.compactMap { fetchArtwork($0, context: context) }
            Task { await saveAll(rest, context: context, primed: true, addsToSession: resume.addsToSession) }
            return
        }
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
                    artwork.fingerprintData = copy.fingerprintData
                    artwork.pixelWidth = copy.pixelWidth
                    artwork.pixelHeight = copy.pixelHeight
                    artwork.renderVersion += 1
                    artwork.processingState = .done
                    try? context.save()
                }
            }
        }
        // The copy couldn't be stored (rare): render the working copy now rather than leave it until next launch.
        if storeCopy, jpeg != nil, Self.isAlive(artwork), artwork.renderedImageData == nil {
            renderingIDs.remove(id)
            await rerender(artwork, context: context)
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
    /// The final export goes through `exportGate`, so two 4096 px exports never run at once; a single save that comes
    /// in during 全部存到照片 runs right after the batch's current item.
    func saveToPhotos(_ artwork: Artwork, context: ModelContext, quiet: Bool = false, primed: Bool = false,
                      addsToSession: Bool = true) async -> Bool {
        lastSaveDenied = false
        guard admit(artwork, action: .save) else { return false }
        // First album save: explain why full Photos access is useful before iOS asks (PhotosPrimerAlert).
        if !primed, UserDefaults.standard.bool(forKey: Keys.useAlbums), PhotoLibrarySaver.needsAlbumPrimer {
            photosPrimer = PhotosPrimer(artworkID: artwork.id)
            return false
        }
        await exportGate.enter()
        var rendered: Data?
        if Self.isAlive(artwork) { rendered = await finalJPEG(for: artwork, context: context) }
        exportGate.leave()
        guard Self.isAlive(artwork) else { return false }
        guard let jpeg = rendered else {
            if !quiet { show(String(localized: "處理失敗，請重試"), style: .problem) }
            return false
        }
        let useAlbums = UserDefaults.standard.bool(forKey: Keys.useAlbums)
        let album = useAlbums ? (artwork.child?.albumTitle ?? String(localized: "冰箱美術館")) : nil
        do {
            let outcome = try await photos.save(jpeg: jpeg, albumTitle: album, creationDate: artwork.capturedAt)
            artwork.lastSavedToPhotosAt = Date()
            markKept(artwork, context: context, addToSession: addsToSession)
            if !quiet {
                let albumName = album ?? ""
                let detail = outcome.savedToAlbum && !albumName.isEmpty
                    ? String(localized: "已存到相簿「\(albumName)」，也掛上冰箱了。")
                    : String(localized: "已存到照片，也掛上冰箱了。")
                show(detail, style: .hung(count: sessionArtworkIDs.count), headline: String(localized: "已存到手機！"), seconds: 3.2)
            }
            return true
        } catch PhotoSaveError.denied {
            lastSaveDenied = true
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

    /// Saves several artworks, one at a time; stops at the first one the free quota blocks (the paywall shows once)
    /// or when Photos access is missing. If the album explanation comes up, the rest continue once it's answered
    /// (continueSave). `primed`: the explanation was already answered. Progress is in `saveAllProgress`.
    func saveAll(_ artworks: [Artwork], context: ModelContext, primed: Bool = false, addsToSession: Bool = true) async {
        guard saveAllProgress == nil else { return }
        saveAllResume = nil
        let list = artworks.filter { Self.isAlive($0) }
        guard !list.isEmpty else { return }
        saveAllProgress = SaveAllProgress(done: 0, total: list.count)
        var ok = 0
        for (index, a) in list.enumerated() {
            // An open editor (or a burst / import) has the phone: the next 4096 px export waits until it's done.
            while isEditorBusy && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(400)) }
            if Task.isCancelled { break }
            guard Self.isAlive(a) else { continue }
            if await saveToPhotos(a, context: context, quiet: true, primed: primed, addsToSession: addsToSession) {
                ok += 1
                saveAllProgress = SaveAllProgress(done: ok, total: list.count)
            } else if photosPrimer != nil {
                saveAllResume = (ids: list[index...].map(\.id), addsToSession: addsToSession)
                break
            } else if paywall != nil || photosDeniedAlert || lastSaveDenied {
                break
            }
        }
        saveAllProgress = nil
        if ok > 0 { show(String(localized: "已存 \(ok) 張到照片")) }
    }

    // MARK: 備份提醒 (artworks only in the app)

    /// Museum artworks never saved to Photos, oldest first.
    func unsavedMuseumArtworks(context: ModelContext) -> [Artwork] {
        let kept = (try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { $0.isKept && !$0.isSample }))) ?? []
        return kept.filter { Self.isAlive($0) && BackupReminder.needsBackup($0) }
            .sorted { ($0.keptAt ?? $0.createdAt) < ($1.keptAt ?? $1.createdAt) }
    }

    /// 全部存到照片 (home backup card, Settings): every museum artwork not yet in Photos, through the usual save path
    /// (album explanation, Photos access). They stay off 這次收的作品.
    func backUpAll(context: ModelContext) async {
        let list = unsavedMuseumArtworks(context: context)
        guard !list.isEmpty else { return }
        await saveAll(list, context: context, addsToSession: false)
    }

    /// 之後再說: hides the backup card for two weeks.
    func snoozeBackupReminder(now: Date = Date()) {
        let until = BackupReminder.snoozeEnd(from: now)
        backupSnoozedUntil = until
        guard !DemoMode.isActive else { return }
        UserDefaults.standard.set(until, forKey: Keys.backupSnoozedUntil)
    }

    // MARK: 繼續 — step through pending captures (e.g. after 連拍)

    /// The capture 繼續 opens: the oldest pending one (a burst is gone through in the order it was shot). With more
    /// than one pending, each 收進這次 / 存到手機 / 不要這張 in the editor moves on to the next (continuePendingWalk).
    func startPendingWalk(context: ModelContext) -> UUID? {
        let pending = pendingArtworks(context: context)
        let first = Self.nextPending(in: pending, excluding: nil)
        isWalkingPending = pending.count > 1
        return first?.id
    }

    /// The oldest pending capture other than `excluding`.
    static func nextPending(in pending: [Artwork], excluding id: UUID?) -> Artwork? {
        pending.filter { $0.id != id && !$0.isKept && !$0.isSample }.min { $0.createdAt < $1.createdAt }
    }

    /// The editor for `id` closed after keeping, saving or discarding it: open the next pending capture (claimed
    /// before the editor closes, so held exports don't start in between). Returns false when the walk is over.
    @discardableResult
    func continuePendingWalk(after id: UUID, context: ModelContext) -> Bool {
        guard isWalkingPending else { return false }
        guard let next = Self.nextPending(in: pendingArtworks(context: context), excluding: id) else {
            isWalkingPending = false
            return false
        }
        claimEditor(next.id, context: context)
        pendingRoute = .edit(next.id)
        return true
    }

    /// The editor closed some other way (back, 重拍, the paywall's pop): stop stepping.
    func endPendingWalk() {
        isWalkingPending = false
    }

    /// `save: false` lets a batch delete (美術館「選取」) save once at the end.
    func delete(_ artwork: Artwork, context: ModelContext, save: Bool = true) {
        let id = artwork.id
        processTasks.removeValue(forKey: id)?.cancel()
        deferredIDs.remove(id)
        staleIDs.remove(id)
        sessionArtworkIDs.removeAll { $0 == id }
        context.delete(artwork)
        if save { try? context.save() }
        Task { await processor.evict(id: id) }
    }

    /// Captures that were never kept (the home sticky note). Samples are left alone.
    func pendingArtworks(context: ModelContext) -> [Artwork] {
        let all = (try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { !$0.isKept && !$0.isSample }))) ?? []
        return all.filter { Self.isAlive($0) }
    }

    // MARK: 這張好像收過了 (likely duplicates)

    /// A kept museum artwork (not a sample) of the same kind that looks like the same physical piece, or nil.
    /// A match by the same child wins over another child's. Only reads the stored fingerprints (< 1 KB each).
    func likelyDuplicate(of fingerprint: ArtFingerprint, kind: ArtworkKind, childID: UUID?, excluding id: UUID,
                         context: ModelContext) -> Artwork? {
        let kept = (try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { $0.isKept && !$0.isSample }))) ?? []
        let sameKind = kept.filter { $0.id != id && $0.kind == kind && Self.isAlive($0) }
        let candidates = sameKind.compactMap { a -> DuplicateFinder.Candidate? in
            guard let fp = ArtFingerprint(data: a.fingerprintData) else { return nil }
            return DuplicateFinder.Candidate(id: a.id, childID: a.child?.id, fingerprint: fp)
        }
        guard let match = DuplicateFinder.bestMatch(for: fingerprint, childID: childID, among: candidates) else { return nil }
        return sameKind.first { $0.id == match }
    }

    @ObservationIgnored private var isBackfillingFingerprints = false

    /// Artworks rendered before fingerprints existed get one from their stored thumbnail (decoded at ≤ 128 px, off
    /// the main actor), one at a time. Run at launch (processUnfinished). Pending captures are included: one rendered
    /// by an older build and kept later would otherwise wait for the next launch.
    /// `.utility`, not `.background`: background-priority jobs only run when the cooperative pool has nothing else
    /// queued, so during renders (or a busy test run) they could be starved for many seconds.
    func backfillFingerprints(context: ModelContext) async {
        guard !isBackfillingFingerprints else { return }
        let all = (try? context.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { !$0.isSample }))) ?? []
        let missing = all.filter { ArtFingerprint(data: $0.fingerprintData) == nil }
        guard !missing.isEmpty else { return }
        isBackfillingFingerprints = true
        defer { isBackfillingFingerprints = false }
        var changed = 0
        for artwork in missing {
            guard Self.isAlive(artwork), let thumbnail = artwork.thumbnailData else { continue }
            let version = artwork.renderVersion
            let fingerprint = await Task.detached(priority: .utility) {
                ArtFingerprint.make(fromImageData: thumbnail)?.encoded
            }.value
            // Skip it if it was deleted or re-rendered meanwhile (the render stored a fresh fingerprint).
            guard let fingerprint, Self.isAlive(artwork), artwork.renderVersion == version else { continue }
            artwork.fingerprintData = fingerprint
            changed += 1
            if changed % 25 == 0 { try? context.save() }
        }
        if changed > 0 { try? context.save() }
    }

    /// 不要了 / 全部不要: deletes every pending (captured, never kept) artwork. Returns how many were deleted.
    @discardableResult
    func discardPending(context: ModelContext) -> Int {
        let pending = pendingArtworks(context: context)
        for artwork in pending { delete(artwork, context: context) }
        return pending.count
    }

    /// 全部收進: hangs every pending capture on the fridge, oldest first, through the same quota gate as 收進這次.
    /// Stops at the first one the free quota blocks (the paywall shows once and resumes that one after an unlock;
    /// the rest stay on the sticky note). Unassigned captures go to `child` (the current capture child).
    /// Returns how many were kept.
    @discardableResult
    func keepAllPending(child: Child?, context: ModelContext) -> Int {
        let pending = pendingArtworks(context: context).sorted { $0.createdAt < $1.createdAt }
        var kept = 0
        for artwork in pending {
            if artwork.child == nil, let child { artwork.child = child }
            guard admit(artwork, action: .keep) else { break }
            markKept(artwork, context: context)
            kept += 1
        }
        try? context.save()
        if kept > 0 {
            show(String(localized: "已把 \(kept) 張掛上冰箱。"), style: .hung(count: sessionArtworkIDs.count),
                 headline: String(localized: "已掛上冰箱！"), seconds: 3.2)
        }
        return kept
    }

    /// The child new captures and imports go to (shown and changeable on the home screen and the camera).
    func setCaptureChild(_ id: UUID?) {
        currentChildID = id
        persistPreferences()
    }
}

/// The stored working copy (≤ 2400 px JPEG + 480 px thumbnail, same sizes and qualities as ImageProcessor.export)
/// made from a larger final export, so 存到手機 on a fresh capture doesn't render twice.
struct StoredRenderCopy: Sendable {
    var imageData: Data
    var thumbnailData: Data
    var pixelWidth: Int
    var pixelHeight: Int
    /// ArtFingerprint of the thumbnail (這張好像收過了).
    var fingerprintData: Data?

    static func make(fromFinalJPEG jpeg: Data) -> StoredRenderCopy? {
        guard let image = ImageMetadata.uprightThumbnail(of: jpeg, maxPixelSize: ImageProcessor.exportMaxEdge),
              let imageData = ImageEncoding.jpegData(image, quality: 0.92),
              let thumb = ImageMetadata.uprightThumbnail(of: jpeg, maxPixelSize: ImageProcessor.thumbnailMaxEdge),
              let thumbnailData = ImageEncoding.jpegData(thumb, quality: 0.8) else { return nil }
        return StoredRenderCopy(imageData: imageData, thumbnailData: thumbnailData,
                                pixelWidth: image.width, pixelHeight: image.height,
                                fingerprintData: ArtFingerprint.make(cgImage: thumb)?.encoded)
    }
}
