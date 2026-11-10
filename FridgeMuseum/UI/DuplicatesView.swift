import SwiftData
import SwiftUI

/// 找重複作品 (1.4.0): look-alike museum artworks, one pair at a time. 留這張 keeps one (it takes over what only the
/// other had) and moves the other to 最近刪除; 不是重複 remembers the pair on this device. Nothing is deleted without
/// a choice.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Artwork> { $0.isKept && !$0.isSample && $0.deletedAt == nil }) private var museum: [Artwork]

    @State private var pairs: [DuplicateFinder.Pair] = []
    @State private var loaded = false
    @State private var handled = 0

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let pair = current {
                    compare(pair)
                } else {
                    done
                }
            }
            .background(Palette.wall.ignoresSafeArea())
            .navigationTitle(Text("找重複作品"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("完成") }
                }
            }
        }
        .task { await find() }
    }

    private func artwork(_ id: UUID) -> Artwork? { museum.first { $0.id == id && AppModel.isAlive($0) } }

    /// The first pair whose two artworks are both still in the museum.
    private var current: DuplicateFinder.Pair? {
        pairs.first { artwork($0.first) != nil && artwork($0.second) != nil }
    }

    private var remaining: Int {
        pairs.filter { artwork($0.first) != nil && artwork($0.second) != nil }.count
    }

    private func find() async {
        let entries = museum.compactMap { a -> DuplicateFinder.Entry? in
            guard AppModel.isAlive(a), let fp = ArtFingerprint(data: a.fingerprintData) else { return nil }
            return DuplicateFinder.Entry(id: a.id, kindRaw: a.kindRaw, fingerprint: fp)
        }
        let ignored = DuplicateIgnoreList.load()
        pairs = await Task.detached(priority: .userInitiated) {
            DuplicateFinder.pairs(among: entries, ignoring: ignored)
        }.value
        loaded = true
    }

    private func compare(_ pair: DuplicateFinder.Pair) -> some View {
        let a = artwork(pair.first)!, b = artwork(pair.second)!
        return ScrollView {
            VStack(spacing: 18) {
                Text("這兩件很像，要留哪一件？（還有 \(remaining) 組）")
                    .font(.fmDisplay(20, relativeTo: .title3))
                    .foregroundStyle(Palette.title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 14) {
                    side(a, other: b)
                    side(b, other: a)
                }
                Text("沒留的那件會移到「最近刪除」，30 天內可以復原；它的標題、備註、標籤和錄音會併到留下的那件。")
                    .font(.fm(13.5)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    DuplicateIgnoreList.add(pair)
                    pairs.removeAll { $0 == pair }
                } label: {
                    Text("不是重複，兩件都留")
                }
                .buttonStyle(SecondaryCapsuleStyle())
                .frame(maxWidth: 420)
            }
            .padding(Metrics.gutter)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private func side(_ keep: Artwork, other: Artwork) -> some View {
        VStack(spacing: 10) {
            ArtworkImage(artwork: keep)
                .aspectRatio(keep.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 360)
                .padding(6)
                .background(Palette.print)
                .shadow(color: Palette.printShadow, radius: 5, y: 3)
            Placard(artwork: keep, compact: true)
            Button {
                DuplicateMerge.fill(keep, from: other)
                app.moveToTrash(other, context: modelContext, save: false)
                try? modelContext.save()
                handled += 1
            } label: {
                Text("留這張")
            }
            .buttonStyle(PrimaryCapsuleStyle())
            .hoverEffect(.lift)
        }
        .frame(maxWidth: .infinity)
    }

    private var done: some View {
        VStack(spacing: 12) {
            Image(handled > 0 ? "bibi-proud" : "bibi-empty").resizable().scaledToFit().frame(height: 140)
                .accessibilityHidden(true)
            Text(handled > 0 ? "整理好了！" as LocalizedStringKey : "沒有找到重複的作品")
                .font(.fmDisplay(22)).foregroundStyle(Palette.title)
            if handled > 0 {
                Text("沒留的作品在「最近刪除」，30 天內可以復原。")
                    .font(.fm(15)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
