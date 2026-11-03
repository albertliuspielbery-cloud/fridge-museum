import CloudKit
import Foundation
import Observation
import SwiftData
import UIKit

/// 家庭美術館 (1.3.0): one museum shared by several Apple Accounts (PLAN-1.3.md §A).
///
/// SwiftData can't mirror a CloudKit *shared* database, so the family museum is synced by hand with CKSyncEngine:
/// - the owner's records live in the custom zone `FamilyMuseum` of their private database, shared as a whole with a
///   zone-wide CKShare (participants read/write); the owner's engine runs on `privateCloudDatabase`;
/// - a member's engine runs on `sharedCloudDatabase` and sees the same zone.
/// Locally the family museum is its own SwiftData file (family.store, ArchiveStore). Exactly one store is opened per
/// launch — the personal one (1.2 rules, CloudSync) or the family one — so creating, joining, leaving or stopping
/// takes effect at the next launch, like the 1.2 sync switch. **The personal store is never deleted or emptied**:
/// entering copies the personal works into family.store, every way out copies the family works back.
///
/// Local changes are found by comparing the store with the uploaded-state table (`FamilySyncState.uploaded`) after
/// every save (`ModelContext.didSave` — that covers AppModel's save points and the editors' alike, so AppModel needs
/// no hooks), see `FamilySyncPolicy.changes`. Downloads update the table as they are written, so they are never sent
/// back. The decisions are in ArchiveKit/FamilySyncPolicy.swift (unit-tested); this file only talks to CloudKit.
///
/// Simulator, screenshot demos and unit tests never touch CloudKit (`CloudSync.isSupportedEnvironment`).
@MainActor
@Observable
final class FamilySync {
    enum Keys {
        static let membership = "family.membership"
        static let lastSyncedAt = "family.lastSyncedAt"
        /// A family museum ended while the app was open: Bibi says so once at the next (personal) launch.
        static let endedNotice = "family.endedNotice"
    }

    /// The app's instance: the scene delegate hands share invitations to it.
    static weak var current: FamilySync?

