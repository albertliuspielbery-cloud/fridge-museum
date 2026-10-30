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
