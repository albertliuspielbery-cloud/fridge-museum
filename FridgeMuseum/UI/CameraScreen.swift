import SwiftData
import SwiftUI
import UIKit

/// Full-screen camera (opened from the counter shutter). Live paper outline for drawings; one shot → editor.
struct CameraScreen: View {
    let onCaptured: (UUID) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Child.createdAt) private var children: [Child]

    @State private var camera = CameraModel()
    @State private var flash = false

    private var currentChild: Child? { children.first { $0.id == app.currentChildID } }

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
                bottomBar
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .task {
            await camera.start()
            // Closed before the session finished starting: don't leave the camera running behind the editor.
            if Task.isCancelled {
                camera.stop()
                return
            }
            camera.setDetectionEnabled(app.captureKind == .flat)
        }
        .onDisappear { camera.stop() }
        .onChange(of: app.captureKind) { _, kind in
            camera.setDetectionEnabled(kind == .flat)
            app.persistPreferences()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.shutterCount)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .accessibilityLabel(Text("關閉"))
            Spacer()
            KindSwitch(kind: Bindable(app).captureKind, long: false, compact: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var hint: some View {
        let text: LocalizedStringKey
        switch (app.captureKind, camera.paperFound) {
        case (.flat, true): text = "找到紙張了，按下快門"
        case (.flat, false): text = "把整張畫放進畫面，四個角都要拍到"
        case (.craft, _): text = "把勞作放在桌上，拍清楚一點"
        }
        return HStack(spacing: 8) {
            Image("bibi-head").resizable().scaledToFit().frame(width: 26, height: 20)
            Text(text).font(.fm(15, bold: true))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.black.opacity(0.5)))
        .padding(.bottom, 14)
        .opacity(camera.state == .running ? 1 : 0)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.state {
        case .denied:
            VStack(spacing: 14) {
                Image("bibi-oops").resizable().scaledToFit().frame(height: 120)
                Text("需要相機權限才能拍作品").font(.fm(18, bold: true))
                Button("打開設定") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(PrimaryCapsuleStyle())
                .frame(width: 220)
                Text("也可以回到廚房，按「相簿」從照片挑選").font(.fm(14))
            }
            .foregroundStyle(.white)
            .padding()
        case .unavailable:
            VStack(spacing: 14) {
                Image("bibi-think").resizable().scaledToFit().frame(height: 120)
                Text("這台裝置不能使用相機\n可以回到廚房，按「相簿」從照片挑選")
                    .font(.fm(16))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding()
        default:
            EmptyView()
        }
    }

    private var bottomBar: some View {
        HStack {
            Color.clear.frame(width: 58, height: 58)
            Spacer()
            ShutterButton(action: shoot)
                .disabled(camera.state != .running || camera.isCapturing)
                .environment(\.colorScheme, .light)
            Spacer()
            Color.clear.frame(width: 58, height: 58)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
    }

    private func shoot() {
        Task {
            flash = true
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeOut(duration: 0.25)) { flash = false }
        }
        Task {
            if let data = await camera.capture() {
                let a = app.ingest(data, kind: app.captureKind, child: currentChild, capturedAt: Date(), context: modelContext,
                                   opensEditor: true)
                onCaptured(a.id)
            } else {
                app.show(String(localized: "拍照失敗，再試一次"), style: .problem)
            }
        }
    }
}
