import SwiftData
import SwiftUI
import UIKit

enum EditTool: String, CaseIterable, Identifiable {
    case crop, adjust, brush, label

    var id: String { rawValue }
    var title: String {
        switch self {
        case .crop: String(localized: "裁切")
        case .adjust: String(localized: "調整")
        case .brush: String(localized: "筆刷")
        case .label: String(localized: "說明牌")
        }
    }
    var panelTitle: String {
        switch self {
        case .crop: String(localized: "裁切四角")
        case .adjust: String(localized: "調整")
        case .brush: String(localized: "筆刷")
        case .label: String(localized: "作品說明牌")
        }
    }
    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .adjust: "slider.horizontal.3"
        case .brush: "paintbrush.pointed"
        case .label: "text.below.photo"
        }
    }
}

/// The studio: the artwork on a mint stage, compare slider, tools (裁切 / 調整 / 筆刷 / 說明牌) and
/// 收進這次 / 存到手機. The quota is only checked when keeping or saving — never mid-edit.
struct EditView: View {
    @Bindable var artwork: Artwork
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: EditModel
    @State private var tool: EditTool?
    @State private var showLabel = false
    @State private var brushMode: BrushStroke.Mode = .erase
    @State private var brushSize: Double = 3
    @State private var compare = false
    @State private var split: CGFloat = 0.5
    /// The stroke being drawn, in artwork-normalized points (so zoom / pan never moves it).
    @State private var liveStroke: [CGPoint] = []
    /// Its radius (fraction of the output's long edge), fixed when the stroke starts: slider size ÷ zoom.
    @State private var liveStrokeRadius: Double = 0
    /// Output mapping when the live stroke began (its points are in that picture's coordinates).
    @State private var liveStrokeMapping: OutputMapping?
    /// 筆刷 / 對比: two-finger pinch & pan, double tap (view only — strokes stay in artwork space).
    @State private var stageZoom = StageZoom()
    @State private var pinchStart: PinchStart?
    /// Ring showing the brush size for a moment after the slider moves.
    @State private var showsSizePreview = false
    @State private var sizePreviewToken = 0
    /// 「兩指可以放大、移動」 rides on the brush hint the first time the brush is opened.
    @State private var showsZoomHint = false
    @AppStorage("brushZoomHintShown") private var brushZoomHintShown = false
    @State private var isSaving = false
    @State private var kindSelection: ArtworkKind
    @State private var activeCorner: Int?
    /// After 向左轉 / 向右轉 / 拉直 the crop tool shows the turned result; tapping 裁切 again returns to the corners.
    @State private var cropShowsResult = false
    @State private var pickingParts = false
    /// 重拍 / 不要這張: the capture is thrown away only after the editor is gone, so nothing renders a deleted model.
    @State private var discardOnDisappear = false
    /// 重拍 reopens the camera after discarding; 不要這張 just goes back.
    @State private var retakeAfterDiscard = false
    @State private var confirmDiscard = false
    /// Closed by 收進這次 / 存到手機 / 不要這張: when stepping through pending captures (繼續), the next one opens.
    @State private var advancesPendingWalk = false
    /// 這張好像收過了: a kept artwork that looks like this capture (checked when the preview is ready, once per kind).
    @State private var duplicate: Artwork?
    @State private var duplicateCheckedKind: ArtworkKind?
    @State private var peekDuplicate = false
    /// 不要這張 tapped in the peek sheet: ask (the usual discard dialog) once the sheet is gone.
    @State private var discardAfterPeek = false

    init(artwork: Artwork) {
        _artwork = Bindable(artwork)
        _model = State(initialValue: EditModel(artwork: artwork))
        _kindSelection = State(initialValue: artwork.kind)
    }

    private var tools: [EditTool] {
        model.recipe.kind == .flat ? EditTool.allCases : [.adjust, .brush, .label]
    }

