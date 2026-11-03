import SwiftData
import SwiftUI
import UIKit

@main
struct FridgeMuseumApp: App {
    /// Hands 家庭美術館 invitations (CloudKit share links) to FamilySync.
    @UIApplicationDelegateAdaptor(FamilyAppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()
    /// Opened once per launch, after CloudSync has decided whether this launch syncs with iCloud (it may ask
    /// CloudKit for the account status — and, once this phone has synced, which Apple Account is signed in — first:
    /// both at once, usually a fraction of a second, at most `CloudSync.launchCheckSeconds` (3 s)).
    @State private var container: ModelContainer?

    init() {
        Self.styleNavigationBars()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let container {
                    RootView()
                        .environment(appModel)
                        .environment(appModel.store.purchases)   // PaywallView reads PurchaseStore from the environment
                        .environment(appModel.store.quota)
                        .font(.fm(17))
                        .tint(Palette.teal)
                        .modelContainer(container)
                } else {
                    Wallpaper().ignoresSafeArea()
                }
            }
            .preferredColorScheme(DemoMode.colorScheme)
            .task {
                guard container == nil else { return }
                // 家庭美術館 (1.3.0): a family launch opens family.store only — the personal store stays closed
                // (and untouched) this launch; otherwise the personal store opens the 1.2 way.
                if let family = appModel.family.openStoreIfFamily() {
                    if appModel.family.grantsFullVersion { appModel.store.familyAccess.grant() }
                    container = family
                } else {
                    container = await appModel.sync.openStore(isFullVersion: appModel.store.isPurchased)
                }
            }
        }
    }

    /// Navigation titles in the kitchen fonts (Huninn large titles, Chiron GoRound inline titles).
    private static func styleNavigationBars() {
        let title = UIColor.dynamic(0x4A2F24, 0xF6EFE4)
        let large = UIFont(name: FMFont.display, size: 34) ?? .systemFont(ofSize: 34, weight: .bold)
        let inline = UIFont(name: FMFont.bold, size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large), .foregroundColor: title]
        appearance.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline), .foregroundColor: title]
        let back = UIBarButtonItemAppearance()
        back.normal.titleTextAttributes = [.font: UIFont(name: FMFont.bold, size: 16) ?? .systemFont(ofSize: 16)]
        appearance.backButtonAppearance = back
        appearance.buttonAppearance = back
        let scrolled = appearance.copy()
        scrolled.configureWithDefaultBackground()
        scrolled.backgroundColor = UIColor.dynamic(0xFCEBD2, 0x1E2340, alpha: 0.94)
        scrolled.shadowColor = .clear
        scrolled.largeTitleTextAttributes = appearance.largeTitleTextAttributes
        scrolled.titleTextAttributes = appearance.titleTextAttributes
        scrolled.backButtonAppearance = back
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = scrolled
        bar.compactAppearance = scrolled
        bar.scrollEdgeAppearance = appearance
        bar.tintColor = UIColor.dynamic(0x4A2F24, 0xF4EEE4)
    }
}
