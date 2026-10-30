import Foundation
import SwiftData

// iCloud sync (1.2.0) — the decisions, kept free of CloudKit so they are unit-testable (CloudSyncTests).
// The CloudKit side (account status, events, the launch bootstrap) is App/CloudSync.swift.

/// The iCloud account as CloudKit reports it at launch.
enum SyncAccount: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    /// couldNotDetermine, an error, or no answer in time.
    case unknown
}

/// Why this launch runs on the on-device store only.
enum SyncOffReason: Equatable, Sendable {
    /// Screenshot demos, unit tests, the simulator: CloudKit is never touched.
    case notSupported
    case notFullVersion
    /// Full Version, but the one-time explanation hasn't been answered yet.
    case introPending
    case turnedOff
    case noAccount
    /// Restricted, temporarily unavailable, or unknown.
    case accountUnavailable
    /// A different Apple Account than the one this phone last synced with (sync stays paused; see `decide`).
    case accountChanged
    /// This phone synced before, but the current Apple Account couldn't be confirmed (offline): not this launch.
    case accountUnverified
    /// The CloudKit store couldn't be opened; the same file was opened without sync instead.
    case containerFailed
}

enum SyncDecision: Equatable, Sendable {
    /// Open the store with `cloudKitDatabase: .private(CloudSync.containerID)`.
    case cloud
    /// Open the same store file with `cloudKitDatabase: .none` (nothing on the device is touched).
    case local(SyncOffReason)
}

struct SyncInputs: Equatable, Sendable {
    var isSupported = true
    var isFullVersion = false
    var introShown = false
    var wantsSync = true
    var account: SyncAccount = .available
    /// This phone has synced before (the Apple Account it synced with is remembered).
    var hasStoredAccount = false
    /// Does the current Apple Account match the remembered one? nil = couldn't tell (offline, no answer in time).
    var sameAccountAsLastSync: Bool?
}

enum SyncPolicy {
    /// Which store configuration this launch uses. Decided once per launch: switching needs a relaunch, so two
    /// containers never run on the store file at once.
    static func decide(_ i: SyncInputs) -> SyncDecision {
        guard i.isSupported else { return .local(.notSupported) }
        guard i.isFullVersion else { return .local(.notFullVersion) }
        guard i.introShown else { return .local(.introPending) }
        guard i.wantsSync else { return .local(.turnedOff) }
        switch i.account {
        case .available:
            // Opening the mirrored store under a *different* Apple Account than last time makes
            // NSPersistentCloudKitContainer drop the previous account's data from the device — including artworks
            // that never reached iCloud (made offline, or while sync was off). So once this phone has synced, the
            // account is confirmed at every launch; a different one, or one that can't be confirmed, stays local.
            guard i.hasStoredAccount else { return .cloud }
            switch i.sameAccountAsLastSync {
            case .some(true): return .cloud
            case .some(false): return .local(.accountChanged)
            case .none: return .local(.accountUnverified)
            }
        case .noAccount:
            return .local(.noAccount)
        case .restricted, .temporarilyUnavailable, .unknown:
            return .local(.accountUnavailable)
        }
    }

    /// True when the account must be asked at all (keeps CloudKit untouched for free users and when sync is off).
    static func needsAccountCheck(_ i: SyncInputs) -> Bool {
        var probe = i
        probe.account = .available
        probe.hasStoredAccount = false
        probe.sameAccountAsLastSync = nil
        return decide(probe) == .cloud
    }
}

/// What Settings shows under 「iCloud 同步」.
enum SyncStatus: Equatable, Sendable {
    /// Free version: the row opens the paywall.
    case upgradeNeeded
    case off
    case willStartNextLaunch
    case willStopNextLaunch
    case noAccount
    case accountUnavailable
    case accountChanged
    /// Synced before, but the Apple Account couldn't be confirmed this launch (offline).
    case accountUnverified
    /// The iCloud account changed while the app was open (CKAccountChanged): checked again at the next launch.
    case restartNeeded
    /// The CloudKit store couldn't be opened, or this build can't sync.
    case unavailable
    case starting
    case syncing
    case synced
    case waitingForNetwork
    case quotaFull
    case failed
}

