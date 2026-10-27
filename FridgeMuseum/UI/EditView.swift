import SwiftData
import SwiftUI
import UIKit

enum EditTool: String, CaseIterable, Identifiable {
    case crop, adjust, brush, info

    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: "裁切"
        case .adjust: "調整"
        case .brush: "筆刷"
        case .info: "資料"
        }
    }
    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .adjust: "slider.horizontal.3"
        case .brush: "paintbrush.pointed"
        case .info: "tag"
        }
    }
    var tint: Color {
        switch self {
        case .crop: Palette.blue
        case .adjust: Palette.yellow
        case .brush: Palette.pink
        case .info: Palette.green
        }
    }
}

/// Full-screen studio: stage + 4 tools (裁切 / 調整 / 筆刷 / 資料) + 分享 / 存到手機.
struct EditView: View {
    @Bindable var artwork: Artwork
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext

    @State private var model: EditModel
    @State private var tool: EditTool?
    @State private var brushMode: BrushStroke.Mode = .erase
    @State private var brushSize: Double = 3
    @State private var compare = false
    @State private var split: CGFloat = 0.5
    @State private var liveStroke: [CGPoint] = []
    @State private var isSaving = false
    @State private var kindSelection: ArtworkKind

    init(artwork: Artwork) {
        _artwork = Bindable(artwork)
        _model = State(initialValue: EditModel(artwork: artwork))
        _kindSelection = State(initialValue: artwork.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(hintText)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            if let tool {
                panel(for: tool)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Palette.surface))
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toolBar
            actionBar
        }
        .background(Palette.paper.ignoresSafeArea())
        .navigationTitle(artwork.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("種類", selection: $kindSelection) {
                    ForEach(ArtworkKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    artwork.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: artwork.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(artwork.isFavorite ? Palette.yellow : Palette.muted)
                }
                .accessibilityLabel(artwork.isFavorite ? "取消最愛" : "加到最愛")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tool)
        .onChange(of: kindSelection) { _, newKind in
            if newKind == .craft, tool == .crop { tool = nil }
            Task { await model.setKind(newKind) }
        }
        .task { model.render() }
        .onDisappear {
            // Capture everything now: environment values must not be read after the view is gone.
            let model = self.model, artwork = self.artwork, app = self.app, context = modelContext
            Task {
                await Self.commit(model: model, artwork: artwork, app: app, context: context)
                await model.evictCaches()
            }
        }
    }

    // MARK: Stage

