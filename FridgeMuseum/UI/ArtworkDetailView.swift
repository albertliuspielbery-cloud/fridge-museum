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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                printPanel
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
                        .accessibilityLabel(Text("編輯說明牌"))
                    }
                if !artwork.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(artwork.tags, id: \.self) { t in
                            ChipLabel(title: "#\(t)", selected: false)
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
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .background(Wallpaper())
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .navigationTitle(Text(verbatim: artwork.placardTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    artwork.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: artwork.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(artwork.isFavorite ? Palette.yellow : Palette.ink)
                }
                .accessibilityLabel(artwork.isFavorite ? Text("取消最愛") : Text("加到最愛"))
                .sensoryFeedback(.selection, trigger: artwork.isFavorite)
                Menu {
                    Button { showLabel = true } label: { Label("編輯說明牌", systemImage: "text.below.photo") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("刪除", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Palette.ink)
                }
                .accessibilityLabel(Text("更多"))
            }
        }
        .confirmationDialog(Text("刪除這件作品？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(role: .destructive) {
                let a = artwork
                dismiss()
                app.delete(a, context: modelContext)
            } label: {
                Text("刪除")
            }
        } message: {
            Text("只會刪除 App 裡的資料，已存到照片的不受影響。")
        }
        .sheet(isPresented: $showLabel) {
            LabelSheet(artwork: artwork, model: EditModel(artwork: artwork))
        }
        .overlay(alignment: .topLeading) {
            if DemoMode.scene("detail"), artwork.thumbnailData != nil { ReadyMarker() }
        }
    }

    private var printPanel: some View {
        HungPrint(id: artwork.id, tilt: 1.2, tape: .stripe, padding: 10) {
            Group {
                if let data = artwork.renderedImageData ?? artwork.thumbnailData, let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    ArtworkImage(artwork: artwork)
                }
            }
            .frame(maxHeight: 420)
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
                Label("編輯", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(SecondaryCapsuleStyle())
            ShareLink(item: shareItem, preview: SharePreview(artwork.placardTitle, image: Image("bibi-proud"))) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryCapsuleStyle())
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
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Palette.wall.opacity(0.94).ignoresSafeArea(edges: .bottom))
    }

    private var shareItem: ShareableArtwork {
        ShareableArtwork(id: artwork.id, originalData: artwork.originalImageData ?? Data(), recipe: artwork.recipe,
                         captionTitle: app.captionTitle(artwork), captionDetail: app.captionDetail(artwork),
                         captionBackground: app.captionBackground(artwork.recipe))
    }
}
