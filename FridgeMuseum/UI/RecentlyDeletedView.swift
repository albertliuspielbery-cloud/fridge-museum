import SwiftData
import SwiftUI

/// 最近刪除 (1.4.0): museum artworks deleted in the last 30 days. Tap prints to select them, then 復原 (back on the
/// wall) or 永久刪除; with nothing selected the buttons act on everything. Opened from Settings and the museum.
struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Artwork> { $0.isKept && !$0.isSample && $0.deletedAt != nil },
           sort: \Artwork.deletedAt, order: .reverse) private var trashed: [Artwork]

    @State private var selection: Set<UUID> = []
    @State private var confirmDelete = false

    private var alive: [Artwork] { trashed.filter { AppModel.isAlive($0) } }
    private var targets: [Artwork] { selection.isEmpty ? alive : alive.filter { selection.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Group {
                if alive.isEmpty {
                    empty
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("作品會在這裡保留 30 天，之後自動永久刪除。點選作品可以只復原或刪除其中幾件。")
                                .font(.fm(14)).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16)],
                                      alignment: .leading, spacing: 20) {
                                ForEach(alive) { artwork in tile(artwork) }
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 1000)
                        .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { actions }
                }
            }
            .background(Palette.wall.ignoresSafeArea())
            .overlay(alignment: .topLeading) {
                if DemoMode.scene("trash"), !alive.isEmpty { ReadyMarker() }
            }
            .navigationTitle(Text("最近刪除"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("完成") }
                }
            }
        }
    }

    private func tile(_ artwork: Artwork) -> some View {
        let selected = selection.contains(artwork.id)
        return Button {
            if selected { selection.remove(artwork.id) } else { selection.insert(artwork.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkImage(artwork: artwork)
                    .aspectRatio(artwork.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .padding(6)
                    .background(Palette.print)
                    .shadow(color: Palette.printShadow, radius: 5, y: 3)
                    .overlay(alignment: .topLeading) {
                        SelectionMark(selected: selected, size: 24).padding(8)
                    }
                    .opacity(selection.isEmpty || selected ? 1 : 0.7)
                Text(verbatim: artwork.placardTitle)
                    .font(.fm(14, bold: true)).foregroundStyle(Palette.ink).lineLimit(1)
                if let left = TrashPolicy.daysLeft(deletedAt: artwork.deletedAt, now: Date()) {
                    Text("還有 \(left) 天").font(.fm(12.5)).foregroundStyle(Palette.muted)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                let list = targets
                app.restore(list, context: modelContext)
                app.show(String(localized: "已復原 \(list.count) 件作品"))
                selection = []
            } label: {
                Text(selection.isEmpty ? "全部復原" : "復原 \(selection.count) 件")
            }
            .buttonStyle(SecondaryCapsuleStyle())
            Button { confirmDelete = true } label: {
                Text(selection.isEmpty ? "全部刪除" : "刪除 \(selection.count) 件")
            }
            .buttonStyle(SecondaryCapsuleStyle(ink: Palette.warn))
            .confirmationDialog(Text("永久刪除 \(targets.count) 件作品？"), isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button(role: .destructive) {
                    let list = targets
                    for artwork in list { app.deleteForever(artwork, context: modelContext, save: false) }
                    try? modelContext.save()
                    selection = []
                } label: {
                    Text("永久刪除")
                }
            } message: {
                Text("刪除後就不能復原了。已存到照片的不受影響。")
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Palette.wall.opacity(0.95).ignoresSafeArea(edges: .bottom))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image("bibi-empty").resizable().scaledToFit().frame(height: 140)
                .accessibilityHidden(true)
            Text("最近刪除是空的").font(.fmDisplay(22)).foregroundStyle(Palette.title)
            Text("刪掉的作品會在這裡放 30 天，可以隨時復原。")
                .font(.fm(15)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
