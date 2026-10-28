import StoreKit
import SwiftUI
import UIKit

/// The Full Version paywall (sheet). Kind-aware copy, Bibi holding a ticket, StoreKit's localized price.
/// Needs `PurchaseStore` in the environment. Calls `onUnlocked` once when the Full Version becomes unlocked while it is
/// open (purchase, restore, Ask to Buy approval, family sharing), then dismisses itself. See StoreKit/API.md.
struct PaywallView: View {
    let kind: ArtworkKind
    var onUnlocked: @MainActor () -> Void

    @Environment(PurchaseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var messageIsError = false
    @State private var didFinish = false

    init(kind: ArtworkKind, onUnlocked: @escaping @MainActor () -> Void = {}) {
        self.kind = kind
        self.onUnlocked = onUnlocked
    }

    private var isCraft: Bool { kind == .craft }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    bibi
                    VStack(spacing: 8) {
                        Text(title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    perks
                    ticket
                    Label {
                        Text(PaywallText.familySharing)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "person.2.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let message {
                        Text(message)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .safeAreaInset(edge: .bottom) { buttons }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(PaywallText.close)
                }
            }
        }
        .task {
            if store.product == nil { await store.load() }
            if store.isFullUnlocked { finishUnlocked() }
        }
        .onChange(of: store.isFullUnlocked) { _, unlocked in
            if unlocked { finishUnlocked() }
        }
        .onChange(of: store.isPending) { _, pending in
            if pending { show(PaywallText.pending, error: false) }
        }
    }

    // MARK: Pieces

    private var bibi: some View {
        VStack(spacing: 6) {
            Group {
                if UIImage(named: "bibi-ticket") != nil {
                    Image("bibi-ticket").resizable().scaledToFit()
                } else {
                    Image(systemName: "ticket.fill")
                        .resizable().scaledToFit()
                        .padding(22)
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 128, height: 128)
            .accessibilityHidden(true)
            Text(PaywallText.bibiSays)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var perks: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([PaywallText.perk1, PaywallText.perk2, PaywallText.perk3], id: \.self) { perk in
                Label {
                    Text(perk).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ticket: some View {
        VStack(spacing: 4) {
            Text(PaywallText.ticketKicker)
                .font(.caption.weight(.heavy))
                .tracking(2)
                .foregroundStyle(.tint)
            Text(PaywallText.productName)
                .font(.headline)
            priceText
                .font(.title.weight(.bold))
                .monospacedDigit()
            Text(PaywallText.oneTime)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .foregroundStyle(.tint)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var priceText: some View {
        if let price = store.displayPrice {
            Text(price)
        } else if store.isLoading || !store.hasLoaded {
            ProgressView().accessibilityLabel(PaywallText.priceLoading)
        } else {
            VStack(spacing: 6) {
                Text(PaywallText.priceUnavailable)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(PaywallText.retry) { Task { await store.load() } }
                    .font(.footnote.weight(.semibold))
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button(action: buy) {
                Group {
                    if store.isPurchasing {
                        ProgressView()
                    } else if let price = store.displayPrice {
                        Text(PaywallText.unlock(price: price))
                    } else {
                        Text(PaywallText.productName)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(store.displayPrice == nil || store.isPurchasing)

            Button { dismiss() } label: {
                Text(isCraft ? PaywallText.laterCraft : PaywallText.laterFlat)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)

            Button(PaywallText.restore, action: restore)
                .font(.footnote.weight(.semibold))
                .disabled(store.isPurchasing)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // MARK: Copy

    private var title: String {
        isCraft ? PaywallText.titleCraft : PaywallText.titleFlat(QuotaTracker.freeFlatPerDay)
    }

    private var subtitle: String {
        isCraft ? PaywallText.subtitleCraft(QuotaTracker.craftFreeTrial) : PaywallText.subtitleFlat(QuotaTracker.freeFlatPerDay)
    }

    // MARK: Actions

    private func buy() {
        message = nil
        Task {
            do {
                if try await store.purchaseFull() {
                    finishUnlocked()
                } else if store.isPending {
                    show(PaywallText.pending, error: false)
                }
            } catch {
                show(PaywallText.failed, error: true)
            }
        }
    }

    private func restore() {
        message = nil
        Task {
            do {
                if try await store.restore() {
                    finishUnlocked()
                } else {
                    show(PaywallText.noPurchase, error: false)
                }
            } catch StoreKitError.userCancelled {
                // The person closed the Apple Account sign-in: nothing to say.
            } catch {
                show(PaywallText.failed, error: true)
            }
        }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func finishUnlocked() {
        guard !didFinish else { return }
        didFinish = true
        onUnlocked()
        dismiss()
    }
}

/// Paywall copy from `Paywall.xcstrings` (zh-Hant source, en). Keys are `paywall.*`.
enum PaywallText {
    private static func text(_ value: String.LocalizationValue) -> String {
        String(localized: value, table: "Paywall")
    }

    static func titleFlat(_ n: Int) -> String { text("paywall.title.flat \(n)") }
    static var titleCraft: String { text("paywall.title.craft") }
    static func subtitleFlat(_ n: Int) -> String { text("paywall.subtitle.flat \(n)") }
    static func subtitleCraft(_ n: Int) -> String { text("paywall.subtitle.craft \(n)") }
    static var bibiSays: String { text("paywall.bibi") }
    static var perk1: String { text("paywall.perk1") }
    static var perk2: String { text("paywall.perk2") }
    static var perk3: String { text("paywall.perk3") }
    static var ticketKicker: String { text("paywall.ticketKicker") }
    static var productName: String { text("paywall.productName") }
    static var oneTime: String { text("paywall.oneTime") }
    static var familySharing: String { text("paywall.family") }
    static func unlock(price: String) -> String { text("paywall.unlock \(price)") }
    static var laterFlat: String { text("paywall.later.flat") }
    static var laterCraft: String { text("paywall.later.craft") }
    static var restore: String { text("paywall.restore") }
    static var close: String { text("paywall.close") }
    static var priceLoading: String { text("paywall.priceLoading") }
    static var priceUnavailable: String { text("paywall.priceUnavailable") }
    static var retry: String { text("paywall.retry") }
    static var pending: String { text("paywall.pending") }
    static var failed: String { text("paywall.failed") }
    static var noPurchase: String { text("paywall.noPurchase") }
    static var restored: String { text("paywall.restored") }
}

#Preview("Flat") {
    PaywallView(kind: .flat).environment(PurchaseStore())
}

#Preview("Craft") {
    PaywallView(kind: .craft).environment(PurchaseStore())
}
