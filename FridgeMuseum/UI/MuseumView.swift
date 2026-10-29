import SwiftData
import SwiftUI

/// 美術館 — every kept artwork, per child or all, filterable by 畫作/勞作, school year & semester, age, tags and ⭐,
/// grouped into semester sections with crayon headers.
struct MuseumView: View {
    enum ChildFilter: Hashable {
        case all
        case unassigned
        case child(UUID)
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case term, age, year, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .term: String(localized: "依學期")
            case .age: String(localized: "依年齡")
            case .year: String(localized: "依年份")
            case .none: String(localized: "不分組")
            }
        }
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        var subtitle: String?
        var sortKey: Int
        var items: [Artwork]
    }

    let open: (Route) -> Void
    let showSettings: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Artwork.capturedAt, order: .reverse) private var allArtworks: [Artwork]
    @Query(sort: \Child.createdAt) private var children: [Child]

    @State private var childFilter: ChildFilter = .all
    @State private var kindFilter: ArtworkKind?
    @State private var favoritesOnly = false
    @State private var termFilter: SchoolTerm?
    @State private var ageFilter: Int?
    @State private var tagFilter: String?
    @AppStorage("museumGrouping") private var groupingRaw = Grouping.term.rawValue
    @AppStorage("museumNewestFirst") private var newestFirst = true
    /// 大圖 / 標準 / 小圖 (MuseumLayout.swift).
    @AppStorage(MuseumViewMode.storageKey) private var viewModeRaw = MuseumViewMode.standard.rawValue
    @State private var contentWidth: CGFloat = 0
    @State private var viewer: MuseumViewerStart?
    @Environment(\.displayScale) private var displayScale
    @State private var editingChild: Child?
    @State private var showNewChild = false
    // 選取: change several artworks at once.
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var batchSheet: BatchSheet?
    @State private var confirmBatchDelete = false
    @State private var batchSaving = false

    enum BatchSheet: String, Identifiable {
        case tags, date
        var id: String { rawValue }
    }

    private var grouping: Grouping { Grouping(rawValue: groupingRaw) ?? .term }
    /// Demo screenshots pin their own mode, so a mode left over from another scene never leaks in.
    private var viewMode: MuseumViewMode { DemoMode.museumViewMode ?? MuseumViewMode(stored: viewModeRaw) }
    /// `isAlive` first: a batch delete must never make a view read a deleted model.
    private var artworks: [Artwork] { allArtworks.filter { AppModel.isAlive($0) && $0.isInMuseum } }

    /// Artworks matching the child filter only (drives the other menus' options).
    private var childScoped: [Artwork] {
        artworks.filter { a in
            switch childFilter {
            case .all: true
            case .unassigned: a.child == nil
            case .child(let id): a.child?.id == id
            }
        }
    }

    private var filtered: [Artwork] {
        var list = childScoped.filter { a in
            if let k = kindFilter, a.kind != k { return false }
            if favoritesOnly && !a.isFavorite { return false }
            if let t = termFilter, a.schoolTerm != t { return false }
            if let y = ageFilter, a.ageAtCreation?.years != y { return false }
            if let t = tagFilter, !a.tags.contains(t) { return false }
            return true
        }
        if !newestFirst { list.reverse() }
        return list
    }

    /// Selected artworks that the current filter shows (only these are changed).
    private var selectedArtworks: [Artwork] { filtered.filter { selection.contains($0.id) } }

    private var allVisibleSelected: Bool {
        let list = filtered
        return !list.isEmpty && list.allSatisfy { selection.contains($0.id) }
    }

    private var hasFilters: Bool {
        kindFilter != nil || favoritesOnly || termFilter != nil || ageFilter != nil || tagFilter != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                childShelf
                filterBar
                let list = filtered
                if artworks.isEmpty {
                    emptyMuseum
                } else if list.isEmpty {
                    noMatches
                } else {
                    HStack {
                        Text("共 \(list.count) 件").font(.fm(14, bold: true)).foregroundStyle(Palette.muted)
                        Spacer()
                        sortMenu
                    }
                    .padding(.horizontal, Metrics.gutter + 4)
                    let mode = viewMode
                    ForEach(sections(list)) { section in
                        sectionView(section, mode: mode)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        // Pinch the wall: in → smaller prints, out → bigger (one step per pinch).
        .simultaneousGesture(
            MagnifyGesture().onEnded { value in
                let next = viewMode.afterPinch(scale: value.magnification)
                if next != viewMode { setViewMode(next) }
            }
        )
        .sensoryFeedback(.selection, trigger: viewModeRaw)
        .background(Wallpaper())
        .navigationTitle(selecting ? Text("已選 \(selectedArtworks.count) 件") : Text("美術館"))
        .navigationBarBackButtonHidden(selecting)
        .toolbarBackground(Palette.wall, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selecting {
                    Button {
                        if allVisibleSelected { selection = [] } else { selection = Set(filtered.map(\.id)) }
                    } label: {
                        Text(allVisibleSelected ? "全不選" as LocalizedStringKey : "全選")
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                viewModeMenu
                    .disabled(artworks.isEmpty)
                if selecting {
                    Button {
                        withAnimation { endSelection() }
                    } label: {
                        Text("完成").font(.fm(17, bold: true))
                    }
                } else {
                    Button {
                        withAnimation { selecting = true }
                    } label: {
                        Text("選取")
                    }
                    .disabled(artworks.isEmpty)
                    Button(action: showSettings) { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text("設定"))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                MuseumSelectionBar(
                    count: selectedArtworks.count,
                    children: children,
                    saving: batchSaving,
                    onChild: batchAssign,
                    onTags: { batchSheet = .tags },
                    onDate: { batchSheet = .date },
                    onFavorite: batchFavorite,
                    onSave: batchSave,
                    onDelete: { confirmBatchDelete = true }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .sheet(item: $batchSheet) { sheet in
            switch sheet {
            case .tags:
                BatchTagSheet(count: selectedArtworks.count, existing: allTags) { tags in
                    let n = app.addTags(tags, to: selectedArtworks, context: modelContext)
                    if n > 0 { app.show(String(localized: "已幫 \(n) 件作品加上標籤")) }
                }
            case .date:
                BatchDateSheet(count: selectedArtworks.count, initial: selectedArtworks.first?.capturedAt ?? Date()) { date in
                    let n = app.setCapturedAt(date, for: selectedArtworks, context: modelContext)
                    if n > 0 { app.show(String(localized: "已改 \(n) 件作品的日期，學期和年齡也更新了")) }
                }
            }
        }
        .confirmationDialog(Text("刪除這 \(selectedArtworks.count) 件作品？"), isPresented: $confirmBatchDelete,
                            titleVisibility: .visible) {
            Button(role: .destructive) {
                batchDelete()
            } label: {
                Text("刪除 \(selectedArtworks.count) 件")
            }
        } message: {
            Text("只會刪除 App 裡的資料，已存到照片的不受影響。")
        }
        .sheet(item: $editingChild) { child in
            ChildEditorView(child: child)
        }
        .sheet(isPresented: $showNewChild) {
            ChildEditorView(child: nil)
        }
        .fullScreenCover(item: $viewer) { start in
            MuseumViewer(artworks: start.artworks, startID: start.id) { id in
                viewer = nil
                open(.detail(id))
            }
        }
        .task {
            if let preset = DemoMode.museumPreset(children: children) {
                childFilter = preset.child.map { .child($0) } ?? .all
                kindFilter = preset.kind
                favoritesOnly = preset.favorites
            }
        }
        .overlay(alignment: .topLeading) {
            if DemoMode.scene("museum", "museum-filter", "museum-small", "museum-large"), artworks.count >= 6, artworks.allSatisfy({ $0.thumbnailData != nil }) { ReadyMarker() }
        }
    }

    // MARK: Child shelf

    private var childShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                shelfItem(selected: childFilter == .all, title: String(localized: "全部"), count: artworks.count) {
                    Image("bibi-head").resizable().scaledToFit().frame(width: 40)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Palette.door))
                } action: {
                    childFilter = .all
                }
                ForEach(children) { c in
                    shelfItem(selected: childFilter == .child(c.id), title: c.displayName,
                              count: artworks.filter { $0.child?.id == c.id }.count) {
                        ChildAvatar(child: c, size: 58)
                    } action: {
                        childFilter = .child(c.id)
                    }
                    .contextMenu {
                        Button { editingChild = c } label: { Label("編輯 \(c.displayName)", systemImage: "pencil") }
                    }
                }
                if artworks.contains(where: { $0.child == nil }) {
                    shelfItem(selected: childFilter == .unassigned, title: String(localized: "未分類"),
                              count: artworks.filter { $0.child == nil }.count) {
                        Image(systemName: "questionmark")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(Palette.surface2))
                    } action: {
                        childFilter = .unassigned
                    }
                }
                shelfItem(selected: false, title: String(localized: "新增"), count: nil) {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Palette.teal)
                        .frame(width: 58, height: 58)
                        .background(Circle().strokeBorder(Palette.teal, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
                } action: {
                    showNewChild = true
                }
            }
            .padding(.horizontal, Metrics.gutter + 4)
            .padding(.vertical, 4)
        }
    }

    private func shelfItem<Avatar: View>(selected: Bool, title: String, count: Int?, @ViewBuilder avatar: () -> Avatar,
                                         action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(duration: 0.25)) { action() }
            termFilter = nil
            ageFilter = nil
        } label: {
            VStack(spacing: 5) {
                avatar()
                    .padding(3)
                    .overlay(Circle().strokeBorder(selected ? Palette.teal : Color.clear, lineWidth: 3))
                    .shadow(color: Palette.shadow, radius: selected ? 4 : 2, y: 2)
                Text(verbatim: title)
                    .font(.fm(13.5, bold: selected))
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                if let count {
                    Text("\(count) 件").font(.fm(11.5)).foregroundStyle(Palette.faint)
                }
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Filters

    private var terms: [SchoolTerm] {
        Array(Set(childScoped.map(\.schoolTerm))).sorted(by: >)
    }

    private var ages: [Int] {
        Array(Set(childScoped.compactMap { $0.ageAtCreation?.years })).sorted()
    }

    private var tags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for a in childScoped {
            for t in a.tags where !seen.contains(t) {
                seen.insert(t)
                out.append(t)
            }
        }
        return out.sorted()
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ArtworkKind.allCases) { k in
                    Chip(title: k.title, systemImage: nil, selected: kindFilter == k, tint: Palette.color(for: k)) {
                        kindFilter = kindFilter == k ? nil : k
                    }
                }
                Chip(title: String(localized: "最愛"), systemImage: "star.fill", selected: favoritesOnly, tint: Color(0xD99A14, 0xC98A10)) {
                    favoritesOnly.toggle()
                }
                Menu {
                    Button { termFilter = nil } label: { Text("全部學期") }
                    ForEach(terms, id: \.self) { t in
                        Button { termFilter = t } label: {
                            if termFilter == t { Label(t.localizedLabel, systemImage: "checkmark") } else { Text(verbatim: t.localizedLabel) }
                        }
                    }
                } label: {
                    ChipLabel(title: termFilter?.localizedLabel ?? String(localized: "學期"), systemImage: "calendar",
                              selected: termFilter != nil, tint: Palette.blue, showsMenuIndicator: true)
                }
                .disabled(terms.isEmpty)
                if !ages.isEmpty {
                    Menu {
                        Button { ageFilter = nil } label: { Text("全部年齡") }
                        ForEach(ages, id: \.self) { y in
                            let label = ChildAge(years: y, months: 0).localizedYearLabel
                            Button { ageFilter = y } label: {
                                if ageFilter == y { Label(label, systemImage: "checkmark") } else { Text(verbatim: label) }
                            }
                        }
                    } label: {
                        ChipLabel(title: ageFilter.map { ChildAge(years: $0, months: 0).localizedYearLabel } ?? String(localized: "年齡"),
                                  systemImage: "birthday.cake", selected: ageFilter != nil, tint: Palette.pink, showsMenuIndicator: true)
                    }
                }
                if !tags.isEmpty {
                    Menu {
                        Button { tagFilter = nil } label: { Text("全部標籤") }
                        ForEach(tags, id: \.self) { t in
                            Button { tagFilter = t } label: {
                                if tagFilter == t { Label(String("#\(t)"), systemImage: "checkmark") } else { Text(verbatim: "#\(t)") }
                            }
                        }
                    } label: {
                        ChipLabel(title: tagFilter.map { "#\($0)" } ?? String(localized: "標籤"), systemImage: "tag",
                                  selected: tagFilter != nil, tint: Palette.green, showsMenuIndicator: true)
                    }
                }
                if hasFilters {
                    Button {
                        withAnimation {
                            kindFilter = nil; favoritesOnly = false; termFilter = nil; ageFilter = nil; tagFilter = nil
                        }
                    } label: {
                        Label("清除", systemImage: "xmark.circle.fill")
                            .font(.fm(14.5, bold: true))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 8)
                            .frame(height: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.gutter + 4)
            .padding(.vertical, 2)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(selection: $newestFirst) {
                Text("新的在前").tag(true)
                Text("舊的在前").tag(false)
            } label: {
                Text("排序")
            }
            Picker(selection: $groupingRaw) {
                ForEach(Grouping.allCases) { Text(verbatim: $0.title).tag($0.rawValue) }
            } label: {
                Text("分組")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                Text(newestFirst ? "新的在前" as LocalizedStringKey : "舊的在前")
            }
            .font(.fm(14, bold: true))
            .foregroundStyle(Palette.tealInk)
        }
    }

    // MARK: View mode (大圖 / 標準 / 小圖)

    private var viewModeMenu: some View {
        Menu {
            Picker(selection: Binding(get: { viewMode }, set: { setViewMode($0) })) {
                ForEach(MuseumViewMode.menuOrder) { m in
                    Label(m.title, systemImage: m.systemImage).tag(m)
                }
            } label: {
                Text("顯示方式")
            }
        } label: {
            Image(systemName: viewMode.systemImage)
        }
        .accessibilityLabel(Text("顯示方式"))
        .accessibilityValue(Text(verbatim: viewMode.title))
    }

    private func setViewMode(_ mode: MuseumViewMode) {
        withAnimation(.snappy(duration: 0.3)) { viewModeRaw = mode.rawValue }
    }

    @ViewBuilder
    private func tile(_ a: Artwork, mode: MuseumViewMode) -> some View {
        let processing = app.processingIDs.contains(a.id)
        switch mode {
        case .standard:
            MuseumTile(artwork: a, processing: processing, showChild: childFilter == .all)
        case .small:
            MuseumSmallTile(artwork: a, processing: processing, showChild: childFilter == .all)
        case .large:
            // Print width minus HungPrint's 10 pt mat on each side.
            MuseumLargeTile(artwork: a, processing: processing,
                            pixelSize: MuseumViewMode.largePixelSize(
                                widthPoints: mode.tileWidth(containerWidth: contentWidth) - 20,
                                aspect: a.aspectRatio, scale: displayScale))
        }
    }

    // MARK: Sections

    private func sections(_ list: [Artwork]) -> [Section] {
        var out: [Section] = []
        var index: [String: Int] = [:]
        let singleChild: Child? = {
            if case .child(let id) = childFilter { return children.first { $0.id == id } }
            return nil
        }()
        for a in list {
            let (key, title, subtitle, sortKey) = groupKey(a, singleChild: singleChild)
            if let i = index[key] {
                out[i].items.append(a)
            } else {
                index[key] = out.count
                out.append(Section(id: key, title: title, subtitle: subtitle, sortKey: sortKey, items: [a]))
            }
        }
        if grouping != .none {
            out.sort { newestFirst ? $0.sortKey > $1.sortKey : $0.sortKey < $1.sortKey }
        }
        return out
    }

    private func groupKey(_ a: Artwork, singleChild: Child?) -> (String, String, String?, Int) {
        let year = Calendar.current.component(.year, from: a.capturedAt)
        switch grouping {
        case .term:
            let term = a.schoolTerm
            var subtitle: String?
            if let b = singleChild?.birthday, let g = term.localizedGrade(birthday: b) {
                subtitle = AppLanguage.isChinese ? "\(singleChild?.displayName ?? "")・\(g)" : "\(singleChild?.displayName ?? "") · \(g)"
            } else if AppLanguage.isChinese {
                subtitle = term.half == .first ? String(localized: "8 月 – 1 月") : String(localized: "2 月 – 7 月")
            } else {
                subtitle = term.localizedYear
            }
            return ("term-\(term.sortKey)", term.localizedLabel, subtitle, term.sortKey)
        case .age:
            if let age = a.ageAtCreation {
                let name = singleChild == nil ? (a.child?.displayName ?? "") : nil
                return ("age-\(a.child?.id.uuidString ?? "")-\(age.years)", age.localizedYearLabel, name, year * 100 + age.years)
            }
            return ("year-none-\(year)", String(localized: "\(String(year)) 年"), String(localized: "還沒填生日"), year * 100)
        case .year:
            return ("year-\(year)", String(localized: "\(String(year)) 年"), nil, year)
        case .none:
            return ("all", String(localized: "全部作品"), nil, 0)
        }
    }

    private func sectionView(_ section: Section, mode: MuseumViewMode) -> some View {
        VStack(alignment: .leading, spacing: mode == .small ? 8 : 18) {
            if mode == .small {
                CompactSectionHeader(title: section.title, subtitle: section.subtitle, count: section.items.count)
                    .padding(.horizontal, Metrics.gutter + 4)
            } else {
                CrayonHeader(title: section.title, subtitle: section.subtitle, count: section.items.count,
                             ink: Palette.title)
                    .padding(.horizontal, Metrics.gutter + 4)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: mode.columnSpacing),
                                     count: mode.columns(forWidth: contentWidth)),
                      alignment: .leading, spacing: mode.rowSpacing) {
                ForEach(section.items) { a in
                    let isSelected = selection.contains(a.id)
                    Button {
                        if selecting { toggleSelection(a.id) } else { open(.detail(a.id)) }
                    } label: {
                        tile(a, mode: mode)
                            .overlay(alignment: .topLeading) {
                                if selecting { SelectionMark(selected: isSelected, size: mode.selectionMarkSize) }
                            }
                            .opacity(selecting && !isSelected ? 0.8 : 1)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        if mode == .large && !selecting {
                            FullScreenButton { viewer = MuseumViewerStart(id: a.id, artworks: filtered) }
                                .padding(14)
                        }
                    }
                    .accessibilityAddTraits(selecting && isSelected ? .isSelected : [])
                    .contextMenu {
                        if !selecting {
                            Button {
                                a.isFavorite.toggle()
                                try? modelContext.save()
                            } label: {
                                Label(a.isFavorite ? "取消最愛" as LocalizedStringKey : "加到最愛", systemImage: a.isFavorite ? "star.slash" : "star")
                            }
                            Button { open(.edit(a.id)) } label: { Label("編輯", systemImage: "slider.horizontal.3") }
                            Button {
                                Task { _ = await app.saveToPhotos(a, context: modelContext) }
                            } label: {
                                Label("存到手機", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, mode.horizontalPadding)
        }
        .padding(.top, mode == .small ? 4 : 8)
    }

    // MARK: Selection (選取)

    /// Every tag used in the museum (suggestions in 加標籤).
    private var allTags: [String] {
        Array(Set(artworks.flatMap(\.tags))).sorted()
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func endSelection() {
        selecting = false
        selection = []
    }

    private func batchAssign(_ child: Child?) {
        let n = app.assignChild(child, to: selectedArtworks, context: modelContext)
        guard n > 0 else { return }
        if let child {
            app.show(String(localized: "已把 \(n) 件作品設為「\(child.displayName)」"))
        } else {
            app.show(String(localized: "已把 \(n) 件作品設為未分類"))
        }
    }

    private func batchFavorite(_ on: Bool) {
        let n = app.setFavorite(on, for: selectedArtworks, context: modelContext)
        guard n > 0 else { return }
        app.show(on ? String(localized: "已把 \(n) 件作品加到最愛") : String(localized: "已把 \(n) 件作品取消最愛"))
    }

    /// Same path as saving one artwork (quota, Photos primer / permission, per-child albums). saveAll stops at the
    /// first artwork that needs the parent (paywall, album explanation, Photos access) and toasts 已存 N 張到照片.
    private func batchSave() {
        let list = selectedArtworks
        guard !list.isEmpty, !batchSaving else { return }
        batchSaving = true
        Task {
            // Museum artworks are already hung: don't put them on 這次收的作品.
            await app.saveAll(list, context: modelContext, addsToSession: false)
            batchSaving = false
        }
    }

    private func batchDelete() {
        let list = selectedArtworks
        withAnimation { endSelection() }
        let n = app.deleteAll(list, context: modelContext)
        if n > 0 { app.show(String(localized: "已刪除 \(n) 件作品")) }
    }

    // MARK: Empty states

    private var emptyMuseum: some View {
        VStack(spacing: 12) {
            Image("bibi-empty").resizable().scaledToFit().frame(height: 160)
            Text("美術館還是空的").font(.fmDisplay(22)).foregroundStyle(Palette.title)
            Text("回到廚房拍下第一張作品，按「收進這次」就會掛到這裡。")
                .font(.fm(15)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.top, 40)
    }

    private var noMatches: some View {
        VStack(spacing: 12) {
            Image("bibi-think").resizable().scaledToFit().frame(height: 150)
            Text("沒有符合的作品").font(.fmDisplay(21)).foregroundStyle(Palette.title)
            Button {
                withAnimation {
                    kindFilter = nil; favoritesOnly = false; termFilter = nil; ageFilter = nil; tagFilter = nil
                }
            } label: {
                Text("清除篩選")
            }
            .buttonStyle(SecondaryCapsuleStyle())
            .frame(width: 200)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }
}

/// A print on the museum wall: taped/magnet print, crayon title, child + date.
struct MuseumTile: View {
    let artwork: Artwork
    var processing = false
    var showChild = true

    private var magnet: String? {
        let w = wobble(artwork.id, salt: 11)
        if w > 0.45 { return ["mag-tomato", "mag-lemon", "mag-berry", "mag-cloud"][Int((w - 0.45) / 0.55 * 3.99)] }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HungPrint(id: artwork.id, tilt: 2, magnet: magnet, padding: 6) {
                ArtworkImage(artwork: artwork)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(artwork.aspectRatio, contentMode: .fit)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    if processing { ProgressView().controlSize(.small) }
                    if artwork.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.yellow)
                            .padding(5).background(Circle().fill(.white)).shadow(radius: 1)
                    }
                }
                .padding(8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: artwork.placardTitle)
                    .font(.fmDisplay(16, relativeTo: .headline))
                    .foregroundStyle(Palette.title)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(Palette.color(for: artwork.kind)).frame(width: 7, height: 7)
                    Text(verbatim: subtitle).font(.fm(12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(artwork.placardTitle), \(artwork.placardArtist), \(artwork.kind.title)"))
    }

    private var subtitle: String {
        var parts: [String] = []
        if showChild, let c = artwork.child { parts.append(c.displayName) }
        if let age = artwork.ageAtCreation { parts.append(age.localizedLabel) } else { parts.append(AppLanguage.placardDate(artwork.capturedAt)) }
        return parts.joined(separator: " · ")
    }
}
