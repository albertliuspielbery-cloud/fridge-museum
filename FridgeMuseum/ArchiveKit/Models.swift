import Foundation
import SwiftData

// SwiftData models. CloudKit-compatible (1.2.0 iCloud sync, ArchiveStore + App/CloudSync.swift), checked against the
// NSPersistentCloudKitContainer rules: every attribute optional or defaulted, no @Attribute(.unique), every
// relationship optional with an inverse and no .deny delete rule, no ordered relationships. Images use .externalStorage
// (CloudKit assets). Small binary attributes (recipeData, fingerprintData < 1 KB) stay well under the 1 MB record limit.
// Adding attributes later is fine (defaulted → lightweight migration; CloudKit only ever adds fields), but never rename or
// delete one once the schema is deployed to the CloudKit Production environment.

enum ProcessingState: String, Codable, Sendable {
    case pending, processing, done, failed
}

@Model
final class Child {
    var id: UUID = UUID()
    var name: String = ""
    var birthday: Date?
    var avatarColorHex: String = "#2F5BFF"
    /// Optional photo avatar: a small square JPEG (≤ 512 px, made by `AvatarImage.make`). nil = the colour circle.
    @Attribute(.externalStorage) var avatarImageData: Data?
    var createdAt: Date = Date()
    /// The device that created this profile (`DeviceIdentity`); "" = made before 1.2.0 and not stamped yet.
    /// Only used to resolve copies that arrive from several devices (SyncDedupe).
    var originDeviceID: String = ""
    /// Last edit of the profile (name, birthday, colour, avatar) — `touch()`; nil = not edited since 1.2.0. Decides
    /// whose edits win when two devices' copies are merged (SyncDedupe).
    var modifiedAt: Date?

    // Nullify: removing a child profile keeps the artworks (they become 未分類).
    @Relationship(deleteRule: .nullify, inverse: \Artwork.child)
    var artworks: [Artwork]? = []

    init(name: String, birthday: Date? = nil, avatarColorHex: String = "#2F5BFF") {
        self.id = UUID()
        self.name = name
        self.birthday = birthday
        self.avatarColorHex = avatarColorHex
        self.createdAt = Date()
        self.originDeviceID = DeviceIdentity.storedID
        self.modifiedAt = Date()
    }

    /// Marks an edit (SyncDedupe keeps the newer copy's values).
    func touch() { modifiedAt = Date() }

    var displayName: String { name.isEmpty ? String(localized: "小朋友") : name }
    var albumTitle: String { String(localized: "冰箱美術館 – \(displayName)") }
}

@Model
final class Artwork {
    var id: UUID = UUID()
    var child: Child?
    var createdAt: Date = Date()
    /// Date the artwork was made / photographed (editable in 資料).
    var capturedAt: Date = Date()
    var title: String = ""
    var note: String = ""
    var kindRaw: String = ArtworkKind.flat.rawValue
    /// JSON-encoded ProcessingRecipe.
    var recipeData: Data?
    var processingStateRaw: String = ProcessingState.pending.rawValue
    /// Bumped after every re-render (thumbnail cache key).
    var renderVersion: Int = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0

    // Categorization
    var tags: [String] = []
    var isFavorite: Bool = false
    /// 用什麼做的 (placard "medium"), e.g. 蠟筆、紙. Empty = default for the kind.
    var medium: String = ""

    // Lifecycle
    /// false while the artwork is still in the editor after capture (「上一張還沒收進」); true once hung on the fridge
    /// (收進這次) or saved to Photos. Defaults to true so artworks from older builds stay in the museum.
    var isKept: Bool = true
    var keptAt: Date?
    /// One of the bundled sample photos (看範例). Never counts toward the free quota and never shows in the museum.
    var isSample: Bool = false

    // Files
    @Attribute(.externalStorage) var originalImageData: Data?
    @Attribute(.externalStorage) var renderedImageData: Data?
    @Attribute(.externalStorage) var thumbnailData: Data?
    /// Perceptual fingerprint of the finished image (`ArtFingerprint.encoded`, under 1 KB) for 這張好像收過了.
    /// Set with every render; artworks from 1.0.1 and earlier get one from their thumbnail at the next launch.
    var fingerprintData: Data?

    // Voice note
    @Attribute(.externalStorage) var voiceNoteData: Data?
    var voiceTranscript: String = ""

    // Photos
    var lastSavedToPhotosAt: Date?

    // iCloud sync (1.2.0)
    /// The device that captured it (`DeviceIdentity`); "" = made before 1.2.0 and not stamped yet. A pending capture
    /// (isKept == false) belongs to that device: other devices leave it alone (SyncOrigin.ownsPending).
    var originDeviceID: String = ""
    /// Last edit by the parent (recipe, placard, tags, favorite, child, voice note, kept) — `touch()`; nil = not
    /// edited since 1.2.0. Decides whose edits win when two devices' copies are merged (SyncDedupe).
    var modifiedAt: Date?

    init(kind: ArtworkKind, child: Child?, capturedAt: Date, originalImageData: Data) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.child = child
        self.createdAt = Date()
        self.capturedAt = capturedAt
        self.originalImageData = originalImageData
        self.recipeData = try? ProcessingRecipe.default(for: kind).encoded()
        self.originDeviceID = DeviceIdentity.storedID
        self.modifiedAt = Date()
    }

    /// Marks an edit (SyncDedupe keeps the newer copy's values).
    func touch() { modifiedAt = Date() }

    var kind: ArtworkKind {
        get { ArtworkKind(rawValue: kindRaw) ?? .flat }
        set { kindRaw = newValue.rawValue }
    }

    var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .pending }
        set { processingStateRaw = newValue.rawValue }
    }

    var recipe: ProcessingRecipe {
        get {
            if let d = recipeData, let r = try? ProcessingRecipe.decode(d) { return r }
            return .default(for: kind)
        }
        set { recipeData = try? newValue.encoded() }
    }

    var ageAtCreation: ChildAge? {
        guard let b = child?.birthday else { return nil }
        return AgeCalculator.age(birthday: b, at: capturedAt)
    }

    var schoolTerm: SchoolTerm { SchoolTerm.of(capturedAt) }

    var gradeLabel: String? {
        guard let b = child?.birthday else { return nil }
        return schoolTerm.gradeLabel(birthday: b)
    }

    /// Shown in the museum (kept, not a sample).
    var isInMuseum: Bool { isKept && !isSample }
}

enum TagSuggestions {
    static let common = ["家人", "動物", "節日", "母親節", "父親節", "生日", "學校", "自畫像", "風景", "恐龍", "交通工具", "聖誕節", "過年", "花草"]

    /// Normalizes user input: trims, drops "#", collapses whitespace.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") || s.hasPrefix("＃") { s.removeFirst() }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.isEmpty ? nil : String(s.prefix(20))
    }
}
