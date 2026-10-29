import SwiftData
import SwiftUI
import UIKit

/// 設定與關於: full version (unlock / restore), children, Photos albums, language, privacy & support, licenses.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Query(sort: \Child.createdAt) private var children: [Child]
    /// Museum artworks (kept, not samples), for 已存到照片 X／Y 件.
    @Query(filter: #Predicate<Artwork> { $0.isKept && !$0.isSample }) private var museum: [Artwork]
    @AppStorage(AppModel.Keys.useAlbums) private var useAlbums = true
    @State private var editingChild: Child?
    @State private var showNewChild = false
    @State private var restoring = false

    static let privacyURL = URL(string: "https://albertliuspielbery-cloud.github.io/fridge-museum/privacy.html")!
    static let supportURL = URL(string: "https://albertliuspielbery-cloud.github.io/fridge-museum/support.html")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    hero
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                Section {
                    if app.store.isUnlocked {
                        Label {
                            Text("已解鎖完整版")
                        } icon: {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.green)
                        }
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("免費版").font(.fm(16, bold: true))
                                Text(verbatim: quotaSummary).font(.fm(13.5)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                        }
                        Button {
                            dismiss()
                            Task {
                                try? await Task.sleep(for: .milliseconds(350))
                                app.paywall = PaywallRequest(kind: .flat, artworkID: nil, action: .browse)
                            }
                        } label: {
                            Label {
                                Text("解鎖完整版")
                            } icon: {
                                Image("ticket").resizable().scaledToFit().frame(width: 30)
                            }
                        }
                    }
                    Button {
                        restoring = true
                        Task {
                            do {
                                try await app.store.purchases.restore()
                                app.show(app.store.isUnlocked ? String(localized: "已恢復完整版") : String(localized: "這個 Apple 帳號沒有購買紀錄"))
                            } catch {
                                app.show(String(localized: "無法連線到 App Store，請稍後再試"), style: .problem)
                            }
                            restoring = false
                        }
                    } label: {
                        HStack {
                            Text("恢復購買")
                            if restoring { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(restoring)
                } header: {
                    Text("完整版")
                } footer: {
                    Text("一次買斷，不是訂閱。支援「家人共享」。")
                }

                Section {
                    ForEach(children) { c in
                        Button { editingChild = c } label: {
                            HStack(spacing: 12) {
                                ChildAvatar(child: c, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: c.displayName).font(.fm(16, bold: true)).foregroundStyle(Palette.ink)
                                    if let b = c.birthday, let age = AgeCalculator.age(birthday: b, at: Date()) {
                                        Text(verbatim: age.localizedLabel).font(.fm(13.5)).foregroundStyle(Palette.muted)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.faint)
                            }
                        }
                    }
                    Button { showNewChild = true } label: {
                        Label("新增小朋友", systemImage: "person.badge.plus")
                    }
                } header: {
                    Text("小朋友")
                }

                Section {
                    Toggle(isOn: $useAlbums) {
                        Text("存到照片時依小朋友分相簿")
                    }
                } header: {
                    Text("照片")
                } footer: {
                    Text("需要「完整照片取用權限」才能建立「冰箱美術館 – 小明」這樣的相簿；只允許加入照片時，會存到「最近項目」。")
                }

                backupSection

                Section {
                    LabeledContent {
                        Text(verbatim: AppLanguage.isChinese ? "繁體中文" : "English")
                    } label: {
                        Text("語言")
                    }
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Text("在「設定」中更改語言")
                    }
                } header: {
                    Text("語言")
                } footer: {
                    Text("App 支援繁體中文和英文，預設跟隨 iPhone 的語言。")
                }

                Section {
                    OnboardingSettingsRow()
                    Link(destination: Self.privacyURL) { linkRow("隱私權政策", systemImage: "hand.raised") }
                    Link(destination: Self.supportURL) { linkRow("支援與意見回饋", systemImage: "questionmark.bubble") }
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("授權條款", systemImage: "doc.text")
                    }
                    LabeledContent {
                        Text(verbatim: "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))").monospacedDigit()
                    } label: {
                        Text("版本")
                    }
                } header: {
                    Text("關於")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("所有照片都只在這支手機上處理，不會上傳；App 不蒐集任何個人資料。")
                        Text(verbatim: Bundle.main.copyright)
                    }
                    .padding(.top, 4)
                }
            }
            .font(.fm(16))
            .tint(Palette.teal)
            .scrollContentBackground(.hidden)
            .background(Wallpaper())
            .navigationTitle(Text("設定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("完成").font(.fm(17, bold: true)) }
                }
            }
            .sheet(item: $editingChild) { ChildEditorView(child: $0) }
            .sheet(isPresented: $showNewChild) { ChildEditorView(child: nil) }
            .overlay(alignment: .topLeading) { if DemoMode.scene("settings") { ReadyMarker() } }
        }
    }

    /// 備份到照片: how many museum artworks are already in Photos, and 全部存到照片 for the rest.
    private var backupSection: some View {
        let total = museum.count
        let saved = museum.filter { $0.lastSavedToPhotosAt != nil }.count
        return Section {
            LabeledContent {
                if let progress = app.saveAllProgress {
                    Text("正在存到照片… \(progress.done)／\(progress.total)").monospacedDigit()
                }
            } label: {
                Text("已存到照片 \(saved)／\(total) 件").monospacedDigit()
            }
            if total > 0 && saved >= total {
                Label {
                    Text("全部都存到照片了")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                }
            } else if total > 0 {
                Button {
                    // The album explanation, Photos alerts and the paywall live on the root view: close Settings first.
                    let app = self.app, context = modelContext
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        await app.backUpAll(context: context)
                    }
                } label: {
                    Label("全部存到照片", systemImage: "square.and.arrow.down")
                }
                .disabled(app.saveAllProgress != nil)
            }
        } header: {
            Text("備份到照片")
        } footer: {
            Text("作品只存在這支手機裡。存到照片，手機換了也不怕。")
        }
    }

    private var quotaSummary: String {
        let flat = app.store.remaining(.flat), craft = app.store.remaining(.craft)
        return String(localized: "今天還可收 \(flat) 張畫作 · 勞作試用剩 \(craft) 次")
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image("bibi-wave").resizable().scaledToFit().frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: 4) {
                Text("冰箱美術館").font(.fmDisplay(26)).foregroundStyle(Palette.title)
                Text(verbatim: "\(String(localized: "版本")) \(Bundle.main.shortVersion)")
                    .font(.fm(14, bold: true)).foregroundStyle(Palette.muted)
                Text("把孩子的作品掛上冰箱").font(.fm(14)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func linkRow(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.faint)
        }
    }
}

