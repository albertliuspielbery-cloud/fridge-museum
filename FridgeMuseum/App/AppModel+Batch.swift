import Foundation
import SwiftData

/// 美術館「選取」: change several artworks at once (child, tags, date, ⭐, delete). Each call skips artworks that were
/// deleted meanwhile, saves the context once and returns how many artworks it changed.
extension AppModel {
    @discardableResult
    func batchEdit(_ artworks: [Artwork], context: ModelContext, _ change: (Artwork) -> Void) -> Int {
        var count = 0
        for artwork in artworks where Self.isAlive(artwork) {
            let before = ArtworkEdits(artwork)
            change(artwork)
            // Only a real change counts as an edit (e.g. 加標籤 with tags it already has doesn't).
            if ArtworkEdits(artwork) != before { artwork.touch() }
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

    /// 轉向: turns every artwork a quarter turn (recipe.quarterTurns, both kinds) — e.g. to fix photos that came out
    /// sideways. Marks the automatic upright check as done so it never undoes the turn, and queues the re-renders
    /// through the deferred drain (one at a time, oldest first — never all at once).
    @discardableResult
    func rotateAll(_ artworks: [Artwork], clockwise: Bool, context: ModelContext) -> Int {
        let alive = artworks.filter { Self.isAlive($0) }
        for artwork in alive {
            artwork.recipe = Self.turned(artwork.recipe, clockwise: clockwise)
            artwork.touch()
        }
        guard !alive.isEmpty else { return 0 }
        try? context.save()
        for artwork in alive { renderLater(artwork, context: context, stale: true) }
        return alive.count
    }

    /// One quarter turn, with the automatic upright check settled (left as it was if it already ran).
    static func turned(_ recipe: ProcessingRecipe, clockwise: Bool) -> ProcessingRecipe {
        var r = recipe
        if clockwise { r.rotateClockwise() } else { r.rotateCounterClockwise() }
        if r.autoTurns == nil { r.autoTurns = 0 }
        return r
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
