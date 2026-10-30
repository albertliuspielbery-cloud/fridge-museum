import Foundation
import SwiftData
import Testing
@testable import FridgeMuseum

/// iCloud sync (1.2.0): the decisions around CloudKit — which store configuration a launch uses, what Settings shows,
/// which device owns a pending capture, renders for synced artworks, merging copies that arrived from several
/// devices, and that turning sync off never deletes anything. CloudKit itself (uploads, pushes, account changes)
/// can't run in CI: the simulator build is unsigned (no iCloud entitlement) and has no Apple Account.
@MainActor
struct CloudSyncTests {
    private let buyer = SyncInputs(isSupported: true, isFullVersion: true, introShown: true, wantsSync: true,
                                   account: .available, sameAccountAsLastSync: nil)

    // MARK: Which store configuration a launch uses

    @Test func fullVersionWithAccountAndToggleOnSyncs() {
        #expect(SyncPolicy.decide(buyer) == .cloud)
        var same = buyer
        same.sameAccountAsLastSync = true
        #expect(SyncPolicy.decide(same) == .cloud)
    }

    @Test func freeVersionStaysOnDevice() {
        var free = buyer
        free.isFullVersion = false
        #expect(SyncPolicy.decide(free) == .local(.notFullVersion))
        #expect(!SyncPolicy.needsAccountCheck(free))   // CloudKit is never asked for free users
    }

    @Test func toggleOffOrIntroPendingStaysOnDevice() {
        var off = buyer
        off.wantsSync = false
        #expect(SyncPolicy.decide(off) == .local(.turnedOff))
        #expect(!SyncPolicy.needsAccountCheck(off))
        var intro = buyer
        intro.introShown = false
        #expect(SyncPolicy.decide(intro) == .local(.introPending))
    }

    @Test func unsupportedEnvironmentNeverSyncs() {
        var demo = buyer
        demo.isSupported = false
        #expect(SyncPolicy.decide(demo) == .local(.notSupported))
        #expect(!SyncPolicy.needsAccountCheck(demo))
    }

    @Test func accountStatesThatPreventSync() {
        var inputs = buyer
        inputs.account = .noAccount
        #expect(SyncPolicy.decide(inputs) == .local(.noAccount))
        for account in [SyncAccount.restricted, .temporarilyUnavailable, .unknown] {
            inputs.account = account
            #expect(SyncPolicy.decide(inputs) == .local(.accountUnavailable))
        }
        #expect(SyncPolicy.needsAccountCheck(inputs))
    }

    /// Once this phone has synced, every launch confirms the Apple Account: a different one would make CloudKit drop
    /// this phone's data (including artworks not uploaded yet) — stay local, also when it can't be confirmed.
    @Test func differentOrUnconfirmedAppleAccountStaysLocal() {
        var synced = buyer
        synced.hasStoredAccount = true
        synced.sameAccountAsLastSync = true
        #expect(SyncPolicy.decide(synced) == .cloud)
        synced.sameAccountAsLastSync = false
        #expect(SyncPolicy.decide(synced) == .local(.accountChanged))
        synced.sameAccountAsLastSync = nil                     // offline: can't tell
        #expect(SyncPolicy.decide(synced) == .local(.accountUnverified))
        #expect(SyncPolicy.needsAccountCheck(synced))          // still asks CloudKit next time
        // Never synced on this phone: nothing to protect yet, the first account is fine.
        var first = buyer
        first.sameAccountAsLastSync = nil
        #expect(SyncPolicy.decide(first) == .cloud)
    }

    /// Turning sync off (toggle, refund, no account) opens the very same store file without mirroring.
    @Test func syncedAndLocalConfigurationsUseTheSameStoreFile() {
        let schema = ArchiveStore.schema
        let cloud = ArchiveStore.configuration(schema: schema, cloudKitContainerID: CloudSync.containerID)
        let local = ArchiveStore.configuration(schema: schema, cloudKitContainerID: nil)
        #expect(cloud.url == local.url)
        #expect(cloud.name == local.name)
    }

