import SwiftUI
import UIKit

/// The five tutorial pages. Bibi says the title in a speech bubble; one short line under it.
enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome, capture, keep, privacy, start

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "寶貝的畫，一張都不用丟"
        case .capture: "放平，拍一張"
        case .keep: "收進這次，掛上冰箱"
        // Neutral wording: true with iCloud sync off or on (the tutorial can be replayed from Settings while syncing).
        case .privacy: "照片只在手機上處理"
        case .start: "先加一位小朋友吧"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .welcome: "我是冰冰。拍下孩子的畫和勞作，我幫你整理乾淨，掛上冰箱。"
        case .capture: "紙會自動拉正、底色變白；勞作會自動去背。一整疊要收？打開「連拍」，一張接一張拍。"
        case .keep: "作品會依孩子、學期、年齡收進美術館。存到手機時，可以依孩子分相簿。"
        case .privacy: "App 不蒐集任何個人資料，也不用註冊帳號；開啟 iCloud 同步時，作品只存在你自己的 iCloud。"
        case .start: "填上名字和生日，每張作品都會記下當時幾歲。也可以先看看範例。"
        }
    }

    var bibi: String {
        switch self {
        case .welcome: "bibi-wave"
        case .capture: "bibi-talk"
        case .keep: "bibi-proud"
        case .privacy: "bibi-idle"
        case .start: "bibi-cheer"
        }
    }
}

/// 新手教學: swipe or 下一步 through five pages; 略過 at any time. The last page offers 先加一位小朋友 / 先看範例 /
/// 直接開始. No permissions are requested here and nothing is sold (OnboardingCoordinator).
struct OnboardingView: View {
    /// Called once with the parent's pick (nil = 略過 / 直接開始); the presenter closes the tutorial.
    let onFinish: (OnboardingNext?) -> Void

    @State private var page: OnboardingPage = .welcome
    @AccessibilityFocusState private var focusedTitle: OnboardingPage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLast: Bool { page == .start }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .accessibilitySortPriority(0)
            TabView(selection: $page) {
                ForEach(OnboardingPage.allCases) { p in
                    OnboardingPageView(page: p, focusedTitle: $focusedTitle, onFinish: onFinish)
                        .tag(p)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilitySortPriority(2)
            bottomBar
                .accessibilitySortPriority(1)
        }
        // Reading order: the page (title, line, choices), then 下一步 and the page count, then 略過.
        .accessibilityElement(children: .contain)
        .background(Wallpaper())
        .tint(Palette.teal)
        .onChange(of: page) { _, p in focusedTitle = p }
        .overlay(alignment: .topLeading) { if DemoMode.scene(OnboardingCoordinator.demoScene) { ReadyMarker() } }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            if !isLast {
                Button { onFinish(nil) } label: {
                    Text("略過")
                        .font(.fm(17, bold: true, relativeTo: .body))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, Metrics.gutter - 8)
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            dots
            Spacer(minLength: 8)
            if !isLast {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        page = OnboardingPage(rawValue: page.rawValue + 1) ?? .start
                    }
                } label: {
                    Text("下一步")
                }
                .buttonStyle(OnboardingButtonStyle(prominent: true))
                .frame(maxWidth: 220)
            }
        }
        .frame(minHeight: 58)
        .padding(.horizontal, Metrics.gutter + 4)
        .padding(.bottom, 12)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases) { p in
                Capsule()
                    .fill(p == page ? Palette.primary : Palette.line)
                    .frame(width: p == page ? 22 : 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("第 \(page.rawValue + 1) 頁，共 \(OnboardingPage.allCases.count) 頁"))
    }
}

