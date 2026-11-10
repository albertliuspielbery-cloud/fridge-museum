import SwiftData
import SwiftUI

/// One artwork in the museum: the print on the fridge door, its museum label (title, artist + age, medium, date),
/// tags, the child's voice note, and edit / share / save / delete.
struct ArtworkDetailView: View {
    @Bindable var artwork: Artwork
    let open: (Route) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var isSaving = false
    @State private var showLabel = false
    /// Delete only after the screen is gone, so no view reads a deleted model.
    @State private var deleteOnDisappear = false
    /// The print, decoded once per render version (downsampled off the main actor), not on every body pass.
    @State private var display: UIImage?
    @State private var labelModel: EditModel?
    /// The page's size: 700 pt and wider (iPad) puts the print on the left and the label column on the right.
    @State private var pageSize: CGSize = .zero
    @AppStorage(AutoTags.settingKey) private var showAutoTags = true

    private var isWide: Bool { pageSize.width >= 700 }

    var body: some View {
        Group {
            if isWide { wideLayout } else { narrowLayout }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0 }
        .ignoresSafeArea(.keyboard)
        .background(Wallpaper())
        .navigationTitle(Text(verbatim: artwork.placardTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    artwork.isFavorite.toggle()
                    artwork.touch()
                    try? modelContext.save()
                } label: {
                    Image(systemName: artwork.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(artwork.isFavorite ? Palette.yellow : Palette.ink)
                }
                .accessibilityLabel(artwork.isFavorite ? Text("取消最愛") : Text("加到最愛"))
                .sensoryFeedback(.selection, trigger: artwork.isFavorite)
                Menu {
                    ShareCardMenuItems(artwork: artwork, preview: shareImage)
                    Button { showLabel = true } label: { Label("編輯說明牌", systemImage: "text.below.photo") }
                    if !artwork.isTrashed {
                        Button(role: .destructive) { confirmDelete = true } label: { Label("刪除", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Palette.ink)
                }
                // iPad: the dialog's popover points at the More button.
                .confirmationDialog(Text("刪除這件作品？"), isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button(role: .destructive) {
                        deleteOnDisappear = true
                        dismiss()
                    } label: {
                        Text("刪除")
                    }
                } message: {
                    Text("會移到「最近刪除」，30 天內可以復原。已存到照片的不受影響。")
                }
                .accessibilityLabel(Text("更多"))
            }
        }
        .task(id: artwork.renderVersion) {
            guard let data = artwork.renderedImageData ?? artwork.thumbnailData else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageMetadata.uprightThumbnail(of: data, maxPixelSize: 1600).map { RenderedImage(cgImage: $0) }
            }.value
            if let decoded { display = UIImage(cgImage: decoded.cgImage) }
        }
        .onChange(of: showLabel) { _, show in
            if show, labelModel == nil { labelModel = EditModel(artwork: artwork) }
        }
        .onDisappear {
            if deleteOnDisappear {
                deleteOnDisappear = false
                app.delete(artwork, context: modelContext)
            }
        }
        .sheet(isPresented: $showLabel) {
            if let labelModel { LabelSheet(artwork: artwork, model: labelModel) }
        }
        .overlay(alignment: .topLeading) {
            if DemoMode.scene("detail"), artwork.thumbnailData != nil { ReadyMarker() }
        }
        .modifier(ShareCardDemoScene(artwork: artwork))
    }

    /// iPhone and narrow iPad windows: one column, actions pinned at the bottom.
    private var narrowLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                printPanel(maxPrintHeight: DemoMode.compactDetail ? 250 : 420)
                labelColumn
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
    }

