import SwiftData
import SwiftUI

/// 美術館: every artwork, filterable by child / type / favorites / tag, grouped by age, semester or year.
struct GalleryView: View {
    enum ChildFilter: Hashable {
        case all
        case unassigned
        case child(UUID)
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case age, term, year, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .age: "依年齡"
            case .term: "依學期"
            case .year: "依年份"
            case .none: "不分組"
            }
        }
    }

    struct GallerySection: Identifiable {
        let id: String
        let title: String
        var subtitle: String?
        var sortKey: Int
        var items: [Artwork]
    }

    let openArtwork: (UUID) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Artwork.capturedAt, order: .reverse) private var artworks: [Artwork]
    @Query(sort: \Child.createdAt) private var children: [Child]

    @State private var childFilter: ChildFilter = .all
    @State private var kindFilter: ArtworkKind?
    @State private var favoritesOnly = false
    @State private var tagFilter: String?
    @AppStorage("galleryGrouping") private var groupingRaw = Grouping.age.rawValue
    @AppStorage("galleryNewestFirst") private var newestFirst = true
    @AppStorage("useAlbums") private var useAlbums = true
    @State private var editingChild: Child?
    @State private var showNewChild = false
    @State private var pendingDelete: Artwork?
    @State private var showDeleteConfirm = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    private var grouping: Grouping { Grouping(rawValue: groupingRaw) ?? .age }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                filterBar
                let list = filtered
                if list.isEmpty {
                    ContentUnavailableView(artworks.isEmpty ? "美術館還是空的" : "沒有符合的作品",
                                           systemImage: "photo.on.rectangle.angled",
                                           description: Text(artworks.isEmpty ? "回到相機，拍下第一張作品吧！" : "換個篩選條件試試"))
                        .padding(.top, 40)
                } else {
                    ForEach(sections(list)) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Palette.paper.ignoresSafeArea())
        .navigationTitle("冰箱美術館")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
        }
        .sheet(item: $editingChild) { child in
            ChildEditorView(child: child)
        }
        .sheet(isPresented: $showNewChild) {
            ChildEditorView(child: nil)
        }
        .confirmationDialog("刪除這件作品？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                if let a = pendingDelete { app.delete(a, context: modelContext) }
                pendingDelete = nil
            }
        } message: {
            Text("只會刪除 App 裡的資料，已存到照片的不受影響。")
        }
    }

    // MARK: Filters

    private var allTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for a in artworks {
            for t in a.tags where !seen.contains(t) {
                seen.insert(t)
                out.append(t)
            }
        }
        return out.sorted()
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(title: "全部", systemImage: nil, selected: childFilter == .all) { childFilter = .all }
                    ForEach(children) { c in
                        Chip(title: c.displayName, systemImage: nil, selected: childFilter == .child(c.id),
                             tint: Color(hex: c.avatarColorHex)) { childFilter = .child(c.id) }
                            .contextMenu {
                                Button("編輯 \(c.displayName)", systemImage: "pencil") { editingChild = c }
                            }
                    }
                    if artworks.contains(where: { $0.child == nil }) {
                        Chip(title: "未分類", systemImage: nil, selected: childFilter == .unassigned) { childFilter = .unassigned }
                    }
                    Chip(title: "新增", systemImage: "plus", selected: false) { showNewChild = true }
                }
                .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ArtworkKind.allCases) { k in
                        Chip(title: k.label, systemImage: nil, selected: kindFilter == k, tint: Palette.color(for: k)) {
                            kindFilter = kindFilter == k ? nil : k
                        }
                    }
                    Chip(title: "最愛", systemImage: "star.fill", selected: favoritesOnly, tint: Palette.yellow) {
                        favoritesOnly.toggle()
                    }
                    ForEach(allTags, id: \.self) { t in
                        Chip(title: "#\(t)", systemImage: nil, selected: tagFilter == t, tint: Palette.green) {
                            tagFilter = tagFilter == t ? nil : t
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("分組", selection: $groupingRaw) {
                ForEach(Grouping.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("排序", selection: $newestFirst) {
                Text("新的在前").tag(true)
                Text("舊的在前").tag(false)
            }
            Divider()
            Toggle("存到照片時依小朋友分相簿", isOn: $useAlbums)
            Divider()
            ForEach(children) { c in
                Button("編輯 \(c.displayName)", systemImage: "person.crop.circle") { editingChild = c }
            }
            Button("新增小朋友", systemImage: "person.badge.plus") { showNewChild = true }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("篩選與設定")
    }

    private var filtered: [Artwork] {
        var list = artworks.filter { a in
            switch childFilter {
            case .all: break
            case .unassigned: if a.child != nil { return false }
            case .child(let id): if a.child?.id != id { return false }
            }
            if let k = kindFilter, a.kind != k { return false }
            if favoritesOnly && !a.isFavorite { return false }
            if let t = tagFilter, !a.tags.contains(t) { return false }
            return true
        }
        if !newestFirst { list.reverse() }
        return list
    }

    // MARK: Sections

    private func sections(_ list: [Artwork]) -> [GallerySection] {
        var out: [GallerySection] = []
        var index: [String: Int] = [:]
        let multipleChildren = childFilter == .all && Set(list.compactMap { $0.child?.id }).count > 1
        for a in list {
            let (key, title, subtitle, sortKey) = groupKey(a, multipleChildren: multipleChildren)
            if let i = index[key] {
                out[i].items.append(a)
            } else {
                index[key] = out.count
                out.append(GallerySection(id: key, title: title, subtitle: subtitle, sortKey: sortKey, items: [a]))
            }
        }
        if grouping != .none {
            out.sort { newestFirst ? $0.sortKey > $1.sortKey : $0.sortKey < $1.sortKey }
        }
        return out
    }

    private func groupKey(_ a: Artwork, multipleChildren: Bool) -> (String, String, String?, Int) {
        let cal = Calendar.current
        let year = cal.component(.year, from: a.capturedAt)
        let prefix = multipleChildren ? "\(a.child?.displayName ?? "未分類") · " : ""
        let childKey = a.child?.id.uuidString ?? "none"
        switch grouping {
        case .age:
            if let age = a.ageAtCreation {
                // Sort by date of the newest item rather than age, so siblings interleave by time.
                return ("age-\(childKey)-\(age.years)", prefix + age.yearLabel, nil, year * 100 + age.years)
            }
            return ("year-\(childKey)-\(year)", prefix + "\(year) 年", "還沒填生日", year * 100)
        case .term:
            let term = a.schoolTerm
            return ("term-\(term.sortKey)", term.label, multipleChildren ? nil : a.gradeLabel, term.sortKey)
        case .year:
            return ("year-\(year)", "\(year) 年", nil, year)
        case .none:
            return ("all", "全部作品", nil, 0)
        }
    }

    private func sectionView(_ section: GallerySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title).font(.title3.weight(.bold)).foregroundStyle(Palette.ink)
                if let s = section.subtitle {
                    Text(s).font(.subheadline).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text("\(section.items.count) 件").font(.footnote).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 16)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(section.items) { a in
                    Button { openArtwork(a.id) } label: {
                        ArtworkThumb(artwork: a, processing: app.processingIDs.contains(a.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(a.isFavorite ? "取消最愛" : "加到最愛", systemImage: a.isFavorite ? "star.slash" : "star") {
                            a.isFavorite.toggle()
                            try? modelContext.save()
                        }
                        Button("存到手機", systemImage: "square.and.arrow.down") {
                            Task { _ = await app.saveToPhotos(a, context: modelContext) }
                        }
                        Button("刪除", systemImage: "trash", role: .destructive) {
                            pendingDelete = a
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