    /// Which store this launch opened. Never changes during the session.
    private(set) var mode: MuseumMode = .personal
    /// What is saved on this phone (may already differ from `mode`: created / joined / left this session).
    private(set) var membership: FamilyMembership?
    private(set) var activity: SyncActivity = .idle
    private(set) var lastSyncedAt: Date?
    /// The family museum ended during this session (the personal museum opens at the next launch).
    private(set) var endedThisSession: FamilyEndReason?
    /// Creating, joining, leaving or stopping is in progress (Settings shows a spinner, buttons wait).
    private(set) var isWorking = false
    /// A share invitation waiting for 加入 / 先不要 (RootView shows FamilyJoinSheet).
    var invite: FamilyInvite?
    /// Something Bibi says once (RootView shows it as a toast).
    var notice: FamilyNotice?
    /// The result of a stop / leave that wasn't started from Settings' own buttons (the system sharing screen, or a
    /// stop resumed at launch): Settings shows it in an alert, RootView as a toast when Settings isn't open.
    var pendingMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var state = FamilySyncState()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Records whose upload failed for a reason a retry won't fix: not queued again this session (a broken record
    /// must not upload its images again after every save).
    @ObservationIgnored private var failedThisSession: Set<String> = []
    /// Record names found in the store by a scan this session: their disappearance is a real deletion
    /// (FamilySyncPolicy.massDeleteGuard).
    @ObservationIgnored private var seenThisSession: Set<String> = []
    @ObservationIgnored private var refetchTask: Task<Void, Never>?
    @ObservationIgnored private var refetchRounds = 0
    @ObservationIgnored private let shareDelegate = FamilyShareControllerDelegate()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        membership = defaults.data(forKey: Keys.membership).flatMap { try? JSONDecoder().decode(FamilyMembership.self, from: $0) }
        lastSyncedAt = defaults.object(forKey: Keys.lastSyncedAt) as? Date
        Self.current = self
        shareDelegate.onStop = { [weak self] in self?.sharingStoppedInController() }
    }

    /// The family museum can be used in this build (Settings shows the section).
    var isAvailable: Bool { CloudSync.isSupportedEnvironment }

    /// This launch shares the Full Version with the family.
    var grantsFullVersion: Bool { FamilySyncPolicy.grantsFullVersion(mode: mode) }

    var isFamilyMode: Bool { mode.opensFamilyStore }

    var status: FamilyStatus {
        FamilySyncPolicy.status(mode: mode, membership: membership, endedThisSession: endedThisSession,
                                activity: activity, hasSynced: lastSyncedAt != nil)
    }

    private var zoneID: CKRecordZone.ID? {
        guard let membership else { return nil }
        return CKRecordZone.ID(zoneName: FamilySyncPolicy.zoneName, ownerName: membership.zoneOwnerName)
    }

    // MARK: Launch

    /// Decides this launch's store. Returns family.store when this is a family launch (the caller then doesn't open
    /// the personal store at all), nil for a personal launch.
    func openStoreIfFamily() -> ModelContainer? {
        let decided = FamilySyncPolicy.mode(isSupported: CloudSync.isSupportedEnvironment, membership: membership)
        mode = decided
        guard decided.opensFamilyStore else {
            showEndedNoticeIfAny()
            return nil
        }
        let opened = ArchiveStore.openFamily()
        container = opened
        // An in-memory stand-in (family.store couldn't be opened) must never sync: its emptiness would look like
        // "everything was deleted". Nor can it be copied from; the next launch tries again.
        guard !ArchiveStore.isTemporary else { return opened }
        switch decided {
        case .family(let role):
            startSync()
            // A 停止分享 that didn't finish last time (offline, failed copy, or the system sharing screen removed
            // the share) finishes now.
            if role == .owner, membership?.stopRequested == true {
                Task {
                    if let message = await stopSharing() { pendingMessage = message }
                }
            }
        case .closingFamily(let reason): Task { await finishEnding(reason, copy: true) }
        case .personal: break
        }
        return opened
    }

    private func showEndedNoticeIfAny() {
        guard let raw = defaults.string(forKey: Keys.endedNotice) else { return }
        defaults.removeObject(forKey: Keys.endedNotice)
        if let reason = FamilyEndReason(rawValue: raw) { notice = .backToPersonal(reason) }
    }

    // MARK: Sync engine

    private func startSync() {
        guard engine == nil, let membership, container != nil else { return }
        state = loadState()
        try? FileManager.default.removeItem(at: Self.outboxURL)   // asset files of an earlier session
        let ck = CKContainer(identifier: CloudSync.containerID)
        let database = membership.role == .owner ? ck.privateCloudDatabase : ck.sharedCloudDatabase
        let configuration = CKSyncEngine.Configuration(database: database, stateSerialization: loadEngineState(),
                                                       delegate: self)
        engine = CKSyncEngine(configuration)
        UIApplication.shared.registerForRemoteNotifications()

        let center = NotificationCenter.default
        // Every save, wherever it happens (AppModel, editors, Settings): look for local changes a moment later.
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScan(after: 2) }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanNow() }
        })
        scheduleScan(after: 1)
        scheduleRefetch()
    }

    /// Stops syncing for the rest of the session. Doesn't wait for the engine's operations to wind down: this also
    /// runs inside the engine's own delegate callbacks, which an in-flight operation may be waiting for.
    private func stopSync() async {
        scanTask?.cancel()
        scanTask = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let engine {
            self.engine = nil
            Task { await engine.cancelOperations() }
        }
    }

    private func scheduleScan(after seconds: Double) {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.scanNow()
        }
    }

    /// Compares the store with the uploaded-state table and queues what changed. Reads small fields only.
    /// The family store's museum records, small fields only.
    private func localItems() -> [FamilyLocalItem]? {
        guard let context = container?.mainContext else { return nil }
        var items: [FamilyLocalItem] = []
        var artworks = FetchDescriptor<Artwork>(predicate: #Predicate { $0.isKept && !$0.isSample })
        artworks.propertiesToFetch = [\.id, \.modifiedAt, \.renderVersion, \.processingStateRaw]
        for a in (try? context.fetch(artworks)) ?? [] where !a.isDeleted {
            let busy = a.processingState == .pending || a.processingState == .processing
            items.append(FamilyLocalItem(id: a.id, stamp: FamilyStamp(kind: .artwork, modifiedAt: a.modifiedAt,
                                                                       renderVersion: a.renderVersion),
                                         isReady: !busy))
        }
        var children = FetchDescriptor<Child>()
        children.propertiesToFetch = [\.id, \.modifiedAt]
        for c in (try? context.fetch(children)) ?? [] where !c.isDeleted {
            items.append(FamilyLocalItem(id: c.id, stamp: FamilyStamp(kind: .child, modifiedAt: c.modifiedAt)))
        }
        return items
    }

    private func scanNow() {
        guard let engine, let zoneID, endedThisSession == nil, let items = localItems() else { return }
        let changes = FamilySyncPolicy.changes(local: items, uploaded: state.uploaded, seenThisSession: seenThisSession)
        seenThisSession.formUnion(items.map(\.recordName))
        guard !changes.isEmpty else { return }
        let pending = engine.state.pendingRecordZoneChanges
        var add: [CKSyncEngine.PendingRecordZoneChange] = []
        var drop: [CKSyncEngine.PendingRecordZoneChange] = []
        // A record waiting to be fetched again (unreadable asset) isn't uploaded until the server's version is here.
        for name in changes.saves where !failedThisSession.contains(name) && !state.refetch.contains(name) {
            let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(FamilyRecordCodec.recordID(name, zoneID: zoneID))
            if !pending.contains(change) { add.append(change) }
        }
        for name in changes.deletes {
            let id = FamilyRecordCodec.recordID(name, zoneID: zoneID)
            let change = CKSyncEngine.PendingRecordZoneChange.deleteRecord(id)
            if !pending.contains(change) { add.append(change) }
            let save = CKSyncEngine.PendingRecordZoneChange.saveRecord(id)
            if pending.contains(save) { drop.append(save) }
        }
        if !drop.isEmpty { engine.state.remove(pendingRecordZoneChanges: drop) }
        if !add.isEmpty { engine.state.add(pendingRecordZoneChanges: add) }
    }

    private func queueSave(_ name: String) {
        guard let engine, let zoneID else { return }
        let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(FamilyRecordCodec.recordID(name, zoneID: zoneID))
        if !engine.state.pendingRecordZoneChanges.contains(change) {
            engine.state.add(pendingRecordZoneChanges: [change])
        }
    }

    private func inFamilyZone(_ id: CKRecordZone.ID) -> Bool {
        guard let membership, id.zoneName == FamilySyncPolicy.zoneName else { return false }
        return membership.role == .owner || id.ownerName == membership.zoneOwnerName
    }

    // MARK: Store lookups

    private var context: ModelContext? { container?.mainContext }

    private func artwork(_ id: UUID) -> Artwork? {
        var d = FetchDescriptor<Artwork>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context?.fetch(d))?.first
    }

    private func child(_ id: UUID) -> Child? {
        var d = FetchDescriptor<Child>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context?.fetch(d))?.first
    }

    private func localStamp(_ name: String) -> FamilyStamp? {
        guard let id = UUID(uuidString: name) else { return nil }
        if let a = artwork(id), FamilySyncPolicy.qualifies(isKept: a.isKept, isSample: a.isSample) {
            return FamilyStamp(kind: .artwork, modifiedAt: a.modifiedAt, renderVersion: a.renderVersion)
        }
        if let c = child(id) { return FamilyStamp(kind: .child, modifiedAt: c.modifiedAt) }
        return nil
    }

    /// The record to upload for a pending save, built on the last known server record. nil = nothing to upload
    /// any more (deleted, or no longer in the museum).
    private func outgoingRecord(_ recordID: CKRecord.ID) -> CKRecord? {
        guard let zoneID, let id = UUID(uuidString: recordID.recordName) else { return nil }
        let name = recordID.recordName
        let base = state.systemFields[name].flatMap(FamilyRecordCodec.decodeSystemFields)
        if let a = artwork(id), FamilySyncPolicy.qualifies(isKept: a.isKept, isSample: a.isSample) {
            return try? FamilyRecordCodec.record(FamilyArtworkFields(a), zoneID: zoneID,
                                                 base: base?.recordType == FamilySyncPolicy.artworkRecordType ? base : nil,
                                                 assetDirectory: Self.outboxURL)
        }
        if let c = child(id) {
            return try? FamilyRecordCodec.record(FamilyChildFields(c), zoneID: zoneID,
                                                 base: base?.recordType == FamilySyncPolicy.childRecordType ? base : nil,
                                                 assetDirectory: Self.outboxURL)
        }
        return nil
    }

    // MARK: Applying downloads

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        let records = changes.modifications.map(\.record).filter { inFamilyZone($0.recordID.zoneID) }
        // Children first, so artworks in the same batch find theirs.
        for record in records where record.recordType == FamilySyncPolicy.childRecordType { applyIncoming(record, conflict: false) }
        for record in records where record.recordType == FamilySyncPolicy.artworkRecordType { applyIncoming(record, conflict: false) }
        for deletion in changes.deletions where inFamilyZone(deletion.recordID.zoneID) {
            applyDeletion(deletion.recordID.recordName)
        }
        try? context?.save()
        saveState()
    }

    /// A downloaded record (`conflict` false) or the server's copy from a `serverRecordChanged` (`conflict` true).
    private func applyIncoming(_ record: CKRecord, conflict: Bool) {
        guard let context, let server = FamilyRecordCodec.stamp(of: record) else { return }
        let name = record.recordID.recordName
        let mine = localStamp(name)
        let winner = conflict
            ? FamilySyncPolicy.resolveConflict(localModifiedAt: mine?.modifiedAt, serverModifiedAt: server.modifiedAt)
            : FamilySyncPolicy.resolveIncoming(local: mine, uploaded: state.uploaded[name], server: server)
        let unreadable = !FamilyRecordCodec.unreadableAssets(in: record).isEmpty
        switch FamilySyncPolicy.incomingAction(winner: winner, hasUnreadableAssets: unreadable) {
        case .keepLocal:
            // An edit made here is newer: upload it on top of the server's version (no assets needed for that).
            state.systemFields[name] = FamilyRecordCodec.encodeSystemFields(record)
            state.refetch.remove(name)   // the local copy is the one going up; no refetch needed
            queueSave(name)
            return
        case .refetch:
            // The server's version wins, but an image file isn't readable (e.g. a conflict's serverRecord without
            // downloaded assets). Nothing here changes — not the store, not the change tag, not the uploaded
            // table — until the whole record is fetched again; meanwhile this record isn't uploaded (scanNow).
            state.refetch.insert(name)
            scheduleRefetch()
            return
        case .apply:
            state.systemFields[name] = FamilyRecordCodec.encodeSystemFields(record)
            state.refetch.remove(name)
        }
        switch server.kind {
        case .child:
            guard let fields = FamilyRecordCodec.childFields(from: record) else { return }
            let target = child(fields.id) ?? {
                let made = Child(name: fields.name)
                context.insert(made)
                return made
            }()
            fields.apply(to: target)
            linkAwaitingArtworks(to: target)
        case .artwork:
            guard let fields = FamilyRecordCodec.artworkFields(from: record) else { return }
            let owner = fields.childID.flatMap { child($0) }
            let target = artwork(fields.id) ?? {
                let made = Artwork(kind: ArtworkKind(rawValue: fields.kindRaw) ?? .flat, child: nil,
                                   capturedAt: fields.capturedAt, originalImageData: Data())
                context.insert(made)
                return made
            }()
            fields.apply(to: target, child: owner)
            if let childID = fields.childID, owner == nil {
                state.awaitingChild[name] = childID.uuidString
            } else {
                state.awaitingChild[name] = nil
            }
        }
        state.uploaded[name] = server
    }

    /// A child arrived after artworks that point at it.
    private func linkAwaitingArtworks(to child: Child) {
        let childName = child.id.uuidString
        for (artworkName, wanted) in state.awaitingChild where wanted == childName {
            if let id = UUID(uuidString: artworkName), let a = artwork(id) { a.child = child }
            state.awaitingChild[artworkName] = nil
        }
    }

    /// Fetches records whose server version arrived with an unreadable asset again, directly (the sync engine won't
    /// deliver them twice), and applies them once every asset reads. A few rounds per session at most; the rest
    /// waits for the next launch (they stay in `state.refetch`, and aren't uploaded meanwhile).
    private func scheduleRefetch() {
        guard refetchTask == nil, refetchRounds < 5, engine != nil, let membership, !state.refetch.isEmpty else { return }
        refetchRounds += 1
        let names = Array(state.refetch)
        let owner = membership.zoneOwnerName
        let isOwner = membership.role == .owner
        refetchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            let fetched = await Self.fetchRecords(names: names, zoneOwnerName: owner, isOwner: isOwner)
            guard let self else { return }
            self.refetchTask = nil
            guard self.engine != nil, self.endedThisSession == nil else { return }
            // Deleted meanwhile: the deletion arrives through the engine.
            for name in fetched.value.gone { self.state.refetch.remove(name) }
            for record in fetched.value.records where record.recordType == FamilySyncPolicy.childRecordType {
                self.applyIncoming(record, conflict: false)
            }
            for record in fetched.value.records where record.recordType == FamilySyncPolicy.artworkRecordType {
                self.applyIncoming(record, conflict: false)
            }
            try? self.context?.save()
            self.saveState()
        }
    }

    private func applyDeletion(_ name: String) {
        guard let id = UUID(uuidString: name) else { return }
        switch FamilySyncPolicy.resolveIncomingDeletion(local: localStamp(name), uploaded: state.uploaded[name]) {
        case .server:
            // family.store only (this container is always the family one).
            if let a = artwork(id) { context?.delete(a) }
            if let c = child(id) { context?.delete(c) }
            state.uploaded[name] = nil
            state.systemFields[name] = nil
            state.awaitingChild[name] = nil
        case .local:
            // Edited here since the last upload: keep it, and create it again in the zone.
            state.uploaded[name] = nil
            state.systemFields[name] = nil
            queueSave(name)
        }
    }

    // MARK: Upload results

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) async {
        for record in sent.savedRecords {
            let name = record.recordID.recordName
            state.systemFields[name] = FamilyRecordCodec.encodeSystemFields(record)
            if let stamp = FamilyRecordCodec.stamp(of: record) { state.uploaded[name] = stamp }
            state.refetch.remove(name)   // the server now has this phone's copy
            removeOutboxFiles(name)
        }
        var ended = false
        for failure in sent.failedRecordSaves {
            let name = failure.record.recordID.recordName
            removeOutboxFiles(name)
            let error = failure.error
            switch error.code {
            case .serverRecordChanged:
                if let server = error.serverRecord { applyIncoming(server, conflict: true) } else { queueSave(name) }
            case .unknownItem:
                // Deleted in the zone while this phone changed it: create it again (the edit isn't lost).
                state.systemFields[name] = nil
                queueSave(name)
            case .zoneNotFound, .userDeletedZone:
                ended = true
            case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy,
                 .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled, .batchRequestFailed:
                activity = .failed(SyncEvent.classify(error))
                queueSave(name)
            case .quotaExceeded:
                activity = .failed(.quotaFull)
                queueSave(name)
            default:
                activity = .failed(.other)
                failedThisSession.insert(name)
            }
        }
        for id in sent.deletedRecordIDs {
            state.uploaded[id.recordName] = nil
            state.systemFields[id.recordName] = nil
        }
        for (id, error) in sent.failedRecordDeletes {
            switch error.code {
            case .unknownItem:
                state.uploaded[id.recordName] = nil
                state.systemFields[id.recordName] = nil
            case .zoneNotFound, .userDeletedZone:
                ended = true
            default:
                activity = .failed(SyncEvent.classify(error))
            }
        }
        if !sent.savedRecords.isEmpty, sent.failedRecordSaves.isEmpty, sent.failedRecordDeletes.isEmpty {
            activity = .idle
            markSynced()
        }
        try? context?.save()
        saveState()
        if ended { await end(.revoked) }
    }

    private func markSynced() {
        let now = Date()
        lastSyncedAt = now
        defaults.set(now, forKey: Keys.lastSyncedAt)
    }

    // MARK: Ending (revoked, account changed, left, stopped)

    /// The family museum ended without the person choosing it (removed, sharing stopped, iCloud account changed):
    /// copy the family works into the personal store, then the next launch opens the personal museum.
    private func end(_ reason: FamilyEndReason) async {
        guard endedThisSession == nil, var saved = membership else { return }
        endedThisSession = reason
        await stopSync()
        saved.pendingEnd = reason
        saveMembership(saved)
        await finishEnding(reason, copy: true)
    }

    /// Copies the family works into the personal store (if asked) and forgets the membership. If the copy fails the
    /// membership stays with `pendingEnd`, and the next launch opens family.store again (without sync) to retry.
    private func finishEnding(_ reason: FamilyEndReason, copy: Bool) async {
        if copy {
            guard let container else { return }
            do {
                let personal = try ArchiveStore.openPersonalForCopy()
                try await ArchiveStore.copyMuseum(from: container, to: personal)
            } catch {
                return
            }
        }
        saveMembership(nil)
        Self.deleteSyncFiles()
        if endedThisSession == nil { endedThisSession = reason }
        defaults.set(reason.rawValue, forKey: Keys.endedNotice)
        if reason == .revoked || reason == .accountChanged { notice = .ended(reason) }
    }

    /// Before leaving or stopping: fetch the family's latest changes, queue this phone's own, and try to send them.
    /// Returns whether the fetch got through (each step has a time limit; offline just means "not sent").
    private func flush() async -> Bool {
        guard let engine else { return false }
        let fetched = await CloudSync.withTimeout(seconds: 20) { () async -> Bool in
            do { try await engine.fetchChanges(); return true } catch { return false }
        }
        scanNow()
        _ = await CloudSync.withTimeout(seconds: 40) { () async -> Bool in
            do { try await engine.sendChanges(); return true } catch { return false }
        }
        return fetched == true
    }

    /// Records in family.store the family doesn't have (FamilySyncPolicy.unsent).
    private func unsentIDs() -> Set<UUID> {
        Set(FamilySyncPolicy.unsent(local: localItems() ?? [], uploaded: state.uploaded).compactMap { UUID(uuidString: $0) })
    }

    /// 停止分享 (owner): brings family.store up to date (and sends this phone's changes), copies the family works into
    /// the personal store, then deletes the zone (and with it the share; every member's phone copies its works back
    /// when it notices). Marked `stopRequested` first, so a stop that doesn't finish (offline, a failed copy, or the
    /// system sharing screen already removed the share) is resumed at the next launch. Returns a message when it
    /// couldn't finish (nothing is lost; sharing simply continues until it does).
    func stopSharing() async -> String? {
        guard case .family(.owner) = mode, endedThisSession == nil, let container, engine != nil,
              var saved = membership else { return nil }
        isWorking = true
        defer { isWorking = false }
        if saved.stopRequested != true {
            saved.stopRequested = true
            saveMembership(saved)
        }
        guard await flush() else {
            return String(localized: "沒有連上網路，家庭美術館還在分享中。請連上網路再試一次。")
        }
        await stopSync()
        do {
            // Everything, so unsent works are kept too.
            let personal = try ArchiveStore.openPersonalForCopy()
            try await ArchiveStore.copyMuseum(from: container, to: personal)
        } catch {
            startSync()
            return String(localized: "作品沒辦法複製到你的美術館，所以先不停止分享。請重新打開 App 再試一次。")
        }
        do {
            try await Self.deleteFamilyZone()
        } catch {
            startSync()
            return String(localized: "沒有連上網路，家庭美術館還在分享中。請連上網路再試一次。")
        }
        endedThisSession = .stopped
        await finishEnding(.stopped, copy: false)
        return nil
    }

    /// 離開家庭美術館 (member). `copyWorks`: keep a copy of the family works in the personal museum. Works the family
    /// doesn't have yet (not uploaded: offline, still rendering) are always copied — they may exist nowhere else.
    /// `alreadyLeft`: the system sharing screen's 移除我 already removed this phone's account from the share.
    /// Returns a message for the person (a problem, or that unsent works were kept).
    func leave(copyWorks: Bool, alreadyLeft: Bool = false) async -> String? {
        guard mode.opensFamilyStore, endedThisSession == nil, let container, let membership else { return nil }
        isWorking = true
        defer { isWorking = false }
        _ = await flush()
        let unsent = unsentIDs()
        await stopSync()
        if copyWorks || !unsent.isEmpty {
            do {
                let personal = try ArchiveStore.openPersonalForCopy()
                try await ArchiveStore.copyMuseum(from: container, to: personal, only: copyWorks ? nil : unsent)
            } catch {
                if !alreadyLeft { startSync() }
                return String(localized: "作品沒辦法複製到你的美術館，所以先不離開。請重新打開 App 再試一次。")
            }
        }
        if !alreadyLeft && membership.role == .member {
            do {
                try await Self.leaveShare(zoneOwnerName: membership.zoneOwnerName)
            } catch {
                startSync()
                return String(localized: "沒有連上網路，還沒離開家庭美術館。請連上網路再試一次。")
            }
        }
        endedThisSession = .left
        await finishEnding(.left, copy: false)
        if !copyWorks && !unsent.isEmpty {
            return String(localized: "有些作品還沒傳到家庭美術館，已經先複製一份到你的美術館，不會不見。")
        }
        return nil
    }

    /// The system sharing screen stopped the share (owner) or removed this member. Finishes the same way as the
    /// buttons do, and shows what happened if it couldn't finish.
    private func sharingStoppedInController() {
        guard let membership, endedThisSession == nil else { return }
        Task {
            var message: String?
            if membership.role == .owner, case .family(.owner) = mode {
                message = await stopSharing()
            } else if case .family = mode {
                message = await leave(copyWorks: true, alreadyLeft: true)
            } else {
                // Stopped before this phone switched over: nothing local to copy.
                saveMembership(nil)
                Self.deleteSyncFiles()
                endedThisSession = membership.role == .owner ? .stopped : .left
            }
            if let message { pendingMessage = message }
        }
    }

    // MARK: Creating (owner)

    /// 建立家庭美術館: creates the zone and its share, copies the personal museum into a fresh family.store
    /// (the personal store is only read), and remembers the membership; the family museum opens at the next launch.
    /// Then shows the system sharing screen to invite family. Returns a message when it couldn't.
    func create(personal: ModelContainer, isPurchased: Bool) async -> String? {
        guard FamilySyncPolicy.canCreate(isPurchased: isPurchased, isSupported: isAvailable, membership: membership),
              mode == .personal else { return nil }
        isWorking = true
        defer { isWorking = false }
        guard await CloudSync.fetchAccount() == .available else {
            return String(localized: "要先登入 iCloud 才能建立家庭美術館。到 iPhone「設定」登入 Apple 帳號後再試一次。")
        }
        let share: CKShare
        do {
            share = try await Self.makeZoneAndShare(title: String(localized: "家庭美術館")).value
        } catch {
            return Self.message(for: error)
        }
        do {
            try ArchiveStore.resetFamilyStore()
            Self.deleteSyncFiles()
            let family = try ArchiveStore.openFamilyForCopy()
            try await ArchiveStore.copyMuseum(from: personal, to: family)
        } catch {
            return String(localized: "作品沒辦法複製到家庭美術館，請再試一次。你的美術館沒有任何改變。")
        }
        saveMembership(FamilyMembership(role: .owner, zoneOwnerName: CKCurrentUserDefaultName, ownerDisplayName: nil,
                                        joinedAt: Date()))
        present(share)
        return nil
    }

    // MARK: Inviting / members

    /// 邀請家人 (owner) or 家庭成員 (member): the system sharing screen.
    func showSharing() async -> String? {
        guard let membership, endedThisSession == nil else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let share = try await Self.fetchShare(zoneOwnerName: membership.zoneOwnerName,
                                                  isOwner: membership.role == .owner).value
            present(share)
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    private func present(_ share: CKShare) {
        let controller = UICloudSharingController(share: share, container: CKContainer(identifier: CloudSync.containerID))
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = shareDelegate
        Self.topViewController()?.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: Joining (member)

    /// An invitation link was opened (scene delegate). Shows the join sheet; nothing changes until 加入.
    static func receive(_ metadata: CKShare.Metadata) {
        current?.handleInvitation(metadata)
    }

    private func handleInvitation(_ metadata: CKShare.Metadata) {
        guard CloudSync.isSupportedEnvironment else { return }
        let zone = metadata.share.recordID.zoneID
        guard metadata.containerIdentifier == CloudSync.containerID,
              metadata.share.recordID.recordName == CKRecordNameZoneWideShare,
              zone.zoneName == FamilySyncPolicy.zoneName else {
            notice = .invalidInvitation
            return
        }
        let name = metadata.ownerIdentity.nameComponents
            .map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            .flatMap { $0.isEmpty ? nil : $0 }
        invite = FamilyInvite(metadata: metadata, ownerName: name, isOwnShare: metadata.participantRole == .owner,
                              zoneOwnerName: zone.ownerName)
    }

    /// 加入: accepts the share, empties family.store, copies the personal works into it if asked (the personal
    /// store is only read), and remembers the membership; the family museum opens at the next launch.
    func join(_ invite: FamilyInvite, copyMyWorks: Bool, personal: ModelContainer) async -> String? {
        guard membership == nil, mode == .personal else {
            return String(localized: "你已經在家庭美術館裡了。要加入別的家庭美術館，請先到設定離開。")
        }
        isWorking = true
        defer { isWorking = false }
        if !invite.isOwnShare {
            do {
                try await Self.accept(UncheckedSendableBox(invite.metadata))
            } catch {
                return Self.message(for: error)
            }
        }
        do {
            try ArchiveStore.resetFamilyStore()
            Self.deleteSyncFiles()
            if copyMyWorks {
                let family = try ArchiveStore.openFamilyForCopy()
                try await ArchiveStore.copyMuseum(from: personal, to: family)
            }
        } catch {
            return String(localized: "作品沒辦法複製到家庭美術館，請再試一次。你的美術館沒有任何改變。")
        }
        // The owner opening their own link on another device: the same zone, in their private database.
        saveMembership(FamilyMembership(role: invite.isOwnShare ? .owner : .member,
                                        zoneOwnerName: invite.isOwnShare ? CKCurrentUserDefaultName : invite.zoneOwnerName,
                                        ownerDisplayName: invite.isOwnShare ? nil : invite.ownerName,
                                        joinedAt: Date()))
        return nil
    }

    // MARK: Persistence

    private func saveMembership(_ value: FamilyMembership?) {
        membership = value
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Keys.membership)
        } else {
            defaults.removeObject(forKey: Keys.membership)
        }
    }

    private static var directoryURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("FamilyMuseum", isDirectory: true)
    }
    private static var stateURL: URL { directoryURL.appendingPathComponent("sync-state.json") }
    private static var engineStateURL: URL { directoryURL.appendingPathComponent("engine-state.json") }
    /// Asset files waiting to upload (CKAsset needs a file).
    static var outboxURL: URL { directoryURL.appendingPathComponent("outbox", isDirectory: true) }

    private func loadState() -> FamilySyncState {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let decoded = try? JSONDecoder().decode(FamilySyncState.self, from: data) else { return FamilySyncState() }
        return decoded
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    private func loadEngineState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: Self.engineStateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveEngineState(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        try? FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
        try? data.write(to: Self.engineStateURL, options: .atomic)
    }

    /// Forgets everything about a previous zone (a new family museum starts clean). Not the stores.
    private static func deleteSyncFiles() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func removeOutboxFiles(_ recordName: String) {
        let prefix = FamilyRecordCodec.assetFilePrefix(recordName)
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.outboxURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: CloudKit calls (nonisolated; only Sendable values cross back)

    nonisolated private static func makeZoneAndShare(title: String) async throws -> UncheckedSendableBox<CKShare> {
        let database = CKContainer(identifier: CloudSync.containerID).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: FamilySyncPolicy.zoneName, ownerName: CKCurrentUserDefaultName)
        let zones = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        if case .failure(let error)? = zones.saveResults[zoneID] { throw error }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        // A share left from an earlier attempt is reused.
        if let existing = try? await database.record(for: shareID), let share = existing as? CKShare {
            return UncheckedSendableBox(share)
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = title
        share.publicPermission = .none
        let saved = try await database.modifyRecords(saving: [share], deleting: [])
        guard let result = saved.saveResults[share.recordID] else { throw CKError(.internalError) }
        guard let savedShare = try result.get() as? CKShare else { throw CKError(.internalError) }
        return UncheckedSendableBox(savedShare)
    }

    nonisolated private static func fetchShare(zoneOwnerName: String, isOwner: Bool) async throws -> UncheckedSendableBox<CKShare> {
        let ck = CKContainer(identifier: CloudSync.containerID)
        let database = isOwner ? ck.privateCloudDatabase : ck.sharedCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: FamilySyncPolicy.zoneName, ownerName: zoneOwnerName)
        let record = try await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID))
        guard let share = record as? CKShare else { throw CKError(.unknownItem) }
        return UncheckedSendableBox(share)
    }

    struct FetchedRecords {
        var records: [CKRecord] = []
        /// No longer on the server.
        var gone: [String] = []
    }

    /// Fetches records of the family zone directly (with their assets). Failures leave them for a later round.
    nonisolated private static func fetchRecords(names: [String], zoneOwnerName: String,
                                                 isOwner: Bool) async -> UncheckedSendableBox<FetchedRecords> {
        let ck = CKContainer(identifier: CloudSync.containerID)
        let database = isOwner ? ck.privateCloudDatabase : ck.sharedCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: FamilySyncPolicy.zoneName, ownerName: zoneOwnerName)
        var fetched = FetchedRecords()
        guard let results = try? await database.records(for: names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
        else { return UncheckedSendableBox(fetched) }
        for (id, result) in results {
            switch result {
            case .success(let record):
                fetched.records.append(record)
            case .failure(let error):
                if (error as? CKError)?.code == .unknownItem { fetched.gone.append(id.recordName) }
            }
        }
        return UncheckedSendableBox(fetched)
    }

    nonisolated private static func deleteFamilyZone() async throws {
        let database = CKContainer(identifier: CloudSync.containerID).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: FamilySyncPolicy.zoneName, ownerName: CKCurrentUserDefaultName)
        let result = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
        if case .failure(let error)? = result.deleteResults[zoneID] {
            if let ck = error as? CKError, ck.code == .zoneNotFound || ck.code == .userDeletedZone { return }
            throw error
        }
    }

    /// A participant leaves a share by deleting it from their shared database (the owner's data is untouched).
    nonisolated private static func leaveShare(zoneOwnerName: String) async throws {
        let database = CKContainer(identifier: CloudSync.containerID).sharedCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: FamilySyncPolicy.zoneName, ownerName: zoneOwnerName)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let result = try await database.modifyRecords(saving: [], deleting: [shareID])
        if case .failure(let error)? = result.deleteResults[shareID] {
            if let ck = error as? CKError, [.unknownItem, .zoneNotFound, .userDeletedZone].contains(ck.code) { return }
            throw error
        }
    }

    nonisolated private static func accept(_ metadata: UncheckedSendableBox<CKShare.Metadata>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata.value])
            operation.qualityOfService = .userInitiated
            operation.acceptSharesResultBlock = { result in
                continuation.resume(with: result)
            }
            CKContainer(identifier: CloudSync.containerID).add(operation)
        }
    }

    nonisolated private static func message(for error: any Error) -> String {
        switch SyncEvent.classify(error) {
        case .network: String(localized: "沒有連上網路，請連上網路再試一次。")
        case .quotaFull: String(localized: "iCloud 空間不足，整理空間後再試一次。")
        case .notSignedIn: String(localized: "要先登入 iCloud。到 iPhone「設定」登入 Apple 帳號後再試一次。")
        case .other: String(localized: "iCloud 暫時無法使用，請稍後再試一次。")
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension FamilySync: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            saveEngineState(update.stateSerialization)
        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                break
            case .signOut, .switchAccounts:
                await end(.accountChanged)
            @unknown default:
                break
            }
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { inFamilyZone($0.zoneID) }) {
                await end(.revoked)
            }
        case .fetchedRecordZoneChanges(let changes):
            applyFetched(changes)
        case .sentRecordZoneChanges(let sent):
            await handleSent(sent)
        case .willFetchChanges, .willSendChanges:
            if case .failed(.quotaFull) = activity { break }
            activity = .syncing
        case .didFetchChanges:
            if activity == .syncing {
                activity = .idle
                markSynced()
            }
        case .didSendChanges:
            if activity == .syncing { activity = .idle }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine, endedThisSession == nil else { return nil }
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        var saves: [CKRecord] = []
        var deletes: [CKRecord.ID] = []
        var stale: [CKSyncEngine.PendingRecordZoneChange] = []
        var bytes = 0
        // Keep each request modest: a few records, or until the images add up to ~40 MB.
        for change in pending {
            if saves.count + deletes.count >= 12 || bytes > 40_000_000 { break }
            switch change {
            case .saveRecord(let id):
                if let record = outgoingRecord(id) {
                    saves.append(record)
                    bytes += Self.assetBytes(record)
                } else {
                    stale.append(change)
                }
            case .deleteRecord(let id):
                deletes.append(id)
            @unknown default:
                break
            }
        }
        if !stale.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: stale) }
        guard !saves.isEmpty || !deletes.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: saves, recordIDsToDelete: deletes, atomicByZone: false)
    }

    /// Only the family zone: the owner's private database also holds the 1.2 iCloud sync zone, never fetched here.
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                 syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        if let zoneID { options.scope = .zoneIDs([zoneID]) }
        return options
    }

    private static func assetBytes(_ record: CKRecord) -> Int {
        var total = 0
        for key in record.allKeys() {
            if let url = (record[key] as? CKAsset)?.fileURL,
               let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += size
            }
        }
        return total
    }
}

