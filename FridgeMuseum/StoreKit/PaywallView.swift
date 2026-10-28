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
                VStack(alignment: .leading, spacing: 18) {
                    Text(title)
                        .font(.fmDisplay(25, relativeTo: .title2))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    bibi
                    Text(subtitle)
                        .font(.fm(16))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    perks
                    ticket
                    if isUnavailable { unavailableNotice }
                    Label {
                        Text(PaywallText.familySharing)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "house").foregroundStyle(Palette.teal)
                    }
                    .font(.fm(14.5))
                    .foregroundStyle(Palette.muted)
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
            .scrollIndicators(.hidden)
            .background(Palette.surface)
            .safeAreaInset(edge: .bottom) { buttons }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Palette.surface2))
                    }
                    .accessibilityLabel(PaywallText.close)
                }
            }
            .toolbarBackground(Palette.surface, for: .navigationBar)
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
        HStack(alignment: .center, spacing: 10) {
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
            .frame(width: 120, height: 120)
            .accessibilityHidden(true)
            Text(PaywallText.bibiSays)
                .font(.fm(15.5, bold: true))
                .foregroundStyle(Palette.bubbleInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24).padding(.trailing, 14).padding(.vertical, 12)
                .background(SpeechBubble().fill(Palette.card))
                .overlay(SpeechBubble().stroke(Palette.cardLine, lineWidth: 2))
        }
    }

    private var perks: some View {
        let dots = [Palette.blue, Palette.red, Palette.teal]
        let items = [PaywallText.perk1, PaywallText.perk2, PaywallText.perk3]
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, perk in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Circle().fill(dots[i]).frame(width: 18, height: 18)
                        .shadow(color: Palette.shadow, radius: 1, y: 1)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
                    Text(perk).font(.fm(16)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ticket: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PaywallText.ticketKicker)
                .font(.fm(13, bold: true))
                .tracking(2)
                .foregroundStyle(Palette.cardMuted)
            HStack(alignment: .firstTextBaseline) {
                Text(PaywallText.productName)
                    .font(.fmDisplay(22, relativeTo: .title3))
                    .foregroundStyle(Palette.cardInk)
                Spacer(minLength: 8)
                priceText
                    .font(.fm(26, bold: true, relativeTo: .title))
                    .foregroundStyle(Palette.cardInk)
                    .monospacedDigit()
            }
            Line()
                .stroke(Palette.red, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(height: 1)
            Text(PaywallText.oneTime)
                .font(.fm(14))
                .foregroundStyle(Palette.cardMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(TicketShape().fill(Palette.card))
        .overlay(TicketShape().stroke(Palette.cardLine, lineWidth: 2))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
    }

    /// Price never loaded (offline / product not available): explain it full width under the ticket.
    private var isUnavailable: Bool {
        store.displayPrice == nil && store.hasLoaded && !store.isLoading
    }

    @ViewBuilder private var priceText: some View {
        if let price = store.displayPrice {
            Text(price)
        } else if isUnavailable {
            Text(verbatim: "—").accessibilityHidden(true)
        } else {
            ProgressView().accessibilityLabel(PaywallText.priceLoading)
        }
    }

    private var unavailableNotice: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.warn)
            Text(PaywallText.priceUnavailable)
                .font(.fm(15))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { Task { await store.load() } } label: {
                Text(PaywallText.retry)
                    .font(.fm(15, bold: true))
                    .foregroundStyle(Palette.tealInk)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(Capsule().fill(Palette.tealSoft))
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface2))
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button(action: buy) {
                Group {
                    if store.isPurchasing {
                        ProgressView()
                    } else if let price = store.displayPrice {
                        Text(PaywallText.unlock(price: price))
                    } else if isUnavailable {
                        Text(PaywallText.purchaseUnavailable)
                    } else {
                        Text(PaywallText.priceLoading)
                    }
                }
            }
            .buttonStyle(store.displayPrice == nil
                         ? PrimaryCapsuleStyle(tint: Palette.surface2, deep: Palette.line, ink: Palette.muted, dimsWhenDisabled: false)
                         : PrimaryCapsuleStyle())
            .disabled(store.displayPrice == nil || store.isPurchasing)

            Button { dismiss() } label: {
                Text(isCraft ? PaywallText.laterCraft : PaywallText.laterFlat)
            }
            .buttonStyle(LaterCapsuleStyle())

            Button(action: restore) {
                Text(PaywallText.restore).underline()
            }
            .font(.fm(15, bold: true))
            .foregroundStyle(Palette.muted)
            .disabled(store.isPurchasing)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Palette.surface.ignoresSafeArea(edges: .bottom))
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

/// Admission-ticket outline: rounded card with a half-circle notch on each side.
private struct TicketShape: Shape {
    func path(in r: CGRect) -> Path {
        let card = Path(roundedRect: r, cornerRadius: 16, style: .continuous)
        let notch: CGFloat = 9
        var holes = Path()
        holes.addEllipse(in: CGRect(x: r.minX - notch, y: r.midY - notch, width: notch * 2, height: notch * 2))
        holes.addEllipse(in: CGRect(x: r.maxX - notch, y: r.midY - notch, width: notch * 2, height: notch * 2))
        return card.subtracting(holes)
    }
}

private struct Line: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        }
    }
}

/// 明天再收 / 先不要: a soft cream capsule.
private struct LaterCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fm(18, bold: true, relativeTo: .headline))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(Palette.surface2))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
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
    static var purchaseUnavailable: String { text("paywall.purchaseUnavailable") }
}

#Preview("Flat") {
    PaywallView(kind: .flat).environment(PurchaseStore())
}

#Preview("Craft") {
    PaywallView(kind: .craft).environment(PurchaseStore())
}
