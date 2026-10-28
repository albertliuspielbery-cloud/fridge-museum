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

    init() {
        let purchases = PurchaseStore()
        self.purchases = purchases
        self.quota = QuotaTracker(purchases: purchases)
    }

    var isUnlocked: Bool { purchases.isFullUnlocked }
    var displayPrice: String? { purchases.displayPrice }

    func load() async {
        await purchases.load()
    }

    func canKeep(kind: ArtworkKind, artworkID: UUID) -> Bool {
        if DemoMode.forcePaywall { return false }
        return quota.canKeep(kind: kind, artworkID: artworkID)
    }

    func recordKeep(kind: ArtworkKind, artworkID: UUID) {
        quota.recordKeep(kind: kind, artworkID: artworkID)
    }

    func remaining(_ kind: ArtworkKind) -> Int {
        kind == .flat ? quota.remainingFlatToday : quota.remainingCraftTrial
    }

    /// What Bibi says on the freezer door (今天還能再收 3 張畫作喔！).
    func bubbleText(for kind: ArtworkKind) -> String {
        if isUnlocked { return String(localized: "完整版：想收幾張都可以喔！") }
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