    var body: some View {
        VStack(spacing: 10) {
            stage
                .frame(maxWidth: .infinity, minHeight: 190, maxHeight: .infinity)
                .padding(.horizontal, Metrics.gutter)
                .padding(.trailing, 8)
            if let duplicate, showsDuplicateNotice {
                DuplicateNotice(existing: duplicate, onPeek: { peekDuplicate = true }, onDiscard: { confirmDiscard = true })
                    .padding(.horizontal, Metrics.gutter)
                    .transition(.opacity)
            } else {
                BibiHint(text: hintText)
                    .padding(.horizontal, Metrics.gutter + 4)
                    .animation(.easeInOut(duration: 0.2), value: hintText)
            }
            if let tool, tool != .label {
                panel(for: tool)
                    .padding(.horizontal, Metrics.gutter)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toolBar
            actionBar
        }
        .padding(.top, 4)
        .background(Wallpaper())
        .navigationTitle(Text(verbatim: artwork.placardTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                KindSwitch(kind: $kindSelection, long: false, compact: true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                trailingButton
            }
        }
        .animation(.spring(duration: 0.3), value: tool)
        .onChange(of: kindSelection) { _, newKind in
            if newKind == .craft, tool == .crop { tool = nil }
            compare = false
            resetZoom()
            pickingParts = false
            Task { await model.setKind(newKind) }
        }
        .confirmationDialog(Text("不要這張作品？"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(role: .destructive) {
                retakeAfterDiscard = false
                discardOnDisappear = true
                advancesPendingWalk = true
                dismiss()
            } label: {
                Text("不要這張")
            }
            Button(role: .cancel) {} label: { Text("取消") }
        } message: {
            Text("這張會從 App 裡刪掉，不會存到手機。")
        }
        .onChange(of: tool) { _, newTool in
            resetZoom()
            if newTool == .brush {
                if !brushZoomHintShown, !DemoMode.isActive {
                    brushZoomHintShown = true
                    showsZoomHint = true
                }
            } else {
                showsZoomHint = false
            }
        }
        .onChange(of: compare) { _, _ in resetZoom() }
        .onChange(of: artwork.id) { _, _ in resetZoom() }
        .onChange(of: brushSize) { _, _ in flashSizePreview() }
        // The picture turned under a stroke in progress (the automatic upright turn landed): its points
        // were recorded on the old picture, so drop it rather than paint in the wrong place.
        .onChange(of: model.recipe.quarterTurns) { _, _ in liveStroke = [] }
        .onAppear { app.beginEditing(artwork.id) }
        .task {
            if DemoMode.isActive {
                model.render()
                DemoMode.configure(editor: model, tool: $tool, compare: $compare, activeCorner: $activeCorner, showLabel: $showLabel)
                return
            }
            // First preview first (awaited, so the check's warp doesn't get onto the processor ahead of it); then the
            // one-time upright check, re-rendering only if it turned the artwork.
            await model.renderAndWait()
            if await model.autoOrient(), !Task.isCancelled { model.render() }
        }
        .sheet(isPresented: $showLabel) {
            LabelSheet(artwork: artwork, model: model)
        }
        .sheet(isPresented: $peekDuplicate, onDismiss: {
            if discardAfterPeek {
                discardAfterPeek = false
                confirmDiscard = true
            }
        }) {
            if let duplicate {
                DuplicatePeekSheet(existing: duplicate, onDiscard: {
                    discardAfterPeek = true
                    peekDuplicate = false
                })
            }
        }
        .onChange(of: model.output != nil) { _, ready in
            if ready { checkDuplicate() }
        }
        .onDisappear {
            // Capture everything now: environment values must not be read after the view is gone.
            let model = self.model, artwork = self.artwork, app = self.app, context = modelContext
            // Stepping through pending captures: this one's full-size render waits in the queue (it runs after the
            // walk) instead of alongside the next editor's previews. Read before continuePendingWalk ends the walk.
            let rendersLater = advancesPendingWalk && app.isWalkingPending
            // Before endEditing: the next capture is claimed first, so held exports don't start in between.
            if advancesPendingWalk {
                app.continuePendingWalk(after: artwork.id, context: context)
            } else {
                app.endPendingWalk()
            }
            app.endEditing(artwork.id, context: context)
            if discardOnDisappear {
                app.delete(artwork, context: context)
                if retakeAfterDiscard { app.cameraRequest += 1 }
                Task { await model.evictCaches() }
                return
            }
            Task {
                if rendersLater {
                    let edited = model.isDirty
                    await Self.commit(model: model, artwork: artwork, app: app, context: context, render: false)
                    app.renderLater(artwork, context: context, stale: edited)
                } else {
                    await Self.commit(model: model, artwork: artwork, app: app, context: context)
                }
                await model.evictCaches()
            }
        }
        .overlay(alignment: .topLeading) {
            if demoReady { ReadyMarker() }
        }
    }

    private var demoReady: Bool {
        if DemoMode.scene("edit-flat") { return compare && model.output != nil }
        if DemoMode.scene("crop-loupe") { return activeCorner != nil && model.source != nil }
        if DemoMode.scene("crop") { return tool == .crop && model.source != nil }
        if DemoMode.scene("edit-craft", "adjust", "brush-craft") { return model.output != nil || model.failed }
        return false
    }

    @ViewBuilder
    private var trailingButton: some View {
        if !artwork.isKept && !artwork.isSample {
            Button {
                retakeAfterDiscard = true
                discardOnDisappear = true
                dismiss()
            } label: {
                // Icon + text as a plain HStack: toolbars collapse a `Label` to its icon, which hid what 重拍 does.
                HStack(spacing: 5) {
                    Image(systemName: "camera")
                    Text("重拍")
                }
                .font(.fm(16, bold: true))
                .foregroundStyle(Palette.ink)
                .fixedSize()
            }
            .accessibilityLabel(Text("重拍"))
        } else if artwork.isKept {
            Button {
                artwork.isFavorite.toggle()
                artwork.touch()
                try? modelContext.save()
            } label: {
                Image(systemName: artwork.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(artwork.isFavorite ? Palette.yellow : Palette.ink)
            }
            .accessibilityLabel(artwork.isFavorite ? Text("取消最愛") : Text("加到最愛"))
        }
    }

    // MARK: Stage

    private var stage: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return GeometryReader { geo in
            let inner = CGSize(width: max(1, geo.size.width - 40), height: max(1, geo.size.height - 72))
            ZStack {
                if tool == .crop && model.recipe.kind == .flat && !cropShowsResult {
                    cropStage(size: inner)
                } else {
                    resultStage(size: inner)
                }
            }
            .frame(width: inner.width, height: inner.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background {
            ZStack {
                shape.fill(Palette.doorLo).offset(x: 9, y: 5)
                shape.fill(tool == .crop ? Color(0x4F8270, 0x22534D) : Palette.door)
                Capsule().fill(Palette.doorHi.opacity(0.7)).frame(width: 12, height: 110)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 18).padding(.top, 60)
            }
        }
        .overlay(alignment: .topLeading) {
            if artwork.isSample {
                Text("範例")
                    .font(.fm(15, bold: true))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Capsule().fill(Palette.chip))
                    .padding(12)
            } else if !artwork.isKept, tool == nil, !pickingParts, !compare {
                // 不要這張: throw a capture away without reopening the camera (asks first).
                Button { confirmDiscard = true } label: {
                    Label("不要這張", systemImage: "trash")
                        .font(.fm(15, bold: true))
                        .foregroundStyle(Palette.red)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Capsule().fill(Palette.surface))
                        .overlay(Capsule().strokeBorder(Palette.red, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.canPickParts, tool == nil, !compare {
                Button {
                    withAnimation(.spring(duration: 0.3)) { pickingParts.toggle() }
                } label: {
                    Label(pickingParts ? "完成選取" as LocalizedStringKey : "點選要留的部分",
                          systemImage: pickingParts ? "checkmark" : "hand.tap")
                        .font(.fm(15, bold: true))
                        .foregroundStyle(pickingParts ? Color.white : Palette.tealInk)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Capsule().fill(pickingParts ? Palette.teal : Palette.surface))
                        .overlay(Capsule().strokeBorder(Palette.teal, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if pickingParts, tool == nil {
                Button { model.keepAllParts() } label: {
                    Text("全部保留")
                        .font(.fm(15, bold: true))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Capsule().fill(Palette.surface))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if tool != .brush, !(tool == .crop && !cropShowsResult), !pickingParts, model.before != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { compare.toggle() }
                } label: {
                    Label("對比", systemImage: "rectangle.split.2x1")
                        .font(.fm(15, bold: true))
                        .foregroundStyle(compare ? Color.white : Palette.tealInk)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Capsule().fill(compare ? Palette.teal : Palette.surface))
                        .overlay(Capsule().strokeBorder(Palette.teal, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func resultStage(size: CGSize) -> some View {
        if let out = model.output {
            let fit = fitRect(out.size, in: size)
            // Where the artwork is drawn: the fit rect, zoomed / panned while 筆刷 or 對比 is on.
            let rect = stageZoom.displayRect(fit: fit)
            let visible = rect.intersection(CGRect(origin: .zero, size: size))
            let shown = visible.isNull ? rect : visible
            // 對比: the visible part of the left (原圖) side, drawn through a plain clip (no offscreen mask).
            let beforeClip = CGRect(x: rect.minX, y: rect.minY, width: rect.width * split, height: rect.height)
                .intersection(CGRect(origin: .zero, size: size))
            let touchSurface = usesStageTouches
            ZStack(alignment: .topLeading) {
                Image(uiImage: out)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    // Zoomed (up to 6×) the image is far bigger than the stage: no shadow then, so nothing renders
                    // an offscreen shadow pass of the whole enlarged print.
                    .modifier(PrintShadow(enabled: !stageZoom.isZoomed))
                    .offset(x: rect.minX, y: rect.minY)
                if compare, let before = model.before {
                    if !beforeClip.isNull, beforeClip.width > 0, beforeClip.height > 0 {
                        Image(uiImage: before)
                            .resizable()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX - beforeClip.minX, y: rect.minY - beforeClip.minY)
                            .frame(width: beforeClip.width, height: beforeClip.height, alignment: .topLeading)
                            .clipped()
                            .offset(x: beforeClip.minX, y: beforeClip.minY)
                    }
                    CompareDivider(height: shown.height)
                        .offset(x: rect.minX + rect.width * split - 22, y: shown.minY)
                    HStack {
                        StageChip(text: String(localized: "原圖"))
                        Spacer()
                        StageChip(text: String(localized: "處理後"))
                    }
                    .padding(10)
                    .frame(width: shown.width)
                    .offset(x: shown.minX, y: shown.maxY - 52)
                    .allowsHitTesting(false)
                }
                if pickingParts {
                    ForEach(model.parts) { part in
                        let r = CGRect(x: rect.minX + part.bounds.minX * rect.width, y: rect.minY + part.bounds.minY * rect.height,
                                       width: part.bounds.width * rect.width, height: part.bounds.height * rect.height)
                            .intersection(rect)
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(part.isRemoved ? Palette.red : Palette.mark,
                                          style: StrokeStyle(lineWidth: 3, dash: part.isRemoved ? [7, 6] : []))
                            .background(RoundedRectangle(cornerRadius: 10).fill(part.isRemoved ? Palette.red.opacity(0.12) : Color.clear))
                            .overlay(alignment: .topLeading) {
                                Image(systemName: part.isRemoved ? "minus.circle.fill" : "checkmark.circle.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(part.isRemoved ? Palette.red : Palette.teal)
                                    .background(Circle().fill(.white).padding(2))
                                    .offset(x: -8, y: -8)
                            }
                            .frame(width: max(24, r.width), height: max(24, r.height))
                            .offset(x: r.minX, y: r.minY)
                            .allowsHitTesting(false)
                    }
                }
                if !liveStroke.isEmpty {
                    let points = liveStroke.map { stageZoom.viewPoint(fromImage: $0, fit: fit) }
                    let radius = CGFloat(liveStrokeRadius) * max(rect.width, rect.height)
                    Path { p in p.addLines(points) }
                        .stroke(liveStrokeColor,
                                style: StrokeStyle(lineWidth: max(2, radius * 2), lineCap: .round, lineJoin: .round))
                    if let last = points.last {
                        BrushRing(radius: radius)
                            .position(last)
                    }
                } else if tool == .brush, showsSizePreview {
                    BrushRing(radius: StageZoom.screenRadius(sliderSize: brushSize, fit: fit))
                        .position(x: size.width / 2, y: size.height / 2)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            // Zoomed: keep the artwork inside the stage (at 1× the print's shadow may spill over as before).
            .clipShape(Rectangle().inset(by: stageZoom.isZoomed ? 0 : -40))
            .contentShape(Rectangle())
            .gesture(stageGesture(rect: rect))
            .allowsHitTesting(!touchSurface)
            .overlay {
                if touchSurface {
                    StageTouchSurface { event in
                        handleStageTouch(event, fit: fit, viewport: size)
                    }
                    .accessibilityHidden(true)
                }
            }
            .overlay {
                if model.isRendering {
                    ProgressView()
                        .padding(10)
                        .background(Circle().fill(Palette.surface))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if touchSurface, stageZoom.isZoomed {
                    zoomResetChip
                        .padding(6)
                        .transition(.opacity)
                }
            }
        } else if model.failed {
            VStack(spacing: 12) {
                Image("bibi-oops").resizable().scaledToFit().frame(height: 150)
                Text("這張照片處理不了").font(.fmDisplay(20)).foregroundStyle(Palette.doorInk)
                Text(model.recipe.kind == .flat ? "可以試試「裁切」對準紙張四角，或改成勞作。" as LocalizedStringKey : "可以試試改成畫作，或重拍一張。")
                    .font(.fm(14.5)).foregroundStyle(Palette.doorMuted).multilineTextAlignment(.center)
                Button { model.render() } label: {
                    Label("再試一次", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryCapsuleStyle())
                .frame(width: 200)
            }
            .frame(width: size.width, height: size.height)
        } else {
            VStack(spacing: 14) {
                Image("bibi-think").resizable().scaledToFit().frame(height: 160)
                HStack(spacing: 10) {
                    ProgressView().tint(Palette.teal)
                    Text(model.recipe.kind == .craft ? "AI 去背中…" as LocalizedStringKey : "處理中…")
                        .font(.fm(17, bold: true))
                        .foregroundStyle(Palette.ink)
                }
                .padding(.horizontal, 22)
                .frame(height: 50)
                .background(Capsule().fill(Palette.surface).shadow(color: Palette.shadow, radius: 5, y: 3))
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private var liveStrokeColor: Color {
        if model.recipe.kind == .flat { return .white.opacity(0.9) }
        return brushMode == .restore ? Palette.green.opacity(0.5) : Palette.red.opacity(0.5)
    }

    /// 筆刷 and 對比 take the stage's touches through `StageTouchSurface` (one finger draws / drags the split line,
    /// two fingers zoom and pan, double tap zooms); otherwise the SwiftUI gesture below (part picking).
    private var usesStageTouches: Bool { tool == .brush || compare }

    /// Part picking (taps on the craft parts). 筆刷 / 對比 go through `handleStageTouch` instead.
    private func stageGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                if pickingParts, rect.width > 0, rect.height > 0 {
                    let p = CGPoint(x: (value.location.x - rect.minX) / rect.width, y: (value.location.y - rect.minY) / rect.height)
                    if model.togglePart(atOutputPoint: p) == false {
                        app.show(String(localized: "至少要留下一個部分喔"), style: .problem)
                    }
                }
            }
    }

    private func handleStageTouch(_ event: StageTouchEvent, fit: CGRect, viewport: CGSize) {
        switch event {
        case .strokeBegan(let p):
            if tool == .brush {
                liveStrokeRadius = StageZoom.strokeRadius(sliderSize: brushSize, scale: stageZoom.scale)
                liveStrokeMapping = model.result?.mapping
                liveStroke = [stageZoom.imagePoint(fromView: p, fit: fit)]
            } else if compare {
                split = stageZoom.imagePoint(fromView: p, fit: fit).x.clamped(0, 1)
            }
        case .strokeMoved(let p):
            if tool == .brush {
                guard !liveStroke.isEmpty else { return }
                liveStroke.append(stageZoom.imagePoint(fromView: p, fit: fit))
            } else if compare {
                split = stageZoom.imagePoint(fromView: p, fit: fit).x.clamped(0, 1)
            }
        case .strokeEnded:
            if tool == .brush { commitStroke() } else { liveStroke = [] }
        case .strokeCancelled:
            liveStroke = []
        case let .transformBegan(centroid, distance):
            pinchStart = PinchStart(zoom: stageZoom, centroid: centroid, distance: distance)
        case let .transformChanged(centroid, distance):
            guard let start = pinchStart else { return }
            stageZoom = start.zoom.pinched(startCentroid: start.centroid, startDistance: start.distance,
                                           centroid: centroid, distance: distance, fit: fit, viewport: viewport)
        case .transformEnded:
            pinchStart = nil
        case .doubleTap(let p):
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                stageZoom = stageZoom.toggled(at: p, fit: fit, viewport: viewport)
            }
        }
    }

    private func commitStroke() {
        let points = liveStroke
        liveStroke = []
        // The mapping of the picture the stroke was drawn on (a craft's crop box follows the mask after each stroke).
        guard !points.isEmpty, let mapping = liveStrokeMapping ?? model.result?.mapping else { return }
        // Points are output-normalized; strokes live unturned (flat: corrected sheet, craft: original photo).
        let norm = points.map { v -> NormPoint in
            let s = mapping.toStrokeSpace(v)
            return NormPoint(x: Double(s.x), y: Double(s.y))
        }
        let radius = mapping.strokeRadius(fromOutputRadius: liveStrokeRadius)
        model.addStroke(BrushStroke(mode: model.recipe.kind == .flat ? .paintWhite : brushMode, radius: radius, points: norm))
    }

    private func resetZoom() {
        stageZoom = StageZoom()
        pinchStart = nil
        liveStroke = []
    }

    /// Brush size ring at the stage center for a moment after the slider moves (the real on-screen size).
    private func flashSizePreview() {
        guard tool == .brush else { return }
        sizePreviewToken += 1
        let token = sizePreviewToken
        withAnimation(.easeOut(duration: 0.15)) { showsSizePreview = true }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard token == sizePreviewToken else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsSizePreview = false }
        }
    }

    /// 「100%」: back to the whole artwork. Shows the current zoom.
    private var zoomResetChip: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { stageZoom = StageZoom() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text(verbatim: "\(Int((stageZoom.scale * 100).rounded()))%")
            }
            .font(.fm(14, bold: true))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(Palette.chip))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("恢復原尺寸"))
    }

    @ViewBuilder
    private func cropStage(size: CGSize) -> some View {
        if let src = model.source {
            let rect = fitRect(src.size, in: size)
            let quad = model.recipe.corners ?? .full
            let pts = quad.points.map { toView($0, rect) }
            ZStack(alignment: .topLeading) {
                Image(uiImage: src)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                QuadOutline(points: pts)
                ForEach(0..<4, id: \.self) { i in
                    CornerHandle(active: activeCorner == i)
                        .position(pts[i])
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("cropStage"))
                                .onChanged { value in
                                    activeCorner = i
                                    var q = model.recipe.corners ?? .full
                                    q[i] = NormPoint(x: Double((value.location.x - rect.minX) / rect.width),
                                                     y: Double((value.location.y - rect.minY) / rect.height)).clampedToUnit()
                                    model.recipe.corners = q
                                }
                                .onEnded { _ in
                                    activeCorner = nil
                                    model.cornersChanged()
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel(Text(cornerName(i)))
                        .accessibilityAdjustableAction { direction in
                            var q = model.recipe.corners ?? .full
                            let d = direction == .increment ? 0.01 : -0.01
                            q[i] = NormPoint(x: q[i].x + (i == 0 || i == 3 ? d : -d), y: q[i].y + (i < 2 ? d : -d)).clampedToUnit()
                            model.recipe.corners = q
                            model.cornersChanged()
                        }
                }
                if let i = activeCorner {
                    let focus = pts[i]
                    let loupeSize: CGFloat = 124
                    let onRight = focus.x < size.width / 2
                    let atBottom = focus.y < loupeSize + 30
                    Loupe(image: src, imageRect: rect, focus: focus, quad: pts, size: loupeSize)
                        .position(x: onRight ? size.width - loupeSize / 2 - 6 : loupeSize / 2 + 6,
                                  y: atBottom ? size.height - loupeSize / 2 - 6 : loupeSize / 2 + 6)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(.named("cropStage"))
            .animation(.easeOut(duration: 0.15), value: activeCorner)
        } else {
            ProgressView()
                .frame(width: size.width, height: size.height)
                .task { await model.loadSource() }
        }
    }

    private func cornerName(_ i: Int) -> String {
        switch i {
        case 0: String(localized: "左上角")
        case 1: String(localized: "右上角")
        case 2: String(localized: "右下角")
        default: String(localized: "左下角")
        }
    }

    private func toView(_ p: NormPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(p.x) * rect.width, y: rect.minY + CGFloat(p.y) * rect.height)
    }

    // MARK: 這張好像收過了

    /// The notice takes the hint line's place while no tool, compare or part picking needs that line.
    private var showsDuplicateNotice: Bool {
        !artwork.isKept && !artwork.isSample && tool == nil && !compare && !pickingParts
            && model.output != nil && duplicate.map { AppModel.isAlive($0) } == true
    }

    /// Compares this capture's preview with the kept artworks of the same kind. Only a reminder: 收進這次 and
    /// 存到手機 stay exactly the same (no extra question when the parent keeps it anyway).
    private func checkDuplicate() {
        guard !artwork.isKept, !artwork.isSample, !DemoMode.isActive, let cg = model.output?.cgImage else { return }
        let kind = model.recipe.kind
        guard duplicateCheckedKind != kind else { return }
        duplicateCheckedKind = kind
        duplicate = nil
        let preview = RenderedImage(cgImage: cg)
        // Environment values are read now, not after the await (the editor may be gone by then).
        let model = self.model, artwork = self.artwork, app = self.app, context = modelContext
        Task {
            let fingerprint = await Task.detached(priority: .userInitiated) {
                ArtFingerprint.make(cgImage: preview.cgImage)
            }.value
            guard let fingerprint, AppModel.isAlive(artwork), !artwork.isKept, model.recipe.kind == kind else { return }
            let match = app.likelyDuplicate(of: fingerprint, kind: kind, childID: artwork.child?.id,
                                            excluding: artwork.id, context: context)
            withAnimation(.easeInOut(duration: 0.2)) { duplicate = match }
        }
    }

    // MARK: Hint / tools / actions

    private var hintText: String {
        let flat = model.recipe.kind == .flat
        var t: String
        switch tool {
        case .crop:
            t = cropShowsResult ? String(localized: "已轉向。再按一次「裁切」可回到四角。")
                : String(localized: "拖曳四個白點對準紙張四角，放開後會自動重新處理。")
        case .brush:
            if flat { t = String(localized: "在髒點上塗抹，會塗成白色。只建議用在空白紙面。") }
            else if brushMode == .restore { t = String(localized: "塗抹被誤刪的作品部分，把它補回來。") }
            else { t = String(localized: "塗抹要去掉的背景部分。") }
            if showsZoomHint {
                if AppLanguage.isChinese {
                    if !t.hasSuffix("。") { t += " · " }
                } else {
                    t += " "
                }
                t += String(localized: "兩指可以放大、移動")
            }
        default:
            if model.output == nil { t = String(localized: "冰冰正在整理這張作品，請稍等一下。") }
            else if pickingParts { t = String(localized: "點一下要留下或拿掉的部分，至少要留一個。") }
            else if model.isAutoTurned, !artwork.isKept, model.notes.first != .paperNotFound {
                t = String(localized: "已自動轉正，不對的話到「裁切」轉一下。")
            }
            else if let note = model.notes.first { t = note.localizedText }
            else if model.recipe.kind == .flat, model.result?.paperMode == .paintCovered, !compare {
                t = String(localized: "顏料幾乎蓋滿紙，只輕調光線")
            }
            else if compare { t = String(localized: "左右拖曳白線，比較前後") }
            else if artwork.isKept && !artwork.isSample { t = String(localized: "改好了就存到手機或分享。修改會自動保存。") }
            else { t = String(localized: "看起來可以了，就存到手機或收進這次。") }
        }
        if flat, tool != .crop, !pickingParts, model.recipe.removeSpecks, model.specksRemoved > 0, model.output != nil {
            if AppLanguage.isChinese {
                if !t.hasSuffix("。") { t += " · " }
            } else {
                t += " "
            }
            t += String(localized: "已自動清掉 \(model.specksRemoved) 個小黑點")
        }
        return t
    }

    private var toolBar: some View {
        HStack(alignment: .top) {
            ForEach(tools) { t in
                Button {
                    if t == .label {
                        showLabel = true
                        return
                    }
                    if t == .crop, tool == .crop, cropShowsResult {
                        cropShowsResult = false          // 再按一次「裁切」回到四角
                        return
                    }
                    tool = (tool == t) ? nil : t
                    cropShowsResult = false
                    pickingParts = false
                    if tool == .crop { compare = false; Task { await model.loadSource() } }
                    if tool == .brush { compare = false }
                } label: {
                    VStack(spacing: 6) {
                        RoundKnob(systemImage: t.systemImage, selected: tool == t, size: 54)
                        Text(verbatim: t.title)
                            .font(.fm(13.5, bold: true))
                            .foregroundStyle(tool == t ? Palette.tealInk : Palette.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tool == t ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if artwork.isKept && !artwork.isSample {
                if let shareItem {
                    ShareLink(item: shareItem, preview: SharePreview(artwork.placardTitle, image: shareImage)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryCapsuleStyle())
                    .frame(maxWidth: 150)
                }
            } else {
                Button(action: keep) {
                    Label("收進這次", systemImage: "plus")
                }
                .buttonStyle(SecondaryCapsuleStyle())
                .frame(maxWidth: 160)
                .disabled(model.output == nil || isSaving)
            }
            Button(action: save) {
                HStack(spacing: 8) {
                    if isSaving { ProgressView().tint(Palette.primaryInk) } else { Image(systemName: "square.and.arrow.down") }
                    Text("存到手機")
                }
            }
            .buttonStyle(PrimaryCapsuleStyle())
            .disabled(isSaving || model.output == nil)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 6)
    }

    private var shareImage: Image {
        if let out = model.output { return Image(uiImage: out) }
        return Image("bibi-idle")
    }

    private var shareItem: ShareableArtwork? {
        ShareableArtwork(artwork: artwork, recipe: model.recipe, app: app)
    }

    private func keep() {
        let model = self.model, artwork = self.artwork, app = self.app, context = modelContext
        // Stepping through pending captures: the commit (and its render) happens when the editor closes, queued
        // behind the walk (onDisappear → AppModel.renderLater).
        if !app.isWalkingPending {
            Task { await Self.commit(model: model, artwork: artwork, app: app, context: context) }
        }
        if app.keep(artwork, context: context) {
            advancesPendingWalk = true
            dismiss()
        }
    }

    private func save() {
        isSaving = true
        let model = self.model, artwork = self.artwork, app = self.app, context = modelContext
        let wasPending = !artwork.isKept
        Task {
            // The one-time upright check lands first, so the saved picture and the editor agree.
            if await model.autoOrient() { model.render() }
            // Only write edits back here. A fresh capture with no working copy gets it from the save's own export
            // (AppModel.finalJPEG), so the tap runs one heavy render, not two.
            if model.isDirty {
                await Self.commit(model: model, artwork: artwork, app: app, context: context,
                                  render: artwork.renderedImageData != nil)
            }
            let ok = await app.saveToPhotos(artwork, context: context)
            isSaving = false
            if ok && wasPending {
                advancesPendingWalk = true
                dismiss()
            }
        }
    }

    private func redetectCorners() {
        cropShowsResult = false
        Task { await model.redetectCorners() }
    }

    private func panel(for tool: EditTool) -> some View {
        let isCrop = tool == .crop
        let icon: String? = isCrop ? "viewfinder" : nil
        let action: (() -> Void)? = isCrop ? { redetectCorners() } : nil
        return PanelCard(title: tool.panelTitle, onDone: { self.tool = nil }, accessoryIcon: icon,
                         accessoryLabel: String(localized: "重新自動找四角"), onAccessory: action) {
            panelContent(for: tool)
        }
    }

    @ViewBuilder
    private func panelContent(for tool: EditTool) -> some View {
        switch tool {
        case .crop:
            CropPanel(model: model, onTurn: { cropShowsResult = true }, onCorners: { cropShowsResult = false })
        case .adjust:
            if model.recipe.kind == .flat {
                // Four controls: scroll inside the card so the artwork keeps most of the screen on small phones.
                ScrollView { AdjustPanel(model: model).padding(.trailing, 2) }
                    .scrollIndicators(.visible)
                    .frame(maxHeight: 236)
            } else {
                AdjustPanel(model: model)
            }
        case .brush:
            BrushPanel(model: model, brushMode: $brushMode, brushSize: $brushSize)
        case .label:
            EmptyView()
        }
    }

    /// Writes the recipe back and re-renders the full-size output if anything changed. A fresh capture has no
    /// full-size render yet (the background export waits while the editor is open), so it gets its one render here.
    /// `render: false` only writes the recipe back (存到手機 on a capture with no working copy: the save's export
    /// stores one; if the save stops early, the commit on disappear still renders because `needsRender` is true).
    static func commit(model: EditModel, artwork: Artwork, app: AppModel, context: ModelContext,
                       render: Bool = true) async {
        guard AppModel.isAlive(artwork) else { return }
        // Keep / save right after opening: let the one-time upright check land first, so the editor's recipe and
        // the stored one agree (rerender / finalJPEG would otherwise pay it on the stored recipe alone).
        await model.autoOrient()
        guard AppModel.isAlive(artwork) else { return }
        if model.isDirty {
            artwork.recipe = model.recipe
            artwork.kind = model.recipe.kind
            artwork.touch()
            model.markSaved()
            if render {
                await app.rerender(artwork, context: context)
            } else {
                try? context.save()
            }
        } else if render, app.needsRender(artwork) {
            await app.rerender(artwork, context: context)
        }
    }
}

// MARK: 這張好像收過了 — notice card + peek sheet

/// Gentle reminder under the stage: the kept artwork this capture looks like, with 看一下 / 不要這張.
/// Keeping it anyway is still the one 收進這次 tap.
struct DuplicateNotice: View {
    let existing: Artwork
    let onPeek: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkImage(artwork: existing)
                .frame(width: 50, height: 58)
                .clipped()
                .padding(3)
                .background(Palette.print)
                .rotationEffect(.degrees(-4))
                .shadow(color: Palette.printShadow.opacity(0.6), radius: 3, y: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("這張好像收過了")
                    .font(.fm(15.5, bold: true))
                    .foregroundStyle(Palette.ink)
                Text(verbatim: existing.duplicateCaption)
                    .font(.fm(13.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                // Side by side when they fit; stacked on narrow phones / long English labels.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        peekButton
                        discardButton
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        peekButton
                        discardButton
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.surface)
                .shadow(color: Palette.shadow, radius: 4, y: 2)
        )
        // .contain so VoiceOver reaches 看一下 and 不要這張 separately.
        .accessibilityElement(children: .contain)
    }

    private var peekButton: some View {
        Button(action: onPeek) {
            Text("看一下")
                .font(.fm(14.5, bold: true))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(Capsule().fill(Palette.teal))
        }
        .buttonStyle(.plain)
    }

    private var discardButton: some View {
        Button(action: onDiscard) {
            Text("不要這張")
                .font(.fm(14.5, bold: true))
                .foregroundStyle(Palette.red)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .overlay(Capsule().strokeBorder(Palette.red, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 看一下: the kept artwork, big, with its placard. 不要這張 hands back to the editor's usual discard question.
struct DuplicatePeekSheet: View {
    let existing: Artwork
    let onDiscard: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ArtworkImage(artwork: existing)
                        .padding(6)
                        .background(Palette.print)
                        .shadow(color: Palette.printShadow, radius: 8, y: 4)
                        .frame(maxHeight: 340)
                    Placard(artwork: existing)
                        .padding(.horizontal, 24)
                    Text("已經在美術館裡了。兩張都想留，就按「收進這次」。")
                        .font(.fm(14.5))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onDiscard) {
                        Label("不要這張", systemImage: "trash")
                    }
                    .buttonStyle(SecondaryCapsuleStyle(ink: Palette.red))
                    .frame(maxWidth: 220)
                }
                .padding(20)
            }
            .background(Palette.surface)
            .navigationTitle(Text("已經收過的作品"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("關閉").font(.fm(17, bold: true)) }
                        .tint(Palette.tealInk)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
    }
}

extension Artwork {
    /// “小明 · 2026/03/14” — who and when, for 這張好像收過了.
    var duplicateCaption: String {
        let name = child.map(\.displayName) ?? String(localized: "小畫家")
        return "\(name) · \(AppLanguage.placardDate(capturedAt))"
    }
}

// MARK: Stage pieces

/// Where a two-finger gesture started (zoom, finger centroid and distance).
struct PinchStart {
    var zoom: StageZoom
    var centroid: CGPoint
    var distance: CGFloat
}

/// The print's drop shadow on the stage; left off while zoomed (see `resultStage`).
struct PrintShadow: ViewModifier {
    var enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.shadow(color: Palette.printShadow, radius: 8, y: 4)
        } else {
            content
        }
    }
}

/// Brush size outline (white with a dark edge so it shows on any artwork).
struct BrushRing: View {
    var radius: CGFloat

    var body: some View {
        Circle()
            .strokeBorder(Color.black.opacity(0.35), lineWidth: 3.5)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            .frame(width: max(6, radius * 2), height: max(6, radius * 2))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct StageChip: View {
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.fm(14, bold: true))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Palette.chip))
    }
}

/// White split line with a round ‹ › knob.
struct CompareDivider: View {
    var height: CGFloat

    var body: some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 3, height: height).shadow(color: .black.opacity(0.3), radius: 2)
            Circle().fill(.white).frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(Color(0x2B2E4A, 0x2B2E4A), lineWidth: 2))
                .overlay(
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Color(0x2B2E4A, 0x2B2E4A))
                )
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .frame(width: 44, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The paper outline in crop mode: yellow marker line with a dark edge so it shows on any table.
struct QuadOutline: View {
    var points: [CGPoint]

    var body: some View {
        let path = Path { p in
            p.addLines(points)
            p.closeSubpath()
        }
        ZStack {
            path.fill(Palette.mark.opacity(0.08))
            path.stroke(Palette.markEdge, style: StrokeStyle(lineWidth: 5.5, lineJoin: .round))
            path.stroke(Palette.mark, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

struct CornerHandle: View {
    var active = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: active ? 30 : 26, height: active ? 30 : 26)
            .overlay(Circle().strokeBorder(Palette.mark, lineWidth: 5))
            .overlay(Circle().strokeBorder(Palette.markEdge, lineWidth: 1).padding(-1))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .frame(width: 52, height: 52)
            .contentShape(Circle())
    }
}

/// Magnifier shown while a corner is dragged, so the finger doesn't hide the paper edge.
struct Loupe: View {
    let image: UIImage
    let imageRect: CGRect
    let focus: CGPoint
    let quad: [CGPoint]
    var size: CGFloat = 124
    var zoom: CGFloat = 2.6

    var body: some View {
        let c = CGPoint(x: size / 2, y: size / 2)
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: c.x + (p.x - focus.x) * zoom, y: c.y + (p.y - focus.y) * zoom) }
        let outline = Path { p in
            p.addLines(quad.map(map))
            p.closeSubpath()
        }
        return ZStack(alignment: .topLeading) {
            Color(0x2B2E4A, 0x14131C)
            Image(uiImage: image)
                .resizable()
                .frame(width: imageRect.width * zoom, height: imageRect.height * zoom)
                .position(map(CGPoint(x: imageRect.midX, y: imageRect.midY)))
            outline.stroke(Palette.markEdge, lineWidth: 4)
            outline.stroke(Palette.mark, lineWidth: 2.2)
            Path { p in
                p.move(to: CGPoint(x: c.x - 11, y: c.y)); p.addLine(to: CGPoint(x: c.x + 11, y: c.y))
                p.move(to: CGPoint(x: c.x, y: c.y - 11)); p.addLine(to: CGPoint(x: c.x, y: c.y + 11))
            }
            .stroke(.white, lineWidth: 1.6)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: 4))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}

extension ProcessingNote {
    /// Hint-line copy for a processing note (catalog keys `processing.note.*`).
    var localizedText: String {
        String(localized: String.LocalizationValue(localizationKey))
    }
}
