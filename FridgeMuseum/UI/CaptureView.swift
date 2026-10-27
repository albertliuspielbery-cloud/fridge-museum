import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Home screen = the camera (like the prototype's camera dock): pick 平面畫作 / 立體勞作, shoot in batches,
/// import from the photo library, open 這次 (this batch) or the museum.
struct CaptureView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \Child.createdAt) private var children: [Child]
    @Query(sort: \Artwork.createdAt, order: .reverse) private var allArtworks: [Artwork]

    @State private var camera = CameraModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showSession = false
    @State private var showNewChild = false
    @State private var showPhotoPicker = false
    @State private var flash = false

    let openGallery: () -> Void
    let openArtwork: (UUID) -> Void

    private var currentChild: Child? { children.first { $0.id == app.currentChildID } }

    private var sessionArtworks: [Artwork] {
        let ids = app.sessionArtworkIDs
        return ids.compactMap { id in allArtworks.first { $0.id == id } }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(model: camera, quad: camera.liveQuad)
                .ignoresSafeArea()
            statusOverlay
            if flash {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                hint
                dock
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await camera.start()
            camera.setDetectionEnabled(app.captureKind == .flat)
        }
        .onDisappear { camera.stop() }
        .onChange(of: app.captureKind) { _, kind in
            camera.setDetectionEnabled(kind == .flat)
            app.persistPreferences()
        }
        .onChange(of: app.currentChildID) { app.persistPreferences() }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importItems(items) }
        }
        .sheet(isPresented: $showSession) {
            SessionSheet(artworks: sessionArtworks) { id in
                showSession = false
                openArtwork(id)
            }
        }
        .sheet(isPresented: $showNewChild) {
            ChildEditorView(child: nil) { created in app.currentChildID = created.id }
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            Button(action: openGallery) {
                Label("美術館", systemImage: "building.columns")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            Menu {
                Picker("小朋友", selection: Bindable(app).currentChildID) {
                    Text("未分類").tag(UUID?.none)
                    ForEach(children) { c in
                        Text(c.displayName).tag(Optional(c.id))
                    }
                }
                Button("新增小朋友…", systemImage: "plus") { showNewChild = true }
            } label: {
                HStack(spacing: 6) {
                    if let c = currentChild {
                        AvatarDot(hex: c.avatarColorHex, name: c.displayName, size: 22)
                    } else {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    Text(currentChild?.displayName ?? "選小朋友")
                        .font(.headline)
                    Image(systemName: "chevron.down").font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var hint: some View {
        let text: String
        switch (app.captureKind, camera.paperFound) {
        case (.flat, true): text = "找到紙張了，按下快門"
        case (.flat, false): text = "把整張畫放進畫面，四個角都要拍到"
        case (.craft, _): text = "把勞作放在桌上，拍清楚一點"
        }
        return Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.45)))
            .padding(.bottom, 12)
            .opacity(camera.state == .running ? 1 : 0)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.state {
        case .denied:
            VStack(spacing: 12) {
                Text("需要相機權限才能拍作品").font(.headline)
                Button("打開設定") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                Text("也可以按下方「相簿」從照片挑選").font(.footnote)
            }
            .foregroundStyle(.white)
            .padding()
        case .unavailable:
            Text("這台裝置不能使用相機\n可以按下方「相簿」從照片挑選")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding()
        default:
            EmptyView()
        }
    }

    private var dock: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(ArtworkKind.allCases) { kind in
                    let selected = app.captureKind == kind
                    Button {
                        app.captureKind = kind
                    } label: {
                        Text(kind.longLabel)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(Capsule().fill(selected ? Palette.color(for: kind) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(.thinMaterial))

            HStack {
                // Button + .photosPicker modifier (not the PhotosPicker view): its label closure is
                // nonisolated in the iOS 26 SDK, which can't call this main-actor view's helpers.
                Button { showPhotoPicker = true } label: {
                    sideLabel("相簿") { Image(systemName: "photo.on.rectangle").font(.title3) }
                }
                Spacer()
                Button(action: shoot) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                        Circle().fill(Palette.color(for: app.captureKind)).frame(width: 64, height: 64)
                        Image(systemName: "camera.fill").font(.title2).foregroundStyle(.white)
                    }
                }
                .disabled(camera.state != .running || camera.isCapturing)
                .accessibilityLabel("拍一張作品")
                Spacer()
                Button { showSession = true } label: {
                    sideLabel("這次") {
                        if let last = sessionArtworks.last {
                            ArtworkThumb(artwork: last, processing: app.processingIDs.contains(last.id))
                                .overlay(alignment: .topTrailing) {
                                    Text("\(sessionArtworks.count)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(Circle().fill(Palette.coral))
                                        .offset(x: 6, y: -6)
                                }
                        } else {
                            Image(systemName: "square.stack").font(.title3)
                        }
                    }
                }
                .disabled(sessionArtworks.isEmpty)
                .opacity(sessionArtworks.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 30, matching: .images)
    }

    private func sideLabel<Icon: View>(_ title: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 4) {
            icon()
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
            Text(title).font(.caption)
        }
        .foregroundStyle(.primary)
    }

    // MARK: Actions

    private func shoot() {
        Task {
            flash = true
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeOut(duration: 0.25)) { flash = false }
        }
        Task {
            if let data = await camera.capture() {
                app.ingest(data, kind: app.captureKind, child: currentChild, capturedAt: Date(), context: modelContext)
            } else {
                app.show("拍照失敗，再試一次")
            }
        }
    }

    private func importItems(_ items: [PhotosPickerItem]) async {
        pickerItems = []
        var count = 0
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let date = ImageMetadata.captureDate(of: data) ?? Date()
                app.ingest(data, kind: app.captureKind, child: currentChild, capturedAt: date, context: modelContext)
                count += 1
            }
        }
        if count > 0 { showSession = true }
    }
}
