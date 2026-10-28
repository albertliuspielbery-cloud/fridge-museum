// TEMPORARY — stand-ins for the Store team's FridgeMuseum/StoreKit (feat/store) so this branch builds on its own.
// Deleted at integration, when origin/feat/store is merged. Shapes follow the shared contract.
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class PurchaseStore {
    var isFullUnlocked = false
    var displayPrice: String? = "NT$190"

    func load() async {}

    func purchaseFull() async throws -> Bool {
        isFullUnlocked = true
        return true
    }

    func restore() async throws {}
}

@MainActor
@Observable
final class QuotaTracker {
    static let freeFlatPerDay = 3
    static let craftFreeTrial = 3

    private let purchases: PurchaseStore
    private var flatKept: Set<UUID> = []
    private var craftKept: Set<UUID> = []

    init(purchases: PurchaseStore) {
        self.purchases = purchases
    }

    var remainingFlatToday: Int { max(0, Self.freeFlatPerDay - flatKept.count) }
    var remainingCraftTrial: Int { max(0, Self.craftFreeTrial - craftKept.count) }

    func canKeep(kind: ArtworkKind, artworkID: UUID) -> Bool {
        if purchases.isFullUnlocked { return true }
        switch kind {
        case .flat: return flatKept.contains(artworkID) || remainingFlatToday > 0
        case .craft: return craftKept.contains(artworkID) || remainingCraftTrial > 0
        }
    }

    func recordKeep(kind: ArtworkKind, artworkID: UUID) {
        switch kind {
        case .flat: flatKept.insert(artworkID)
        case .craft: craftKept.insert(artworkID)
        }
    }
}

struct PaywallView: View {
    let kind: ArtworkKind
    let purchases: PurchaseStore
    var onFinish: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image("bibi-ticket").resizable().scaledToFit().frame(height: 140)
            Text(kind == .flat ? "今天的 3 張免費畫作收滿了" : "勞作免費試用用完了").font(.fmDisplay(22))
            Button("解鎖完整版 \(purchases.displayPrice ?? "")") {
                Task { onFinish((try? await purchases.purchaseFull()) ?? false) }
            }
            .buttonStyle(PrimaryCapsuleStyle())
            Button(kind == .flat ? "明天再收" : "先不要") { onFinish(false) }
                .buttonStyle(SecondaryCapsuleStyle())
            Button("恢復購買") { Task { try? await purchases.restore(); onFinish(purchases.isFullUnlocked) } }
                .font(.fm(15))
        }
        .padding(24)
    }
}
