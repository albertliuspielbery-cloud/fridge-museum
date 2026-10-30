import CloudKit
import CoreData
import Foundation
import Observation
import SwiftData
import UIKit

/// iCloud sync (1.2.0, a Full Version feature): the person's own private CloudKit database, same Apple Account on
/// all their devices. Built on SwiftData's CloudKit mirroring (NSPersistentCloudKitContainer).
///
/// The store is opened **once per launch** (`openStore`), mirrored or not, and stays that way for the whole session.
/// Every switch — the Settings toggle, buying or a refund, signing in or out of iCloud — takes effect at the next
/// launch. Rebuilding the container mid-session would mean two containers on the same file while views, tasks and the
/// mirroring delegate still hold the old one; a relaunch is the only switch that is safe.
///
/// Turning sync off (toggle, refund, no iCloud account) opens the same file with `cloudKitDatabase: .none`: every
/// artwork stays on the device. What this code cannot prevent: if the person signs out of iCloud (or turns iCloud off
/// for this app in iOS Settings) *while the app is running with sync on*, NSPersistentCloudKitContainer removes the
/// synced data from the device by design (Apple: privacy on shared devices); it comes back when the same account signs
/// in again, but changes not uploaded yet are lost. For account changes made while the app was closed, the launch
/// checks first: no account → this launch stays local; once this phone has synced, the current Apple Account must
/// match the remembered one at every launch — a different account (or one that can't be confirmed, e.g. offline)
/// stays local too, so the mirroring never starts under another account and never drops this phone's artworks.
@MainActor
@Observable
final class CloudSync {
    nonisolated static let containerID = "iCloud.tw.starlight.fridgemuseum"

    enum Keys {
        /// The Settings toggle (default on for Full Version users, effective after the one-time explanation).
        static let enabled = "sync.enabled"
        static let introShown = "sync.introShown"
        /// The previous launch ran with sync (also evidence, in a restored backup, that the store was synced).
        static let lastLaunchCloud = "sync.lastLaunchCloud"
        /// CloudKit user record name of the account this phone last synced with.
        static let userRecordName = "sync.userRecordName"
        static let lastSyncedAt = "sync.lastSyncedAt"
    }

