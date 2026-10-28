import PhotosUI
import SwiftData
import SwiftUI

/// Home = the kitchen: a fridge door with Bibi on the freezer (speech bubble = today's quota), this visit's works
/// taped to the main door with crayon placards, and the counter dock (mode switch, shutter, Photos, museum).
struct HomeView: View {
    let open: (Route) -> Void
    let showSettings: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Artwork.createdAt, order: .reverse) private var artworks: [Artwork]

    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var openAfterCamera: UUID?

    private var museum: [Artwork] {
        artworks.filter(\.isInMuseum).sorted { ($0.keptAt ?? $0.createdAt) > ($1.keptAt ?? $1.createdAt) }
    }

    private var pending: [Artwork] { artworks.filter { !$0.isKept && !$0.isSample } }

    private var session: [Artwork] {
        app.sessionArtworkIDs.reversed().compactMap { id in artworks.first { $0.id == id && $0.isKept } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Fridge {
                    freezer
                } main: {
                    mainDoor
                }
                .padding(.horizontal, Metrics.gutter)
            }
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Wallpaper())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CounterDock(
                kind: Bindable(app).captureKind,
                museumThumb: museum.first,
                museumCount: museum.count,
                sessionCount: session.count,
                onPhotos: { showPhotoPicker = true },
                onShutter: { showCamera = true },
                onMuseum: { open(.museum) }
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: app.captureKind) { app.persistPreferences() }
        .onChange(of: app.cameraRequest) { showCamera = true }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importItems(items) }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if let id = openAfterCamera {
                openAfterCamera = nil
                open(.edit(id))
            }
        }) {
            CameraScreen { id in
                openAfterCamera = id
                showCamera = false
            }
        }
        .overlay(alignment: .topLeading) {
            if demoReady { ReadyMarker() }
        }
    }

    private var demoReady: Bool {
        if DemoMode.scene("home-empty") { return true }
        if DemoMode.scene("success") { return app.toast != nil && museum.allSatisfy { $0.thumbnailData != nil } && museum.count >= 6 }
        if DemoMode.scene("home-full", "pending") { return museum.count >= 6 && museum.allSatisfy { $0.thumbnailData != nil } }
        return false
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("冰箱美術館")
                    .font(.fmDisplay(38, relativeTo: .largeTitle))
                    .foregroundStyle(Palette.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                Label {
                    Text("照片只在這支手機上處理，不會上傳")
                } icon: {
                    Image(systemName: "lock")
                }
                .font(.fm(13.5, relativeTo: .footnote))
                .foregroundStyle(Palette.muted)
                .labelStyle(TightLabelStyle())
            }
            .padding(.top, 10)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 10) {
                Image("kitchen-window").resizable().scaledToFit().frame(width: 92).accessibilityHidden(true)
                Button(action: showSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text("設定")
                    }
                    .font(.fm(15, bold: true))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Capsule().fill(Palette.surface))
                    .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.gutter + 4)
    }

    // MARK: Freezer — Bibi + quota bubble

    private var bibiFace: String {
        if app.toast?.isCelebration == true { return "bibi-face-joy" }
        if app.store.isOut(app.captureKind) { return "bibi-face-hope" }
        return "bibi-face-smile"
    }

    private var freezer: some View {
        HStack(spacing: 6) {
            Image(bibiFace)
                .resizable()
                .scaledToFit()
                .frame(width: 128)
                .padding(.leading, 22)
                .accessibilityHidden(true)
                .animation(.easeInOut(duration: 0.2), value: bibiFace)
            Spacer(minLength: 0)
            Text(verbatim: app.store.bubbleText(for: app.captureKind))
                .font(.fm(16.5, bold: true, relativeTo: .callout))
                .foregroundStyle(Palette.bubbleInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
                .padding(.trailing, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 190, alignment: .leading)
                .background(SpeechBubble().fill(Palette.bubble).shadow(color: Palette.shadow, radius: 4, y: 3))
                .padding(.trailing, 44)
                .accessibilityLabel(Text(verbatim: app.store.bubbleText(for: app.captureKind)))
        }
        .padding(.vertical, 30)
    }

    // MARK: Main door

    private var mainDoor: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let p = pending.first {
                PendingCard(artwork: p, extra: pending.count - 1) { open(.edit(p.id)) }
            }
            if !session.isEmpty {
                workWall(title: String(localized: "這次收的作品"), items: Array(session.prefix(6)), count: session.count)
            } else if !museum.isEmpty {
                workWall(title: String(localized: "最近掛上的"), items: Array(museum.prefix(4)), count: nil)
            } else {
                emptyFridge
            }
            if !museum.isEmpty {
                Button { open(.museum) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "building.columns")
                        Text("到美術館看全部 \(museum.count) 件")
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                    }
                }
                .buttonStyle(SecondaryCapsuleStyle())
            }
            TipsCard()
            Button(action: showSettings) {
                HStack(spacing: 8) {
                    Image("bibi-head").resizable().scaledToFit().frame(width: 30, height: 22)
                    Text("冰箱美術館").font(.fm(14))
                    Text(verbatim: Bundle.main.shortVersion).font(.fm(14, bold: true))
                }
                .foregroundStyle(Palette.cardInk)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.cardLine, lineWidth: 2))
                .shadow(color: Palette.shadow, radius: 2, y: 2)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("版本資訊"))
        }
        .padding(.leading, 26)
        .padding(.trailing, 40)
        .padding(.vertical, 28)
    }

    private func workWall(title: String, items: [Artwork], count: Int?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            CrayonHeader(title: title, count: count)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], alignment: .leading, spacing: 26) {
                ForEach(items) { a in
                    Button { open(.detail(a.id)) } label: {
                        FridgeWork(artwork: a, processing: app.processingIDs.contains(a.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyFridge: some View {
        VStack(spacing: 14) {
            Image(colorScheme == .dark ? "bibi-sleep" : "bibi-empty")
                .resizable().scaledToFit().frame(height: 150)
                .accessibilityHidden(true)
            Text("冰箱還空空的，拍第一張作品掛上來吧")
                .font(.fmDisplay(19, relativeTo: .headline))
                .foregroundStyle(Palette.doorInk)
                .multilineTextAlignment(.center)
            Text("按下方快門拍一張。整理好按「收進這次」，作品就會掛在這裡。")
                .font(.fm(14.5))
                .foregroundStyle(Palette.doorMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                SampleTile(kind: .flat) { openSample(.flat) }
                SampleTile(kind: .craft) { openSample(.craft) }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    // MARK: Actions

    private func openSample(_ kind: ArtworkKind) {
        if let a = app.openSample(kind, context: modelContext) { open(.edit(a.id)) }
    }

    private func importItems(_ items: [PhotosPickerItem]) async {
        pickerItems = []
        var first: UUID?
        var failed = 0
        let child = app.currentChildID.flatMap { id in try? modelContext.fetch(FetchDescriptor<Child>(predicate: #Predicate { $0.id == id })).first }
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), UIImage(data: data) != nil {
                let date = ImageMetadata.captureDate(of: data) ?? Date()
                let a = app.ingest(data, kind: app.captureKind, child: child, capturedAt: date, context: modelContext)
                if first == nil { first = a.id }
            } else {
                failed += 1
            }
        }
        if failed > 0 { app.show(String(localized: "這張照片打不開，請換一張再試一次。"), style: .problem) }
        if let first { open(.edit(first)) }
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

extension Bundle {
    var shortVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0" }
    var buildNumber: String { (infoDictionary?["CFBundleVersion"] as? String) ?? "1" }
    /// NSHumanReadableCopyright (single source: APP_COPYRIGHT in project.yml).
    var copyright: String { (infoDictionary?["NSHumanReadableCopyright"] as? String) ?? "© 星光工作室 Starlight Studio" }
}

/// A finished work on the fridge door: taped print + compact crayon placard.
struct FridgeWork: View {
    let artwork: Artwork
    var processing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HungPrint(id: artwork.id, tilt: 2.5) {
                ArtworkImage(artwork: artwork)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(artwork.aspectRatio, contentMode: .fit)
            }
            .overlay(alignment: .bottomTrailing) {
                if processing { ProgressView().padding(10) }
            }
            Placard(artwork: artwork, compact: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Thumbnail (or rendered image) of an artwork, filling its frame.
struct ArtworkImage: View {
    let artwork: Artwork

    var body: some View {
        if let img = ThumbnailCache.shared.image(for: artwork) {
            Image(uiImage: img).resizable().scaledToFit()
        } else if artwork.processingState == .failed {
            Image("bibi-oops").resizable().scaledToFit().padding(20).background(Palette.surface2)
        } else {
            Rectangle().fill(Palette.surface2).overlay(ProgressView())
        }
    }
}

extension Artwork {
    /// Width / height of the finished image (for layout before the thumbnail decodes).
    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 0.75 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }
}

/// 上一張還沒收進 — a sticky note with tape, so a captured-but-not-kept artwork is never forgotten.
struct PendingCard: View {
    let artwork: Artwork
    var extra: Int = 0
    let resume: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ArtworkImage(artwork: artwork)
                .frame(width: 64, height: 76)
                .clipped()
                .padding(4)
                .background(Palette.print)
                .rotationEffect(.degrees(-4))
                .shadow(color: Palette.printShadow.opacity(0.6), radius: 3, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(extra > 0 ? "還有 \(extra + 1) 張還沒收進" as LocalizedStringKey : "上一張還沒收進")
                    .font(.fm(17, bold: true))
                    .foregroundStyle(Palette.noteInk)
                Text("存到手機或收進這次，才不會不見")
                    .font(.fm(14))
                    .foregroundStyle(Palette.noteInk.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: resume) {
                    Text("繼續")
                        .font(.fm(15, bold: true))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 20)
                        .frame(height: 38)
                        .background(Capsule().fill(Color(0x2B2E4A, 0x1E2340)))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Rectangle().fill(Palette.note).shadow(color: Palette.printShadow.opacity(0.5), radius: 6, y: 4))
        .rotationEffect(.degrees(-0.8))
        .overlay(alignment: .topTrailing) { Tape(style: .check, width: 96, angle: 4).offset(x: -24, y: -10) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("還沒收進的作品"))
    }
}

/// 看範例畫作 / 看範例勞作 — a cream tile with a face magnet.
struct SampleTile: View {
    let kind: ArtworkKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: kind.longTitle).font(.fmDisplay(17, relativeTo: .headline)).foregroundStyle(Palette.cardInk)
                Text(kind == .flat ? "找出紙張四角，拉正、修平光線" as LocalizedStringKey : "AI 去掉桌面，換上乾淨背景和陰影")
                    .font(.fm(12.5)).foregroundStyle(Palette.cardMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                HStack(spacing: 4) {
                    Text(kind == .flat ? "看範例畫作" as LocalizedStringKey : "看範例勞作")
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                }
                .font(.fm(13.5, bold: true))
                .foregroundStyle(Palette.color(for: kind))
                .environment(\.colorScheme, .light)
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(12)
            .padding(.top, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.cardLine, lineWidth: 2))
            .shadow(color: Palette.shadow, radius: 4, y: 3)
            .overlay(alignment: .topTrailing) {
                Image(kind == .flat ? "mag-cloud" : "mag-berry").resizable().scaledToFit().frame(width: 36)
                    .offset(x: 6, y: -16)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 拍照小技巧 — a taped cream card that unfolds.
struct TipsCard: View {
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.3)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "lightbulb").foregroundStyle(Palette.teal)
                    Text("拍照小技巧").font(.fm(16, bold: true)).foregroundStyle(Palette.cardInk)
                    Spacer()
                    Image(systemName: expanded ? "minus" : "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.green)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    tip("拍畫作時盡量讓整張紙入鏡，四周留一點桌面。")
                    tip("拍勞作時放在素色桌面上，四周留空。")
                    tip("光線均勻最好；不用開閃光燈，App 會幫你修平光線。")
                    tip("所有處理都在這支手機上完成，不會上傳。")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.cardLine, lineWidth: 2))
        .shadow(color: Palette.shadow, radius: 3, y: 2)
        .overlay(alignment: .topLeading) { Tape(style: .mint, width: 74, angle: -6).offset(x: 24, y: -10) }
        .environment(\.colorScheme, .light)
    }

    private func tip(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Palette.teal).frame(width: 6, height: 6)
            Text(key).font(.fm(14)).foregroundStyle(Palette.cardMuted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Counter dock

/// The kitchen counter: a wooden edge (cat + crayon cup), the 平面畫作 / 立體勞作 switch, the big shutter,
/// Photos on the left and the museum on the right.
struct CounterDock: View {
    @Binding var kind: ArtworkKind
    var museumThumb: Artwork?
    var museumCount: Int
    var sessionCount: Int
    let onPhotos: () -> Void
    let onShutter: () -> Void
    let onMuseum: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(Palette.wood).frame(height: 9)
                Rectangle().fill(Palette.woodDeep).frame(height: 3)
            }
            .overlay(alignment: .bottomLeading) {
                Image("cat-peek").resizable().scaledToFit().frame(width: 70).offset(x: 26, y: -10).accessibilityHidden(true)
            }
            .overlay(alignment: .bottomTrailing) {
                Image("prop-crayons").resizable().scaledToFit().frame(width: 30).offset(x: -30, y: -10).accessibilityHidden(true)
            }
            VStack(spacing: 10) {
                KindSwitch(kind: $kind)
                HStack(alignment: .center) {
                    SideButton(title: String(localized: "相簿"), action: onPhotos) {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 21, weight: .semibold))
                    }
                    Spacer()
                    ShutterButton(highlight: sessionCount > 0, action: onShutter)
                    Spacer()
                    SideButton(title: String(localized: "美術館"), action: onMuseum) {
                        if let museumThumb, let img = ThumbnailCache.shared.image(for: museumThumb) {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Image(systemName: "building.columns").font(.system(size: 21, weight: .semibold))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if museumCount > 0 {
                            Text(verbatim: "\(museumCount)")
                                .font(.fm(12, bold: true))
                                .foregroundStyle(Palette.cardInk)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(Circle().fill(Palette.yellow))
                                .offset(x: 6, y: -6)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .background(Palette.counter.ignoresSafeArea(edges: .bottom))
        }
    }
}

struct SideButton<Icon: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder var icon: Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                icon
                    .foregroundStyle(Palette.ink)
                    .frame(width: 58, height: 58)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.dockRaise))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Palette.shadow, radius: 3, y: 2)
                Text(verbatim: title).font(.fm(13, bold: true)).foregroundStyle(Palette.muted)
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
    }
}

struct ShutterButton: View {
    var highlight = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Palette.dockRaise).frame(width: 92, height: 92)
                    .shadow(color: Palette.shadow, radius: 5, y: 3)
                if highlight {
                    Circle().strokeBorder(Palette.yellow, lineWidth: 4).frame(width: 92, height: 92)
                }
                Circle().fill(Palette.primaryDeep).frame(width: 74, height: 74).offset(y: 3)
                Circle().fill(Palette.primary).frame(width: 74, height: 74)
                Image(systemName: "camera.fill").font(.system(size: 27, weight: .semibold)).foregroundStyle(Palette.primaryInk)
            }
        }
        .buttonStyle(ShutterPressStyle())
        .accessibilityLabel(Text("拍一張作品"))
    }
}

struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
