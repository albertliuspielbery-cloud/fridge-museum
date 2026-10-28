import Foundation
import SwiftData

/// 美術館「選取」: change several artworks at once (child, tags, date, ⭐, delete). Each call skips artworks that were
/// deleted meanwhile, saves the context once and returns how many artworks it changed.
extension AppModel {
    @discardableResult
    func batchEdit(_ artworks: [Artwork], context: ModelContext, _ change: (Artwork) -> Void) -> Int {
        var count = 0
        for artwork in artworks where Self.isAlive(artwork) {
            change(artwork)
            count += 1
        }
        if count > 0 { try? context.save() }
        return count
    }

    /// 設定孩子. `nil` = 未分類.
    @discardableResult
    func assignChild(_ child: Child?, to artworks: [Artwork], context: ModelContext) -> Int {
        batchEdit(artworks, context: context) { $0.child = child }
    }

    /// 加標籤: adds each tag (normalized like the tag editor) that an artwork doesn't have yet. Existing tags stay.
    @discardableResult
    func addTags(_ tags: [String], to artworks: [Artwork], context: ModelContext) -> Int {
        var clean: [String] = []
        for raw in tags {
            if let t = TagSuggestions.normalize(raw), !clean.contains(t) { clean.append(t) }
        }
        guard !clean.isEmpty else { return 0 }
        return batchEdit(artworks, context: context) { a in
            var list = a.tags
            for t in clean where !list.contains(t) { list.append(t) }
            if list != a.tags { a.tags = list }
        }
    }

    /// 日期: sets the date made (capturedAt), which also moves the artwork's 學期 and 年齡.
    @discardableResult
    func setCapturedAt(_ date: Date, for artworks: [Artwork], context: ModelContext) -> Int {
        batchEdit(artworks, context: context) { $0.capturedAt = date }
    }

    /// 最愛 on / off.
    @discardableResult
    func setFavorite(_ on: Bool, for artworks: [Artwork], context: ModelContext) -> Int {
        batchEdit(artworks, context: context) { $0.isFavorite = on }
    }

    /// 刪除: deletes them all (same bookkeeping as a single delete), saving once.
    @discardableResult
    func deleteAll(_ artworks: [Artwork], context: ModelContext) -> Int {
        let alive = artworks.filter { Self.isAlive($0) }
        for artwork in alive { delete(artwork, context: context, save: false) }
        if !alive.isEmpty { try? context.save() }
        return alive.count
    }
}
