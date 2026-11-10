import CloudKit
import Foundation
import SwiftData

// 家庭美術館 (1.3.0) — one museum shared by several Apple Accounts through a zone-wide CKShare (PLAN-1.3.md §A).
// Everything here is pure (or plain SwiftData / CKRecord value mapping) so FamilySyncTests can cover it without
// CloudKit: which store a launch opens, which records qualify, what changed locally, who wins a conflict, and how a
// Child / Artwork maps to record fields. The network side (CKSyncEngine, sharing, accepting) is App/FamilySync.swift.

// MARK: - Mode (decided once per launch)

enum FamilyRole: String, Codable, Equatable, Sendable {
    /// Created the family museum: the records live in a custom zone of *their* private database.
    case owner
    /// Joined through an invitation: the same zone, seen through their shared database.
    case member
}

/// Why a family museum ended on this phone. Every end copies the family works back into the personal museum (or
/// offers to, when the person leaves on purpose) — nothing is ever deleted from the personal store.
enum FamilyEndReason: String, Codable, Equatable, Sendable {
    /// The member chose 離開家庭美術館.
    case left
    /// The owner chose 停止分享.
    case stopped
    /// The owner stopped sharing or removed this member (the shared zone disappeared).
    case revoked
    /// The iCloud account signed out or changed while the family museum was open.
    case accountChanged
}

/// This phone's membership, saved in UserDefaults (FamilySync.Keys.membership).
struct FamilyMembership: Codable, Equatable, Sendable {
    var role: FamilyRole
    /// The zone owner's CloudKit user record name (`CKCurrentUserDefaultName` for the owner themselves).
    var zoneOwnerName: String
    /// 「○○ 的家庭美術館」 for members; nil for the owner.
    var ownerDisplayName: String?
    var joinedAt: Date
    /// Set when the family museum ended but the family works haven't been copied into the personal store yet
    /// (the copy is retried at every launch until it succeeds; only then is the membership cleared).
    var pendingEnd: FamilyEndReason?
    /// 停止分享 started but didn't finish (copy back or zone deletion failed, e.g. offline, or the system sharing
    /// screen already removed the share): the next family launch resumes it, so the owner never stays half-stopped.
    var stopRequested: Bool?
}

/// Which store this launch opens. Exactly one: switching takes effect at the next launch (same reason as 1.2 —
/// nothing in the running session may still hold the other container).
enum MuseumMode: Equatable, Sendable {
    /// Application Support/default.store, opened the 1.2 way (iCloud sync or not, CloudSync decides).
    case personal
    /// family.store, synced with the shared zone.
    case family(FamilyRole)
    /// family.store without sync, only to finish copying the family works into the personal store.
    case closingFamily(FamilyEndReason)

    var opensFamilyStore: Bool { self != .personal }
}

enum FamilySyncPolicy {
    static let zoneName = "FamilyMuseum"
    static let childRecordType = "FMChild"
    static let artworkRecordType = "FMArtwork"

    /// Two timestamps closer than this are the same edit: CloudKit keeps milliseconds, SwiftData keeps more.
    static let timeTolerance: TimeInterval = 0.01

    /// Deletions of records this phone hasn't seen in the store during this session (a store that opened empty or
    /// broken looks exactly like that) are held back when they would remove at least this many records *and* more
    /// than half of everything uploaded — they would empty every family phone. Deletions of records seen earlier
    /// this session (the person deleted them, or they left the museum) always go through.
    static let massDeleteGuard = 3

    /// Simulator, screenshot demos and unit tests (`isSupported` false) never open the family store, whatever is
    /// saved — CloudKit is never touched there.
    static func mode(isSupported: Bool, membership: FamilyMembership?) -> MuseumMode {
        guard isSupported, let membership else { return .personal }
        if let end = membership.pendingEnd { return .closingFamily(end) }
        return .family(membership.role)
    }

    /// Only artworks hung in the museum are shared; a capture still being edited stays on the phone that took it,
    /// and the bundled samples never leave the phone.
    static func qualifies(isKept: Bool, isSample: Bool) -> Bool {
        isKept && !isSample
    }