    /// iPad: the print fills the left; the label, tags, the child's words and the actions sit in a 360 pt column.
    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 24) {
            printPanel(maxPrintHeight: max(300, pageSize.height * 0.72))
                .frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) { labelColumn }
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
                actionBar
            }
            .frame(width: 360)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    @ViewBuilder private var labelColumn: some View {
        // Opened from a stale widget link, or trashed on another device while open.
        if artwork.isTrashed {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(Palette.muted)
                Text("這件作品在「最近刪除」裡").font(.fm(15, bold: true)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Button { app.restore([artwork], context: modelContext) } label: { Text("復原") }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.teal)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface))
        }
        Placard(title: artwork.placardTitle, lines: [artwork.placardArtist, artwork.placardMedium, artwork.placardTerm])
            .padding(.horizontal, 6)
            .overlay(alignment: .topTrailing) {
                Button { showLabel = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Palette.tealInk)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Palette.tealSoft))
                }
                .buttonStyle(.plain)
                .padding(14)
                .environment(\.colorScheme, .light)
                .hoverEffect(.lift)
                .accessibilityLabel(Text("編輯說明牌"))
            }
        let autoNames = showAutoTags ? artwork.autoTagNames.filter { !artwork.tags.contains($0) } : []
        if !artwork.tags.isEmpty || !autoNames.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(artwork.tags, id: \.self) { t in
                    ChipLabel(title: "#\(t)", selected: false)
                }
                // 自動標籤: lighter, so they read as suggestions the app added.
                ForEach(autoNames, id: \.self) { t in
                    ChipLabel(title: "#\(t)", selected: false)
                        .opacity(0.6)
                        .accessibilityLabel(Text("自動標籤 \(t)"))
                }
            }
        }
        if !artwork.note.isEmpty || artwork.voiceNoteData != nil || !artwork.voiceTranscript.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("孩子說", systemImage: "quote.bubble")
                    .font(.fm(15, bold: true)).foregroundStyle(Palette.muted)
                if !artwork.note.isEmpty {
                    Text(verbatim: artwork.note).font(.fm(16)).foregroundStyle(Palette.ink)
                }
                VoiceNoteRow(artwork: artwork)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface))
        } else {
            VoiceNoteRow(artwork: artwork)
        }
    }

    private func printPanel(maxPrintHeight: CGFloat) -> some View {
        HungPrint(id: artwork.id, tilt: 1.2, tape: .stripe, padding: 10) {
            Group {
                if let display {
                    Image(uiImage: display).resizable().scaledToFit()
                } else {
                    ArtworkImage(artwork: artwork)
                }
            }
            // The paper hugs the artwork: without a width cap a wide page stretched the print into a banner.
            .frame(maxWidth: maxPrintHeight * printAspect, maxHeight: maxPrintHeight)
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .background(FridgeDoorShape(top: 30, bottom: 30, handleHeight: 90).padding(.trailing, 10))
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { open(.edit(artwork.id)) } label: {
                RoundKnob(systemImage: "slider.horizontal.3", size: 54)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("編輯"))
            ShareMenuKnob(artwork: artwork, photoItem: shareItem, preview: shareImage)
            Button {
                isSaving = true
                Task {
                    _ = await app.saveToPhotos(artwork, context: modelContext)
                    isSaving = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().tint(Palette.primaryInk) } else { Image(systemName: "square.and.arrow.down") }
                    Text("存到手機")
                }
            }
            .buttonStyle(PrimaryCapsuleStyle())
            .disabled(isSaving)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, isWide ? 0 : Metrics.gutter)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Palette.wall.opacity(0.94).ignoresSafeArea(edges: .bottom))
    }

    /// Width ÷ height of the print (the decoded image, else the stored pixel size, else a sheet of paper).
    private var printAspect: CGFloat {
        if let display, display.size.height > 0 { return display.size.width / display.size.height }
        if artwork.pixelWidth > 0, artwork.pixelHeight > 0 { return CGFloat(artwork.pixelWidth) / CGFloat(artwork.pixelHeight) }
        return 0.75
    }

    private var shareItem: ShareableArtwork? {
        ShareableArtwork(artwork: artwork, recipe: artwork.recipe, app: app)
    }

    private var shareImage: Image {
        if let display { return Image(uiImage: display) }
        return Image("bibi-proud")
    }
}
