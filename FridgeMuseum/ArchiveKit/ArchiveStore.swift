import Foundation
import SwiftData

enum ArchiveStore {
    /// true when the on-disk store couldn't be opened and this session runs on a temporary in-memory store
    /// (RootView shows a warning banner: nothing kept now survives a relaunch).
    @MainActor static private(set) var isTemporary = false

    static var schema: Schema { Schema([Child.self, Artwork.self]) }

    /// On-device store without sync (`cloudKitDatabase: .none`). Unit tests and screenshot demos use this.
    @MainActor
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        open(inMemory: inMemory, cloudKitContainerID: nil).container
    }

    /// Opens the store once per launch (CloudSync.openStore decides which way).
    /// - `cloudKitContainerID` nil: `cloudKitDatabase: .none` — no network, exactly like 1.0–1.1.
    /// - set: `.private(id)` — NSPersistentCloudKitContainer mirrors the store to the person's private iCloud database.
    ///
    /// Both use the same default configuration name, so they open the **same file** (Application Support/default.store):
    /// turning sync on uploads the artworks already there, turning it off keeps them all (the store simply isn't
    /// mirrored that launch). Never call this twice in one launch — two containers must not share the file.
    /// If the CloudKit store can't be opened (e.g. the build lacks the iCloud entitlement), the same file is opened
    /// without sync; `isCloud` tells which one it is.
    @MainActor
    static func open(inMemory: Bool = false, cloudKitContainerID: String?) -> (container: ModelContainer, isCloud: Bool) {
        let schema = Self.schema
        if let id = cloudKitContainerID, !inMemory {
            let cloud = configuration(schema: schema, cloudKitContainerID: id)
            if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
                return (container, true)
            }
        }
        let config = configuration(schema: schema, inMemory: inMemory, cloudKitContainerID: nil)
        do {
            return (try ModelContainer(for: schema, configurations: [config]), false)
        } catch {
            // Last resort so the app still opens; data will not persist in this session (banner in RootView).
            isTemporary = !inMemory
            let memory = configuration(schema: schema, inMemory: true, cloudKitContainerID: nil)
            do {
                return (try ModelContainer(for: schema, configurations: [memory]), false)
            } catch {
                fatalError("無法建立資料庫：\(error)")
            }
        }
    }

    /// The store configuration with or without iCloud mirroring. Same (default) name either way → same file
    /// (CloudSyncTests checks the URLs match).
    static func configuration(schema: Schema, inMemory: Bool = false, cloudKitContainerID: String?) -> ModelConfiguration {
        if let id = cloudKitContainerID {
            return ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .private(id))
        }
        return ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
    }
}

// MARK: - 家庭美術館 (1.3.0)

/// The family museum's store: a second file next to the personal one (Application Support/family.store), always
/// `cloudKitDatabase: .none` — FamilySync talks to CloudKit itself (SwiftData can't mirror a shared database).
///
/// Data safety: the personal store is never deleted or emptied by anything here. Entering a family museum *copies*
/// the personal works into family.store; leaving copies the family works back. The copies use a short-lived second
/// container on the *other* file (never a second container on the file this launch has open), and the only
/// destructive helper, `resetFamilyStore`, refuses to run on the personal store's URL.
extension ArchiveStore {
    enum FamilyStoreError: Error {
        /// The family URL resolved to the personal store's URL (never expected; nothing is touched).
        case wouldTouchPersonalStore
    }

    /// The personal store's file (the default configuration: Application Support/default.store).
    static var personalStoreURL: URL {
        configuration(schema: schema, cloudKitContainerID: nil).url
    }

    /// family.store, next to the personal store.
    static var familyStoreURL: URL {
        personalStoreURL.deletingLastPathComponent().appendingPathComponent("family.store")
    }

    /// A different configuration name *and* an explicit, different URL from the personal store (FamilySyncTests
    /// checks the two never resolve to the same file).
    static func familyConfiguration(schema: Schema, url: URL? = nil) -> ModelConfiguration {
        ModelConfiguration("family", schema: schema, url: url ?? familyStoreURL, cloudKitDatabase: .none)
    }

    /// Opens family.store as this launch's only store (FamilySync decided this launch is a family launch).
    /// Falls back to an in-memory store like `open` (isTemporary → FamilySync never syncs that session).
    @MainActor
    static func openFamily() -> ModelContainer {
        let schema = Self.schema
        if let container = try? ModelContainer(for: schema, configurations: [familyConfiguration(schema: schema)]) {
            return container
        }
        isTemporary = true
        let memory = configuration(schema: schema, inMemory: true, cloudKitContainerID: nil)
        do {
            return try ModelContainer(for: schema, configurations: [memory])
        } catch {
            fatalError("無法建立資料庫：\(error)")
        }
    }