    /// Creating a family museum needs the Full Version bought on this Apple Account (a family member's free access
    /// doesn't count), a build that can use CloudKit, and no family museum on this phone yet.
    static func canCreate(isPurchased: Bool, isSupported: Bool, membership: FamilyMembership?) -> Bool {
        isPurchased && isSupported && membership == nil
    }

    /// In a family museum everyone has the Full Version features (the owner's purchase covers the family).
    static func grantsFullVersion(mode: MuseumMode) -> Bool {
        if case .family = mode { return true }
        return false
    }
}

// MARK: - Local changes against the uploaded-state table

enum FamilyRecordKind: String, Codable, Equatable, Sendable {
    case child
    case artwork

    var recordType: String {
        self == .child ? FamilySyncPolicy.childRecordType : FamilySyncPolicy.artworkRecordType
    }

    init?(recordType: String) {
        switch recordType {
        case FamilySyncPolicy.childRecordType: self = .child
        case FamilySyncPolicy.artworkRecordType: self = .artwork
        default: return nil
        }
    }
}

/// The version of one record: what was last uploaded (or downloaded), or what the store holds now.
struct FamilyStamp: Codable, Equatable, Sendable {
    var kind: FamilyRecordKind
    var modifiedAt: Date?
    /// Bumped by every re-render (artworks only; children use 0).
    var renderVersion: Int = 0

    /// Same edit, allowing for CloudKit's millisecond timestamps.
    func isSameVersion(as other: FamilyStamp) -> Bool {
        guard kind == other.kind, renderVersion == other.renderVersion else { return false }
        switch (modifiedAt, other.modifiedAt) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < FamilySyncPolicy.timeTolerance
        default: return false
        }
    }
}

/// One qualifying record in the family store, read with small fields only (the scan never loads images).
struct FamilyLocalItem: Equatable, Sendable {
    var id: UUID
    var stamp: FamilyStamp
    /// false while a render is running or waiting: the record stays (no deletion) but uploads after the render, so
    /// the family gets the finished image once instead of the original twice.
    var isReady: Bool = true

    var recordName: String { id.uuidString }
}

struct FamilyChanges: Equatable, Sendable {
    /// Record names to upload (new or changed since the last upload).
    var saves: [String] = []
    /// Record names that were uploaded but are no longer in the store (deleted, or no longer in the museum).
    var deletes: [String] = []
    /// Deletions were held back by `massDeleteGuard`.
    var heldBackDeletes = false

    var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
}

/// What this phone knows about the shared zone, saved next to the CKSyncEngine state (FamilySync).
struct FamilySyncState: Codable, Equatable, Sendable {
    /// The last version uploaded or downloaded, per record name.
    var uploaded: [String: FamilyStamp] = [:]
    /// CKRecord system fields (encoded) per record name, so the next save carries the server's change tag.
    var systemFields: [String: Data] = [:]
    /// Artworks whose child hasn't arrived yet: artwork record name → child record name.
    var awaitingChild: [String: String] = [:]
    /// Server records that arrived with an asset file that couldn't be read: not applied (that would wipe the image
    /// here and, with the next edit, for the whole family); fetched again directly (FamilySync.refetch).
    var refetch: Set<String> = []

    init() {}

    /// Missing keys decode as empty (state files written by earlier builds).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uploaded = try c.decodeIfPresent([String: FamilyStamp].self, forKey: .uploaded) ?? [:]
        systemFields = try c.decodeIfPresent([String: Data].self, forKey: .systemFields) ?? [:]
        awaitingChild = try c.decodeIfPresent([String: String].self, forKey: .awaitingChild) ?? [:]
        refetch = try c.decodeIfPresent(Set<String>.self, forKey: .refetch) ?? []
    }
}