    /// How this launch's store was opened. Never changes during the session.
    private(set) var decision: SyncDecision = .local(.notSupported)
    /// The last upload (export) failed: shown until an upload succeeds (空間不足 / 暫時無法同步 stay up while
    /// uploads keep failing, even if downloads work).
    private(set) var exportProblem: SyncProblem?
    /// The last download (import / setup) failed.
    private(set) var importProblem: SyncProblem?
    private(set) var isRunning = false
    /// Last time the uploads were confirmed up to date (a successful export, or a successful import while no upload
    /// is failing).
    private(set) var lastSyncedAt: Date?
    private(set) var accountChangedThisSession = false
    private(set) var wantsSync: Bool
    private(set) var introShown: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var runningEvents: Set<UUID> = []
    @ObservationIgnored private var maintenance: (@MainActor () -> Bool)?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var recordedAccount = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.enabled: true])
        wantsSync = defaults.bool(forKey: Keys.enabled)
        introShown = defaults.bool(forKey: Keys.introShown)
        lastSyncedAt = defaults.object(forKey: Keys.lastSyncedAt) as? Date
    }

    var activity: SyncActivity {
        if let problem = exportProblem ?? importProblem { return .failed(problem) }
        return isRunning ? .syncing : .idle
    }

    /// This session's store is mirrored to iCloud.
    var isActive: Bool { decision == .cloud }

    func status(isFullVersion: Bool) -> SyncStatus {
        SyncPolicy.status(isFullVersion: isFullVersion, wantsSync: wantsSync, introShown: introShown, decision: decision,
                          activity: activity, hasSynced: lastSyncedAt != nil, accountChangedThisSession: accountChangedThisSession)
    }

    // MARK: Settings

    func setWantsSync(_ on: Bool) {
        wantsSync = on
        defaults.set(on, forKey: Keys.enabled)
        // Choosing in Settings counts as having read the explanation.
        markIntroShown()
    }

    /// The one-time explanation was answered (開啟 iCloud 同步 / 先不要).
    func answerIntro(enable: Bool) {
        setWantsSync(enable)
    }

    private func markIntroShown() {
        guard !introShown else { return }
        introShown = true
        defaults.set(true, forKey: Keys.introShown)
    }

    /// Full Version, never asked yet, and this build can sync: show the explanation sheet.
    func shouldOfferIntro(isFullVersion: Bool) -> Bool {
        isFullVersion && !introShown && Self.isSupportedEnvironment
    }

    // MARK: Launch

    /// Screenshot demos, unit-test hosts and the simulator never touch CloudKit (those builds are unsigned: without
    /// the iCloud entitlement, CKContainer would trap).
    nonisolated static var isSupportedEnvironment: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if DemoMode.isActive { return false }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
    }

    /// Opens the store for this launch. `isFullVersion`: PurchaseStore's cached entitlement (a refund noticed during a
    /// session stops sync at the next launch).
    func openStore(isFullVersion: Bool) async -> ModelContainer {
        if DemoMode.isActive {
            decision = .local(.notSupported)
            return ArchiveStore.makeContainer(inMemory: true)
        }
        Self.saveDeviceID(defaults: defaults)
        #if DEBUG
        if CloudKitSchemaInitializer.isRequested { CloudKitSchemaInitializer.run() }
        #endif
        var inputs = SyncInputs(isSupported: Self.isSupportedEnvironment, isFullVersion: isFullVersion,
                                introShown: introShown, wantsSync: wantsSync)
        if SyncPolicy.needsAccountCheck(inputs) {
            inputs.account = await Self.fetchAccount()
            // Synced before: confirm it's the same Apple Account at every launch (SyncPolicy.decide).
            if inputs.account == .available, let last = defaults.string(forKey: Keys.userRecordName) {
                inputs.hasStoredAccount = true
                if let current = await Self.fetchUserRecordName() { inputs.sameAccountAsLastSync = current == last }
            }
        }
        let previouslySynced = defaults.bool(forKey: Keys.lastLaunchCloud) || defaults.string(forKey: Keys.userRecordName) != nil
        var decided = SyncPolicy.decide(inputs)
        let opened = ArchiveStore.open(cloudKitContainerID: decided == .cloud ? Self.containerID : nil)
        if decided == .cloud && !opened.isCloud { decided = .local(.containerFailed) }
        decision = decided
        defaults.set(decided == .cloud, forKey: Keys.lastLaunchCloud)
        // Records made before 1.2.0 get this device's id (once), before anything else touches the store.
        SyncOrigin.stampLegacyRecords(context: opened.container.mainContext, defaults: defaults,
                                      previouslySynced: previouslySynced)
        if decided == .cloud { startMonitoring() }
        return opened.container
    }

    /// identifierForVendor: stays the same for this app on this device, differs on another device — also on a new
    /// phone restored from this one's backup (UserDefaults come along in the backup, so a saved UUID wouldn't).
    private static func saveDeviceID(defaults: UserDefaults) {
        guard let id = UIDevice.current.identifierForVendor?.uuidString else { return }
        if defaults.string(forKey: DeviceIdentity.key) != id { defaults.set(id, forKey: DeviceIdentity.key) }
    }

    // MARK: Maintenance (duplicates, renders for artworks that arrived without one)

    /// `run` returns false when it couldn't run now (an editor is open…); it is retried a little later.
    func setMaintenance(_ run: @escaping @MainActor () -> Bool) {
        maintenance = run
        scheduleMaintenance(after: 1)
    }

    private func scheduleMaintenance(after seconds: Double) {
        guard isActive, maintenance != nil else { return }
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, let run = self.maintenance else { return }
            if !run() { self.scheduleMaintenance(after: 20) }
        }
    }

    // MARK: Monitoring

    private func startMonitoring() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let event = SyncEvent(note) else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountMayHaveChanged() }
        })
    }

    private func handle(_ event: SyncEvent) {
        guard event.isFinished else {
            runningEvents.insert(event.id)
            isRunning = true
            return
        }
        runningEvents.remove(event.id)
        isRunning = !runningEvents.isEmpty
        if let problem = event.problem {
            if event.kind == .export { exportProblem = problem } else { importProblem = problem }
            return
        }
        guard event.succeeded else { return }
        switch event.kind {
        case .export:
            exportProblem = nil
            markSynced(event.endDate)
        case .import:
            importProblem = nil
            // Downloads alone don't prove the uploads are through: only while no upload is failing.
            if exportProblem == nil { markSynced(event.endDate) }
            scheduleMaintenance(after: 3)
        case .setup:
            importProblem = nil
        case .other:
            break
        }
        recordAccountOnce()
    }

    private func markSynced(_ date: Date?) {
        let when = date ?? Date()
        lastSyncedAt = when
        defaults.set(when, forKey: Keys.lastSyncedAt)
    }

    /// Remembers which Apple Account this phone syncs with (checked when sync is switched back on later).
    private func recordAccountOnce() {
        guard !recordedAccount else { return }
        recordedAccount = true
        Task { [weak self] in
            guard let name = await Self.fetchUserRecordName() else {
                self?.recordedAccount = false
                return
            }
            self?.defaults.set(name, forKey: Keys.userRecordName)
        }
    }

    private func accountMayHaveChanged() {
        Task { [weak self] in
            let account = await Self.fetchAccount()
            if account != .available { self?.accountChangedThisSession = true }
        }
    }

    // MARK: CloudKit calls (each with a time limit: the launch waits for them)

    nonisolated static func fetchAccount() async -> SyncAccount {
        let result = await withTimeout(seconds: 4) { () async -> SyncAccount in
            do {
                let status = try await CKContainer(identifier: containerID).accountStatus()
                return SyncAccount(status)
            } catch {
                return .unknown
            }
        }
        return result ?? .unknown
    }

    nonisolated static func fetchUserRecordName() async -> String? {
        let result = await withTimeout(seconds: 4) { () async -> String? in
            try? await CKContainer(identifier: containerID).userRecordID().recordName
        }
        return result ?? nil
    }

    /// The operation's result, or nil if it takes longer than `seconds` (the late result is dropped).
    nonisolated static func withTimeout<T: Sendable>(seconds: Double,
                                                     _ operation: @escaping @Sendable () async -> T) async -> T? {
        let gate = FirstResult<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.set(continuation)
            Task {
                let value = await operation()
                gate.finish(value)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                gate.finish(nil)
            }
        }
    }
}

