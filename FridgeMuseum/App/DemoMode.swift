import SwiftData
import SwiftUI

/// Deterministic screens for the screenshot UI tests (FridgeMuseumUITests): launched with `-FMDemo <scenario>`
/// (+ `-FMAppearance dark`, `-AppleLanguages (en)`), the app uses an in-memory store, seeds a small museum from the
/// two sample photos and opens the requested screen. Never active in normal launches.
enum DemoMode {
    static var scenario: String? { value(after: "-FMDemo") }
    static var isActive: Bool { scenario != nil }

    /// True when the current demo scenario is one of `names` (each screen only raises its own ready marker).
    static func scene(_ names: String...) -> Bool {
        guard let scenario else { return false }
        return names.contains(scenario)
    }
    /// The paywall scenario forces the keep/save gate shut.
    static var forcePaywall: Bool { scenario == "paywall" }

    static var colorScheme: ColorScheme? {
        switch value(after: "-FMAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    struct MuseumPreset {
        var child: UUID?
        var kind: ArtworkKind?
        var favorites = false
    }

    @MainActor
    static func museumPreset(children: [Child]) -> MuseumPreset? {
        guard scenario == "museum-filter" else { return nil }
        return MuseumPreset(child: children.first?.id, kind: .flat)
    }

    // MARK: Editor states

    @MainActor
    static func configure(editor model: EditModel, tool: Binding<EditTool?>, compare: Binding<Bool>,
                          activeCorner: Binding<Int?>, showLabel: Binding<Bool>) {
        switch scenario {
        case "edit-flat":
            Task {
                for _ in 0..<150 where model.before == nil { try? await Task.sleep(for: .milliseconds(200)) }
                compare.wrappedValue = true
            }
        case "crop", "crop-loupe":
            tool.wrappedValue = .crop
            Task {
                await model.loadSource()
                if scenario == "crop-loupe" { activeCorner.wrappedValue = 1 }
            }
        case "adjust":
            tool.wrappedValue = .adjust
        case "brush", "brush-craft":
            tool.wrappedValue = .brush
        case "label":
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                showLabel.wrappedValue = true
            }
        default:
            break
        }
    }

    // MARK: Seeding

    @MainActor
    static func prepare(app: AppModel, context: ModelContext, path: Binding<NavigationPath>, showSettings: Binding<Bool>) async {
        guard let scenario else { return }
        app.captureKind = .flat
        app.currentChildID = nil
        if scenario == "home-empty" { return }

        let seeded = await seed(app: app, context: context)
        switch scenario {
        case "home-full":
            app.sessionArtworkIDs = seeded.session
        case "success":
            app.sessionArtworkIDs = seeded.session
            app.show(String(localized: "這是第 \(seeded.session.count) 張，按快門拍下一張。"), style: .hung(count: seeded.session.count),
                     headline: String(localized: "已掛上冰箱！"), seconds: 600)
        case "pending":
            app.sessionArtworkIDs = seeded.session
        case "edit-flat", "crop", "crop-loupe", "adjust", "label":
            path.wrappedValue.append(Route.edit(seeded.pendingFlat))
        case "edit-craft", "brush-craft":
            path.wrappedValue.append(Route.edit(seeded.pendingCraft))
        case "paywall":
            path.wrappedValue.append(Route.edit(seeded.pendingFlat))
            try? await Task.sleep(for: .seconds(2))
            app.paywall = PaywallRequest(kind: .flat, artworkID: seeded.pendingFlat, action: .keep)
        case "museum", "museum-filter":
            path.wrappedValue.append(Route.museum)
        case "detail":
            path.wrappedValue.append(Route.detail(seeded.featured))
        case "settings":
            showSettings.wrappedValue = true
        default:
            break
        }
    }

    struct Seeded {
        var session: [UUID]
        var featured: UUID
        var pendingFlat: UUID
        var pendingCraft: UUID
    }