extension FamilySyncPolicy {
    /// Compares the store with the uploaded-state table. `seenThisSession`: record names found in the store by an
    /// earlier scan this session (see `massDeleteGuard`).
    static func changes(local: [FamilyLocalItem], uploaded: [String: FamilyStamp],
                        seenThisSession: Set<String> = []) -> FamilyChanges {
        var result = FamilyChanges()
        var present = Set<String>()
        for item in local {
            let name = item.recordName
            present.insert(name)
            guard item.isReady else { continue }
            if let last = uploaded[name], last.isSameVersion(as: item.stamp) { continue }
            result.saves.append(name)
        }
        result.saves.sort()
        let missing = uploaded.keys.filter { !present.contains($0) }.sorted()
        let known = missing.filter { seenThisSession.contains($0) }
        let unknown = missing.filter { !seenThisSession.contains($0) }
        if unknown.count >= massDeleteGuard && unknown.count * 2 > uploaded.count {
            result.heldBackDeletes = true
            result.deletes = known
        } else {
            result.deletes = missing
        }
        return result
    }

    /// Records in the store that the family doesn't have yet (never uploaded, or changed since), including ones
    /// still rendering. Leaving copies these into the personal store even when the person chose not to keep the
    /// family works: they may exist nowhere else.
    static func unsent(local: [FamilyLocalItem], uploaded: [String: FamilyStamp]) -> [String] {
        local.filter { item in
            guard let last = uploaded[item.recordName] else { return true }
            return !last.isSameVersion(as: item.stamp)
        }.map(\.recordName).sorted()
    }

    enum IncomingAction: Equatable, Sendable {
        /// Write the server's version into the store.
        case apply
        /// Keep this phone's newer edit and upload it on top of the server's version.
        case keepLocal
        /// The server's version wins but an asset couldn't be read: change nothing here, fetch the record again.
        case refetch
    }

    /// What to do with a server record once the winner is known. A record with an unreadable asset is never applied
    /// — not even partly — because a missing image would be read as "no image" and uploaded with the next edit.
    static func incomingAction(winner: Winner, hasUnreadableAssets: Bool) -> IncomingAction {
        switch winner {
        case .local: return .keepLocal
        case .server: return hasUnreadableAssets ? .refetch : .apply
        }
    }

    enum Winner: Equatable, Sendable {
        case local
        case server
    }

    /// A save came back `serverRecordChanged`: the newer edit wins (as in 1.2 SyncDedupe); a tie goes to the server.
    static func resolveConflict(localModifiedAt: Date?, serverModifiedAt: Date?) -> Winner {
        switch (localModifiedAt, serverModifiedAt) {
        case let (l?, s?):
            return l.timeIntervalSince(s) >= timeTolerance ? .local : .server
        case (.some, nil):
            return .local
        default:
            return .server
        }
    }

    /// A downloaded record for something the store may already hold. Without an edit made here since the last
    /// upload the server's version is taken as is (clocks on two phones can disagree; an untouched record must
    /// follow the family). With one, the newer edit wins.
    static func resolveIncoming(local: FamilyStamp?, uploaded: FamilyStamp?, server: FamilyStamp) -> Winner {
        guard let local else { return .server }
        if let uploaded, local.isSameVersion(as: uploaded) { return .server }
        return resolveConflict(localModifiedAt: local.modifiedAt, serverModifiedAt: server.modifiedAt)
    }

    /// Someone else deleted a record. An edit made here since the last upload keeps it (it is uploaded again);
    /// otherwise the family store follows.
    static func resolveIncomingDeletion(local: FamilyStamp?, uploaded: FamilyStamp?) -> Winner {
        guard let local else { return .server }
        guard let uploaded else { return .local }
        return local.isSameVersion(as: uploaded) ? .server : .local
    }
}

// MARK: - Status (Settings)

enum FamilyStatus: Equatable, Sendable {
    /// Personal museum, no family museum on this phone.
    case off
    /// Created or joined this session: the family museum opens at the next launch.
    case willOpenNextLaunch
    /// Ended this session (or copying back): the personal museum opens at the next launch.
    case willCloseNextLaunch(FamilyEndReason)
    case starting
    case syncing
    case synced
    case waitingForNetwork
    case quotaFull
    case notSignedIn
    case failed
}