    /// A short-lived container on the personal file without iCloud mirroring, used only to copy the family works
    /// back while family.store is this launch's store (the personal file isn't open in a family launch).
    /// `url` is for tests.
    @MainActor
    static func openPersonalForCopy(url: URL? = nil) throws -> ModelContainer {
        let schema = Self.schema
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? configuration(schema: schema, cloudKitContainerID: nil)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// A short-lived container on family.store, used while the personal store is this launch's store.
    @MainActor
    static func openFamilyForCopy(url: URL? = nil) throws -> ModelContainer {
        let schema = Self.schema
        return try ModelContainer(for: schema, configurations: [familyConfiguration(schema: schema, url: url)])
    }

    /// Empties family.store before a new family museum fills it (the previous family's works were copied back to
    /// the personal store when it ended, or the person chose not to keep them). Refuses the personal store's URL.
    @MainActor
    static func resetFamilyStore(url: URL? = nil, personalURL: URL? = nil) throws {
        let target = url ?? familyStoreURL
        guard target.standardizedFileURL != (personalURL ?? personalStoreURL).standardizedFileURL else {
            throw FamilyStoreError.wouldTouchPersonalStore
        }
        let container = try openFamilyForCopy(url: target)
        let context = ModelContext(container)
        for artwork in try context.fetch(FetchDescriptor<Artwork>()) { context.delete(artwork) }
        for child in try context.fetch(FetchDescriptor<Child>()) { context.delete(child) }
        try context.save()
    }

    /// Copies the museum (children + artworks with `isKept && !isSample`) from `source` into `target`, keeping
    /// every id, so copying twice never makes duplicates. A record already in `target` is only updated when the
    /// source copy was edited later (`modifiedAt`); nothing in `target` is ever deleted, and `source` is only read.
    /// Works in small batches with a fresh context each (images stay out of memory), yielding between batches.
    /// Returns how many artworks were added or updated.
    @MainActor @discardableResult
    static func copyMuseum(from source: ModelContainer, to target: ModelContainer) async throws -> Int {
        let batch = 8
        // Children first, so artworks can point at them.
        do {
            let read = ModelContext(source)
            let write = ModelContext(target)
            write.autosaveEnabled = false
            let existing = Dictionary(try write.fetch(FetchDescriptor<Child>()).map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
            for child in try read.fetch(FetchDescriptor<Child>(sortBy: [SortDescriptor(\.createdAt)])) {
                let fields = FamilyChildFields(child)
                if let mine = existing[child.id] {
                    if isNewer(fields.modifiedAt, than: mine.modifiedAt) { fields.apply(to: mine) }
                } else {
                    let copy = Child(name: fields.name)
                    write.insert(copy)
                    fields.apply(to: copy)
                }
            }
            try write.save()
        }

        let museum = #Predicate<Artwork> { $0.isKept && !$0.isSample }
        let total = try ModelContext(source).fetchCount(FetchDescriptor<Artwork>(predicate: museum))
        var copied = 0
        var offset = 0
        while offset < total {
            var page = FetchDescriptor<Artwork>(predicate: museum, sortBy: [SortDescriptor(\.createdAt)])
            page.fetchOffset = offset
            page.fetchLimit = batch
            let read = ModelContext(source)
            let write = ModelContext(target)
            write.autosaveEnabled = false
            let artworks = try read.fetch(page)
            if artworks.isEmpty { break }
            for artwork in artworks {
                let id = artwork.id
                let mine = try write.fetch(FetchDescriptor<Artwork>(predicate: #Predicate { $0.id == id })).first
                if let mine, !isNewer(artwork.modifiedAt, than: mine.modifiedAt) { continue }
                var child: Child?
                if let childID = artwork.child?.id {
                    child = try write.fetch(FetchDescriptor<Child>(predicate: #Predicate { $0.id == childID })).first
                }
                let destination: Artwork
                if let mine {
                    destination = mine
                } else {
                    destination = Artwork(kind: artwork.kind, child: nil, capturedAt: artwork.capturedAt, originalImageData: Data())
                    write.insert(destination)
                }
                FamilyArtworkFields(artwork).apply(to: destination, child: child)
                // A fact about this phone rather than a shared field, but it belongs with a copy made on this phone.
                destination.lastSavedToPhotosAt = artwork.lastSavedToPhotosAt
                copied += 1
            }
            try write.save()
            offset += artworks.count
            await Task.yield()
        }
        return copied
    }

    /// `a` is a later edit than `b` (an unstamped record counts as the oldest).
    nonisolated static func isNewer(_ a: Date?, than b: Date?) -> Bool {
        switch (a, b) {
        case let (a?, b?): return a.timeIntervalSince(b) >= FamilySyncPolicy.timeTolerance
        case (.some, nil): return true
        default: return false
        }
    }
}
