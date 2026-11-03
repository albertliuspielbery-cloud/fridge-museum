import CloudKit
import Foundation
import SwiftData
import Testing
@testable import FridgeMuseum

/// 家庭美術館 (1.3.0): which store a launch opens, what counts as a local change, who wins a conflict, the record
/// field mapping, and that the personal store is never touched by entering or leaving a family museum.
/// CloudKit itself (sharing, accepting, the sync engine) can't run in CI: the simulator build is unsigned and has no
/// Apple Account — FamilySync never touches CloudKit there.
@MainActor
struct FamilySyncTests {
    private let owner = FamilyMembership(role: .owner, zoneOwnerName: CKCurrentUserDefaultName, ownerDisplayName: nil,
                                         joinedAt: day(2026, 11, 1))
    private let member = FamilyMembership(role: .member, zoneOwnerName: "_abc123", ownerDisplayName: "媽媽",
                                          joinedAt: day(2026, 11, 2))
    private let zoneID = CKRecordZone.ID(zoneName: FamilySyncPolicy.zoneName, ownerName: CKCurrentUserDefaultName)

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("family-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Which store a launch opens

    @Test func noMembershipOpensThePersonalMuseum() {
        #expect(FamilySyncPolicy.mode(isSupported: true, membership: nil) == .personal)
    }

    @Test func membershipOpensTheFamilyMuseum() {
        #expect(FamilySyncPolicy.mode(isSupported: true, membership: owner) == .family(.owner))
        #expect(FamilySyncPolicy.mode(isSupported: true, membership: member) == .family(.member))
        #expect(MuseumMode.family(.member).opensFamilyStore)
        #expect(!MuseumMode.personal.opensFamilyStore)
    }

    /// Simulator, screenshot demos and unit tests never open family.store (nor touch CloudKit), whatever is saved.
    @Test func unsupportedEnvironmentAlwaysOpensThePersonalMuseum() {
        #expect(FamilySyncPolicy.mode(isSupported: false, membership: owner) == .personal)
        #expect(FamilySyncPolicy.mode(isSupported: false, membership: member) == .personal)
    }

    /// An end whose copy back to the personal store hasn't finished opens family.store again — without sync — to retry.
    @Test func unfinishedEndReopensTheFamilyStoreToCopyBack() {
        var ending = member
        ending.pendingEnd = .revoked
        #expect(FamilySyncPolicy.mode(isSupported: true, membership: ending) == .closingFamily(.revoked))
        #expect(MuseumMode.closingFamily(.revoked).opensFamilyStore)
        #expect(!FamilySyncPolicy.grantsFullVersion(mode: .closingFamily(.revoked)))
    }

    @Test func membershipSurvivesEncoding() throws {
        var saved = member
        saved.pendingEnd = .accountChanged
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(FamilyMembership.self, from: data)
        #expect(decoded == saved)
    }

    /// The app object never opens family.store in the unit-test host, even with a membership saved.
    @Test func familySyncStaysPersonalInUnitTests() throws {
        let defaults = try #require(UserDefaults(suiteName: "family-test-\(UUID().uuidString)"))
        defaults.set(try JSONEncoder().encode(member), forKey: FamilySync.Keys.membership)
        let family = FamilySync(defaults: defaults)
        #expect(family.membership == member)
        let opened = family.openStoreIfFamily()
        #expect(opened == nil)
        #expect(family.mode == .personal)
        #expect(!family.grantsFullVersion)
        #expect(!family.isAvailable)
        #expect(family.status == .willOpenNextLaunch)
    }

    // MARK: Purchases

    @Test func onlyABuyerCanCreate() {
        #expect(FamilySyncPolicy.canCreate(isPurchased: true, isSupported: true, membership: nil))
        #expect(!FamilySyncPolicy.canCreate(isPurchased: false, isSupported: true, membership: nil))
        #expect(!FamilySyncPolicy.canCreate(isPurchased: true, isSupported: false, membership: nil))
        #expect(!FamilySyncPolicy.canCreate(isPurchased: true, isSupported: true, membership: member))
    }

    @Test func everyoneInAFamilyMuseumHasTheFullVersion() {
        #expect(FamilySyncPolicy.grantsFullVersion(mode: .family(.member)))
        #expect(FamilySyncPolicy.grantsFullVersion(mode: .family(.owner)))
        #expect(!FamilySyncPolicy.grantsFullVersion(mode: .personal))
    }

    @Test func familyAccessUnlocksFeaturesAndQuota() {
        let store = StoreBridge()
        store.familyAccess.grant()
        #expect(store.isUnlocked)
        #expect(store.quota.isUnlocked)
        #expect(!store.quota.isTracking)
        let id = UUID()
        #expect(store.quota.canKeep(kind: .craft, artworkID: id))
    }

    // MARK: What is shared

    @Test func onlyMuseumArtworksQualify() {
        #expect(FamilySyncPolicy.qualifies(isKept: true, isSample: false))
        #expect(!FamilySyncPolicy.qualifies(isKept: false, isSample: false))   // still being edited
        #expect(!FamilySyncPolicy.qualifies(isKept: true, isSample: true))     // bundled sample
        #expect(!FamilySyncPolicy.qualifies(isKept: false, isSample: true))
    }

    // MARK: Local changes against the uploaded-state table

    private func item(_ id: UUID, _ modified: Date?, render: Int = 0, kind: FamilyRecordKind = .artwork,
                      ready: Bool = true) -> FamilyLocalItem {
        FamilyLocalItem(id: id, stamp: FamilyStamp(kind: kind, modifiedAt: modified, renderVersion: render), isReady: ready)
    }

    @Test func newRecordsAreUploaded() {
        let a = UUID(), c = UUID()
        let changes = FamilySyncPolicy.changes(local: [item(a, day(2026, 1, 1)), item(c, nil, kind: .child)], uploaded: [:])
        #expect(Set(changes.saves) == [a.uuidString, c.uuidString])
        #expect(changes.deletes.isEmpty)
    }

    @Test func unchangedRecordsAreNotUploadedAgain() {
        let a = UUID()
        let t = day(2026, 1, 1)
        let uploaded = [a.uuidString: FamilyStamp(kind: .artwork, modifiedAt: t, renderVersion: 2)]
        let changes = FamilySyncPolicy.changes(local: [item(a, t, render: 2)], uploaded: uploaded)
        #expect(changes.isEmpty)
    }

    @Test func editsAndRendersAreUploaded() {
        let a = UUID(), b = UUID()
        let t = day(2026, 1, 1)
        let uploaded = [a.uuidString: FamilyStamp(kind: .artwork, modifiedAt: t, renderVersion: 1),
                        b.uuidString: FamilyStamp(kind: .artwork, modifiedAt: t, renderVersion: 1)]
        let changes = FamilySyncPolicy.changes(local: [item(a, t.addingTimeInterval(5), render: 1), item(b, t, render: 2)],
                                               uploaded: uploaded)
        #expect(changes.saves == [a.uuidString, b.uuidString].sorted())
    }

    /// CloudKit keeps milliseconds: a downloaded timestamp a fraction of a millisecond off is the same edit.
    @Test func millisecondRoundingIsNotAnEdit() {
        let a = UUID()
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000.123_456_7)
        let rounded = Date(timeIntervalSinceReferenceDate: 800_000_000.123)
        let uploaded = [a.uuidString: FamilyStamp(kind: .artwork, modifiedAt: rounded)]
        #expect(FamilySyncPolicy.changes(local: [item(a, t)], uploaded: uploaded).isEmpty)
    }