    // MARK: Settings status

    @Test func statusInSettings() {
        func status(full: Bool = true, wants: Bool = true, intro: Bool = true, _ decision: SyncDecision,
                    _ activity: SyncActivity = .idle, synced: Bool = false, changed: Bool = false) -> SyncStatus {
            SyncPolicy.status(isFullVersion: full, wantsSync: wants, introShown: intro, decision: decision,
                              activity: activity, hasSynced: synced, accountChangedThisSession: changed)
        }
        #expect(status(full: false, .local(.notFullVersion)) == .upgradeNeeded)
        #expect(status(.local(.notFullVersion)) == .willStartNextLaunch)          // just bought
        #expect(status(.local(.turnedOff)) == .willStartNextLaunch)               // toggled on
        #expect(status(wants: false, .local(.turnedOff)) == .off)
        #expect(status(intro: false, .local(.introPending)) == .off)
        #expect(status(.local(.noAccount)) == .noAccount)
        #expect(status(.local(.accountChanged)) == .accountChanged)
        #expect(status(.local(.accountUnverified)) == .accountUnverified)
        #expect(status(.local(.containerFailed)) == .unavailable)
        #expect(status(.cloud) == .starting)
        #expect(status(.cloud, synced: true) == .synced)
        #expect(status(.cloud, .syncing) == .syncing)
        #expect(status(.cloud, .failed(.quotaFull)) == .quotaFull)
        #expect(status(.cloud, .failed(.network)) == .waitingForNetwork)
        #expect(status(.cloud, .failed(.notSignedIn)) == .noAccount)
        #expect(status(.cloud, changed: true) == .restartNeeded)
        #expect(status(wants: false, .cloud) == .willStopNextLaunch)              // toggled off mid-session
        #expect(status(full: false, .cloud) == .willStopNextLaunch)               // refunded mid-session
    }

    // MARK: Pending captures from another device

    @Test func pendingCaptureBelongsToTheDeviceThatTookIt() {
        let now = day(2026, 11, 10)
        #expect(SyncOrigin.ownsPending(origin: "A", createdAt: now, device: "A", now: now))
        #expect(!SyncOrigin.ownsPending(origin: "B", createdAt: now, device: "A", now: now))
        #expect(SyncOrigin.ownsPending(origin: "", createdAt: now, device: "A", now: now))      // made before 1.2.0
        #expect(SyncOrigin.ownsPending(origin: "B", createdAt: now, device: "", now: now))      // no device id yet
        // Abandoned for over a week on the other device (reset / replaced phone): shows here too.
        #expect(SyncOrigin.ownsPending(origin: "B", createdAt: day(2026, 11, 1), device: "A", now: now))
    }

