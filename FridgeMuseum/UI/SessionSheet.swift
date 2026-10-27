import SwiftData
import SwiftUI

/// 這次收的作品: the current capture batch.
struct SessionSheet: View {
    let artworks: [Artwork]
    let open: (UUID) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var savingAll = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if artworks.isEmpty {
                    ContentUnavailableView("這次還沒有作品", systemImage: "camera", description: Text("按下快門開始收作品"))
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(artworks) { artwork in
                            Button { open(artwork.id) } label: {
                                ArtworkThumb(artwork: artwork, processing: app.processingIDs.contains(artwork.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    Text("點一張可以調整、加資料。原始照片都會保留。")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }
            }
            .background(Palette.paper)
            .navigationTitle("這次收的作品（\(artworks.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        savingAll = true
                        Task {
                            await app.saveAll(artworks, context: modelContext)
                            savingAll = false
                        }
                    } label: {
                        if savingAll { ProgressView() } else { Text("全部存到手機") }
                    }
                    .disabled(artworks.isEmpty || savingAll)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("開始新的一批") {
                        app.sessionArtworkIDs = []
                        dismiss()
                    }
                    .disabled(artworks.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