/// The last CloudKit event's outcome this session.
enum SyncActivity: Equatable, Sendable {
    case idle
    case syncing
    case failed(SyncProblem)
}

enum SyncProblem: Equatable, Sendable {
    case network
    case quotaFull
    case notSignedIn
    case other
}

extension SyncPolicy {
    static func status(isFullVersion: Bool, wantsSync: Bool, introShown: Bool, decision: SyncDecision,
                       activity: SyncActivity, hasSynced: Bool, accountChangedThisSession: Bool) -> SyncStatus {
        if decision == .cloud {
            guard isFullVersion, wantsSync else { return .willStopNextLaunch }
            if accountChangedThisSession { return .restartNeeded }
            switch activity {
            case .syncing: return .syncing
            case .failed(.network): return .waitingForNetwork
            case .failed(.quotaFull): return .quotaFull
            case .failed(.notSignedIn): return .noAccount
            case .failed(.other): return .failed
            case .idle: return hasSynced ? .synced : .starting
            }
        }
        guard isFullVersion else { return .upgradeNeeded }
        guard wantsSync, introShown else { return .off }
        guard case .local(let reason) = decision else { return .off }
        switch reason {
        case .notFullVersion, .introPending, .turnedOff: return .willStartNextLaunch
        case .noAccount: return .noAccount
        case .accountUnavailable: return .accountUnavailable
        case .accountChanged: return .accountChanged
        case .accountUnverified: return .accountUnverified
        case .containerFailed, .notSupported: return .unavailable
        }
    }
}

// MARK: - Which device a record came from

/// A per-device id (identifierForVendor, saved by CloudSync at launch). Stamped on new artworks and children so a
/// pending capture stays with the phone that took it, and copies from several devices can be told apart.
enum DeviceIdentity {
    static let key = "sync.deviceID"

    /// "" until the first 1.2.0 launch saved one (or in unit tests): then every record counts as this device's.
    static var storedID: String { UserDefaults.standard.string(forKey: key) ?? "" }
}

enum SyncOrigin {
    /// A pending capture from another device that nobody touched for this long is treated as abandoned (that phone
    /// was reset or replaced) and shows on this device's sticky note too.
    static let orphanAfter: TimeInterval = 7 * 86_400

    /// Made on this device (or before 1.2.0, or no device id is known yet).
    static func isLocal(_ origin: String, device: String) -> Bool {
        origin.isEmpty || device.isEmpty || origin == device
    }

    /// A pending capture (isKept == false) this device may show on its sticky note, step through, keep or discard.
    /// Another device's capture stays with that device: 全部不要 here must never delete what the iPhone is editing.
    static func ownsPending(origin: String, createdAt: Date, device: String, now: Date = Date()) -> Bool {
        isLocal(origin, device: device) || now.timeIntervalSince(createdAt) > orphanAfter
    }