    /// 全部不要 on one device must never delete what another device is still editing.
    @Test func discardPendingLeavesAnotherDevicesCaptures() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let device = DeviceIdentity.storedID
        let mine = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([1]))
        mine.isKept = false
        mine.originDeviceID = device
        let theirs = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([2]))
        theirs.isKept = false
        theirs.originDeviceID = device.isEmpty ? "" : "other-device"
        context.insert(mine)
        context.insert(theirs)
        try context.save()

        app.discardPending(context: context)

        #expect(!AppModel.isAlive(mine))
        // Without a device id (first launch / unit-test host before CloudSync ran) everything is this device's.
        #expect(AppModel.isAlive(theirs) == !device.isEmpty)
    }

    // MARK: Renders for synced artworks

    @Test func launchRenderRules() {
        let old: TimeInterval = 3600, fresh: TimeInterval = 30
        // This device's work: as before 1.2.0.
        #expect(LaunchRender.action(isLocal: true, ownsPending: true, isKept: true, hasRender: false, age: fresh) == .render)
        #expect(LaunchRender.action(isLocal: true, ownsPending: true, isKept: true, hasRender: true, age: fresh) == .rerender)
        // Synced with its render: never re-rendered here.
        #expect(LaunchRender.action(isLocal: false, ownsPending: false, isKept: true, hasRender: true, age: old) == .skip)
        // Synced without a render: rendered once, after the grace period.
        #expect(LaunchRender.action(isLocal: false, ownsPending: false, isKept: true, hasRender: false, age: old) == .render)
        #expect(LaunchRender.action(isLocal: false, ownsPending: false, isKept: true, hasRender: false, age: fresh) == .skip)
        // Another device's capture still in its editor: left alone.
        #expect(LaunchRender.action(isLocal: false, ownsPending: false, isKept: false, hasRender: false, age: old) == .skip)
    }

    // MARK: Copies from several devices

    @Test func resolveKeepsTheSameCopyOnEveryDevice() {
        let t0 = day(2026, 1, 1), t1 = day(2026, 1, 2)
        let plan = SyncDedupe.resolve(origins: ["B", "A"], createdAt: [t0, t1])
        #expect(plan?.keep == 1)
        #expect(plan?.remove == [0])
        // Same set in another order → the same copy (device A's) stays.
        let swapped = SyncDedupe.resolve(origins: ["A", "B"], createdAt: [t1, t0])
        #expect(swapped?.keep == 0)
        #expect(swapped?.remove == [1])
        // An unstamped copy: wait. Copies from one device: never removed.
        #expect(SyncDedupe.resolve(origins: ["A", ""], createdAt: [t0, t1]) == nil)
        #expect(SyncDedupe.resolve(origins: ["A", "A"], createdAt: [t0, t1]) == nil)
        #expect(SyncDedupe.resolve(origins: ["A"], createdAt: [t0]) == nil)
    }

    @Test func childrenWithTheSameNameFromTwoDevicesMerge() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID(), id4 = UUID()
        let facts = [
            SyncDedupe.ChildFacts(id: id1, name: "小明", birthday: day(2020, 5, 3), origin: "A", createdAt: day(2026, 1, 1)),
            SyncDedupe.ChildFacts(id: id2, name: " 小明 ", birthday: nil, origin: "B", createdAt: day(2026, 2, 1)),
            SyncDedupe.ChildFacts(id: id3, name: "小明", birthday: day(2021, 1, 1), origin: "C", createdAt: day(2026, 3, 1)),
            SyncDedupe.ChildFacts(id: id4, name: "小明", birthday: nil, origin: "A", createdAt: day(2026, 4, 1)),
        ]
        let merges = SyncDedupe.nameMerges(facts, calendar: utc)
        // B's 小明 (no birthday) joins A's; C's has another birthday; A's second one is from the same device.
        #expect(merges.count == 1)
        #expect(merges.first?.remove == 1)
        #expect(merges.first?.into == 0)
        let unnamed = [
            SyncDedupe.ChildFacts(id: id1, name: "", birthday: nil, origin: "A", createdAt: day(2026, 1, 1)),
            SyncDedupe.ChildFacts(id: id2, name: "", birthday: nil, origin: "B", createdAt: day(2026, 1, 2)),
        ]
        #expect(SyncDedupe.nameMerges(unnamed, calendar: utc).isEmpty)
    }

    /// A phone restored from another's backup uploads a second copy of everything (same ids). The copy from device
    /// "A" stays (fixed order), but the copy edited last wins the edited fields; facts from both are kept.
    @Test func duplicateCopiesKeepTheNewerEdits() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let kidA = Child(name: "小明")
        kidA.originDeviceID = "A"
        kidA.modifiedAt = day(2026, 3, 1)
        let kidB = Child(name: "小明明", birthday: day(2020, 5, 3))   // renamed later on device B
        kidB.id = kidA.id
        kidB.originDeviceID = "B"
        kidB.avatarColorHex = "#FF0000"
        kidB.modifiedAt = day(2026, 3, 2)
        context.insert(kidA)
        context.insert(kidB)

        let artA = Artwork(kind: .flat, child: kidA, capturedAt: day(2026, 3, 1), originalImageData: Data([1]))
        artA.originDeviceID = "A"
        artA.tags = ["家人", "舊標籤"]
        artA.title = "舊名字"
        artA.isKept = true
        artA.keptAt = day(2026, 3, 1)
        artA.modifiedAt = day(2026, 3, 1)
        let artB = Artwork(kind: .flat, child: kidB, capturedAt: day(2026, 3, 1), originalImageData: Data([1]))
        artB.id = artA.id
        artB.originDeviceID = "B"
        artB.tags = ["家人"]                       // 舊標籤 deleted on B: must not come back
        artB.isFavorite = true
        artB.title = "氣球派對"
        artB.lastSavedToPhotosAt = day(2026, 3, 2)
        artB.modifiedAt = day(2026, 3, 3)
        context.insert(artA)
        context.insert(artB)
        // Only on device B: must survive (its child copy goes away, it moves to the one that stays).
        let onlyB = Artwork(kind: .craft, child: kidB, capturedAt: day(2026, 3, 5), originalImageData: Data([3]))
        onlyB.originDeviceID = "B"
        context.insert(onlyB)
        try context.save()

        let report = SyncDedupe.run(context: context)

        #expect(report.removedChildren == 1)
        #expect(report.removedArtworks == 1)
        let children = try context.fetch(FetchDescriptor<Child>())
        #expect(children.count == 1)
        let kid = try #require(children.first)
        #expect(kid.originDeviceID == "A")
        #expect(kid.name == "小明明")
        #expect(kid.avatarColorHex == "#FF0000")
        #expect(kid.birthday == day(2020, 5, 3))
        let artworks = try context.fetch(FetchDescriptor<Artwork>())
        #expect(artworks.count == 2)
        let merged = try #require(artworks.first { $0.id == artA.id })
        #expect(merged.originDeviceID == "A")
        #expect(merged.tags == ["家人"])
        #expect(merged.isFavorite)
        #expect(merged.title == "氣球派對")
        #expect(merged.isKept)                                   // a fact from A's copy
        #expect(merged.keptAt == day(2026, 3, 1))
        #expect(merged.lastSavedToPhotosAt == day(2026, 3, 2))  // a fact from B's copy
        let moved = try #require(artworks.first { $0.id == onlyB.id })
        #expect(moved.child?.originDeviceID == "A")

        // Running again changes nothing.
        let again = SyncDedupe.run(context: context)
        #expect(again == SyncDedupe.Report())
    }

    /// The staying copy edited last keeps its values; an older copy can't revive a deleted tag or old text.
    @Test func olderCopyDoesNotUndoEdits() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let a = Artwork(kind: .flat, child: nil, capturedAt: day(2026, 4, 1), originalImageData: Data([1]))
        a.originDeviceID = "A"
        a.title = "新名字"
        a.tags = ["恐龍"]
        a.modifiedAt = day(2026, 4, 5)
        let b = Artwork(kind: .flat, child: nil, capturedAt: day(2026, 4, 1), originalImageData: Data([1]))
        b.id = a.id
        b.originDeviceID = "B"
        b.title = "舊名字"
        b.tags = ["恐龍", "已刪除"]
        b.isFavorite = true
        b.modifiedAt = day(2026, 4, 2)
        context.insert(a)
        context.insert(b)
        try context.save()

        SyncDedupe.run(context: context)

        let left = try context.fetch(FetchDescriptor<Artwork>())
        #expect(left.count == 1)
        #expect(left.first?.title == "新名字")
        #expect(left.first?.tags == ["恐龍"])
        #expect(left.first?.isFavorite == false)
        #expect(SyncDedupe.isNewer(modifiedAt: nil, renderVersion: 2, than: nil, renderVersion: 1))
        #expect(!SyncDedupe.isNewer(modifiedAt: nil, renderVersion: 0, than: nil, renderVersion: 0))
    }

    /// Busy artworks (being edited / rendered) are left for a later run.
    @Test func dedupeSkipsBusyArtworks() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let a = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([1]))
        a.originDeviceID = "A"
        let b = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([1]))
        b.id = a.id
        b.originDeviceID = "B"
        context.insert(a)
        context.insert(b)
        try context.save()

        let report = SyncDedupe.run(context: context, skipping: [a.id])
        #expect(report.removedArtworks == 0)
        #expect(try context.fetch(FetchDescriptor<Artwork>()).count == 2)
    }

    // MARK: Turning sync off never deletes local data

    /// Stamping records made before 1.2.0 only fills in the device id — every record is still there.
    @Test func stampingLegacyRecordsKeepsEverything() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let defaults = try #require(UserDefaults(suiteName: "CloudSyncTests-\(UUID().uuidString)"))
        defaults.set("NEW", forKey: DeviceIdentity.key)
        defaults.set("OLD", forKey: "sync.stampedDevice")       // the store came from another phone's backup
        let legacy = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([1]))
        legacy.originDeviceID = ""
        let cloned = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([2]))
        cloned.originDeviceID = "OLD"
        let synced = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([3]))
        synced.originDeviceID = "THIRD"
        for a in [legacy, cloned, synced] { context.insert(a) }
        try context.save()

        let changed = SyncOrigin.stampLegacyRecords(context: context, defaults: defaults)

        #expect(changed == 2)
        #expect(legacy.originDeviceID == "NEW")
        #expect(cloned.originDeviceID == "NEW")
        #expect(synced.originDeviceID == "THIRD")
        #expect(try context.fetch(FetchDescriptor<Artwork>()).count == 3)
        // Once per device.
        #expect(SyncOrigin.stampLegacyRecords(context: context, defaults: defaults) == 0)
    }

    /// Restored from a phone that already synced: its records are its iCloud records, so only unstamped ones are
    /// stamped (the other phone's pending captures stay its own).
    @Test func stampingAfterRestoringASyncedPhoneLeavesItsRecords() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let defaults = try #require(UserDefaults(suiteName: "CloudSyncTests-\(UUID().uuidString)"))
        defaults.set("NEW", forKey: DeviceIdentity.key)
        defaults.set("OLD", forKey: "sync.stampedDevice")
        let legacy = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([1]))
        legacy.originDeviceID = ""
        let theirs = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([2]))
        theirs.originDeviceID = "OLD"
        context.insert(legacy)
        context.insert(theirs)
        try context.save()

        #expect(SyncOrigin.stampLegacyRecords(context: context, defaults: defaults, previouslySynced: true) == 1)
        #expect(legacy.originDeviceID == "NEW")
        #expect(theirs.originDeviceID == "OLD")
    }

    /// The same store file opened again without mirroring (what "sync off at the next launch" does) still has every
    /// artwork. (Uses its own temporary file, never the app's store.)
    @Test func reopeningTheStoreWithoutSyncKeepsEveryArtwork() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-off-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = ArchiveStore.schema
        var ids: Set<UUID> = []
        do {
            let first = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(first)
            for n in 0..<3 {
                let a = Artwork(kind: .flat, child: nil, capturedAt: day(2026, 1, n + 1), originalImageData: Data([UInt8(n)]))
                context.insert(a)
                ids.insert(a.id)
            }
            try context.save()
        }
        let second = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let found = try ModelContext(second).fetch(FetchDescriptor<Artwork>())
        #expect(Set(found.map(\.id)) == ids)
    }

    /// Maintenance does nothing unless this launch syncs.
    @Test func maintenanceIsANoOpWithoutSync() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let a = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([1]))
        a.originDeviceID = "A"
        let b = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data([1]))
        b.id = a.id
        b.originDeviceID = "B"
        context.insert(a)
        context.insert(b)
        try context.save()

        #expect(!app.sync.isActive)
        #expect(app.runSyncMaintenance(context: context))
        #expect(try context.fetch(FetchDescriptor<Artwork>()).count == 2)
    }
}
