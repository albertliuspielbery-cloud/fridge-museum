import Foundation

/// 找重複作品 (1.4.0): when the parent keeps one of two look-alike artworks, the one kept takes over what only the
/// other had, so choosing never loses a title, a note, tags, a voice note, a favourite or the child.
enum DuplicateMerge {
    @MainActor
    static func fill(_ keeper: Artwork, from other: Artwork) {
        if keeper.title.trimmingCharacters(in: .whitespaces).isEmpty { keeper.title = other.title }
        if keeper.note.trimmingCharacters(in: .whitespaces).isEmpty { keeper.note = other.note }
        if keeper.medium.isEmpty { keeper.medium = other.medium }
        for tag in other.tags where !keeper.tags.contains(tag) { keeper.tags.append(tag) }
        for tag in other.autoTags where !keeper.autoTags.contains(tag) { keeper.autoTags.append(tag) }
        if keeper.voiceNoteData == nil, let voice = other.voiceNoteData {
            keeper.voiceNoteData = voice
            keeper.voiceTranscript = other.voiceTranscript
        }
        if other.isFavorite { keeper.isFavorite = true }
        if keeper.child == nil, let child = other.child { keeper.child = child }
        if let saved = other.lastSavedToPhotosAt, keeper.lastSavedToPhotosAt.map({ saved > $0 }) ?? true {
            keeper.lastSavedToPhotosAt = saved
        }
        keeper.touch()
    }
}

/// 不是重複: pairs the parent dismissed, remembered on this device only (no schema change).
enum DuplicateIgnoreList {
    static let key = "notDuplicatePairs"

    static func load(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func add(_ pair: DuplicateFinder.Pair, _ defaults: UserDefaults = .standard) {
        var all = load(defaults)
        all.insert(pair.key)
        defaults.set(Array(all), forKey: key)
    }
}