    /// Gives every record made before 1.2.0 (origin "") this device's id, once per device.
    ///
    /// Restored from another phone's backup (the saved stamp is that phone's device id):
    /// - `previouslySynced` false — that phone never synced, so these records are a private *copy*; if both phones
    ///   turn on sync each uploads its own. Its id is re-stamped as this device's so the two copies can be told
    ///   apart (SyncDedupe).
    /// - `previouslySynced` true — the backup came from a phone that already synced: these records *are* its iCloud
    ///   records (same CloudKit record names), so re-stamping would rewrite the other phone's records and move its
    ///   pending captures here. Only unstamped ("") records are stamped.
    /// Returns how many records changed.
    @MainActor @discardableResult
    static func stampLegacyRecords(context: ModelContext, defaults: UserDefaults = .standard,
                                   previouslySynced: Bool = false) -> Int {
        guard let device = defaults.string(forKey: DeviceIdentity.key), !device.isEmpty else { return 0 }
        let stampedKey = "sync.stampedDevice"
        let previous = defaults.string(forKey: stampedKey)
        guard previous != device else { return 0 }
        let old = previouslySynced ? "" : (previous ?? "")
        var changed = 0
        for artwork in (try? context.fetch(FetchDescriptor<Artwork>())) ?? []
        where artwork.originDeviceID.isEmpty || artwork.originDeviceID == old {
            artwork.originDeviceID = device
            changed += 1
        }
        for child in (try? context.fetch(FetchDescriptor<Child>())) ?? []
        where child.originDeviceID.isEmpty || child.originDeviceID == old {
            child.originDeviceID = device
            changed += 1
        }
        if changed > 0 {
            do { try context.save() } catch { return 0 }   // not saved: try again next launch
        }
        defaults.set(device, forKey: stampedKey)
        return changed
    }
}

/// The fields batch edits change, to tell a real edit from a no-op (`touch()` only on a real one).
struct ArtworkEdits: Equatable {
    var childID: UUID?
    var tags: [String]
    var capturedAt: Date
    var isFavorite: Bool
    var title: String
    var note: String
    var medium: String

    @MainActor
    init(_ artwork: Artwork) {
        childID = artwork.child?.id
        tags = artwork.tags
        capturedAt = artwork.capturedAt
        isFavorite = artwork.isFavorite
        title = artwork.title
        note = artwork.note
        medium = artwork.medium
    }
}

extension Artwork {
    /// On this device's sticky note (pending, not a sample, captured here or abandoned elsewhere).
    var isOwnPending: Bool {
        !isKept && !isSample
            && SyncOrigin.ownsPending(origin: originDeviceID, createdAt: createdAt, device: DeviceIdentity.storedID)
    }
}

// MARK: - Background renders for synced artworks

enum LaunchRender: Equatable, Sendable {
    case skip
    /// No working copy yet: render it once.
    case render
    /// Has a render, but it is outdated (the recipe changed after it): render again.
    case rerender

    /// A synced artwork usually brings its render along; only render it here if it is still unfinished a while after
    /// its last edit (the device that edited it is probably rendering it now and its render will arrive shortly).
    static let foreignGrace: TimeInterval = 10 * 60

    /// For an artwork whose processing state is unfinished (pending / processing). `age`: since its last edit
    /// (`modifiedAt`, else `createdAt`).
    static func action(isLocal: Bool, ownsPending: Bool, isKept: Bool, hasRender: Bool, age: TimeInterval) -> LaunchRender {
        if isLocal { return hasRender ? .rerender : .render }
        // Another device's capture still in its editor: that device renders it.
        if !isKept && !ownsPending { return .skip }
        // Synced and unfinished: the other device is normally rendering it right now (its render arrives with
        // state .done). Still unfinished well after its last edit (that device was closed mid-render, or a merge
        // left an outdated render): render it here — with or without an old render — so it never stays stale.
        guard age > foreignGrace else { return .skip }
        return hasRender ? .rerender : .render
    }
}

// MARK: - Duplicates from several devices

/// Copies of the same record can reach iCloud twice — typically when a new phone was restored from a backup of the
/// old one and both turn on sync: each uploads its own copy of every artwork and child (same `id`). Also, a child
/// profile can be created on two devices before they sync. This merges them, deterministically, so every device
/// keeps the same copy and deletes the same others (otherwise two devices could delete each other's copy).
///
/// Which copy *stays* is fixed (device id order) on purpose: if it followed recency, an edit made on one device
/// while another is merging could make each device delete a different copy — and both copies would be gone. Which
/// *values* stay is recency-aware instead: the copy edited last (`modifiedAt`, then `renderVersion`) wins the edited
/// fields (merge(artwork:) / merge(child:)), so a stale copy never undoes newer edits.
enum SyncDedupe {
    struct Report: Equatable {
        var removedChildren = 0
        var removedArtworks = 0
        /// Child profile id → the profile it was merged into (only for different ids; same-id copies keep their id).
        var childRemap: [UUID: UUID] = [:]
        /// Merged artworks whose render no longer matches their recipe: render them on this device.
        var needsRender: [UUID] = []
    }