/// One page: picture (decorative), Bibi + bubble (the title, a header), the line, and on the last page the choices.
private struct OnboardingPageView: View {
    let page: OnboardingPage
    var focusedTitle: AccessibilityFocusState<OnboardingPage?>.Binding
    let onFinish: (OnboardingNext?) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Drawn at a fixed design size and scaled, so it never pushes into the text (smaller at large text).
                let height: CGFloat = typeSize.isAccessibilitySize ? 150 : 250
                OnboardingPicture(page: page)
                    .dynamicTypeSize(.large)
                    .frame(width: 300, height: 250)
                    .scaleEffect(height / 250)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .accessibilityHidden(true)
                speech
                Text(page.message)
                    .font(.fm(19, relativeTo: .body))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if page == .start { choices }
            }
            .padding(.horizontal, Metrics.gutter + 4)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Bibi beside the bubble; stacked at accessibility text sizes so the title keeps its width.
    private var speech: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                  : AnyLayout(HStackLayout(alignment: .center, spacing: 6))
        return layout {
            Image(page.bibi)
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Text(page.title)
                .font(.fmDisplay(27, relativeTo: .title))
                .foregroundStyle(Palette.bubbleInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 26)
                .padding(.trailing, 16)
                .padding(.vertical, 14)
                .background(SpeechBubble().fill(Palette.bubble).shadow(color: Palette.shadow, radius: 4, y: 3))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused(focusedTitle, equals: page)
        }
    }

    private var choices: some View {
        VStack(spacing: 14) {
            Button { onFinish(.addChild) } label: {
                Label {
                    Text("先加一位小朋友")
                } icon: {
                    Image(systemName: "person.badge.plus")
                }
                .labelStyle(TightLabelStyle())
            }
            .buttonStyle(OnboardingButtonStyle(prominent: true))
            Button { onFinish(.sample) } label: {
                Text("先看範例")
            }
            .buttonStyle(OnboardingButtonStyle(prominent: false))
            Button { onFinish(nil) } label: {
                Text("直接開始")
                    .font(.fm(17, bold: true, relativeTo: .body))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }
}

/// Big rounded buttons that wrap instead of shrinking (large Dynamic Type sizes).
struct OnboardingButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fm(18, bold: true, relativeTo: .headline))
            .foregroundStyle(prominent ? Palette.primaryInk : Palette.tealInk)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                if prominent {
                    ZStack {
                        RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Palette.primaryDeep)
                            .offset(y: configuration.isPressed ? 1 : 4)
                        RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Palette.primary)
                            .offset(y: configuration.isPressed ? 2 : 0)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Palette.surface)
                        .shadow(color: Palette.shadow, radius: 5, y: 3)
                }
            }
            .offset(y: prominent && configuration.isPressed ? 2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
    }
}

// MARK: Pictures — compositions of the existing kitchen art and the bundled sample photo (no new illustrations)

private struct OnboardingPicture: View {
    let page: OnboardingPage

    var body: some View {
        switch page {
        case .welcome: welcome
        case .capture: capture
        case .keep: keep
        case .privacy: privacy
        case .start: start
        }
    }

