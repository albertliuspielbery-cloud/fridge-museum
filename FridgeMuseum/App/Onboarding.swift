import Observation
import SwiftData
import SwiftUI

/// 新手教學: shown once on first launch, re-opened from Settings (使用教學).
///
/// Rules: a fresh install sees it once; finishing or 略過 (any way out) never shows it again. People upgrading from
/// 1.1.0 who already have artworks or children saved skip it (marked done on that first check, so it doesn't pop up
/// later if they empty the museum). Demo launches show it only in the `onboarding` screenshot scene and never write
/// the flag. The tutorial asks for no permissions and shows no purchase: the camera / Photos primers and the paywall
/// keep their own moments.
@MainActor
@Observable
final class OnboardingCoordinator {
    static let shared = OnboardingCoordinator()

    /// UserDefaults flag: the tutorial was finished, skipped, or not needed (existing user).
    nonisolated static let completedKey = "onboardingCompleted"
    /// The DemoMode scene that shows the tutorial's first page for the screenshot tests.
    nonisolated static let demoScene = "onboarding"

    var isPresented = false

    private let defaults: UserDefaults
    private let demoScenario: String?
    @ObservationIgnored private var evaluated = false

    init(defaults: UserDefaults = .standard, demoScenario: String? = DemoMode.scenario) {
        self.defaults = defaults
        self.demoScenario = demoScenario
    }

    var hasCompleted: Bool { defaults.bool(forKey: Self.completedKey) }

    /// Pure rule (unit-tested): demo launches only in their own scene; otherwise once, and not for existing users.
    nonisolated static func shouldShowAtLaunch(completed: Bool, hasExistingWork: Bool, demoScenario: String?) -> Bool {
        if let demoScenario { return demoScenario == demoScene }
        return !completed && !hasExistingWork
    }

    /// Called once per launch. `hasExistingWork`: any artwork (not a sample) or child profile is already saved.
    func evaluateAtLaunch(hasExistingWork: Bool) {
        guard !evaluated else { return }
        evaluated = true
        if demoScenario == nil, hasExistingWork, !hasCompleted {
            defaults.set(true, forKey: Self.completedKey)   // upgrading user: never needs the tutorial
        }
        isPresented = Self.shouldShowAtLaunch(completed: hasCompleted, hasExistingWork: hasExistingWork,
                                              demoScenario: demoScenario)
    }

    /// 使用教學 in Settings.
    func replay() {
        isPresented = true
    }

    /// Any way out (略過, 直接開始, 先加一位小朋友, 先看範例): close and remember.
    func finish() {
        isPresented = false
        guard demoScenario == nil else { return }
        defaults.set(true, forKey: Self.completedKey)
    }
}

/// What to open once the tutorial has closed.
enum OnboardingNext: Equatable {
    case addChild
    case sample
}

/// RootView's single hook (`.onboardingTutorial()`): decides at launch, presents the tutorial full screen, then opens
/// the child editor or the sample (the existing 看範例 flow) if the parent picked one on the last page.
struct OnboardingPresenter: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var next: OnboardingNext?
    @State private var showNewChild = false

    func body(content: Content) -> some View {
        @Bindable var coordinator = OnboardingCoordinator.shared
        content
            .fullScreenCover(isPresented: $coordinator.isPresented, onDismiss: openNext) {
                OnboardingView { choice in
                    next = choice
                    OnboardingCoordinator.shared.finish()
                }
            }
            .sheet(isPresented: $showNewChild) {
                ChildEditorView(child: nil) { created in app.setCaptureChild(created.id) }
            }
            .task { evaluate() }
    }

    private func evaluate() {
        // A database that couldn't be opened looks empty: don't greet an existing user as new (decide next launch).
        if ArchiveStore.isTemporary && !DemoMode.isActive { return }
        let artworks = (try? modelContext.fetchCount(FetchDescriptor<Artwork>(predicate: #Predicate { !$0.isSample }))) ?? 0
        let children = (try? modelContext.fetchCount(FetchDescriptor<Child>())) ?? 0
        OnboardingCoordinator.shared.evaluateAtLaunch(hasExistingWork: artworks > 0 || children > 0)
    }

    private func openNext() {
        guard let choice = next else { return }
        next = nil
        switch choice {
        case .addChild:
            showNewChild = true
        case .sample:
            if let sample = app.openSample(.flat, context: modelContext) { app.pendingRoute = .edit(sample.id) }
        }
    }
}

extension View {
    /// 新手教學 (first launch + Settings › 使用教學).
    func onboardingTutorial() -> some View {
        modifier(OnboardingPresenter())
    }
}

/// Settings' single hook: 使用教學 closes Settings, then re-opens the tutorial on the root view.
struct OnboardingSettingsRow: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                OnboardingCoordinator.shared.replay()
            }
        } label: {
            Label("使用教學", systemImage: "book")
        }
    }
}