    private static func sampleData(_ kind: ArtworkKind) -> Data {
        let name = kind == .flat ? "sample-flat" : "sample-craft"
        if let dir = ProcessInfo.processInfo.environment["FM_SEED_DIR"],
           let d = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(name).jpg")) {
            return d
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "jpg"), let d = try? Data(contentsOf: url) { return d }
        return Data()
    }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date()
    }

    @MainActor
    private static func seed(app: AppModel, context: ModelContext) async -> Seeded {
        let zh = AppLanguage.isChinese
        let kid1 = Child(name: zh ? "小明" : "Mia", birthday: day(2020, 5, 3), avatarColorHex: Palette.avatarHexes[0])
        let kid2 = Child(name: zh ? "小美" : "Leo", birthday: day(2022, 9, 12), avatarColorHex: Palette.avatarHexes[4])
        context.insert(kid1)
        context.insert(kid2)

        // Process each sample once, then reuse the rendered output for the other demo works.
        let flatData = sampleData(.flat), craftData = sampleData(.craft)
        let flatSource = Artwork(kind: .flat, child: kid1, capturedAt: day(2026, 3, 14), originalImageData: flatData)
        let craftSource = Artwork(kind: .craft, child: kid1, capturedAt: day(2025, 10, 8), originalImageData: craftData)
        context.insert(flatSource)
        context.insert(craftSource)
        await app.autoProcess(flatSource, context: context)
        await app.autoProcess(craftSource, context: context)

        struct Spec {
            var zh: String
            var en: String
            var kind: ArtworkKind
            var child: Child
            var date: Date
            var tags: (zh: [String], en: [String])
            var favorite = false
            var medium: (zh: String, en: String) = ("", "")
        }
        let specs: [Spec] = [
            Spec(zh: "氣球派對", en: "Balloon Party", kind: .flat, child: kid1, date: day(2026, 3, 14),
                 tags: (["家人", "生日"], ["Family", "Birthday"]), favorite: true, medium: ("彩色筆、紙", "Markers")),
            Spec(zh: "國旗勞作", en: "Flag Craft", kind: .craft, child: kid1, date: day(2025, 10, 8),
                 tags: (["學校", "節日"], ["School", "Holidays"]), medium: ("不織布、珠子", "Felt & beads")),
            Spec(zh: "我的家", en: "My House", kind: .flat, child: kid2, date: day(2026, 2, 20),
                 tags: (["家人"], ["Family"]), medium: ("蠟筆、紙", "Crayons")),
            Spec(zh: "動物園", en: "At the Zoo", kind: .flat, child: kid1, date: day(2025, 9, 2),
                 tags: (["動物"], ["Animals"])),
            Spec(zh: "生日禮物", en: "Birthday Gift", kind: .craft, child: kid2, date: day(2025, 12, 24),
                 tags: (["生日"], ["Birthday"]), favorite: true),
            Spec(zh: "恐龍世界", en: "Dino World", kind: .flat, child: kid1, date: day(2025, 4, 18),
                 tags: (["恐龍"], ["Dinosaurs"])),
        ]
        var ids: [UUID] = []
        for (i, s) in specs.enumerated() {
            let a: Artwork
            if i == 0 {
                a = flatSource
            } else if i == 1 {
                a = craftSource
            } else {
                let src = s.kind == .flat ? flatSource : craftSource
                a = Artwork(kind: s.kind, child: s.child, capturedAt: s.date, originalImageData: src.originalImageData ?? Data())
                a.recipe = src.recipe
                a.renderedImageData = src.renderedImageData
                a.thumbnailData = src.thumbnailData
                a.pixelWidth = src.pixelWidth
                a.pixelHeight = src.pixelHeight
                a.renderVersion = 1
                a.processingState = src.processingState
                context.insert(a)
            }
            a.child = s.child
            a.capturedAt = s.date
            a.title = zh ? s.zh : s.en
            a.tags = zh ? s.tags.zh : s.tags.en
            a.isFavorite = s.favorite
            a.medium = zh ? s.medium.zh : s.medium.en
            a.isKept = true
            a.keptAt = Date().addingTimeInterval(Double(-i) * 3600)
            ids.append(a.id)
        }

        // Fresh captures still in the editor (上一張還沒收進) — only for the scenarios that show one.
        var pendingFlatID = ids[0], pendingCraftID = ids[1]
        if ["edit-flat", "crop", "crop-loupe", "adjust", "label", "paywall", "pending"].contains(scenario ?? "") {
            let p = Artwork(kind: .flat, child: kid1, capturedAt: Date(), originalImageData: flatData)
            context.insert(p)
            p.isKept = false
            p.recipe = flatSource.recipe
            p.renderedImageData = flatSource.renderedImageData
            p.thumbnailData = flatSource.thumbnailData
            p.pixelWidth = flatSource.pixelWidth
            p.pixelHeight = flatSource.pixelHeight
            p.processingState = .done
            pendingFlatID = p.id
        }
        if ["edit-craft", "brush-craft"].contains(scenario ?? "") {
            let p = Artwork(kind: .craft, child: kid2, capturedAt: Date(), originalImageData: craftData)
            context.insert(p)
            p.isKept = false
            p.recipe = craftSource.recipe
            pendingCraftID = p.id
        }
        try? context.save()
        return Seeded(session: [ids[0], ids[2]], featured: ids[0], pendingFlat: pendingFlatID, pendingCraft: pendingCraftID)
    }
}
