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

    @State private var model: EditModel
    @State private var tool: EditTool?
    @State private var showLabel = false
    @State private var brushMode: BrushStroke.Mode = .erase
    @State private var brushSize: Double = 3
    @State private var compare = false
    @State private var split: CGFloat = 0.5
    @State private var liveStroke: [CGPoint] = []
    @State private var isSaving = false
    @State private var kindSelection: ArtworkKind
    @State private var activeCorner: Int?
    /// After 向左轉 / 向右轉 / 拉直 the crop tool shows the turned result; tapping 裁切 again returns to the corners.
    @State private var cropShowsResult = false
    @State private var pickingParts = false

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, Metrics.gutter)
                .padding(.trailing, 8)
            BibiHint(text: hintText)
                .padding(.horizontal, Metrics.gutter + 4)
                .animation(.easeInOut(duration: 0.2), value: hintText)
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
            pickingParts = false
            Task { await model.setKind(newKind) }
        }
        .task {
            model.render()
            if DemoMode.isActive { DemoMode.configure(editor: model, tool: $tool, compare: $compare, activeCorner: $activeCorner, showLabel: $showLabel) }
        }
        .sheet(isPresented: $showLabel) {
            LabelSheet(artwork: artwork, model: model)
        }
        .onDisappear {
            // Capture everything now: environment values must not be read after the view is gone.
            let model = self.model, artwork = self.artwork, app = self.app, context = modelContext
            Task {
                await Self.commit(model: model, artwork: artwork, app: app, context: context)
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
                let a = artwork
                dismiss()
                app.delete(a, context: modelContext)
                app.cameraRequest += 1
            } label: {
                Label("重拍", systemImage: "camera")
                    .labelStyle(.titleAndIcon)
                    .font(.fm(16, bold: true))
                    .foregroundStyle(Palette.ink)
            }
        } else if artwork.isKept {
            Button {
                artwork.isFavorite.toggle()
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
            let rect = fitRect(out.size, in: size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: out)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .shadow(color: Palette.printShadow, radius: 8, y: 4)
                    .offset(x: rect.minX, y: rect.minY)
                if compare, let before = model.before {
                    Image(uiImage: before)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: rect.width * split)
                        }
                        .offset(x: rect.minX, y: rect.minY)
                    CompareDivider(height: rect.height)
                        .offset(x: rect.minX + rect.width * split - 22, y: rect.minY)
                    HStack {
                        StageChip(text: String(localized: "原圖"))
                        Spacer()
                        StageChip(text: String(localized: "處理後"))
                    }
                    .padding(10)
                    .frame(width: rect.width)
                    .offset(x: rect.minX, y: rect.maxY - 52)
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
                    Path { p in p.addLines(liveStroke) }
                        .stroke(liveStrokeColor,
                                style: StrokeStyle(lineWidth: max(2, liveRadius(rect: rect) * 2), lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(stageGesture(rect: rect))
            .overlay {
                if model.isRendering {
                    ProgressView()
                        .padding(10)
                        .background(Circle().fill(Palette.surface))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
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

    /// Brush radius in view points for the live stroke preview (radius = fraction of the output's long edge).
    private func liveRadius(rect: CGRect) -> CGFloat {
        CGFloat(brushSize * 0.006) * max(rect.width, rect.height)
    }

    private func stageGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pickingParts { return }
                if tool == .brush {
                    liveStroke.append(value.location)
                } else if compare, rect.width > 0 {
                    split = ((value.location.x - rect.minX) / rect.width).clamped(0, 1)
                }
            }
            .onEnded { value in
                if tool == .brush { commitStroke(rect: rect) }
                if pickingParts, rect.width > 0, rect.height > 0 {
                    let p = CGPoint(x: (value.location.x - rect.minX) / rect.width, y: (value.location.y - rect.minY) / rect.height)
                    if model.togglePart(atOutputPoint: p) == false {
                        app.show(String(localized: "至少要留下一個部分喔"), style: .problem)
                    }
                }
            }
    }

    private func commitStroke(rect: CGRect) {
        let points = liveStroke
        liveStroke = []
        guard !points.isEmpty, rect.width > 0, rect.height > 0 else { return }
        guard let mapping = model.result?.mapping else { return }
        // Touches are output-normalized; strokes live unturned (flat: corrected sheet, craft: original photo).
        let norm = points.map { v -> NormPoint in
            let s = mapping.toStrokeSpace(CGPoint(x: (v.x - rect.minX) / rect.width, y: (v.y - rect.minY) / rect.height))
            return NormPoint(x: Double(s.x), y: Double(s.y))
        }
        let radius = mapping.strokeRadius(fromOutputRadius: brushSize * 0.006)
        model.addStroke(BrushStroke(mode: model.recipe.kind == .flat ? .paintWhite : brushMode, radius: radius, points: norm))
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
        default:
            if model.output == nil { t = String(localized: "冰冰正在整理這張作品，請稍等一下。") }
            else if pickingParts { t = String(localized: "點一下要留下或拿掉的部分，至少要留一個。") }
            else if let note = model.notes.first { t = note.localizedText }
            else if model.recipe.kind == .flat, model.result?.paperMode == .paintCovered, !compare {
                t = String(localized: "顏料幾乎蓋滿紙，只輕調光線")
            }
            else if compare { t = String(localized: "左右拖曳白線，比較前後") }
            else if artwork.isKept && !artwork.isSample { t = String(localized: "改好了就存到手機或分享。修改會自動保存。") }
            else { t = String(localized: "看起來可以了，就存到手機或收進這次。") }
        }
        if flat, tool != .crop, !pickingParts, model.recipe.removeSpecks, model.specksRemoved > 0, model.output != nil {
            t += AppLanguage.isChinese ? " · " : " "
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
                ShareLink(item: shareItem, preview: SharePreview(artwork.placardTitle, image: shareImage)) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryCapsuleStyle())
                .frame(maxWidth: 150)
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

    private var shareItem: ShareableArtwork {
        ShareableArtwork(id: artwork.id, originalData: model.originalData, recipe: model.recipe,
                         captionTitle: app.captionTitle(artwork), captionDetail: app.captionDetail(artwork),
                         captionBackground: app.captionBackground(model.recipe))
    }

    private func keep() {
        let model = self.model, artwork = self.artwork, app = self.app, context = modelContext
        Task { await Self.commit(model: model, artwork: artwork, app: app, context: context) }
        if app.keep(artwork, context: context) { dismiss() }
    }

    private func save() {
        isSaving = true
        let model = self.model, artwork = self.artwork, app = self.app, context = modelContext
        let wasPending = !artwork.isKept
        Task {
            await Self.commit(model: model, artwork: artwork, app: app, context: context)
            let ok = await app.saveToPhotos(artwork, context: context)
            isSaving = false
            if ok && wasPending { dismiss() }
        }
    }

    @ViewBuilder
    private func panel(for tool: EditTool) -> some View {
        PanelCard(title: tool.panelTitle, onDone: { self.tool = nil }) {
            switch tool {
            case .crop: CropPanel(model: model, onTurn: { cropShowsResult = true }, onCorners: { cropShowsResult = false })
            case .adjust: AdjustPanel(model: model)
            case .brush: BrushPanel(model: model, brushMode: $brushMode, brushSize: $brushSize)
            case .label: EmptyView()
            }
        }
    }

    /// Writes the recipe back and re-renders the full-size output if anything changed.
    static func commit(model: EditModel, artwork: Artwork, app: AppModel, context: ModelContext) async {
        guard model.isDirty else { return }
        artwork.recipe = model.recipe
        artwork.kind = model.recipe.kind
        model.markSaved()
        await app.rerender(artwork, context: context)
    }
}

// MARK: Stage pieces

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