// MARK: - Supporting types

/// An invitation waiting for 加入 / 先不要.
struct FamilyInvite: Identifiable {
    let id = UUID()
    let metadata: CKShare.Metadata
    /// The owner's name as iCloud gives it (nil when hidden).
    let ownerName: String?
    /// The owner opened their own link (e.g. on their iPad).
    let isOwnShare: Bool
    let zoneOwnerName: String
}

enum FamilyNotice: Equatable {
    /// Ended while the app was open (removed / sharing stopped / account changed): the works were copied.
    case ended(FamilyEndReason)
    /// The first personal launch after a family museum ended.
    case backToPersonal(FamilyEndReason)
    case invalidInvitation

    var text: String {
        switch self {
        case .ended(.accountChanged):
            String(localized: "iCloud 帳號換了，家庭美術館先關起來。作品已經複製一份到你的美術館，重新打開 App 就會看到。")
        case .ended:
            String(localized: "家庭美術館停止分享了。作品已經複製一份到你的美術館，重新打開 App 就會看到。")
        case .backToPersonal(.left), .backToPersonal(.stopped):
            String(localized: "回到你自己的美術館了。")
        case .backToPersonal:
            String(localized: "回到你自己的美術館了，家庭美術館的作品也複製了一份在這裡。")
        case .invalidInvitation:
            String(localized: "這個連結不是冰箱美術館的家庭美術館邀請。")
        }
    }
}