extension FamilySyncPolicy {
    static func status(mode: MuseumMode, membership: FamilyMembership?, endedThisSession: FamilyEndReason?,
                       activity: SyncActivity, hasSynced: Bool) -> FamilyStatus {
        if let endedThisSession { return .willCloseNextLaunch(endedThisSession) }
        switch mode {
        case .personal:
            guard let membership else { return .off }
            if let end = membership.pendingEnd { return .willCloseNextLaunch(end) }
            return .willOpenNextLaunch
        case .closingFamily(let reason):
            return .willCloseNextLaunch(reason)
        case .family:
            switch activity {
            case .syncing: return .syncing
            case .failed(.network): return .waitingForNetwork
            case .failed(.quotaFull): return .quotaFull
            case .failed(.notSignedIn): return .notSignedIn
            case .failed(.other): return .failed
            case .idle: return hasSynced ? .synced : .starting
            }
        }
    }
}

// MARK: - Record fields

/// The shared fields of a Child (everything but local bookkeeping).
struct FamilyChildFields: Equatable, Sendable {
    var id: UUID
    var name: String = ""
    var birthday: Date?
    var avatarColorHex: String = "#2F5BFF"
    var avatarImageData: Data?
    var createdAt: Date = Date()
    var originDeviceID: String = ""
    var modifiedAt: Date?

    var stamp: FamilyStamp { FamilyStamp(kind: .child, modifiedAt: modifiedAt, renderVersion: 0) }
}

/// The shared fields of an Artwork. Not shared: `isKept` / `isSample` (only museum artworks are shared, so always
/// true / false) and `lastSavedToPhotosAt` (whether *this* phone saved it to Photos).
struct FamilyArtworkFields: Equatable, Sendable {
    var id: UUID
    var childID: UUID?
    var createdAt: Date = Date()
    var capturedAt: Date = Date()
    var title: String = ""
    var note: String = ""
    var kindRaw: String = ArtworkKind.flat.rawValue
    var recipeData: Data?
    var processingStateRaw: String = ProcessingState.pending.rawValue
    var renderVersion: Int = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var tags: [String] = []
    var isFavorite = false
    var medium: String = ""
    var keptAt: Date?
    /// 最近刪除 and 自動標籤 (1.4.0). A 1.3 phone ignores both (it keeps showing a trashed artwork until purged).
    var deletedAt: Date?
    var autoTags: [String] = []
    var originalImageData: Data?
    var renderedImageData: Data?
    var thumbnailData: Data?
    var fingerprintData: Data?
    var voiceNoteData: Data?
    var voiceTranscript: String = ""
    var originDeviceID: String = ""
    var modifiedAt: Date?

    var stamp: FamilyStamp { FamilyStamp(kind: .artwork, modifiedAt: modifiedAt, renderVersion: renderVersion) }
}

extension FamilyChildFields {
    @MainActor init(_ child: Child) {
        id = child.id
        name = child.name
        birthday = child.birthday
        avatarColorHex = child.avatarColorHex
        avatarImageData = child.avatarImageData
        createdAt = child.createdAt
        originDeviceID = child.originDeviceID
        modifiedAt = child.modifiedAt
    }

    @MainActor func apply(to child: Child) {
        child.id = id
        child.name = name
        child.birthday = birthday
        child.avatarColorHex = avatarColorHex
        if child.avatarImageData != avatarImageData { child.avatarImageData = avatarImageData }
        child.createdAt = createdAt
        child.originDeviceID = originDeviceID
        child.modifiedAt = modifiedAt
    }
}

extension FamilyArtworkFields {
    @MainActor init(_ artwork: Artwork) {
        id = artwork.id
        childID = artwork.child?.id
        createdAt = artwork.createdAt
        capturedAt = artwork.capturedAt
        title = artwork.title
        note = artwork.note
        kindRaw = artwork.kindRaw
        recipeData = artwork.recipeData
        processingStateRaw = artwork.processingStateRaw
        renderVersion = artwork.renderVersion
        pixelWidth = artwork.pixelWidth
        pixelHeight = artwork.pixelHeight
        tags = artwork.tags
        isFavorite = artwork.isFavorite
        medium = artwork.medium
        keptAt = artwork.keptAt
        deletedAt = artwork.deletedAt
        autoTags = artwork.autoTags
        originalImageData = artwork.originalImageData
        renderedImageData = artwork.renderedImageData
        thumbnailData = artwork.thumbnailData
        fingerprintData = artwork.fingerprintData
        voiceNoteData = artwork.voiceNoteData
        voiceTranscript = artwork.voiceTranscript
        originDeviceID = artwork.originDeviceID
        modifiedAt = artwork.modifiedAt
    }

