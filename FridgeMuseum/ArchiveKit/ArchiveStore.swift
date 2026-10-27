import Foundation
import SwiftData

enum ArchiveStore {
    /// On-device store. CloudKit is explicitly off (`.none`): the app makes no network calls.
    @MainActor
    static func makeContainer() -> ModelContainer {
        let schema = Schema([Child.self, Artwork.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Last resort so the app still opens; data will not persist in this session.
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return try ModelContainer(for: schema, configurations: [memory])
            } catch {
                fatalError("無法建立資料庫：\(error)")
            }
        }
    }
}