    /// A render in progress waits (no double upload) but isn't mistaken for a deletion.
    @Test func busyArtworksWaitButAreNotDeleted() {
        let a = UUID()
        let uploaded = [a.uuidString: FamilyStamp(kind: .artwork, modifiedAt: day(2026, 1, 1))]
        let changes = FamilySyncPolicy.changes(local: [item(a, day(2026, 1, 2), ready: false)], uploaded: uploaded)
        #expect(changes.isEmpty)
        let fresh = FamilySyncPolicy.changes(local: [item(UUID(), day(2026, 1, 2), ready: false)], uploaded: [:])
        #expect(fresh.isEmpty)
    }

    @Test func removedRecordsAreDeleted() {
        let keep = UUID(), gone = UUID()
        let t = day(2026, 1, 1)
        let uploaded = [keep.uuidString: FamilyStamp(kind: .artwork, modifiedAt: t),
                        gone.uuidString: FamilyStamp(kind: .child, modifiedAt: t)]
        let changes = FamilySyncPolicy.changes(local: [item(keep, t)], uploaded: uploaded)
        #expect(changes.saves.isEmpty)
        #expect(changes.deletes == [gone.uuidString])
        #expect(!changes.heldBackDeletes)
    }

    /// An empty store (couldn't be read, or a broken file) must never empty every family member's phone.
    @Test func anEmptyStoreNeverDeletesEverything() {
        let t = day(2026, 1, 1)
        var uploaded: [String: FamilyStamp] = [:]
        for _ in 0..<FamilySyncPolicy.massDeleteGuard { uploaded[UUID().uuidString] = FamilyStamp(kind: .artwork, modifiedAt: t) }
        let changes = FamilySyncPolicy.changes(local: [], uploaded: uploaded)
        #expect(changes.deletes.isEmpty)
        #expect(changes.heldBackDeletes)
        // A small museum (fewer than the guard) can still be emptied on purpose.
        let small = [UUID().uuidString: FamilyStamp(kind: .artwork, modifiedAt: t)]
        #expect(FamilySyncPolicy.changes(local: [], uploaded: small).deletes.count == 1)
    }