/// Resumes a continuation once, with whichever result comes first.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    func set(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ value: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension SyncAccount {
    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

/// The parts of an NSPersistentCloudKitContainer event the status needs (Sendable, read on the posting side).
struct SyncEvent: Sendable {
    enum Kind: Sendable { case setup, `import`, export, other }

    let id: UUID
    let kind: Kind
    let isFinished: Bool
    let succeeded: Bool
    let endDate: Date?
    let problem: SyncProblem?

    init?(_ note: Notification) {
        guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return nil }
        id = event.identifier
        switch event.type {
        case .setup: kind = .setup
        case .import: kind = .import
        case .export: kind = .export
        @unknown default: kind = .other
        }
        endDate = event.endDate
        isFinished = event.endDate != nil
        succeeded = event.succeeded
        problem = event.endDate != nil && !event.succeeded ? SyncEvent.classify(event.error) : nil
    }

    static func classify(_ error: (any Error)?) -> SyncProblem {
        guard let error else { return .other }
        guard let ck = error as? CKError else {
            let ns = error as NSError
            return ns.domain == NSURLErrorDomain ? .network : .other
        }
        switch ck.code {
        case .quotaExceeded:
            return .quotaFull
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .network
        case .notAuthenticated:
            return .notSignedIn
        case .partialFailure:
            let codes = (ck.partialErrorsByItemID ?? [:]).values.compactMap { ($0 as? CKError)?.code }
            if codes.contains(.quotaExceeded) { return .quotaFull }
            if codes.contains(where: { [.networkUnavailable, .networkFailure, .serviceUnavailable].contains($0) }) { return .network }
            return .other
        default:
            return .other
        }
    }
}