    /// Writes the shared fields into a museum artwork. `child` is the store's Child for `childID` (nil when there is
    /// none or it hasn't arrived yet). Large data is only assigned when it differs (externalStorage rewrites).
    @MainActor func apply(to artwork: Artwork, child: Child?) {
        artwork.id = id
        if artwork.child?.id != child?.id { artwork.child = child }
        artwork.createdAt = createdAt
        artwork.capturedAt = capturedAt
        artwork.title = title
        artwork.note = note
        artwork.kindRaw = kindRaw
        artwork.recipeData = recipeData
        artwork.processingStateRaw = processingStateRaw
        artwork.renderVersion = renderVersion
        artwork.pixelWidth = pixelWidth
        artwork.pixelHeight = pixelHeight
        artwork.tags = tags
        artwork.isFavorite = isFavorite
        artwork.medium = medium
        artwork.isKept = true
        artwork.isSample = false
        artwork.keptAt = keptAt
        artwork.deletedAt = deletedAt
        artwork.autoTags = autoTags
        if artwork.originalImageData != originalImageData { artwork.originalImageData = originalImageData }
        if artwork.renderedImageData != renderedImageData { artwork.renderedImageData = renderedImageData }
        if artwork.thumbnailData != thumbnailData { artwork.thumbnailData = thumbnailData }
        artwork.fingerprintData = fingerprintData
        if artwork.voiceNoteData != voiceNoteData { artwork.voiceNoteData = voiceNoteData }
        artwork.voiceTranscript = voiceTranscript
        artwork.originDeviceID = originDeviceID
        artwork.modifiedAt = modifiedAt
    }
}

// MARK: - CKRecord mapping

/// Record field names (`ci/cloudkit/schema.ckdb` declares the same names and types). Never rename or remove one
/// once the schema is deployed to Production; add new ones only.
enum FamilyRecordField {
    // Both
    static let createdAt = "createdAt"            // TIMESTAMP
    static let originDeviceID = "originDeviceID"  // STRING
    static let modifiedAt = "modifiedAt"          // TIMESTAMP
    // FMChild
    static let name = "name"                      // STRING
    static let birthday = "birthday"              // TIMESTAMP
    static let avatarColorHex = "avatarColorHex"  // STRING
    static let avatarImage = "avatarImage"        // ASSET
    // FMArtwork
    static let childID = "childID"                // STRING ("" = no child; a string, not a reference, so deleting
                                                  // a child never cascades to artworks)
    static let capturedAt = "capturedAt"          // TIMESTAMP
    static let title = "title"                    // STRING
    static let note = "note"                      // STRING
    static let kind = "kind"                      // STRING
    static let recipe = "recipe"                  // BYTES
    static let processingState = "processingState"  // STRING
    static let renderVersion = "renderVersion"    // INT64
    static let pixelWidth = "pixelWidth"          // INT64
    static let pixelHeight = "pixelHeight"        // INT64
    static let tags = "tags"                      // LIST<STRING>
    static let isFavorite = "isFavorite"          // INT64 (0 / 1)
    static let medium = "medium"                  // STRING
    static let keptAt = "keptAt"                  // TIMESTAMP
    static let deletedAt = "deletedAt"            // TIMESTAMP (1.4.0)
    static let autoTags = "autoTags"              // LIST<STRING> (1.4.0)
    static let originalImage = "originalImage"    // ASSET
    static let renderedImage = "renderedImage"    // ASSET
    static let thumbnail = "thumbnail"            // ASSET
    static let fingerprint = "fingerprint"        // BYTES
    static let voiceNote = "voiceNote"            // ASSET
    static let voiceTranscript = "voiceTranscript"  // STRING
}