    /// The guard is proportional: many deletions of records not seen this session are held back, a few go through,
    /// and deletions of records seen earlier this session (the person deleted them) always go through.
    @Test func massDeleteGuardIsProportional() {
        let t = day(2026, 1, 1)
        let ids = (0..<10).map { _ in UUID() }
        var uploaded: [String: FamilyStamp] = [:]
        for id in ids { uploaded[id.uuidString] = FamilyStamp(kind: .artwork, modifiedAt: t) }
        // 4 of 10 missing: not more than half → sent.
        let fewGone = FamilySyncPolicy.changes(local: ids.prefix(6).map { item($0, t) }, uploaded: uploaded)
        #expect(fewGone.deletes.count == 4)
        #expect(!fewGone.heldBackDeletes)
        // 6 of 10 missing, never seen this session → held back.
        let mostGone = FamilySyncPolicy.changes(local: ids.prefix(4).map { item($0, t) }, uploaded: uploaded)
        #expect(mostGone.deletes.isEmpty)
        #expect(mostGone.heldBackDeletes)
        // The same 6, seen earlier this session (deleted here on purpose) → sent.
        let seen = Set(ids.map(\.uuidString))
        let deliberate = FamilySyncPolicy.changes(local: ids.prefix(4).map { item($0, t) }, uploaded: uploaded,
                                                  seenThisSession: seen)
        #expect(deliberate.deletes.count == 6)
        #expect(!deliberate.heldBackDeletes)
        // Mixed: seen ones go, unseen ones wait.
        let partly = Set(ids.suffix(2).map(\.uuidString))
        let mixed = FamilySyncPolicy.changes(local: ids.prefix(2).map { item($0, t) }, uploaded: uploaded,
                                             seenThisSession: partly)
        #expect(Set(mixed.deletes) == partly)
        #expect(mixed.heldBackDeletes)
    }

    /// What leaving keeps even without "copy": never uploaded, changed since, or still rendering.
    @Test func unsentFindsWorksTheFamilyDoesNotHave() {
        let t = day(2026, 1, 1)
        let synced = UUID(), edited = UUID(), fresh = UUID(), rendering = UUID()
        let uploaded = [synced.uuidString: FamilyStamp(kind: .artwork, modifiedAt: t),
                        edited.uuidString: FamilyStamp(kind: .artwork, modifiedAt: t),
                        rendering.uuidString: FamilyStamp(kind: .artwork, modifiedAt: t)]
        let local = [item(synced, t), item(edited, t.addingTimeInterval(9)), item(fresh, t),
                     item(rendering, t, render: 1, ready: false)]
        let unsent = FamilySyncPolicy.unsent(local: local, uploaded: uploaded)
        #expect(Set(unsent) == [edited.uuidString, fresh.uuidString, rendering.uuidString])
    }

    // MARK: Unreadable assets

    @Test func unreadableAssetsAreNeverApplied() {
        #expect(FamilySyncPolicy.incomingAction(winner: .server, hasUnreadableAssets: false) == .apply)
        #expect(FamilySyncPolicy.incomingAction(winner: .server, hasUnreadableAssets: true) == .refetch)
        #expect(FamilySyncPolicy.incomingAction(winner: .local, hasUnreadableAssets: true) == .keepLocal)
        #expect(FamilySyncPolicy.incomingAction(winner: .local, hasUnreadableAssets: false) == .keepLocal)
    }