extension SyncStatus {
    /// The status line in Settings.
    var label: String {
        switch self {
        case .upgradeNeeded: String(localized: "完整版功能")
        case .off: String(localized: "已關閉")
        case .willStartNextLaunch: String(localized: "下次打開 App 時開始同步")
        case .willStopNextLaunch: String(localized: "下次打開 App 時停止同步")
        case .noAccount: String(localized: "iCloud 未登入")
        case .accountUnavailable: String(localized: "iCloud 暫時無法使用")
        case .accountChanged: String(localized: "iCloud 帳號不同，已暫停")
        case .accountUnverified: String(localized: "無法確認 iCloud 帳號，這次先不同步")
        case .restartNeeded: String(localized: "iCloud 帳號有變動，請重新打開 App")
        case .unavailable: String(localized: "這次無法開啟同步")
        case .starting: String(localized: "準備中…")
        case .syncing: String(localized: "同步中…")
        case .synced: String(localized: "已同步")
        case .waitingForNetwork: String(localized: "等待網路連線")
        case .quotaFull: String(localized: "iCloud 空間不足")
        case .failed: String(localized: "暫時無法同步，稍後會自動再試")
        }
    }

    /// A longer explanation under the status, when there is something to do.
    var detail: String? {
        switch self {
        case .willStartNextLaunch, .willStopNextLaunch:
            String(localized: "從背景把 App 滑掉再打開就會生效。手機上的作品都會留著。")
        case .noAccount:
            String(localized: "到 iPhone「設定」登入 Apple 帳號並開啟 iCloud，再重新打開 App。作品都還在手機上。")
        case .accountChanged:
            String(localized: "這支手機現在登入的 Apple 帳號，和上次同步時不同。為了不刪掉手機上的作品，先暫停同步；換回原本的帳號就會繼續。")
        case .accountUnverified:
            String(localized: "這支手機同步過，要先確認登入的還是同一個 Apple 帳號才會同步（保護手機上還沒上傳的作品）。連上網路後重新打開 App 就會繼續。")
        case .quotaFull:
            String(localized: "iCloud 空間滿了，新作品先留在手機上。到「設定 › Apple 帳號 › iCloud」整理空間後會自動繼續。")
        case .restartNeeded:
            String(localized: "作品都還在 iCloud。重新打開 App 後會再檢查一次。")
        default:
            nil
        }
    }
}

#if DEBUG
/// Development only (needs a Mac): run a **Debug build signed with a development profile** on a device or simulator
/// signed into iCloud, with the launch argument `-FMInitCloudKitSchema`. It creates the record types CD_Child and
/// CD_Artwork in the container's *Development* environment from the SwiftData models (Apple's documented way for
/// SwiftData: NSPersistentCloudKitContainer.initializeCloudKitSchema on a throwaway store), then deploy the schema to
/// Production in CloudKit Console. Uses a temporary file, never the real store. TestFlight / App Store builds are
/// Release and talk to the Production environment, where record types can't be created — see HANDOFF.md「1.2.0 iCloud 同步」.
enum CloudKitSchemaInitializer {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-FMInitCloudKitSchema") }

    static func run() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-init-\(UUID().uuidString).store")
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: CloudSync.containerID)
        description.shouldAddStoreAsynchronously = false
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [Child.self, Artwork.self]) else {
            print("CloudKit schema: couldn't build the model")
            return
        }
        let container = NSPersistentCloudKitContainer(name: "SchemaInit", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error { print("CloudKit schema: store failed: \(error)") }
        }
        do {
            try container.initializeCloudKitSchema()
            print("CloudKit schema: initialized in the Development environment")
        } catch {
            print("CloudKit schema: failed: \(error)")
        }
        if let store = container.persistentStoreCoordinator.persistentStores.first {
            try? container.persistentStoreCoordinator.remove(store)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