/// Third-party notices: the two bundled fonts (SIL OFL 1.1). Everything else is Apple system frameworks.
struct LicensesView: View {
    struct Notice: Identifiable {
        let id: String
        let name: String
        let file: String
        let link: String
    }

    static let notices = [
        Notice(id: "huninn", name: "Huninn（粉圓體）", file: "OFL-Huninn", link: "https://github.com/justfont/Huninn"),
        Notice(id: "chiron", name: "Chiron GoRound TC（昭源甜圓）", file: "OFL-ChironGoRoundTC",
               link: "https://github.com/chiron-fonts/chiron-go-round-tc"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.notices) { n in
                    NavigationLink {
                        ScrollView {
                            Text(verbatim: Self.text(n.file))
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                        }
                        .navigationTitle(Text(verbatim: n.name))
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: n.name).font(.fm(16, bold: true))
                            Text("SIL Open Font License 1.1").font(.fm(13)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            } header: {
                Text("字型")
            } footer: {
                Text("App 內附的字型為了縮小檔案只保留常用字，依 OFL 授權修改與散布。")
            }
            Section {
                Text("App 內購（StoreKit）、相機、照片、Vision 與語音辨識都是 Apple 的系統功能，沒有使用第三方程式庫。")
                    .font(.fm(14.5))
            } header: {
                Text("其他")
            }
        }
        .font(.fm(16))
        .scrollContentBackground(.hidden)
        .background(Wallpaper())
        .navigationTitle(Text("授權條款"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static func text(_ file: String) -> String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "SIL Open Font License 1.1 — https://openfontlicense.org" }
        return s
    }
}