/// Child / Artwork fields ⇄ CKRecord. Images and the voice note travel as CKAssets: each is written to a file in
/// `assetDirectory` first (CloudKit uploads from files; FamilySync deletes them once the save is through).
enum FamilyRecordCodec {
    typealias F = FamilyRecordField

    static func recordID(_ recordName: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    /// `base`: the last known server record (keeps its change tag), or nil for a new record.
    static func record(_ fields: FamilyChildFields, zoneID: CKRecordZone.ID, base: CKRecord?,
                       assetDirectory: URL) throws -> CKRecord {
        let record = base ?? CKRecord(recordType: FamilySyncPolicy.childRecordType,
                                      recordID: recordID(fields.id.uuidString, zoneID: zoneID))
        record[F.name] = fields.name
        record[F.birthday] = fields.birthday
        record[F.avatarColorHex] = fields.avatarColorHex
        record[F.avatarImage] = try asset(fields.avatarImageData, name: fields.id.uuidString, field: F.avatarImage,
                                          in: assetDirectory)
        record[F.createdAt] = fields.createdAt
        record[F.originDeviceID] = fields.originDeviceID
        record[F.modifiedAt] = fields.modifiedAt
        return record
    }

    static func record(_ fields: FamilyArtworkFields, zoneID: CKRecordZone.ID, base: CKRecord?,
                       assetDirectory: URL) throws -> CKRecord {
        let name = fields.id.uuidString
        let record = base ?? CKRecord(recordType: FamilySyncPolicy.artworkRecordType,
                                      recordID: recordID(name, zoneID: zoneID))
        record[F.childID] = fields.childID?.uuidString ?? ""
        record[F.createdAt] = fields.createdAt
        record[F.capturedAt] = fields.capturedAt
        record[F.title] = fields.title
        record[F.note] = fields.note
        record[F.kind] = fields.kindRaw
        record[F.recipe] = fields.recipeData
        record[F.processingState] = fields.processingStateRaw
        record[F.renderVersion] = Int64(fields.renderVersion)
        record[F.pixelWidth] = Int64(fields.pixelWidth)
        record[F.pixelHeight] = Int64(fields.pixelHeight)
        record[F.tags] = fields.tags
        record[F.isFavorite] = Int64(fields.isFavorite ? 1 : 0)
        record[F.medium] = fields.medium
        record[F.keptAt] = fields.keptAt
        record[F.deletedAt] = fields.deletedAt
        record[F.autoTags] = fields.autoTags.isEmpty ? nil : fields.autoTags
        record[F.originalImage] = try asset(fields.originalImageData, name: name, field: F.originalImage, in: assetDirectory)
        record[F.renderedImage] = try asset(fields.renderedImageData, name: name, field: F.renderedImage, in: assetDirectory)
        record[F.thumbnail] = try asset(fields.thumbnailData, name: name, field: F.thumbnail, in: assetDirectory)
        record[F.fingerprint] = fields.fingerprintData
        record[F.voiceNote] = try asset(fields.voiceNoteData, name: name, field: F.voiceNote, in: assetDirectory)
        record[F.voiceTranscript] = fields.voiceTranscript
        record[F.originDeviceID] = fields.originDeviceID
        record[F.modifiedAt] = fields.modifiedAt
        return record
    }

    static func childFields(from record: CKRecord) -> FamilyChildFields? {
        guard record.recordType == FamilySyncPolicy.childRecordType,
              let id = UUID(uuidString: record.recordID.recordName) else { return nil }
        var f = FamilyChildFields(id: id)
        f.name = string(record, F.name)
        f.birthday = record[F.birthday] as? Date
        f.avatarColorHex = (record[F.avatarColorHex] as? String) ?? f.avatarColorHex
        f.avatarImageData = data(ofAsset: record, F.avatarImage)
        f.createdAt = (record[F.createdAt] as? Date) ?? f.createdAt
        f.originDeviceID = string(record, F.originDeviceID)
        f.modifiedAt = record[F.modifiedAt] as? Date
        return f
    }

    static func artworkFields(from record: CKRecord) -> FamilyArtworkFields? {
        guard record.recordType == FamilySyncPolicy.artworkRecordType,
              let id = UUID(uuidString: record.recordID.recordName) else { return nil }
        var f = FamilyArtworkFields(id: id)
        f.childID = UUID(uuidString: string(record, F.childID))
        f.createdAt = (record[F.createdAt] as? Date) ?? f.createdAt
        f.capturedAt = (record[F.capturedAt] as? Date) ?? f.capturedAt
        f.title = string(record, F.title)
        f.note = string(record, F.note)
        f.kindRaw = (record[F.kind] as? String) ?? f.kindRaw
        f.recipeData = record[F.recipe] as? Data
        f.processingStateRaw = (record[F.processingState] as? String) ?? f.processingStateRaw
        f.renderVersion = int(record, F.renderVersion)
        f.pixelWidth = int(record, F.pixelWidth)
        f.pixelHeight = int(record, F.pixelHeight)
        f.tags = (record[F.tags] as? [String]) ?? []
        f.isFavorite = int(record, F.isFavorite) != 0
        f.medium = string(record, F.medium)
        f.keptAt = record[F.keptAt] as? Date
        f.deletedAt = record[F.deletedAt] as? Date
        f.autoTags = (record[F.autoTags] as? [String]) ?? []
        f.originalImageData = data(ofAsset: record, F.originalImage)
        f.renderedImageData = data(ofAsset: record, F.renderedImage)
        f.thumbnailData = data(ofAsset: record, F.thumbnail)
        f.fingerprintData = record[F.fingerprint] as? Data
        f.voiceNoteData = data(ofAsset: record, F.voiceNote)
        f.voiceTranscript = string(record, F.voiceTranscript)
        f.originDeviceID = string(record, F.originDeviceID)
        f.modifiedAt = record[F.modifiedAt] as? Date
        return f
    }

    /// The asset fields of each record type.
    static let assetFields: [String: [String]] = [
        FamilySyncPolicy.childRecordType: [F.avatarImage],
        FamilySyncPolicy.artworkRecordType: [F.originalImage, F.renderedImage, F.thumbnail, F.voiceNote],
    ]

    /// Asset fields that hold a CKAsset whose file can't be read here. An absent field (nil) is a real "no image";
    /// an unreadable file is not, and must never be treated as one.
    static func unreadableAssets(in record: CKRecord) -> [String] {
        (assetFields[record.recordType] ?? []).filter { key in
            guard let value = record[key] else { return false }
            guard let asset = value as? CKAsset, let url = asset.fileURL else { return true }
            return !FileManager.default.isReadableFile(atPath: url.path)
        }
    }

    /// The version a record carries (for the uploaded-state table), without reading its assets.
    static func stamp(of record: CKRecord) -> FamilyStamp? {
        guard let kind = FamilyRecordKind(recordType: record.recordType) else { return nil }
        return FamilyStamp(kind: kind, modifiedAt: record[F.modifiedAt] as? Date,
                           renderVersion: kind == .artwork ? int(record, F.renderVersion) : 0)
    }

    /// Files written for a record's assets start with its record name (FamilySync removes them by prefix).
    static func assetFilePrefix(_ recordName: String) -> String { recordName + "." }

    /// The record's system fields (ids, change tag) only, to build the next save on the server's version.
    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: Helpers

    private static func asset(_ data: Data?, name: String, field: String, in directory: URL) throws -> CKAsset? {
        guard let data, !data.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(assetFilePrefix(name) + field)
        try data.write(to: url, options: .atomic)
        return CKAsset(fileURL: url)
    }

    private static func data(ofAsset record: CKRecord, _ key: String) -> Data? {
        guard let url = (record[key] as? CKAsset)?.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func string(_ record: CKRecord, _ key: String) -> String {
        (record[key] as? String) ?? ""
    }

    private static func int(_ record: CKRecord, _ key: String) -> Int {
        (record[key] as? NSNumber)?.intValue ?? 0
    }
}
