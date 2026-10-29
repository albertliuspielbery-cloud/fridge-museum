import Foundation
import Testing
@testable import FridgeMuseum

/// 新手教學: shown once on a fresh install, never again after finishing or 略過, re-opened from Settings, skipped for
/// people upgrading with artworks or children already saved, and only in its own scene for demo screenshots.
@MainActor
struct OnboardingTests {
    /// A private defaults suite per test, so the real app's flag is never touched.
    private func freshDefaults() -> UserDefaults {
        let name = "onboarding-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func freshInstallShowsTheTutorial() {
        let coordinator = OnboardingCoordinator(defaults: freshDefaults(), demoScenario: nil)
        coordinator.evaluateAtLaunch(hasExistingWork: false)
        #expect(coordinator.isPresented)
        #expect(!coordinator.hasCompleted)
    }

    @Test func finishingOrSkippingHidesItForGood() {
        let defaults = freshDefaults()
        let first = OnboardingCoordinator(defaults: defaults, demoScenario: nil)
        first.evaluateAtLaunch(hasExistingWork: false)
        first.finish()   // 略過, 直接開始 and both last-page choices all end here
        #expect(!first.isPresented)
        #expect(first.hasCompleted)

        // Next launch, still an empty museum: not again.
        let next = OnboardingCoordinator(defaults: defaults, demoScenario: nil)
        next.evaluateAtLaunch(hasExistingWork: false)
        #expect(!next.isPresented)
    }

    @Test func quittingMidwayShowsItAgainNextLaunch() {
        let defaults = freshDefaults()
        let first = OnboardingCoordinator(defaults: defaults, demoScenario: nil)
        first.evaluateAtLaunch(hasExistingWork: false)
        #expect(first.isPresented)
        // App closed without finishing: nothing written.
        let next = OnboardingCoordinator(defaults: defaults, demoScenario: nil)
        next.evaluateAtLaunch(hasExistingWork: false)
        #expect(next.isPresented)
    }

    @Test func onlyDecidedOncePerLaunch() {
        let coordinator = OnboardingCoordinator(defaults: freshDefaults(), demoScenario: nil)
        coordinator.evaluateAtLaunch(hasExistingWork: false)
        coordinator.finish()
        coordinator.evaluateAtLaunch(hasExistingWork: false)   // the root view's task running again
        #expect(!coordinator.isPresented)
    }

    @Test func settingsReopensItAfterFinishing() {
        let defaults = freshDefaults()
        let coordinator = OnboardingCoordinator(defaults: defaults, demoScenario: nil)
        coordinator.evaluateAtLaunch(hasExistingWork: false)
        coordinator.finish()
        coordinator.replay()
        #expect(coordinator.isPresented)
        coordinator.finish()
        #expect(!coordinator.isPresented)
        #expect(coordinator.hasCompleted)
    }

    @Test func settingsReopensItForExistingUsers() {
        let coordinator = OnboardingCoordinator(defaults: freshDefaults(), demoScenario: nil)
        coordinator.evaluateAtLaunch(hasExistingWork: true)
        #expect(!coordinator.isPresented)
        coordinator.replay()
        #expect(coordinator.isPresented)
    }

    /// Upgrading from 1.1.0 with artworks or children saved: no tutorial, and it stays off even if they later empty
    /// the museum.
    @Test func upgradingUsersWithWorkSkipIt() {
        let defaults = freshDefaults()
        let upgraded = OnboardingCoordinator(defaults: defaults, demoScenario: nil)
        upgraded.evaluateAtLaunch(hasExistingWork: true)
        #expect(!upgraded.isPresented)
        #expect(upgraded.hasCompleted)

        let later = OnboardingCoordinator(defaults: defaults, demoScenario: nil)
        later.evaluateAtLaunch(hasExistingWork: false)
        #expect(!later.isPresented)
    }

    @Test func ruleTable() {
        #expect(OnboardingCoordinator.shouldShowAtLaunch(completed: false, hasExistingWork: false, demoScenario: nil))
        #expect(!OnboardingCoordinator.shouldShowAtLaunch(completed: true, hasExistingWork: false, demoScenario: nil))
        #expect(!OnboardingCoordinator.shouldShowAtLaunch(completed: false, hasExistingWork: true, demoScenario: nil))
        #expect(!OnboardingCoordinator.shouldShowAtLaunch(completed: true, hasExistingWork: true, demoScenario: nil))
    }

    /// Screenshot scenes never show it, except its own `onboarding` scene; demo launches never write the flag.
    @Test func demoScenesShowItOnlyInTheirOwnScene() {
        for scene in ["home-empty", "home-full", "museum", "settings", "paywall"] {
            let coordinator = OnboardingCoordinator(defaults: freshDefaults(), demoScenario: scene)
            coordinator.evaluateAtLaunch(hasExistingWork: false)
            #expect(!coordinator.isPresented, "\(scene)")
        }
        let defaults = freshDefaults()
        defaults.set(true, forKey: OnboardingCoordinator.completedKey)
        let shot = OnboardingCoordinator(defaults: defaults, demoScenario: OnboardingCoordinator.demoScene)
        shot.evaluateAtLaunch(hasExistingWork: true)
        #expect(shot.isPresented)

        let untouched = freshDefaults()
        let demo = OnboardingCoordinator(defaults: untouched, demoScenario: OnboardingCoordinator.demoScene)
        demo.evaluateAtLaunch(hasExistingWork: true)
        demo.finish()
        #expect(!demo.hasCompleted)
    }
}
