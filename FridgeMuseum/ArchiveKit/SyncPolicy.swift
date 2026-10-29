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
    /// Only checked when sync is switched back on after a launch without it: does the current Apple Account match
    /// the one this phone last synced with? nil = not checked / couldn't tell (offline).
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
            // Turning mirroring back on under a *different* Apple Account makes NSPersistentCloudKitContainer drop the
            // previous account's data from the device — including artworks made while sync was off, which never
            // reached iCloud. Stay local instead.
            if i.sameAccountAsLastSync == false { return .local(.accountChanged) }
            return .cloud
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

    /// Gives every record made before 1.2.0 (origin "") this device's id, once per device. When the store came from a
    /// backup of another phone (the saved stamp is a different device id), that phone's records are re-stamped as
    /// this device's, so the two copies of the same artwork can be told apart if both phones sync (SyncDedupe).
    /// Returns how many records changed.
    @MainActor @discardableResult
    static func stampLegacyRecords(context: ModelContext, defaults: UserDefaults = .standard) -> Int {
        guard let device = defaults.string(forKey: DeviceIdentity.key), !device.isEmpty else { return 0 }
        let stampedKey = "sync.stampedDevice"
        let previous = defaults.string(forKey: stampedKey)
        guard previous != device else { return 0 }
        let old = previous ?? ""
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

    /// A synced artwork usually brings its render along; only give it one if it arrived without, and not right away
    /// (the device that captured it is probably rendering it now and its render will arrive shortly).
    static let foreignGrace: TimeInterval = 10 * 60

    /// For an artwork whose processing state is unfinished (pending / processing).
    static func action(isLocal: Bool, ownsPending: Bool, isKept: Bool, hasRender: Bool, age: TimeInterval) -> LaunchRender {
        if isLocal { return hasRender ? .rerender : .render }
        // Another device's capture still in its editor: that device renders it.
        if !isKept && !ownsPending { return .skip }
        // Arrived with a render: never re-render (the other device owns its recipe changes).
        if hasRender { return .skip }
        return age > foreignGrace ? .render : .skip
    }
}

// MARK: - Duplicates from several devices

/// Copies of the same record can reach iCloud twice — typically when a new phone was restored from a backup of the
/// old one and both turn on sync: each uploads its own copy of every artwork and child (same `id`). Also, a child
/// profile can be created on two devices before they sync. This merges them, deterministically, so every device
/// keeps the same copy and deletes the same others (otherwise two devices could delete each other's copy).
enum SyncDedupe {
    struct Report: Equatable {
        var removedChildren = 0
        var removedArtworks = 0
        /// Child profile id → the profile it was merged into (only for different ids; same-id copies keep their id).
        var childRemap: [UUID: UUID] = [:]
    }

    /// Copies of one record (same `id`): which one to keep and which to remove. The copy from the lexicographically
    /// smallest device id wins (the earliest created among those); copies from that same device are never removed.
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
    /// Nothing is lost: a removed copy's tags, notes, voice note, favorite, kept/saved state and child are folded into
    /// the copy that stays; a removed child's artworks move to the profile that stays.
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
            merge(child: loser, into: keeper)
            removed.insert(loser.persistentModelID)
            context.delete(loser)
            report.removedChildren += 1
        }

        // 3. Artworks: same id.
        let artworks = ((try? context.fetch(FetchDescriptor<Artwork>())) ?? []).filter { !$0.isDeleted }
        for group in Dictionary(grouping: artworks, by: \.id).values where group.count > 1 {
            guard let first = group.first, !busy.contains(first.id),
                  let plan = resolve(origins: group.map(\.originDeviceID), createdAt: group.map(\.createdAt)) else { continue }
            for i in plan.remove {
                merge(artwork: group[i], into: group[plan.keep])
                context.delete(group[i])
                report.removedArtworks += 1
            }
        }

        if report.removedChildren + report.removedArtworks > 0 { try? context.save() }
        return report
    }

    @MainActor
    static func merge(child loser: Child, into keeper: Child) {
        let moving = loser.artworks ?? []
        for artwork in moving { artwork.child = keeper }
        if keeper.name.isEmpty { keeper.name = loser.name }
        if keeper.birthday == nil { keeper.birthday = loser.birthday }
        if keeper.avatarImageData == nil, let avatar = loser.avatarImageData { keeper.avatarImageData = avatar }
    }

    @MainActor
    static func merge(artwork loser: Artwork, into keeper: Artwork) {
        if loser.isKept && !keeper.isKept {
            keeper.isKept = true
            keeper.keptAt = loser.keptAt ?? keeper.keptAt
        }
        if loser.isFavorite { keeper.isFavorite = true }
        if keeper.title.isEmpty { keeper.title = loser.title }
        if keeper.note.isEmpty { keeper.note = loser.note }
        if keeper.voiceTranscript.isEmpty { keeper.voiceTranscript = loser.voiceTranscript }
        if keeper.voiceNoteData == nil, let voice = loser.voiceNoteData { keeper.voiceNoteData = voice }
        for tag in loser.tags where !keeper.tags.contains(tag) { keeper.tags.append(tag) }
        if let saved = loser.lastSavedToPhotosAt, keeper.lastSavedToPhotosAt.map({ saved > $0 }) ?? true {
            keeper.lastSavedToPhotosAt = saved
        }
        if keeper.child == nil, let child = loser.child, !child.isDeleted { keeper.child = child }
        if keeper.renderedImageData == nil, let rendered = loser.renderedImageData {
            keeper.renderedImageData = rendered
            keeper.thumbnailData = loser.thumbnailData
            keeper.fingerprintData = loser.fingerprintData
            keeper.pixelWidth = loser.pixelWidth
            keeper.pixelHeight = loser.pixelHeight
            keeper.renderVersion = max(keeper.renderVersion, loser.renderVersion) + 1
            keeper.processingStateRaw = loser.processingStateRaw
        }
    }
}