    private var stage: some View {
        GeometryReader { geo in
            ZStack {
                if tool == .crop && model.recipe.kind == .flat {
                    cropStage(size: geo.size)
                } else {
                    resultStage(size: geo.size)
                }
                if model.isRendering {
                    ProgressView()
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                }
            }
        }
        .padding(12)
        .overlay(alignment: .bottomTrailing) {
            if tool != .crop, model.before != nil {
                Button {
                    compare.toggle()
                } label: {
                    Label("對比", systemImage: "rectangle.split.2x1")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(compare ? Palette.blue : Palette.surface))
                        .foregroundStyle(compare ? Color.white : Palette.ink)
                }
                .padding(20)
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
                    .offset(x: rect.minX, y: rect.minY)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                if compare, tool != .brush, let before = model.before {
                    Image(uiImage: before)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: rect.width * split)
                        }
                        .offset(x: rect.minX, y: rect.minY)
                    Rectangle()
                        .fill(.white)
                        .frame(width: 3, height: rect.height)
                        .shadow(radius: 2)
                        .offset(x: rect.minX + rect.width * split - 1.5, y: rect.minY)
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
        } else if model.failed {
            ContentUnavailableView("處理失敗", systemImage: "exclamationmark.triangle", description: Text("可以試試切換畫作／勞作"))
        } else {
            ProgressView("處理中…")
                .frame(width: size.width, height: size.height)
        }
    }

    private var liveStrokeColor: Color {
        if model.recipe.kind == .flat { return .white.opacity(0.9) }
        return brushMode == .restore ? Palette.green.opacity(0.5) : Palette.coral.opacity(0.5)
    }

    /// Brush radius in view points for the live stroke preview.
    private func liveRadius(rect: CGRect) -> CGFloat {
        let r = brushSize * 0.006
        if model.recipe.kind == .flat { return CGFloat(r) * max(rect.width, rect.height) }
        guard let map = model.outputToSource, map.width > 0, map.height > 0 else { return CGFloat(r) * max(rect.width, rect.height) }
        let srcLong = max(rect.width / CGFloat(map.width), rect.height / CGFloat(map.height))
        return CGFloat(r) * srcLong
    }

    private func stageGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if tool == .brush {
                    liveStroke.append(value.location)
                } else if compare, rect.width > 0 {
                    split = ((value.location.x - rect.minX) / rect.width).clamped(0, 1)
                }
            }
            .onEnded { _ in
                if tool == .brush { commitStroke(rect: rect) }
            }
    }

    private func commitStroke(rect: CGRect) {
        let points = liveStroke
        liveStroke = []
        guard !points.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let norm = points.map {
            NormPoint(x: Double(($0.x - rect.minX) / rect.width), y: Double(($0.y - rect.minY) / rect.height))
        }
        let radius = brushSize * 0.006
        if model.recipe.kind == .flat {
            model.addStroke(BrushStroke(mode: .paintWhite, radius: radius, points: norm))
        } else if let map = model.outputToSource {
            model.addStroke(BrushStroke(mode: brushMode, radius: radius, points: norm.map { map.toParent($0) }))
        }
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
                Path { p in
                    p.addLines(pts)
                    p.closeSubpath()
                }
                .fill(Palette.blue.opacity(0.15))
                Path { p in
                    p.addLines(pts)
                    p.closeSubpath()
                }
                .stroke(.white, lineWidth: 2)
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Palette.blue, lineWidth: 3))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                        .position(pts[i])
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("cropStage"))
                                .onChanged { value in
                                    var q = model.recipe.corners ?? .full
                                    q[i] = NormPoint(x: Double((value.location.x - rect.minX) / rect.width),
                                                     y: Double((value.location.y - rect.minY) / rect.height)).clampedToUnit()
                                    model.recipe.corners = q
                                }
                                .onEnded { _ in model.cornersChanged() }
                        )
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(.named("cropStage"))
        } else {
            ProgressView()
                .frame(width: size.width, height: size.height)
                .task { await model.loadSource() }
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
        case .crop: t = flat ? "拖曳四個白點對準紙張四角，放開後會自動重新處理。" : "勞作會自動裁切到作品周圍。"
        case .brush:
            if flat { t = "在髒點上塗抹，會塗成白色。只建議用在空白紙面。" }
            else { t = brushMode == .restore ? "塗抹被誤刪的作品部分，把它補回來。" : "塗抹要去掉的背景部分。" }
        default: t = compare ? "左右拖曳白線，比較前後" : "看起來可以了，就存到手機。"
        }
        if flat, tool != .crop, model.recipe.removeSpecks, model.specksRemoved > 0 {
            t += " · 已自動清掉 \(model.specksRemoved) 個小黑點"
        }
        return t
    }

    private var toolBar: some View {
        HStack {
            ForEach(EditTool.allCases) { t in
                let disabled = t == .crop && model.recipe.kind == .craft
                Button {
                    tool = (tool == t) ? nil : t
                    if tool == .crop { Task { await model.loadSource() } }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.systemImage)
                            .font(.title3)
                            .frame(width: 46, height: 36)
                            .background(RoundedRectangle(cornerRadius: 12).fill(tool == t ? t.tint : t.tint.opacity(0.15)))
                            .foregroundStyle(tool == t ? Color.white : Palette.ink)
                        Text(t.label).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.35 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            ShareLink(item: shareItem, preview: SharePreview(artwork.displayTitle, image: Image(systemName: "photo"))) {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                isSaving = true
                let model = self.model, artwork = self.artwork, app = self.app, context = modelContext
                Task {
                    await Self.commit(model: model, artwork: artwork, app: app, context: context)
                    _ = await app.saveToPhotos(artwork, context: context)
                    isSaving = false
                }
            } label: {
                HStack {
                    if isSaving { ProgressView().tint(.white) }
                    Label("存到手機", systemImage: "square.and.arrow.down")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var shareItem: ShareableArtwork {
        ShareableArtwork(id: artwork.id, originalData: model.originalData, recipe: model.recipe,
                         captionTitle: app.captionTitle(artwork), captionDetail: app.captionDetail(artwork),
                         captionBackground: app.captionBackground(model.recipe))
    }

    @ViewBuilder
    private func panel(for tool: EditTool) -> some View {
        switch tool {
        case .crop: CropPanel(model: model)
        case .adjust: AdjustPanel(model: model)
        case .brush: BrushPanel(model: model, brushMode: $brushMode, brushSize: $brushSize)
        case .info: InfoPanel(artwork: artwork, model: model)
        }
    }

    /// Writes the recipe back and re-renders the full-size output if anything changed.
    private static func commit(model: EditModel, artwork: Artwork, app: AppModel, context: ModelContext) async {
        guard model.isDirty else { return }
        artwork.recipe = model.recipe
        artwork.kind = model.recipe.kind
        model.markSaved()
        await app.rerender(artwork, context: context)
    }
}
