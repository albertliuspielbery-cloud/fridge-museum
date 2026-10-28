# StoreKit module — API for the UI team

Owner: Store team (branch `feat/store`). Everything lives in `FridgeMuseum/StoreKit/`.
All types are in the app target (no separate module); `ArtworkKind` is the existing enum from `ProcessingKit/ProcessingRecipe.swift`.

## Product

| | |
|---|---|
| Product ID | `tw.starlight.fridgemuseum.full` (`PurchaseStore.fullProductID`) |
| Type | Non-consumable, Family Sharing ON |
| Price | NT$190 base (Taiwan); other storefronts use Apple's equalized price. Never hard-code a price — use `displayPrice`. |
| Local testing | `FridgeMuseum/StoreKit/FridgeMuseum.storekit` (see "project.yml patch" below) |

## `PurchaseStore`

```swift
@MainActor @Observable final class PurchaseStore {
    nonisolated static let fullProductID = "tw.starlight.fridgemuseum.full"

    private(set) var isFullUnlocked: Bool        // true for own purchase AND family-shared; false after refund/revocation
    private(set) var displayPrice: String?       // StoreKit's localized price ("NT$190", "$5.99"…); nil until loaded / offline
    private(set) var product: Product?           // the StoreKit product, nil until loaded
    private(set) var isLoading: Bool             // product request in flight
    private(set) var isPurchasing: Bool          // purchase or restore in flight (disable buttons)
    private(set) var isPending: Bool             // Ask to Buy / SCA pending; unlocks automatically via Transaction.updates
    private(set) var hasLoaded: Bool             // load() finished at least once (product may still be nil)

    init(defaults: UserDefaults = .standard)     // starts the Transaction.updates listener immediately
    func load() async                            // products + currentEntitlements; safe to call repeatedly
    func purchaseFull() async throws -> Bool     // true = unlocked now; false = cancelled or pending
    @discardableResult
    func restore() async throws -> Bool          // AppStore.sync(); true if the Full Version is now unlocked
    func refreshEntitlements() async             // re-reads Transaction.currentEntitlements
}

enum PurchaseError: LocalizedError { case productUnavailable, failedVerification }
```

Behavior:
- **Listener**: `init` starts a task over `Transaction.updates` (Ask to Buy approvals, purchases from other devices,
  family-sharing grants, refunds/revocations). Each verified update for our product re-reads `currentEntitlements`
  and calls `finish()`. Unverified transactions never unlock and are not finished.
- **Launch**: `isFullUnlocked` starts from a cached flag (UserDefaults `store.fullUnlocked`) so a buyer never sees a
  paywall flash; `load()` then replaces it with the truth from `Transaction.currentEntitlements`.
- **Entitlement rule** (`EntitlementPolicy.grantsFull`): product ID matches, `revocationDate == nil`, not expired.
  `ownershipType == .familyShared` counts as unlocked. A refund/revocation re-locks on the next update or launch.
- **purchaseFull()**: `.success(.verified)` → finish + unlock → `true`; `.success(.unverified)` → throws
  `PurchaseError.failedVerification`; `.pending` → `isPending = true`, returns `false`; `.userCancelled` → `false`.
  Throws `PurchaseError.productUnavailable` if the product never loaded (offline / not set up in ASC).
- **restore()**: `AppStore.sync()` (may show Apple ID sign-in; a cancelled sign-in throws `StoreKitError.userCancelled`,
  which the UI should ignore silently), then re-reads entitlements.

## `QuotaTracker`

```swift
@MainActor @Observable final class QuotaTracker {
    nonisolated static let freeFlatPerDay = 3    // flat artworks per LOCAL calendar day
    nonisolated static let craftFreeTrial = 3    // crafts, lifetime trial

    convenience init(purchaseStore: PurchaseStore, defaults: UserDefaults? = .standard)
    init(isUnlocked: @escaping @MainActor () -> Bool, defaults: UserDefaults?,
         now: @escaping @MainActor () -> Date = Date.init, calendar: Calendar = .current)

    var isUnlocked: Bool { get }                 // forwards PurchaseStore.isFullUnlocked (observable)
    var isTracking: Bool { get }                 // false when unlocked or storage unavailable → hide the quota bubble
    var remainingFlatToday: Int { get }          // 0…3 (3 when unlocked/untracked)
    var remainingCraftTrial: Int { get }         // 0…3
    func remaining(for kind: ArtworkKind) -> Int
    func hasCounted(artworkID: UUID) -> Bool

    func canKeep(kind: ArtworkKind, artworkID: UUID, isSample: Bool = false) -> Bool
    func recordKeep(kind: ArtworkKind, artworkID: UUID, isSample: Bool = false)   // idempotent per artworkID
    func refresh()                               // re-read day/counters (call on scenePhase == .active)
}
```

