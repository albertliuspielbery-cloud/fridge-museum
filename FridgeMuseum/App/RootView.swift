import UIKit
import SwiftData
import SwiftUI

enum Route: Hashable {
    case museum
    case detail(UUID)
    case edit(UUID)
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $path) {
            HomeView(open: open, showSettings: { showSettings = true })
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .museum:
                        MuseumView(open: open, showSettings: { showSettings = true })
                    case .detail(let id):
                        ArtworkLoader(id: id) { ArtworkDetailView(artwork: $0, open: open) }
                    case .edit(let id):
                        ArtworkLoader(id: id) { EditView(artwork: $0) }
                    }
                }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if ArchiveStore.isTemporary { TemporaryStoreBanner() }
        }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                ToastBanner(toast: toast)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
                    .onTapGesture { app.toast = nil }
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: app.toast)
        .sensoryFeedback(trigger: app.toast) { _, new in
            guard let new else { return nil }
            switch new.style {
            case .hung: return .impact(weight: .light)
            case .problem: return .warning
            case .info: return nil
            }
        }
        .sheet(item: $app.paywall) { request in
            PaywallSheet(request: request)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert(Text("為每位小朋友建立相簿？"), isPresented: Binding(get: { app.photosPrimer != nil }, set: { if !$0 { app.photosPrimer = nil } }),
               presenting: app.photosPrimer) { primer in
            Button { app.continueSave(after: primer, albums: true, context: modelContext) } label: { Text("建立相簿") }
            Button { app.continueSave(after: primer, albums: false, context: modelContext) } label: { Text("只存到照片") }
            Button(role: .cancel) { app.photosPrimer = nil } label: { Text("取消") }
        } message: { _ in
            Text("要建立「冰箱美術館 – 小明」這樣的相簿，iPhone 會詢問是否允許取用所有照片。App 只會新增作品，不會讀取或上傳你的照片。")
        }
        .alert(Text("沒有照片權限"), isPresented: $app.photosDeniedAlert) {
            Button { openURL(URL(string: UIApplication.openSettingsURLString)!) } label: { Text("打開設定") }
            Button(role: .cancel) {} label: { Text("好") }
        } message: {
            Text("作品還在 App 裡。到「設定 › 冰箱美術館 › 照片」選「僅限加入照片」或「完整取用」，就能存到照片。")
        }
        .onChange(of: app.pendingRoute) { _, route in
            guard let route else { return }
            app.pendingRoute = nil
            path.append(route)
        }
        .onChange(of: app.popToRoot) {
            path = NavigationPath()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.store.refresh() }
        }
        .task {
            await app.store.load()
            await DemoMode.prepare(app: app, context: modelContext, path: $path, showSettings: $showSettings)
        }
    }

    private func open(_ route: Route) {
        path.append(route)
    }
}

/// Resolves an artwork id to the model.
struct ArtworkLoader<Content: View>: View {
    @Query private var matches: [Artwork]
    let content: (Artwork) -> Content

    init(id: UUID, @ViewBuilder content: @escaping (Artwork) -> Content) {
        let target = id
        _matches = Query(filter: #Predicate<Artwork> { $0.id == target })
        self.content = content
    }

    var body: some View {
        if let artwork = matches.first {
            content(artwork)
        } else {
            ContentUnavailableView {
                Label("找不到這件作品", systemImage: "photo")
            }
            .background(Wallpaper())
        }
    }
}

/// Shown for the whole session when the database couldn't be opened and works only live in memory.
struct TemporaryStoreBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(0xFFD45A, 0xFFD45A))
            Text("作品資料庫打不開，這次收的作品不會被保存。請先存到照片，再重新開啟 App。")
                .font(.fm(14, bold: true))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(0xA8341F, 0x8A2A18))
        .accessibilityElement(children: .combine)
    }
}

/// Top banner. Celebrations get Bibi cheering + crayon lettering (已掛上冰箱！).
struct ToastBanner: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 12) {
            switch toast.style {
            case .hung:
                Image("bibi-cheer").resizable().scaledToFit().frame(width: 74, height: 74)
                VStack(alignment: .leading, spacing: 4) {
                    if let headline = toast.headline {
                        CrayonText(text: headline, size: 30)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Text(verbatim: toast.text)
                        .font(.fm(14.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .problem:
                Image("bibi-oops").resizable().scaledToFit().frame(width: 52, height: 52)
                Text(verbatim: toast.text).font(.fm(16)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            case .info:
                Image("bibi-head").resizable().scaledToFit().frame(width: 34, height: 26)
                Text(verbatim: toast.text).font(.fm(16)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, toast.isCelebration ? 12 : 12)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Palette.line, lineWidth: 1.5))
        .shadow(color: Palette.shadow, radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Wraps the Store team's PaywallView and resumes the pending keep/save after a successful unlock.
struct PaywallSheet: View {
    let request: PaywallRequest
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        PaywallView(kind: request.kind) {
            app.resumeAfterUnlock(request, context: modelContext)
        }
        .overlay(alignment: .topLeading) { if DemoMode.scene("paywall") { ReadyMarker() } }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.surface)
        .presentationCornerRadius(32)
    }
}
