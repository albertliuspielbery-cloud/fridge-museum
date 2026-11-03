import Foundation
import SwiftData
import UIKit
import WidgetKit

// 主畫面小工具 (1.3.0), app side: copies up to 24 museum artworks (≤ 600 px JPEG) and widget.json into the App Group
// container for the widget extension (which never opens the database), then reloads the widget timelines.
//
// When: after every SwiftData save in the app (any ModelContext — AppModel's save points, the editors, deletes, sync
// maintenance), throttled to one write per 30 s; once at launch; and right away when the app goes to the background.
// The fetch and all image work run off the main thread on their own ModelContext.
// No App Group container (unsigned simulator builds, a profile without the group) → silently does nothing.

@MainActor
final class WidgetSnapshot {
    static let shared = WidgetSnapshot()

    static let throttle: Duration = .seconds(30)
    /// Short pause before the first write so a burst of saves becomes one write.
    static let coalesce: Duration = .seconds(2)

    private var container: ModelContainer?
    private var observer: NSObjectProtocol?
    private var scheduled: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var lastWrite: ContinuousClock.Instant?
    private var dirty = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    /// Unit-test hosts and screenshot demos leave the widget alone.
    private static var isEnabled: Bool {
        if DemoMode.isActive { return false }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    /// Called once the store is open (RootView). Watches saves and schedules the first write.
    func start(container: ModelContainer) {
        guard Self.isEnabled, self.container == nil else { return }
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in WidgetSnapshot.shared.setNeedsWrite() }
        }
        setNeedsWrite()
    }

    /// A save happened: write within 30 s of the previous write (trailing edge, at most one write per 30 s).
    func setNeedsWrite() {
        guard container != nil else { return }
        dirty = true
        guard scheduled == nil else { return }
        let clock = ContinuousClock()
        var delay = Self.coalesce
        if let lastWrite {
            let wait = lastWrite.advanced(by: Self.throttle) - clock.now
            if wait > delay { delay = wait }
        }
        let wait = delay
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.writeNow()
        }
    }

    /// The app is going to the background: write pending changes now (inside a background task, it takes ~1 s).
    func flush() {
        guard container != nil, dirty else { return }
        scheduled?.cancel()
        scheduled = nil
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WidgetSnapshot") {
                // Called on the main thread when time runs out.
                MainActor.assumeIsolated { WidgetSnapshot.shared.endBackgroundTask() }
            }
        }
        Task {
            await writeNow()
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func writeNow() async {
        scheduled = nil
        // One write at a time; a save during a write schedules another one afterwards.
        if let running { await running.value }
        guard let container, dirty else { return }
        dirty = false
        lastWrite = ContinuousClock().now
        let task = Task.detached(priority: .utility) { WidgetSnapshotWriter.write(container: container) }
        running = Task { _ = await task.value }
        let changed = await task.value
        running = nil
        if changed { WidgetCenter.shared.reloadAllTimelines() }
        if dirty { setNeedsWrite() }
    }
}

/// The actual write. Runs on a background thread with its own ModelContext (models never leave this function).
enum WidgetSnapshotWriter {
    /// Returns true when widget.json changed (the timelines need a reload).
    nonisolated static func write(container: ModelContainer) -> Bool {
        guard let root = WidgetShared.containerURL() else { return false }
        let fm = FileManager.default
        let images = root.appendingPathComponent(WidgetShared.imagesFolderName, isDirectory: true)
        let manifestURL = root.appendingPathComponent(WidgetShared.manifestFileName)
        do {
            try fm.createDirectory(at: images, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Artwork>(predicate: #Predicate<Artwork> { $0.isKept && !$0.isSample })
        guard let artworks = try? context.fetch(descriptor) else { return false }
        var byID: [UUID: Artwork] = [:]
        let candidates = artworks.map { a -> WidgetSelection.Candidate in
            byID[a.id] = a
            return WidgetSelection.Candidate(id: a.id, childName: a.child?.displayName, capturedAt: a.capturedAt,
                                             kind: a.kindRaw, renderVersion: a.renderVersion, isFavorite: a.isFavorite,
                                             isInMuseum: a.isInMuseum)
        }

        let existing = Set((try? fm.contentsOfDirectory(atPath: images.path)) ?? [])
        var written: [WidgetArtwork] = []
        // hasImage writes the file as it goes (only for the ≤ 24 that get in), so "has an image" = "file is there".
        let picked = WidgetSelection.select(candidates) { c in
            let name = WidgetArtwork.imageFileName(id: c.id, renderVersion: c.renderVersion)
            if existing.contains(name) { return true }
            guard let artwork = byID[c.id] else { return false }
            return autoreleasepool { writeImage(for: artwork, to: images.appendingPathComponent(name)) }
        }
        for c in picked {
            written.append(WidgetArtwork(id: c.id, childName: c.childName, capturedAt: c.capturedAt, kind: c.kind,
                                         imageFile: WidgetArtwork.imageFileName(id: c.id, renderVersion: c.renderVersion)))
        }

        let manifest = WidgetManifest(generatedAt: Date(), artworks: written)
        let old = (try? Data(contentsOf: manifestURL)).flatMap(WidgetManifest.decode)
        var changed = old?.artworks != manifest.artworks
        if changed || old == nil {
            guard let data = try? manifest.encoded() else { return false }
            do {
                try data.write(to: manifestURL, options: [.atomic])
            } catch {
                return false
            }
            changed = true
        }
        // Only after widget.json no longer points at them.
        let now = (try? fm.contentsOfDirectory(atPath: images.path)) ?? []
        for name in manifest.staleFiles(in: now) {
            try? fm.removeItem(at: images.appendingPathComponent(name))
        }
        return changed
    }

    /// The finished image (or the thumbnail when there is none yet), upright, ≤ 600 px, as JPEG. Atomic.
    nonisolated private static func writeImage(for artwork: Artwork, to url: URL) -> Bool {
        let edge = WidgetShared.maxImageEdge
        let image = artwork.renderedImageData.flatMap { ImageMetadata.uprightThumbnail(of: $0, maxPixelSize: edge) }
            ?? artwork.thumbnailData.flatMap { ImageMetadata.uprightThumbnail(of: $0, maxPixelSize: edge) }
        guard let image, let jpeg = ImageEncoding.jpegData(image, quality: 0.85) else { return false }
        do {
            try jpeg.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