Rules (ported 1:1 from the web prototype `kidart.html` v0.9.0, "free quota + 完整版"):
- An artwork is **counted once**, when it is actually kept: 收進這次 (Hang It Up) **or** 存到手機 (Save to Photos).
  Call `recordKeep` right after either succeeds. Re-save, re-edit, re-render, retake of the same `artworkID` never count again.
- Call `canKeep` **before** keeping; if `false`, present `PaywallView` and run the keep action from `onUnlocked`.
  Editing/processing is never gated — only keeping.
- `canKeep` = `isSample || hasCounted(id) || isUnlocked || storage unavailable || remaining(kind) > 0`.
- Samples (`isSample: true`) never count and are always allowed.
- Flat: 3 per local day; the counter is keyed by the local date (`yyyy-MM-dd` in `calendar`), so it resets at local
  midnight. The tracker also listens for `UIApplication.significantTimeChangeNotification`; call `refresh()` when the
  scene becomes active as well.
- Crafts: 3 lifetime.
- Unlocked: unlimited; `recordKeep` only remembers the ID (no counter change), so a later refund doesn't charge
  artworks kept while unlocked.
- Storage unavailable (`defaults == nil`): never blocks (`canKeep` → `true`, `isTracking` → `false`).
- Persistence: UserDefaults keys `quota.flat.day` (String), `quota.flat.count` (Int), `quota.craft.count` (Int),
  `quota.counted` ([String] artwork UUIDs, newest last, capped at 5000).

## `PaywallView`

```swift
struct PaywallView: View {
    init(kind: ArtworkKind, onUnlocked: @escaping @MainActor () -> Void = {})
}
```
- Reads `PurchaseStore` from the environment: inject with `.environment(purchaseStore)` at the root.
- Present as a sheet (`.sheet(item:)` / `.sheet(isPresented:)`); it closes itself with `@Environment(\.dismiss)`.
- Calls `onUnlocked` once after a successful purchase, a successful restore, or when `isFullUnlocked` turns true while it
  is open (Ask to Buy approval / family sharing), then dismisses. Use it to finish the keep that triggered it.
- Content: kind-aware title/subtitle, Bibi holding a ticket (asset **`bibi-ticket`**, UI team provides it in
  Assets.xcassets; falls back to SF Symbol `ticket.fill` when missing), 3 perks, "ADMIT ONE" ticket with the
  StoreKit `displayPrice`, "One-time purchase — not a subscription", Family Sharing line, buttons
  Unlock · {price} / Maybe Tomorrow (flat) or Not Now (craft) / Restore Purchases. Shows "Waiting for approval" when
  pending, a retry when the price can't be loaded. No test-mode text.
- Strings: `FridgeMuseum/StoreKit/Paywall.xcstrings` (table `Paywall`, zh-Hant source + en), keys `paywall.*`.
  Copy is from `/home/user/kidart/i18n-zh-en.md`; the Family Sharing line is switched to present tense (review note 1)
  and these new keys are NOT yet reviewed: `paywall.priceLoading`, `paywall.priceUnavailable`, `paywall.retry`,
  `paywall.pending`, `paywall.failed`, `paywall.noPurchase`, `paywall.restored`, `paywall.close`.

## App wiring (UI team, `App/FridgeMuseumApp.swift`)

```swift
@main
struct FridgeMuseumApp: App {
    @State private var purchases: PurchaseStore
    @State private var quota: QuotaTracker
    init() {
        let p = PurchaseStore()                       // Transaction.updates listener starts here (app launch)
        _purchases = State(initialValue: p)
        _quota = State(initialValue: QuotaTracker(purchaseStore: p))
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(purchases)
                .environment(quota)
                .task { await purchases.load() }      // currentEntitlements on launch
        }
    }
}
```
Keep flow: `if quota.canKeep(kind:artworkID:isSample:) { keep(); quota.recordKeep(...) } else { show PaywallView(kind:) { keep(); quota.recordKeep(...) } }`.
Quota bubble: hide when `!quota.isTracking`; text from `remainingFlatToday` / `remainingCraftTrial` (UI-owned strings).

## project.yml patch (UI team applies; Store team does not edit project.yml)

```yaml
schemes:
  FridgeMuseum:
    run:
      config: Debug
      storeKitConfiguration: FridgeMuseum/StoreKit/FridgeMuseum.storekit
```
`FridgeMuseum/**` is already globbed into the app target; `.xcstrings` goes to Resources, the `.storekit` file must not
ship in the bundle — if XcodeGen copies it, add `- "StoreKit/FridgeMuseum.storekit"` to the target's `excludes`
and keep only the scheme reference (XcodeGen resolves scheme paths independently of target sources).

## App Store Connect automation

`ci/ci_iap.py` + `.github/workflows/ios-iap.yml` (manual `workflow_dispatch`). See the header of `ci/ci_iap.py`.
