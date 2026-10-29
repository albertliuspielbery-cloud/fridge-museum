import SwiftData
import SwiftUI
import UIKit

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

    /// The detail screen shows a smaller print so the placard and 孩子說 fit above the bottom bar.
    static var compactDetail: Bool { scenario == "detail" }

    /// `xcodebuild test` doesn't apply the scheme's StoreKit configuration, so the simulator's sandbox storefront (USA,
    /// $5.99) would show up in the screenshots. Demo launches show the base price (Taiwan, NT$190; StoreKit/API.md).
    static var storePrice: String? { isActive ? "NT$190" : nil }

    static var colorScheme: ColorScheme? {
        switch value(after: "-FMAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// Demo launches exist only in Debug builds (the screenshot scheme); Release / TestFlight never reads these flags.
    private static func value(after flag: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
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
        resetQuota(app: app)
        if scenario == "home-empty" || scenario == OnboardingCoordinator.demoScene { return }

        let seeded = await seed(app: app, context: context)
        if ["home-full", "success", "pending"].contains(scenario) {
            for id in seeded.session { app.store.recordKeep(kind: .flat, artworkID: id) }
        }
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

    /// The demo quota lives in its own suite (StoreBridge) that survives between launches: every scenario starts from
    /// zero; the fridge scenes then count this visit's drawings as kept today, so Bibi's bubble matches the fridge
    /// (2 kept → 1 left). The paywall scenario forces the gate shut regardless (`forcePaywall`).
    @MainActor
    private static func resetQuota(app: AppModel) {
        #if DEBUG
        app.store.quota.resetForTesting()
        #endif
    }

    struct Seeded {
        var session: [UUID]
        var featured: UUID
        var pendingFlat: UUID
        var pendingCraft: UUID
    }

    private static func sampleData(_ kind: ArtworkKind) -> Data {
        let name = kind == .flat ? "sample-flat" : "sample-craft"
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["FM_SEED_DIR"],
           let d = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(name).jpg")) {
            return d
        }
        #endif
        if let url = Bundle.main.url(forResource: name, withExtension: "jpg"), let d = try? Data(contentsOf: url) { return d }
        return Data()
    }

    /// The sample flag's tip touches the photo's right edge, so the editor would say 作品碰到照片邊緣 and the cut-out looks
    /// clipped. Demo only: widen the photo on the right with the table's own colour (averaged from the lower-right table
    /// area) so the craft sits inside the frame. The app's edge warning itself is unchanged.
    private static func paddedCraft(_ data: Data) -> Data {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return data }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        // Upright (EXIF orientation applied) so the sampled patch is where it looks.
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let patchRect = CGRect(x: size.width * 0.88, y: size.height * 0.72, width: size.width * 0.1, height: size.height * 0.2).integral
        guard let cg = upright.cgImage, let patch = cg.cropping(to: patchRect) else { return data }
        let side = 8
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(patch, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return data }
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(side * side) {
            r += Double(px[i * 4])
            g += Double(px[i * 4 + 1])
            b += Double(px[i * 4 + 2])
        }
        let count = Double(side * side) * 255
        let fill = UIColor(red: r / count, green: g / count, blue: b / count, alpha: 1)
        let margin = (size.width * 0.08).rounded()
        let padded = CGSize(width: size.width + margin, height: size.height)
        let out = UIGraphicsImageRenderer(size: padded, format: format).image { ctx in
            fill.setFill()
            ctx.fill(CGRect(origin: .zero, size: padded))
            upright.draw(at: .zero)
        }
        return out.jpegData(compressionQuality: 0.92) ?? data
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
        // New photos go to 小明 (the 拍給 chip shows a name, not 未分類).
        app.currentChildID = kid1.id

        // Process each sample once, then reuse the rendered output for the other demo works.
        let flatData = sampleData(.flat), craftData = paddedCraft(sampleData(.craft))
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
        // 孩子說 on the featured placard.
        flatSource.note = zh ? "這是我生日那天，大家一起玩氣球！" : "It was my birthday and we all played with balloons!"

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