    /// Copies of one record (same `id`): which one to keep and which to remove. The copy from the lexicographically
    /// smallest device id stays (the earliest created among those); copies from that same device are never removed.
    /// The newer copy's edits are folded into it (merge), so this choice decides only which record survives.
    /// Waits (nil) while any copy is unstamped — its device stamps it at its next launch.
    static func resolve(origins: [String], createdAt: [Date]) -> (keep: Int, remove: [Int])? {
        guard origins.count > 1, origins.count == createdAt.count, !origins.contains(where: \.isEmpty),
              let winner = origins.min() else { return nil }
        let remove = origins.indices.filter { origins[$0] != winner }
        guard !remove.isEmpty,
              let keep = origins.indices.filter({ origins[$0] == winner }).min(by: { createdAt[$0] < createdAt[$1] })
        else { return nil }
        return (keep, remove)
    }

    struct ChildFacts: Equatable {
        var id: UUID
        var name: String
        var birthday: Date?
        var origin: String
        var createdAt: Date
    }

    /// Child profiles with different ids but the same name, created on different devices (both phones added 小明
    /// before syncing): `(remove, into)` index pairs. Never merges profiles made on the same device, unnamed ones,
    /// or ones with different birthdays.
    static func nameMerges(_ children: [ChildFacts], calendar: Calendar = .current) -> [(remove: Int, into: Int)] {
        var result: [(remove: Int, into: Int)] = []
        let named = children.indices.filter { !normalized(children[$0].name).isEmpty }
        let groups = Dictionary(grouping: named) { normalized(children[$0].name) }
        for (_, group) in groups where group.count > 1 {
            guard !group.contains(where: { children[$0].origin.isEmpty }),
                  Set(group.map { children[$0].origin }).count > 1,
                  let keep = group.min(by: { a, b in
                      (children[a].createdAt, children[a].id.uuidString) < (children[b].createdAt, children[b].id.uuidString)
                  }) else { continue }
            for i in group where i != keep && children[i].origin != children[keep].origin
                && birthdaysMatch(children[i].birthday, children[keep].birthday, calendar: calendar) {
                result.append((remove: i, into: keep))
            }
        }
        return result.sorted { $0.remove < $1.remove }
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func birthdaysMatch(_ a: Date?, _ b: Date?, calendar: Calendar) -> Bool {
        guard let a, let b else { return true }
        return calendar.isDate(a, inSameDayAs: b)
    }

    /// Merges duplicates in the store. `busy`: artworks being processed or edited right now (left for a later run).
    /// The copy that stays takes the newer copy's edits and keeps facts from both (kept, saved to Photos); a removed
    /// child's artworks move to the profile that stays.
    @MainActor @discardableResult
    static func run(context: ModelContext, skipping busy: Set<UUID> = []) -> Report {
        var report = Report()
        var removed = Set<PersistentIdentifier>()

        // 1. Children: same id.
        let children = ((try? context.fetch(FetchDescriptor<Child>())) ?? []).filter { !$0.isDeleted }
        for group in Dictionary(grouping: children, by: \.id).values where group.count > 1 {
            guard let plan = resolve(origins: group.map(\.originDeviceID), createdAt: group.map(\.createdAt)) else { continue }
            for i in plan.remove {
                merge(child: group[i], into: group[plan.keep])
                removed.insert(group[i].persistentModelID)
                context.delete(group[i])
                report.removedChildren += 1
            }
        }

        // 2. Children: same name from different devices.
        let remaining = children.filter { !removed.contains($0.persistentModelID) }
        let facts = remaining.map {
            ChildFacts(id: $0.id, name: $0.name, birthday: $0.birthday, origin: $0.originDeviceID, createdAt: $0.createdAt)
        }
        for pair in nameMerges(facts) {
            let loser = remaining[pair.remove], keeper = remaining[pair.into]
            guard !removed.contains(loser.persistentModelID) else { continue }
            report.childRemap[loser.id] = keeper.id
            merge(child: loser, into: keeper, sameRecord: false)
            removed.insert(loser.persistentModelID)
            context.delete(loser)
            report.removedChildren += 1
        }

        // 3. Artworks: same id.
        let artworks = ((try? context.fetch(FetchDescriptor<Artwork>())) ?? []).filter { !$0.isDeleted }
        for group in Dictionary(grouping: artworks, by: \.id).values where group.count > 1 {
            guard let first = group.first, !busy.contains(first.id),
                  let plan = resolve(origins: group.map(\.originDeviceID), createdAt: group.map(\.createdAt)) else { continue }
            var redo = false
            for i in plan.remove {
                if merge(artwork: group[i], into: group[plan.keep]) { redo = true }
                context.delete(group[i])
                report.removedArtworks += 1
            }
            if redo { report.needsRender.append(group[plan.keep].id) }
        }

        if report.removedChildren + report.removedArtworks > 0 { try? context.save() }
        return report
    }

    /// Whose edits are newer: `modifiedAt` (every parent edit `touch()`es it), then `renderVersion` (recipe edits
    /// re-render). Ties — e.g. two untouched copies from before 1.2.0 — count as not newer.
    static func isNewer(modifiedAt a: Date?, renderVersion ra: Int, than b: Date?, renderVersion rb: Int) -> Bool {
        (a ?? .distantPast, ra) > (b ?? .distantPast, rb)
    }

    /// Folds a removed child profile into the one that stays; its artworks move over.
    /// - `sameRecord` (two copies of one profile, same `id`): the profile fields come from the copy edited last — a
    ///   rename, a new colour, a removed photo or birthday on the other device wins. When the staying copy was never
    ///   edited since 1.2.0, missing details are filled in from the other (empty there = missing data).
    /// - Two profiles created separately with the same name (`sameRecord` false): only empty fields are filled in.
    ///   `modifiedAt` says nothing here — the profile created later is "newer" without being an edit of the other —
    ///   so its default colour or missing photo must never replace the staying profile's.
    @MainActor
    static func merge(child loser: Child, into keeper: Child, sameRecord: Bool = true) {
        let moving = loser.artworks ?? []
        for artwork in moving { artwork.child = keeper }
        if sameRecord, (loser.modifiedAt ?? .distantPast) > (keeper.modifiedAt ?? .distantPast) {
            if !loser.name.isEmpty || keeper.name.isEmpty { keeper.name = loser.name }
            keeper.birthday = loser.birthday
            keeper.avatarColorHex = loser.avatarColorHex
            keeper.avatarImageData = loser.avatarImageData
            keeper.modifiedAt = loser.modifiedAt
        } else if !sameRecord || keeper.modifiedAt == nil {
            if keeper.name.isEmpty { keeper.name = loser.name }
            if keeper.birthday == nil { keeper.birthday = loser.birthday }
            if keeper.avatarImageData == nil, let avatar = loser.avatarImageData { keeper.avatarImageData = avatar }
        }
    }

    /// Folds a removed artwork copy (same `id`) into the one that stays. Returns true when the staying copy's render
    /// no longer matches its recipe (it is then marked unfinished and rendered again on this device).
    /// - Facts are never lost: kept (and the earliest keptAt), the latest save to Photos, a voice recording.
    /// - Everything the parent edits (recipe, kind, placard text, date, medium, favorite, child, tags) comes from the
    ///   copy edited last — including a cleared child or an emptied tag list — so a stale copy can't undo newer edits
    ///   or bring back deleted tags. Only when the staying copy was never edited since 1.2.0 are its empty fields
    ///   filled in from the other.
    /// - The render goes with the recipe: taken over with the newer copy's recipe; otherwise only when the recipes
    ///   match. A render that isn't known to match (state not .done) is redone.
    @MainActor @discardableResult
    static func merge(artwork loser: Artwork, into keeper: Artwork) -> Bool {
        if loser.isKept && !keeper.isKept {
            keeper.isKept = true
            keeper.keptAt = loser.keptAt ?? keeper.keptAt
        } else if loser.isKept, let lk = loser.keptAt, keeper.keptAt.map({ lk < $0 }) ?? true {
            keeper.keptAt = lk
        }
        if let saved = loser.lastSavedToPhotosAt, keeper.lastSavedToPhotosAt.map({ saved > $0 }) ?? true {
            keeper.lastSavedToPhotosAt = saved
        }
        if keeper.voiceNoteData == nil, let voice = loser.voiceNoteData {
            keeper.voiceNoteData = voice
            keeper.voiceTranscript = loser.voiceTranscript
        }
        let sameRecipe = loser.recipeData == keeper.recipeData
        if isNewer(modifiedAt: loser.modifiedAt, renderVersion: loser.renderVersion,
                   than: keeper.modifiedAt, renderVersion: keeper.renderVersion) {
            keeper.title = loser.title
            keeper.note = loser.note
            keeper.medium = loser.medium
            keeper.capturedAt = loser.capturedAt
            keeper.kindRaw = loser.kindRaw
            keeper.recipeData = loser.recipeData
            keeper.isFavorite = loser.isFavorite
            keeper.tags = loser.tags
            if let child = loser.child {
                if !child.isDeleted { keeper.child = child }
            } else {
                keeper.child = nil
            }
            if loser.voiceNoteData != nil {
                keeper.voiceNoteData = loser.voiceNoteData
                keeper.voiceTranscript = loser.voiceTranscript
            }
            if loser.renderedImageData != nil {
                takeRender(from: loser, into: keeper)
            } else if !sameRecipe {
                keeper.processingStateRaw = ProcessingState.pending.rawValue
            }
            keeper.modifiedAt = loser.modifiedAt
        } else {
            if keeper.modifiedAt == nil {
                if keeper.tags.isEmpty { keeper.tags = loser.tags }
                if keeper.child == nil, let child = loser.child, !child.isDeleted { keeper.child = child }
                if keeper.title.isEmpty { keeper.title = loser.title }
                if keeper.note.isEmpty { keeper.note = loser.note }
            }
            if keeper.renderedImageData == nil, loser.renderedImageData != nil, sameRecipe {
                takeRender(from: loser, into: keeper)
            }
        }
        // A render not known to match the recipe (pending / processing) is redone here — whatever device the
        // artwork came from — unless it is another device's capture still in its editor.
        let done = ProcessingState.done.rawValue, failed = ProcessingState.failed.rawValue
        guard keeper.processingStateRaw != done, keeper.processingStateRaw != failed,
              keeper.isKept || keeper.isOwnPending else { return false }
        keeper.processingStateRaw = ProcessingState.pending.rawValue
        return true
    }

    @MainActor
    private static func takeRender(from loser: Artwork, into keeper: Artwork) {
        keeper.renderedImageData = loser.renderedImageData
        keeper.thumbnailData = loser.thumbnailData
        keeper.fingerprintData = loser.fingerprintData
        keeper.pixelWidth = loser.pixelWidth
        keeper.pixelHeight = loser.pixelHeight
        keeper.renderVersion = max(keeper.renderVersion, loser.renderVersion) + 1
        keeper.processingStateRaw = loser.processingStateRaw
    }
}
