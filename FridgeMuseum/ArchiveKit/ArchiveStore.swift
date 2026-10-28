import Foundation
import SwiftData

enum ArchiveStore {
    /// true when the on-disk store couldn't be opened and this session runs on a temporary in-memory store
    /// (RootView shows a warning banner: nothing kept now survives a relaunch).
    @MainActor static private(set) var isTemporary = false

    /// On-device store. CloudKit is explicitly off (`.none`): the app makes no network calls.
    /// (The models stay CloudKit-compatible — optional/defaulted attributes, no unique constraints — for a future sync option.)
    @MainActor
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema([Child.self, Artwork.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Last resort so the app still opens; data will not persist in this session (banner in RootView).
            isTemporary = !inMemory
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [memory])
            } catch {
                fatalError("無法建立資料庫：\(error)")
            }
        }
    }
}