    /// A small fridge with the sample drawing taped on the main door, the cat beside it.
    private var welcome: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Fridge {
                HStack(spacing: 18) {
                    Image("mag-tomato").resizable().scaledToFit().frame(width: 30)
                    Image("mag-cloud").resizable().scaledToFit().frame(width: 34)
                }
                .frame(height: 58)
            } main: {
                taped(OnboardingArt.straightened, width: 92)
                    .padding(.vertical, 26)
            }
            .frame(width: 200)
            Image("cat-sit").resizable().scaledToFit().frame(width: 62)
        }
    }

    /// The photo as taken (table and all) → the straightened print.
    private var capture: some View {
        HStack(spacing: 14) {
            Group {
                if let raw = OnboardingArt.raw {
                    Image(uiImage: raw).resizable().scaledToFit()
                } else {
                    Rectangle().fill(Palette.wood)
                }
            }
            .frame(width: 108, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .rotationEffect(.degrees(-5))
            .shadow(color: Palette.printShadow.opacity(0.6), radius: 5, y: 3)
            VStack(spacing: 4) {
                Image("sparkle").resizable().scaledToFit().frame(width: 26)
                Image(systemName: "arrow.right").font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.teal)
            }
            taped(OnboardingArt.straightened, width: 104)
        }
    }

    /// A placard and the ways the museum sorts: child, semester, age; the per-child album.
    private var keep: some View {
        let zh = AppLanguage.isChinese
        let name = zh ? "小明" : "Mia"
        return HStack(alignment: .center, spacing: 14) {
            taped(OnboardingArt.straightened, width: 84)
            VStack(alignment: .leading, spacing: 10) {
                Placard(title: String(localized: "氣球派對"),
                        lines: ["\(name) · \(String(localized: "\(5) 歲"))"], compact: true)

                HStack(spacing: 6) {
                    ChipLabel(title: name, systemImage: "person.fill", selected: true)
                    ChipLabel(title: zh ? "上學期" : "Fall", selected: false)
                }
                Label {
                    Text(verbatim: String(localized: "冰箱美術館 – \(name)")).lineLimit(1)
                } icon: {
                    Image(systemName: "photo.on.rectangle")
                }
                .labelStyle(TightLabelStyle())
                .font(.fm(13.5, bold: true))
                .foregroundStyle(Palette.muted)
            }
            .frame(width: 186, alignment: .leading)
        }
    }

    /// The phone with a lock, the cat asleep beside it.
    private var privacy: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack {
                Image(systemName: "iphone")
                    .font(.system(size: 150, weight: .regular))
                    .foregroundStyle(Palette.teal)
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Palette.primary)
            }
            Image("cat-loaf").resizable().scaledToFit().frame(width: 92)
        }
    }

    /// The counter: cat, crayon cup and a taped blank print waiting for the first artwork.
    private var start: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 22) {
                Image("cat-sit").resizable().scaledToFit().frame(width: 74)
                Rectangle().fill(Palette.print)
                    .frame(width: 96, height: 124)
                    .overlay(Image("bibi-mini").resizable().scaledToFit().frame(width: 40).opacity(0.5))
                    .shadow(color: Palette.printShadow, radius: 6, y: 4)
                    .overlay(alignment: .top) { Tape(style: .dots, width: 78, angle: -4).offset(y: -9) }
                    .rotationEffect(.degrees(3))
                    .padding(.bottom, 18)
                Image("prop-crayons").resizable().scaledToFit().frame(width: 28)
            }
            VStack(spacing: 0) {
                Rectangle().fill(Palette.wood).frame(height: 9)
                Rectangle().fill(Palette.woodDeep).frame(height: 3)
            }
            .frame(width: 280)
        }
    }

    private func taped(_ image: UIImage?, width: CGFloat) -> some View {
        HungPrint(id: OnboardingArt.printID, tilt: 2.5, tape: .mint, padding: 5) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Rectangle().fill(Palette.surface2)
                }
            }
            .frame(width: width)
        }
    }
}

/// The bundled sample drawing (Albert agreed to its public use), downscaled once: as taken, and cropped to the paper
/// as a stand-in for the finished print.
@MainActor
enum OnboardingArt {
    static let printID = UUID(uuidString: "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D") ?? UUID()
    static let raw: UIImage? = load(crop: nil)
    static let straightened: UIImage? = load(crop: CGRect(x: 0.11, y: 0.08, width: 0.78, height: 0.78))

    private static func load(crop: CGRect?) -> UIImage? {
        guard let url = Bundle.main.url(forResource: "sample-flat", withExtension: "jpg"),
              let data = try? Data(contentsOf: url), let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, 480 / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing applies the EXIF orientation, so the crop rect below is in upright pixels.
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let crop else { return small }
        let rect = CGRect(x: size.width * crop.minX, y: size.height * crop.minY,
                          width: size.width * crop.width, height: size.height * crop.height).integral
        guard let cg = small.cgImage?.cropping(to: rect) else { return small }
        return UIImage(cgImage: cg)
    }
}
