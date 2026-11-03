import Foundation
import Observation

/// The UI's single doorway to the Store team's `PurchaseStore` + `QuotaTracker` (FridgeMuseum/StoreKit, see API.md).
/// Everything the screens need — quota copy for Bibi's speech bubble, the keep/save gate, unlock/restore — goes
/// through here, so StoreKit details stay in one place.
@MainActor
@Observable
final class StoreBridge {
    let purchases: PurchaseStore
    let quota: QuotaTracker
    /// 家庭美術館 (1.3.0): set once at launch when this launch opens a family museum.
    let familyAccess: FamilyAccess

    init() {
        let purchases = PurchaseStore()   // starts the Transaction.updates listener at launch
        self.purchases = purchases
        let family = FamilyAccess()
        self.familyAccess = family
        // Screenshot demos never touch the real counters.
        self.quota = QuotaTracker(isUnlocked: { purchases.isFullUnlocked || family.isGranted },
                                  defaults: DemoMode.isActive ? UserDefaults(suiteName: "demo-quota") : .standard)
    }

    /// Full Version features: bought on this Apple Account, or shared by a family museum (everyone in a family
    /// museum has them; the owner's purchase covers the family).
    var isUnlocked: Bool { purchases.isFullUnlocked || familyAccess.isGranted }
    /// Bought (or Family Sharing of the purchase) on this Apple Account — what creating a family museum and the
    /// personal iCloud sync need. A family museum's shared access doesn't count.
    var isPurchased: Bool { purchases.isFullUnlocked }
    var displayPrice: String? { purchases.displayPrice }

    func load() async {
        await purchases.load()
    }

    func canKeep(kind: ArtworkKind, artworkID: UUID, isSample: Bool = false) -> Bool {
        if DemoMode.forcePaywall { return false }
        return quota.canKeep(kind: kind, artworkID: artworkID, isSample: isSample)
    }

    func recordKeep(kind: ArtworkKind, artworkID: UUID, isSample: Bool = false) {
        quota.recordKeep(kind: kind, artworkID: artworkID, isSample: isSample)
    }

    func remaining(_ kind: ArtworkKind) -> Int {
        quota.remaining(for: kind)
    }

    func refresh() {
        quota.refresh()
    }

    /// What Bibi says on the freezer door (今天還能再收 3 張畫作喔！).
    func bubbleText(for kind: ArtworkKind) -> String {
        if isUnlocked { return String(localized: "完整版：想收幾張都可以喔！") }
        if !quota.isTracking { return String(localized: "按下快門，把作品掛上冰箱吧！") }
        let n = remaining(kind)
        switch kind {
        case .flat:
            return n > 0 ? String(localized: "今天還能再收 \(n) 張畫作喔！") : String(localized: "今天的免費畫作收滿了，明天再來")
        case .craft:
            return n > 0 ? String(localized: "勞作免費試用剩 \(n) 次") : String(localized: "勞作免費試用已用完")
        }
    }

    func isOut(_ kind: ArtworkKind) -> Bool { !isUnlocked && remaining(kind) <= 0 }
}

/// 家庭美術館 (1.3.0): the Full Version features a family museum shares with everyone in it. Granted once at launch
/// (FridgeMuseumApp, when FamilySync opens a family museum) and kept for the session; a family museum that ends
/// mid-session keeps it until the next launch, which opens the personal museum.
@MainActor
@Observable
final class FamilyAccess {
    private(set) var isGranted = false

    func grant() { isGranted = true }
}