/// Carries a CloudKit object out of a nonisolated helper to the main actor. Only used for objects nobody else holds
/// (a share just fetched, an invitation's metadata handed to the accept operation).
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// UICloudSharingController's delegate (UIKit needs an NSObject).
@MainActor
final class FamilyShareControllerDelegate: NSObject, UICloudSharingControllerDelegate {
    var onStop: (() -> Void)?

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: any Error) {}

    func itemTitle(for csc: UICloudSharingController) -> String? {
        String(localized: "家庭美術館")
    }

    func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
        UIImage(named: "bibi-wave")?.pngData()
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        onStop?()
    }
}

extension FamilyStatus {
    /// The status line in Settings.
    var label: String {
        switch self {
        case .off: String(localized: "未開啟")
        case .willOpenNextLaunch: String(localized: "重新打開 App 就會進入家庭美術館")
        case .willCloseNextLaunch: String(localized: "重新打開 App 就會回到你的美術館")
        case .starting: String(localized: "準備中…")
        case .syncing: String(localized: "同步中…")
        case .synced: String(localized: "已同步")
        case .waitingForNetwork: String(localized: "等待網路連線")
        case .quotaFull: String(localized: "館長的 iCloud 空間不足")
        case .notSignedIn: String(localized: "iCloud 未登入")
        case .failed: String(localized: "暫時無法同步，稍後會自動再試")
        }
    }

    var detail: String? {
        switch self {
        case .willOpenNextLaunch, .willCloseNextLaunch:
            String(localized: "從背景把 App 滑掉再打開就會生效。")
        case .quotaFull:
            String(localized: "家庭美術館的作品存在館長的 iCloud。館長整理 iCloud 空間後會自動繼續，新作品先留在手機上。")
        default:
            nil
        }
    }
}

// MARK: - Accepting invitations (scene delegate)

/// SwiftUI app + UIKit hooks for CloudKit share invitations: the app delegate gives every scene this delegate, which
/// receives the invitation (a running app: `userDidAcceptCloudKitShareWith`; a cold launch: the connection options).
@MainActor
final class FamilyAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = FamilySceneDelegate.self
        return configuration
    }
}

@MainActor
final class FamilySceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata { FamilySync.receive(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        FamilySync.receive(cloudKitShareMetadata)
    }
}
