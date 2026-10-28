import XCTest

/// Renders the key screens in zh-Hant / en × light / dark for visual review without a Mac.
/// The app is launched with `-FMDemo <scenario>` (see FridgeMuseum/App/DemoMode.swift): in-memory store, demo museum
/// seeded from the two sample photos in this test bundle, and the requested screen opened directly.
/// PNGs go to $SHOTS_DIR (CI: TEST_RUNNER_SHOTS_DIR) and are also attached to the result bundle.
final class ScreenshotTests: XCTestCase {
    static let allScenarios = [
        "home-empty", "home-full", "success", "edit-flat", "edit-craft", "crop-loupe", "adjust", "brush-craft",
        "label", "paywall", "museum", "museum-filter", "detail", "settings",
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    private func list(_ key: String, default value: [String]) -> [String] {
        let raw = ProcessInfo.processInfo.environment[key] ?? ""
        let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return items.isEmpty ? value : items
    }

    // One test per language × appearance, so a stuck simulator query only costs that set, not all 56 shots.
    @MainActor func testZhLight() { run(lang: "zh", look: "light") }
    @MainActor func testZhDark() { run(lang: "zh", look: "dark") }
    @MainActor func testEnLight() { run(lang: "en", look: "light") }
    @MainActor func testEnDark() { run(lang: "en", look: "dark") }

    @MainActor
    private func run(lang: String, look: String) {
        guard list("SHOTS_LANGS", default: ["zh", "en"]).contains(lang),
              list("SHOTS_LOOKS", default: ["light", "dark"]).contains(look) else { return }
        let done = Set((try? FileManager.default.contentsOfDirectory(atPath: ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? "")) ?? [])
        for scenario in list("SHOTS_ONLY", default: Self.allScenarios) where !done.contains("\(lang)-\(look)-\(scenario).png") {
            shoot(scenario, lang: lang, look: look)
        }
    }

    @MainActor
    private func shoot(_ scenario: String, lang: String, look: String) {
        let app = XCUIApplication()
        let zh = lang.hasPrefix("zh")
        app.launchArguments = [
            "-FMDemo", scenario,
            "-FMAppearance", look,
            "-AppleLanguages", zh ? "(zh-Hant)" : "(en)",
            "-AppleLocale", zh ? "zh_TW" : "en_US",
        ]
        if let dir = Bundle(for: ScreenshotTests.self).resourcePath {
            app.launchEnvironment["FM_SEED_DIR"] = dir
        }
        app.launch()
        let ready = app.descendants(matching: .any)["fm.ready"].firstMatch
        let ok = ready.waitForExistence(timeout: 90)
        // Let animations, sheets and the last preview render settle.
        Thread.sleep(forTimeInterval: scenario == "paywall" || scenario == "label" || scenario == "settings" ? 2.5 : 1.5)
        let shot = XCUIScreen.main.screenshot()
        let name = "\(lang)-\(look)-\(scenario)\(ok ? "" : "-notready")"
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url)
        }
        if !ok { XCTFail("\(name): screen never became ready") }
        app.terminate()
    }
}
