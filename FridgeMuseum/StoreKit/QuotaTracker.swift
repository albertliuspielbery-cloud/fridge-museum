import Foundation
import Observation
import UIKit

/// Free quota, ported from the web prototype (kidart.html v0.9.0, "free quota + 完整版"):
/// - counted once per artwork, when it is actually kept (收進這次 or 存到手機); re-saves, re-edits and retakes don't count;
/// - samples never count;
/// - flat works: `freeFlatPerDay` per LOCAL calendar day (resets at local midnight); crafts: `craftFreeTrial` lifetime;
/// - unlimited when the Full Version is unlocked;
/// - if storage is unavailable the person is never blocked.
/// Persisted in UserDefaults (keys in `Keys`). See StoreKit/API.md.
@MainActor
@Observable
final class QuotaTracker {
    nonisolated static let freeFlatPerDay = 3
    nonisolated static let craftFreeTrial = 3
    /// Remembered counted artwork IDs (FIFO cap). Far more than a free user can keep in years at 3/day.
    nonisolated static let countedCap = 5000

    enum Keys {
        static let flatDay = "quota.flat.day"
        static let flatCount = "quota.flat.count"
        static let craftCount = "quota.craft.count"
        static let counted = "quota.counted"
    }

    private var flatDay: String
    private var flatCount: Int
    private var craftCount: Int
    private var countedOrder: [String]
    @ObservationIgnored private var countedSet: Set<String>

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let unlockedProvider: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var timeObserver: (any NSObjectProtocol)?

    convenience init(purchaseStore: PurchaseStore, defaults: UserDefaults? = .standard) {
        self.init(isUnlocked: { purchaseStore.isFullUnlocked }, defaults: defaults)
    }

    init(isUnlocked: @escaping @MainActor () -> Bool,
         defaults: UserDefaults?,
         now: @escaping @MainActor () -> Date = { Date() },
         calendar: Calendar = .autoupdatingCurrent) {
        self.unlockedProvider = isUnlocked
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        self.flatDay = defaults?.string(forKey: Keys.flatDay) ?? ""
        self.flatCount = defaults?.integer(forKey: Keys.flatCount) ?? 0
        self.craftCount = defaults?.integer(forKey: Keys.craftCount) ?? 0
        let ids = defaults?.stringArray(forKey: Keys.counted) ?? []
        self.countedOrder = ids
        self.countedSet = Set(ids)
        timeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    // MARK: State

    var isUnlocked: Bool { unlockedProvider() }
    var isStorageAvailable: Bool { defaults != nil }
    /// False when unlocked or storage is unavailable: hide the quota bubble.
    var isTracking: Bool { !isUnlocked && isStorageAvailable }

    var remainingFlatToday: Int {
        guard isTracking else { return Self.freeFlatPerDay }
        let used = flatDay == todayKey() ? flatCount : 0
        return max(0, Self.freeFlatPerDay - used)
    }

    var remainingCraftTrial: Int {
        guard isTracking else { return Self.craftFreeTrial }
        return max(0, Self.craftFreeTrial - craftCount)
    }

    func remaining(for kind: ArtworkKind) -> Int {
        kind == .craft ? remainingCraftTrial : remainingFlatToday
    }

    func hasCounted(artworkID: UUID) -> Bool {
        countedSet.contains(artworkID.uuidString)
    }

    // MARK: Rules

    func canKeep(kind: ArtworkKind, artworkID: UUID, isSample: Bool = false) -> Bool {
        isSample || hasCounted(artworkID: artworkID) || isUnlocked || !isStorageAvailable || remaining(for: kind) > 0
    }

    /// Call right after an artwork was kept (hung up or saved to Photos). Idempotent per `artworkID`.
    func recordKeep(kind: ArtworkKind, artworkID: UUID, isSample: Bool = false) {
        guard !isSample, let defaults, !hasCounted(artworkID: artworkID) else { return }
        remember(artworkID.uuidString)
        if !isUnlocked {
            switch kind {
            case .craft:
                craftCount += 1
                defaults.set(craftCount, forKey: Keys.craftCount)
            case .flat:
                let today = todayKey()
                if flatDay != today {
                    flatDay = today
                    flatCount = 0
                    defaults.set(today, forKey: Keys.flatDay)
                }
                flatCount += 1
                defaults.set(flatCount, forKey: Keys.flatCount)
            }
        }
        defaults.set(countedOrder, forKey: Keys.counted)
    }

    /// Rolls the daily counter over when the local date changed (call on scenePhase == .active).
    func refresh() {
        let today = todayKey()
        guard flatDay != today else { return }
        flatDay = today
        flatCount = 0
        defaults?.set(today, forKey: Keys.flatDay)
        defaults?.set(0, forKey: Keys.flatCount)
    }

    #if DEBUG
    /// Debug-only: forget all counts (like the web prototype's 重設測試額度).
    func resetForTesting() {
        for key in [Keys.flatDay, Keys.flatCount, Keys.craftCount, Keys.counted] { defaults?.removeObject(forKey: key) }
        flatDay = todayKey()
        flatCount = 0
        craftCount = 0
        countedOrder = []
        countedSet = []
    }
    #endif

    // MARK: Private

    private func remember(_ id: String) {
        countedOrder.append(id)
        countedSet.insert(id)
        if countedOrder.count > Self.countedCap {
            let overflow = countedOrder.count - Self.countedCap
            for old in countedOrder.prefix(overflow) { countedSet.remove(old) }
            countedOrder.removeFirst(overflow)
        }
    }

    private func todayKey() -> String {
        Self.dayKey(for: now(), calendar: calendar)
    }

    nonisolated static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
        return "\(y)-\(m < 10 ? "0" : "")\(m)-\(d < 10 ? "0" : "")\(d)"
    }
}
