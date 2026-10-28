import Foundation
import Observation
import StoreKit

enum PurchaseError: Error, Equatable {
    /// The product couldn't be loaded (offline, or not set up in App Store Connect yet).
    case productUnavailable
    /// StoreKit returned a transaction whose JWS signature didn't verify. Never unlocks.
    case failedVerification
}

/// The facts about a transaction that decide whether it unlocks the Full Version.
/// Kept separate from `StoreKit.Transaction` (which tests can't construct) so the rule is unit-testable.
struct EntitlementFacts: Sendable, Equatable {
    var productID: String
    var revocationDate: Date?
    var expirationDate: Date?
    var isFamilyShared: Bool
}

enum EntitlementPolicy {
    /// Own purchases and family-shared purchases both unlock; refunded/revoked or expired ones don't.
    static func grantsFull(_ facts: EntitlementFacts, productID: String = PurchaseStore.fullProductID, now: Date = Date()) -> Bool {
        guard facts.productID == productID else { return false }
        if facts.revocationDate != nil { return false }
        if let expiry = facts.expirationDate, expiry <= now { return false }
        return true
    }
}

extension StoreKit.Transaction {
    var entitlementFacts: EntitlementFacts {
        EntitlementFacts(productID: productID, revocationDate: revocationDate, expirationDate: expirationDate,
                         isFamilyShared: ownershipType == .familyShared)
    }
}

/// StoreKit 2 wrapper for the single non-consumable "完整版 / Full Version".
/// Create once at app launch (the `Transaction.updates` listener starts in `init`), inject with `.environment(_:)`,
/// and call `load()` from a launch `.task`. See StoreKit/API.md.
@MainActor
@Observable
final class PurchaseStore {
    nonisolated static let fullProductID = "tw.starlight.fridgemuseum.full"
    /// Last known entitlement, so a buyer doesn't see the paywall before `currentEntitlements` has been read.
    nonisolated static let cacheKey = "store.fullUnlocked"

    private(set) var isFullUnlocked: Bool
    private(set) var displayPrice: String?
    private(set) var product: Product?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    /// Ask to Buy / Strong Customer Authentication: the purchase finishes later and arrives via `Transaction.updates`.
    private(set) var isPending = false
    private(set) var hasLoaded = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isFullUnlocked = defaults.bool(forKey: Self.cacheKey)
        startListening()
    }

    /// Fetches the product (for `displayPrice`) and re-reads current entitlements. Safe to call repeatedly.
    func load() async {
        if product == nil, !isLoading {
            isLoading = true
            do {
                let products = try await Product.products(for: [Self.fullProductID])
                if let p = products.first(where: { $0.id == Self.fullProductID }) {
                    product = p
                    displayPrice = p.displayPrice
                }
            } catch {
                // Offline or StoreKit unavailable: keep displayPrice nil; the paywall offers a retry.
            }
            isLoading = false
        }
        await refreshEntitlements()
        hasLoaded = true
    }

    /// Buys the Full Version. Returns `true` when it is unlocked now, `false` when the person cancelled or the
    /// purchase is pending approval (`isPending`). Throws `PurchaseError` or StoreKit errors.
    func purchaseFull() async throws -> Bool {
        if product == nil { await load() }
        guard let product else { throw PurchaseError.productUnavailable }
        isPurchasing = true
        defer { isPurchasing = false }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw PurchaseError.failedVerification
            }
            await transaction.finish()
            isPending = false
            if EntitlementPolicy.grantsFull(transaction.entitlementFacts) {
                setUnlocked(true)
            } else {
                await refreshEntitlements()
            }
            return isFullUnlocked
        case .pending:
            isPending = true
            return false
        case .userCancelled:
            return false
        @unknown default:
            return false
        }
    }

    /// Restore Purchases: syncs with the App Store (may ask for the Apple Account password), then re-reads
    /// entitlements. Returns whether the Full Version is unlocked afterwards.
    @discardableResult
    func restore() async throws -> Bool {
        isPurchasing = true
        defer { isPurchasing = false }
        try await AppStore.sync()
        await refreshEntitlements()
        return isFullUnlocked
    }

    /// Re-reads `Transaction.currentEntitlements` (own + family-shared, excluding refunded/revoked).
    func refreshEntitlements() async {
        var unlocked = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result, EntitlementPolicy.grantsFull(transaction.entitlementFacts) {
                unlocked = true
            }
        }
        setUnlocked(unlocked)
    }

    // MARK: Private

    private func startListening() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.handle(update)
            }
        }
    }

    private func handle(_ update: VerificationResult<StoreKit.Transaction>) async {
        // Unverified transactions never unlock, and are left unfinished.
        guard case .verified(let transaction) = update else { return }
        if transaction.productID == Self.fullProductID {
            if EntitlementPolicy.grantsFull(transaction.entitlementFacts) {
                setUnlocked(true)
                isPending = false
            } else {
                // Refund, revocation, or family sharing removed: re-lock unless another valid entitlement remains.
                await refreshEntitlements()
            }
        }
        await transaction.finish()
    }

    private func setUnlocked(_ value: Bool) {
        if isFullUnlocked != value { isFullUnlocked = value }
        if value { isPending = false }
        defaults.set(value, forKey: Self.cacheKey)
    }
}
