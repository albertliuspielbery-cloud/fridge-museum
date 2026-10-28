import SwiftData
import SwiftUI
import UIKit

/// Full-screen camera (opened from the counter shutter). Live paper outline for drawings; one shot → editor.
/// 連拍 (burst): each shot becomes a pending capture without opening the editor; 完成 goes home, where the sticky
/// note lists them (繼續 steps through them one by one).
struct CameraScreen: View {
    let onCaptured: (UUID) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Child.createdAt) private var children: [Child]

    @State private var camera = CameraModel()
    @State private var flash = false
    /// 連拍 on.
    @State private var burst = false
    /// This visit's burst shots (newest last): id + a small thumbnail for the stack beside the shutter.
    @State private var burstShots: [BurstShot] = []
    /// Short pause after a burst shot so one tap can't take two photos.
    @State private var cooldown = false

    struct BurstShot: Identifiable {
        let id: UUID
        let image: UIImage?
    }

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
        .onDisappear {
            camera.stop()
            // Closed mid-burst (✕ or 完成): the shots stay on the sticky note; their exports may run now.
            app.endBurst(context: modelContext)
        }
        .onChange(of: app.captureKind) { _, kind in
            camera.setDetectionEnabled(kind == .flat)
            app.persistPreferences()
        }
        .onChange(of: burst) { _, on in
            if on {
                app.beginBurst()
            } else {
                app.endBurst(context: modelContext)
            }
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
        return VStack(spacing: 10) {
            if burst {
                burstHint
            } else {
                hintBubble(text)
            }
            burstToggle
        }
        .padding(.bottom, 14)
        .opacity(camera.state == .running ? 1 : 0)
    }

    private var burstHint: some View {
        let n = burstShots.count
        return hintBubble(n == 0 ? "連拍：一張拍完換下一張，最後按「完成」" as LocalizedStringKey : "已拍 \(n) 張，換下一張")
    }

    private func hintBubble(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image("bibi-head").resizable().scaledToFit().frame(width: 26, height: 20)
                .accessibilityHidden(true)
            Text(text).font(.fm(15, bold: true))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.black.opacity(0.5)))
        .padding(.horizontal, 16)
    }

    /// 連拍 chip above the shutter.
    private var burstToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { burst.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.down.right")
                    .font(.system(size: 14, weight: .bold))
                    .accessibilityHidden(true)
                Text("連拍")
                    .font(.fm(15, bold: true, relativeTo: .subheadline))
                    .lineLimit(1)
                if burst {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(burst ? Palette.cardInk : Color.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 38)
            .background(Capsule().fill(burst ? Palette.yellow : Color.black.opacity(0.5)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(burst ? 0 : 0.6), lineWidth: 1.5))
            .contentShape(Capsule())
            .environment(\.colorScheme, .light)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("連拍"))
        .accessibilityValue(burst ? Text("開") : Text("關"))
        .accessibilityHint(Text("連續拍很多張，回到廚房再一張張整理"))
        .accessibilityAddTraits(burst ? .isSelected : [])
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
            // Who this shot is for (each new capture goes to this child; change it here between shots).
            CaptureChildMenu(style: .camera)
            Spacer()
            ShutterButton(action: shoot)
                .disabled(camera.state != .running || camera.isCapturing || cooldown)
                .environment(\.colorScheme, .light)
            Spacer()
            burstTray
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
    }

    /// 連拍: the last few shots as a little stack with the count, and 完成.
    @ViewBuilder
    private var burstTray: some View {
        if burstShots.isEmpty {
            Color.clear.frame(width: 72, height: 58)
        } else {
            Button(action: finishBurst) {
                VStack(spacing: 6) {
                    burstStack
                        .frame(width: 52, height: 52)
                        .overlay(alignment: .topTrailing) {
                            Text(verbatim: "\(burstShots.count)")
                                .font(.fm(12, bold: true))
                                .foregroundStyle(Palette.cardInk)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(Capsule().fill(Palette.yellow))
                                .offset(x: 10, y: -8)
                        }
                    Text("完成")
                        .font(.fm(14, bold: true))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Palette.cardInk)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 28)
                        .background(Capsule().fill(Palette.yellow))
                }
                .frame(width: 72)
                .contentShape(Rectangle())
                .environment(\.colorScheme, .light)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("完成，已拍 \(burstShots.count) 張"))
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Up to three of the newest shots, fanned out (newest on top, straight).
    private var burstStack: some View {
        let recent = Array(burstShots.suffix(3))
        return ZStack {
            ForEach(Array(recent.enumerated()), id: \.element.id) { index, shot in
                burstThumb(shot)
                    .rotationEffect(.degrees(Double(index - recent.count + 1) * 7))
            }
        }
    }

    private func burstThumb(_ shot: BurstShot) -> some View {
        Group {
            if let image = shot.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.8)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }

    private func shoot() {
        guard !cooldown else { return }
        let isBurst = burst
        // Burst: hold the shutter for a moment so one tap (or a bounce) can't take two photos.
        if isBurst { cooldown = true }
        Task {
            flash = true
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeOut(duration: 0.25)) { flash = false }
        }
        Task {
            if let data = await camera.capture() {
                if isBurst {
                    await addBurstShot(data)
                } else {
                    let a = app.ingest(data, kind: app.captureKind, child: currentChild, capturedAt: Date(), context: modelContext,
                                       opensEditor: true)
                    onCaptured(a.id)
                }
            } else {
                app.show(String(localized: "拍照失敗，再試一次"), style: .problem)
            }
            if isBurst {
                try? await Task.sleep(for: .milliseconds(500))
                cooldown = false
            }
        }
    }

    /// A burst shot: a pending capture for the current child, no editor. Its paper corners are found in the
    /// background now; the export waits until the burst ends (AppModel.beginBurst) and then runs one at a time.
    private func addBurstShot(_ data: Data) async {
        let a = app.ingest(data, kind: app.captureKind, child: currentChild, capturedAt: Date(), context: modelContext)
        let thumbData = await Task.detached(priority: .userInitiated) {
            ImageMetadata.uprightThumbnail(of: data, maxPixelSize: 160).flatMap { ImageEncoding.jpegData($0, quality: 0.7) }
        }.value
        let shot = BurstShot(id: a.id, image: thumbData.flatMap { UIImage(data: $0) })
        withAnimation(.spring(duration: 0.3)) { burstShots.append(shot) }
    }

    /// 完成: back to the kitchen; the sticky note lists the shots (繼續 / 全部收進 / 全部不要).
    private func finishBurst() {
        let n = burstShots.count
        app.endBurst(context: modelContext)
        if n > 0 {
            app.show(String(localized: "拍好 \(n) 張了，在便利貼上一張張整理。"), seconds: 4)
        }
        dismiss()
    }
}