    /// "No image" (field absent) and "image file missing" (a CKAsset that can't be read) are told apart.
    @Test func unreadableAssetIsNotNoAsset() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fields = sampleArtworkFields()
        fields.voiceNoteData = nil
        let record = try FamilyRecordCodec.record(fields, zoneID: zoneID, base: nil, assetDirectory: dir)
        let readable = FamilyRecordCodec.unreadableAssets(in: record)
        #expect(readable.isEmpty)   // voiceNote absent: a real "none", not unreadable
        let rendered = try #require((record["renderedImage"] as? CKAsset)?.fileURL)
        try FileManager.default.removeItem(at: rendered)
        let missing = FamilyRecordCodec.unreadableAssets(in: record)
        #expect(missing == ["renderedImage"])
        // Child records too.
        var child = FamilyChildFields(id: UUID())
        child.avatarImageData = Data([1, 2])
        let childRecord = try FamilyRecordCodec.record(child, zoneID: zoneID, base: nil, assetDirectory: dir)
        let avatar = try #require((childRecord["avatarImage"] as? CKAsset)?.fileURL)
        try FileManager.default.removeItem(at: avatar)
        let childMissing = FamilyRecordCodec.unreadableAssets(in: childRecord)
        #expect(childMissing == ["avatarImage"])
    }

    @Test func olderStateAndMembershipFilesStillDecode() throws {
        let oldState = Data(#"{"uploaded":{},"systemFields":{},"awaitingChild":{}}"#.utf8)
        let state = try JSONDecoder().decode(FamilySyncState.self, from: oldState)
        #expect(state.refetch.isEmpty)
        var withRefetch = FamilySyncState()
        withRefetch.refetch = ["a"]
        let encoded = try JSONEncoder().encode(withRefetch)
        let decoded = try JSONDecoder().decode(FamilySyncState.self, from: encoded)
        #expect(decoded == withRefetch)
        let oldMember = Data(#"{"role":"member","zoneOwnerName":"_x","joinedAt":0}"#.utf8)
        let membership = try JSONDecoder().decode(FamilyMembership.self, from: oldMember)
        #expect(membership.stopRequested == nil)
        #expect(membership.pendingEnd == nil)
    }

    // MARK: Conflicts

    @Test func newerEditWinsAConflict() {
        let t = day(2026, 3, 1)
        #expect(FamilySyncPolicy.resolveConflict(localModifiedAt: t.addingTimeInterval(60), serverModifiedAt: t) == .local)
        #expect(FamilySyncPolicy.resolveConflict(localModifiedAt: t, serverModifiedAt: t.addingTimeInterval(60)) == .server)
    }

    @Test func aTieGoesToTheServer() {
        let t = day(2026, 3, 1)
        #expect(FamilySyncPolicy.resolveConflict(localModifiedAt: t, serverModifiedAt: t) == .server)
        #expect(FamilySyncPolicy.resolveConflict(localModifiedAt: t.addingTimeInterval(0.001), serverModifiedAt: t) == .server)
        #expect(FamilySyncPolicy.resolveConflict(localModifiedAt: nil, serverModifiedAt: nil) == .server)
        #expect(FamilySyncPolicy.resolveConflict(localModifiedAt: nil, serverModifiedAt: t) == .server)
        #expect(FamilySyncPolicy.resolveConflict(localModifiedAt: t, serverModifiedAt: nil) == .local)
    }

    /// A downloaded record replaces an untouched local copy even when this phone's clock says the local one is
    /// newer; only an edit made here since the last upload is weighed against it.
    @Test func downloadsReplaceUntouchedRecords() {
        let t = day(2026, 4, 1)
        let mine = FamilyStamp(kind: .artwork, modifiedAt: t.addingTimeInterval(600))
        let server = FamilyStamp(kind: .artwork, modifiedAt: t)
        #expect(FamilySyncPolicy.resolveIncoming(local: nil, uploaded: nil, server: server) == .server)
        #expect(FamilySyncPolicy.resolveIncoming(local: mine, uploaded: mine, server: server) == .server)
        // Edited here, after the server's version: keep it (it is uploaded again).
        let older = FamilyStamp(kind: .artwork, modifiedAt: t.addingTimeInterval(-600))
        #expect(FamilySyncPolicy.resolveIncoming(local: mine, uploaded: older, server: server) == .local)
        // Edited here, but someone edited later: theirs.
        let earlyEdit = FamilyStamp(kind: .artwork, modifiedAt: t.addingTimeInterval(-60))
        #expect(FamilySyncPolicy.resolveIncoming(local: earlyEdit, uploaded: older, server: server) == .server)
        // Same record from two phones before either uploaded (e.g. copies with the same id): newer wins.
        #expect(FamilySyncPolicy.resolveIncoming(local: mine, uploaded: nil, server: server) == .local)
    }

    @Test func remoteDeletionsKeepUnsentEdits() {
        let t = day(2026, 5, 1)
        let uploaded = FamilyStamp(kind: .artwork, modifiedAt: t)
        #expect(FamilySyncPolicy.resolveIncomingDeletion(local: uploaded, uploaded: uploaded) == .server)
        #expect(FamilySyncPolicy.resolveIncomingDeletion(local: nil, uploaded: uploaded) == .server)
        let edited = FamilyStamp(kind: .artwork, modifiedAt: t.addingTimeInterval(30))
        #expect(FamilySyncPolicy.resolveIncomingDeletion(local: edited, uploaded: uploaded) == .local)
        #expect(FamilySyncPolicy.resolveIncomingDeletion(local: edited, uploaded: nil) == .local)
    }

    @Test func stampsCompareKindAndRender() {
        let t = day(2026, 6, 1)
        let a = FamilyStamp(kind: .artwork, modifiedAt: t, renderVersion: 1)
        #expect(a.isSameVersion(as: a))
        #expect(!a.isSameVersion(as: FamilyStamp(kind: .artwork, modifiedAt: t, renderVersion: 2)))
        #expect(!a.isSameVersion(as: FamilyStamp(kind: .child, modifiedAt: t, renderVersion: 1)))
        #expect(!a.isSameVersion(as: FamilyStamp(kind: .artwork, modifiedAt: nil, renderVersion: 1)))
        #expect(FamilyStamp(kind: .child, modifiedAt: nil).isSameVersion(as: FamilyStamp(kind: .child, modifiedAt: nil)))
    }

    // MARK: Status

    @Test func statusFollowsModeAndActivity() {
        func status(_ mode: MuseumMode, _ membership: FamilyMembership?, ended: FamilyEndReason? = nil,
                    _ activity: SyncActivity = .idle, synced: Bool = false) -> FamilyStatus {
            FamilySyncPolicy.status(mode: mode, membership: membership, endedThisSession: ended, activity: activity,
                                    hasSynced: synced)
        }
        #expect(status(.personal, nil) == .off)
        #expect(status(.personal, member) == .willOpenNextLaunch)
        #expect(status(.family(.member), member) == .starting)
        #expect(status(.family(.member), member, synced: true) == .synced)
        #expect(status(.family(.member), member, .syncing) == .syncing)
        #expect(status(.family(.owner), owner, .failed(.quotaFull)) == .quotaFull)
        #expect(status(.family(.owner), owner, .failed(.network)) == .waitingForNetwork)
        #expect(status(.family(.owner), owner, .failed(.notSignedIn)) == .notSignedIn)
        #expect(status(.family(.owner), owner, .failed(.other)) == .failed)
        #expect(status(.family(.member), nil, ended: .left) == .willCloseNextLaunch(.left))
        #expect(status(.closingFamily(.revoked), member) == .willCloseNextLaunch(.revoked))
        var ending = member
        ending.pendingEnd = .accountChanged
        #expect(status(.personal, ending) == .willCloseNextLaunch(.accountChanged))
    }

    // MARK: Record fields

    private func sampleArtworkFields() -> FamilyArtworkFields {
        var f = FamilyArtworkFields(id: UUID())
        f.childID = UUID()
        f.createdAt = day(2026, 2, 1)
        f.capturedAt = day(2026, 1, 30)
        f.title = "恐龍"
        f.note = "在公園畫的"
        f.kindRaw = ArtworkKind.craft.rawValue
        f.recipeData = Data([1, 2, 3])
        f.processingStateRaw = ProcessingState.done.rawValue
        f.renderVersion = 4
        f.pixelWidth = 3000
        f.pixelHeight = 2000
        f.tags = ["動物", "恐龍"]
        f.isFavorite = true
        f.medium = "蠟筆"
        f.keptAt = day(2026, 2, 2)
        f.originalImageData = Data(repeating: 7, count: 64)
        f.renderedImageData = Data(repeating: 8, count: 32)
        f.thumbnailData = Data(repeating: 9, count: 16)
        f.fingerprintData = Data([4, 5])
        f.voiceNoteData = Data(repeating: 1, count: 8)
        f.voiceTranscript = "這是暴龍"
        f.originDeviceID = "PHONE-A"
        f.modifiedAt = day(2026, 2, 3)
        return f
    }

    @Test func artworkFieldsSurviveTheRecord() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fields = sampleArtworkFields()
        let record = try FamilyRecordCodec.record(fields, zoneID: zoneID, base: nil, assetDirectory: dir)
        #expect(record.recordType == "FMArtwork")
        #expect(record.recordID.recordName == fields.id.uuidString)
        #expect(record.recordID.zoneID == zoneID)
        #expect(record["childID"] as? String == fields.childID?.uuidString)
        #expect(record["originalImage"] is CKAsset)
        let decoded = try #require(FamilyRecordCodec.artworkFields(from: record))
        #expect(decoded == fields)
        let stamp = FamilyRecordCodec.stamp(of: record)
        #expect(stamp == fields.stamp)
    }

    @Test func emptyDataAndNoChildMapCleanly() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fields = FamilyArtworkFields(id: UUID())
        fields.modifiedAt = day(2026, 2, 3)
        let record = try FamilyRecordCodec.record(fields, zoneID: zoneID, base: nil, assetDirectory: dir)
        #expect(record["childID"] as? String == "")
        #expect((record["voiceNote"] as? CKAsset) == nil)
        let decoded = try #require(FamilyRecordCodec.artworkFields(from: record))
        #expect(decoded.childID == nil)
        #expect(decoded.originalImageData == nil)
        #expect(decoded.tags.isEmpty)
        #expect(decoded == fields)
    }

    @Test func childFieldsSurviveTheRecord() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fields = FamilyChildFields(id: UUID())
        fields.name = "小明"
        fields.birthday = day(2020, 5, 5)
        fields.avatarColorHex = "#FF8800"
        fields.avatarImageData = Data(repeating: 3, count: 20)
        fields.createdAt = day(2026, 1, 1)
        fields.originDeviceID = "PHONE-B"
        fields.modifiedAt = day(2026, 1, 2)
        let record = try FamilyRecordCodec.record(fields, zoneID: zoneID, base: nil, assetDirectory: dir)
        #expect(record.recordType == "FMChild")
        let decoded = try #require(FamilyRecordCodec.childFields(from: record))
        #expect(decoded == fields)
        let stamp = FamilyRecordCodec.stamp(of: record)
        #expect(stamp == FamilyStamp(kind: .child, modifiedAt: fields.modifiedAt))
        // A record of the other type isn't read as a child.
        #expect(FamilyRecordCodec.artworkFields(from: record) == nil)
    }

    /// The next save is built on the last server record (system fields keep the change tag) with the new values.
    @Test func systemFieldsRoundTripAndCarryNewValues() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fields = FamilyChildFields(id: UUID())
        fields.name = "小美"
        let first = try FamilyRecordCodec.record(fields, zoneID: zoneID, base: nil, assetDirectory: dir)
        let saved = FamilyRecordCodec.encodeSystemFields(first)
        let base = try #require(FamilyRecordCodec.decodeSystemFields(saved))
        #expect(base.recordID == first.recordID)
        #expect(base.recordType == first.recordType)
        fields.name = "小美美"
        let next = try FamilyRecordCodec.record(fields, zoneID: zoneID, base: base, assetDirectory: dir)
        #expect(next === base)
        #expect(next["name"] as? String == "小美美")
    }

    @Test func assetFilesAreNamedAfterTheirRecord() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fields = sampleArtworkFields()
        _ = try FamilyRecordCodec.record(fields, zoneID: zoneID, base: nil, assetDirectory: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 4)   // original, rendered, thumbnail, voice note
        #expect(files.allSatisfy { $0.hasPrefix(FamilyRecordCodec.assetFilePrefix(fields.id.uuidString)) })
    }

    @Test func recordKindsMapToRecordTypes() {
        #expect(FamilyRecordKind(recordType: "FMChild") == .child)
        #expect(FamilyRecordKind(recordType: "FMArtwork") == .artwork)
        #expect(FamilyRecordKind(recordType: "CD_Artwork") == nil)
        #expect(FamilyRecordKind.artwork.recordType == "FMArtwork")
    }

    @Test func syncStateSurvivesEncoding() throws {
        var state = FamilySyncState()
        state.uploaded["a"] = FamilyStamp(kind: .artwork, modifiedAt: day(2026, 1, 1), renderVersion: 3)
        state.systemFields["a"] = Data([1, 2])
        state.awaitingChild["a"] = "c"
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(FamilySyncState.self, from: data)
        #expect(decoded == state)
    }

    // MARK: Model ⇄ fields

    @Test func modelFieldsApplyToAnotherArtwork() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let kid = Child(name: "小明")
        context.insert(kid)
        let source = Artwork(kind: .flat, child: kid, capturedAt: day(2026, 1, 5), originalImageData: Data([9, 9]))
        source.title = "彩虹"
        source.tags = ["風景"]
        source.renderVersion = 2
        source.isFavorite = true
        context.insert(source)
        let target = Artwork(kind: .craft, child: nil, capturedAt: Date(), originalImageData: Data())
        target.isKept = false
        let saved = day(2026, 1, 6)
        target.lastSavedToPhotosAt = saved
        context.insert(target)

        let fields = FamilyArtworkFields(source)
        #expect(fields.childID == kid.id)
        fields.apply(to: target, child: kid)
        #expect(target.id == source.id)
        #expect(target.title == "彩虹")
        #expect(target.kind == .flat)
        #expect(target.child?.id == kid.id)
        #expect(target.originalImageData == Data([9, 9]))
        #expect(target.isKept)
        #expect(!target.isSample)
        #expect(target.lastSavedToPhotosAt == saved)   // a fact about this phone, not shared
        let roundTrip = FamilyArtworkFields(target)
        #expect(roundTrip == fields)
    }

    // MARK: Two stores, personal untouched

    /// The family store is a different file from the personal store (never the same file under two containers).
    @Test func familyAndPersonalConfigurationsUseDifferentFiles() {
        let schema = ArchiveStore.schema
        let personal = ArchiveStore.configuration(schema: schema, cloudKitContainerID: nil)
        let synced = ArchiveStore.configuration(schema: schema, cloudKitContainerID: CloudSync.containerID)
        let family = ArchiveStore.familyConfiguration(schema: schema)
        #expect(family.url != personal.url)
        #expect(family.url != synced.url)
        #expect(family.url.lastPathComponent == "family.store")
        #expect(family.url.standardizedFileURL.path != personal.url.standardizedFileURL.path)
        #expect(ArchiveStore.familyStoreURL.lastPathComponent == "family.store")
        #expect(ArchiveStore.familyStoreURL.deletingLastPathComponent().path
                == ArchiveStore.personalStoreURL.deletingLastPathComponent().path)
        #expect(family.name != personal.name)
    }

    /// The only destructive helper refuses the personal store's file.
    @Test func resettingRefusesThePersonalStore() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let personalURL = dir.appendingPathComponent("default.store")
        let personal = try ArchiveStore.openPersonalForCopy(url: personalURL)
        let context = ModelContext(personal)
        context.insert(Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([1])))
        try context.save()

        #expect(throws: ArchiveStore.FamilyStoreError.self) {
            try ArchiveStore.resetFamilyStore(url: personalURL, personalURL: personalURL)
        }
        let count = try ModelContext(personal).fetchCount(FetchDescriptor<Artwork>())
        #expect(count == 1)
    }

    @Test func resettingEmptiesOnlyTheFamilyStore() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let personalURL = dir.appendingPathComponent("default.store")
        let familyURL = dir.appendingPathComponent("family.store")
        let personal = try ArchiveStore.openPersonalForCopy(url: personalURL)
        let p = ModelContext(personal)
        p.insert(Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([1])))
        try p.save()
        do {
            let family = try ArchiveStore.openFamilyForCopy(url: familyURL)
            let f = ModelContext(family)
            f.insert(Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([2])))
            f.insert(Child(name: "家人"))
            try f.save()
        }
        try ArchiveStore.resetFamilyStore(url: familyURL, personalURL: personalURL)
        let family = try ArchiveStore.openFamilyForCopy(url: familyURL)
        let familyCount = try ModelContext(family).fetchCount(FetchDescriptor<Artwork>())
        let childCount = try ModelContext(family).fetchCount(FetchDescriptor<Child>())
        let personalCount = try ModelContext(personal).fetchCount(FetchDescriptor<Artwork>())
        #expect(familyCount == 0)
        #expect(childCount == 0)
        #expect(personalCount == 1)
    }

    /// Entering a family museum copies the personal museum: every museum artwork and child arrives with the same id,
    /// pending captures and samples stay behind, and the personal store is exactly as it was.
    @Test func copyingIntoTheFamilyLeavesThePersonalStoreUntouched() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let personal = try ArchiveStore.openPersonalForCopy(url: dir.appendingPathComponent("default.store"))
        let p = ModelContext(personal)
        let kid = Child(name: "小明")
        p.insert(kid)
        let kept = Artwork(kind: .flat, child: kid, capturedAt: day(2026, 1, 1), originalImageData: Data([1, 2, 3]))
        kept.title = "太陽"
        kept.renderedImageData = Data([4, 5])
        kept.lastSavedToPhotosAt = day(2026, 1, 2)
        let pending = Artwork(kind: .flat, child: kid, capturedAt: day(2026, 1, 3), originalImageData: Data([6]))
        pending.isKept = false
        let sample = Artwork(kind: .craft, child: nil, capturedAt: day(2026, 1, 4), originalImageData: Data([7]))
        sample.isSample = true
        for a in [kept, pending, sample] { p.insert(a) }
        try p.save()
        let before = try ModelContext(personal).fetch(FetchDescriptor<Artwork>()).map { FamilyArtworkFields($0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        let family = try ArchiveStore.openFamilyForCopy(url: dir.appendingPathComponent("family.store"))
        let copied = try await ArchiveStore.copyMuseum(from: personal, to: family)
        #expect(copied == 1)

        let after = try ModelContext(personal).fetch(FetchDescriptor<Artwork>()).map { FamilyArtworkFields($0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        #expect(after == before)
        let personalChildren = try ModelContext(personal).fetchCount(FetchDescriptor<Child>())
        #expect(personalChildren == 1)

        let f = ModelContext(family)
        let familyArtworks = try f.fetch(FetchDescriptor<Artwork>())
        #expect(familyArtworks.map(\.id) == [kept.id])
        let copy = try #require(familyArtworks.first)
        #expect(copy.title == "太陽")
        #expect(copy.child?.id == kid.id)
        #expect(copy.originalImageData == Data([1, 2, 3]))
        #expect(copy.renderedImageData == Data([4, 5]))
        #expect(copy.lastSavedToPhotosAt == day(2026, 1, 2))
        #expect(copy.isInMuseum)
        let familyChildren = try f.fetch(FetchDescriptor<Child>())
        #expect(familyChildren.map(\.id) == [kid.id])

        // Copying again makes no duplicates.
        let again = try await ArchiveStore.copyMuseum(from: personal, to: family)
        #expect(again == 0)
        let familyCount = try ModelContext(family).fetchCount(FetchDescriptor<Artwork>())
        #expect(familyCount == 1)
    }

    /// Leaving copies the family works back: new ones are added, a personal record edited later than the family
    /// copy keeps its edits, nothing in the personal store is removed.
    @Test func copyingBackNeverRemovesOrOverwritesNewerPersonalWork() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let personal = try ArchiveStore.openPersonalForCopy(url: dir.appendingPathComponent("default.store"))
        let family = try ArchiveStore.openFamilyForCopy(url: dir.appendingPathComponent("family.store"))

        let shared = UUID()
        let p = ModelContext(personal)
        let mine = Artwork(kind: .flat, child: nil, capturedAt: day(2026, 1, 1), originalImageData: Data([1]))
        mine.id = shared
        mine.title = "我改過的"
        mine.modifiedAt = day(2026, 3, 1)
        let onlyMine = Artwork(kind: .flat, child: nil, capturedAt: day(2026, 1, 2), originalImageData: Data([2]))
        p.insert(mine)
        p.insert(onlyMine)
        try p.save()

        let f = ModelContext(family)
        let theirs = Artwork(kind: .flat, child: nil, capturedAt: day(2026, 1, 1), originalImageData: Data([1]))
        theirs.id = shared
        theirs.title = "舊的"
        theirs.modifiedAt = day(2026, 2, 1)
        let fromFamily = Artwork(kind: .craft, child: nil, capturedAt: day(2026, 1, 5), originalImageData: Data([3]))
        fromFamily.title = "家人拍的"
        f.insert(theirs)
        f.insert(fromFamily)
        try f.save()

        let copied = try await ArchiveStore.copyMuseum(from: family, to: personal)
        #expect(copied == 1)
        let all = try ModelContext(personal).fetch(FetchDescriptor<Artwork>())
        #expect(Set(all.map(\.id)) == [shared, onlyMine.id, fromFamily.id])
        #expect(all.first { $0.id == shared }?.title == "我改過的")
        #expect(all.first { $0.id == fromFamily.id }?.title == "家人拍的")

        // A newer family edit does update the personal copy (never deletes it).
        theirs.title = "家人後來改的"
        theirs.modifiedAt = day(2026, 4, 1)
        try f.save()
        let updated = try await ArchiveStore.copyMuseum(from: family, to: personal)
        #expect(updated == 1)
        let refreshed = try ModelContext(personal).fetch(FetchDescriptor<Artwork>())
        #expect(refreshed.count == 3)
        #expect(refreshed.first { $0.id == shared }?.title == "家人後來改的")
    }

    /// 直接離開 still rescues unsent works: only those (and their child) are copied into the personal store.
    @Test func copyingOnlyUnsentWorksBringsTheirChild() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let personal = try ArchiveStore.openPersonalForCopy(url: dir.appendingPathComponent("default.store"))
        let family = try ArchiveStore.openFamilyForCopy(url: dir.appendingPathComponent("family.store"))
        let f = ModelContext(family)
        let kid = Child(name: "小華")
        let otherKid = Child(name: "表哥")
        f.insert(kid)
        f.insert(otherKid)
        let unsent = Artwork(kind: .flat, child: kid, capturedAt: day(2026, 2, 1), originalImageData: Data([1]))
        let synced = Artwork(kind: .flat, child: otherKid, capturedAt: day(2026, 2, 2), originalImageData: Data([2]))
        f.insert(unsent)
        f.insert(synced)
        try f.save()

        let copied = try await ArchiveStore.copyMuseum(from: family, to: personal, only: [unsent.id])
        #expect(copied == 1)
        let p = ModelContext(personal)
        let artworks = try p.fetch(FetchDescriptor<Artwork>())
        #expect(artworks.map(\.id) == [unsent.id])
        #expect(artworks.first?.child?.id == kid.id)
        let children = try p.fetch(FetchDescriptor<Child>())
        #expect(children.map(\.id) == [kid.id])
    }

    @Test func newerCompareTreatsUnstampedAsOldest() {
        let t = day(2026, 1, 1)
        #expect(ArchiveStore.isNewer(t, than: nil))
        #expect(!ArchiveStore.isNewer(nil, than: t))
        #expect(!ArchiveStore.isNewer(nil, than: nil))
        #expect(!ArchiveStore.isNewer(t, than: t))
        #expect(ArchiveStore.isNewer(t.addingTimeInterval(1), than: t))
    }
}
