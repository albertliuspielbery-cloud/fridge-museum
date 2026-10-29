import SwiftData
import SwiftUI

/// 美術館「選取」: the checkmark on a selected print.
struct SelectionMark: View {
    let selected: Bool
    /// Sized per museum view mode (小圖 20 / 標準 26 / 大圖 30).
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(selected ? Palette.teal : Color.white)
            .background(Circle().fill(selected ? Color.white : Color.black.opacity(0.28)))
            .shadow(color: Palette.shadow, radius: 2, y: 1)
            .padding(size < 24 ? 5 : 10)
            .accessibilityHidden(true)
    }
}

/// The bottom action bar while selecting: 設定孩子 / 加標籤 / 日期 / 最愛 / 存到手機 / 刪除.
struct MuseumSelectionBar: View {
    let count: Int
    let children: [Child]
    var saving = false
    let onChild: (Child?) -> Void
    let onTags: () -> Void
    let onDate: () -> Void
    let onFavorite: (Bool) -> Void
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.line).frame(height: 1)
            // One row when the labels fit; scrolls sideways with large text.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { items }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { items }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .disabled(count == 0 || saving)
            .background(Palette.counter.ignoresSafeArea(edges: .bottom))
        }
    }

    @ViewBuilder
    private var items: some View {
        Menu {
            ForEach(children) { c in
                Button { onChild(c) } label: { Text(verbatim: c.displayName) }
            }
            Button { onChild(nil) } label: { Text("未分類") }
        } label: {
            barLabel("設定孩子", systemImage: "person.crop.circle")
        }
        Button(action: onTags) { barLabel("加標籤", systemImage: "tag") }
            .buttonStyle(.plain)
        Button(action: onDate) { barLabel("日期", systemImage: "calendar") }
            .buttonStyle(.plain)
        Menu {
            Button { onFavorite(true) } label: { Label("加到最愛", systemImage: "star") }
            Button { onFavorite(false) } label: { Label("取消最愛", systemImage: "star.slash") }
        } label: {
            barLabel("最愛", systemImage: "star")
        }
        Button(action: onSave) {
            if saving {
                VStack(spacing: 4) {
                    ProgressView()
                    Text("存到手機").font(.fm(12.5, bold: true, relativeTo: .caption)).lineLimit(1)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                barLabel("存到手機", systemImage: "square.and.arrow.down")
            }
        }
        .buttonStyle(.plain)
        Button(action: onDelete) { barLabel("刪除", systemImage: "trash", tint: Palette.warn) }
            .buttonStyle(.plain)
    }

    private func barLabel(_ title: LocalizedStringKey, systemImage: String, tint: Color = Palette.ink) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(.title3, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.fm(12.5, bold: true, relativeTo: .caption))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 54)
        .contentShape(Rectangle())
    }
}

/// 加標籤 for the selected artworks: free tags, the common suggestions, and tags already used in the museum.
struct BatchTagSheet: View {
    let count: Int
    /// Tags already used in the museum (suggested first).
    let existing: [String]
    let onApply: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String] = []

    private var existingLeft: [String] { existing.filter { !tags.contains($0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("會加到選取的 \(count) 件作品，原本的標籤會保留。")
                        .font(.fm(14.5)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !existingLeft.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("美術館裡的標籤").font(.fm(14.5)).foregroundStyle(Palette.muted)
                            FlowLayout(spacing: 6) {
                                ForEach(existingLeft, id: \.self) { t in
                                    Chip(title: "#\(t)", systemImage: "plus", selected: false) { tags.append(t) }
                                        .accessibilityLabel(Text("加入標籤 \(t)"))
                                }
                            }
                        }
                    }
                    TagEditor(tags: $tags)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.surface)
            .navigationTitle(Text("加標籤"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("取消") }
                        .tint(Palette.tealInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply(tags)
                        dismiss()
                    } label: {
                        Text("套用").font(.fm(17, bold: true))
                    }
                    .tint(Palette.tealInk)
                    .disabled(tags.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 日期 for the selected artworks. The date made decides 學期 and 年齡, so the sheet says so before applying.
struct BatchDateSheet: View {
    let count: Int
    let onApply: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(count: Int, initial: Date, onApply: @escaping (Date) -> Void) {
        self.count = count
        self.onApply = onApply
        _date = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DatePicker(selection: $date, in: ...Date(), displayedComponents: .date) {
                        Text("作品日期")
                    }
                    .datePickerStyle(.graphical)
                    .tint(Palette.teal)
                    Label {
                        Text("選取的 \(count) 件會改成這天，學期和年齡也會跟著改（\(SchoolTerm.of(date).localizedLabel)）。")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.fm(14.5))
                    .foregroundStyle(Palette.muted)
                }
                .padding(20)
            }
            .background(Palette.surface)
            .navigationTitle(Text("日期"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("取消") }
                        .tint(Palette.tealInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply(date)
                        dismiss()
                    } label: {
                        Text("套用").font(.fm(17, bold: true))
                    }
                    .tint(Palette.tealInk)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// 拍給：小明 — which child new captures and imports go to (AppModel.currentChildID). Shown on the home screen and
/// the camera; hidden until there is at least one child profile.
struct CaptureChildMenu: View {
    enum Style {
        /// Capsule under the home title.
        case home
        /// Avatar + name beside the camera shutter.
        case camera
    }

    var style: Style = .home

    @Environment(AppModel.self) private var app
    @Query(sort: \Child.createdAt) private var children: [Child]

    private var current: Child? { children.first { $0.id == app.currentChildID } }
    private var name: String { current?.displayName ?? String(localized: "未分類") }

    var body: some View {
        if children.isEmpty {
            if style == .camera { Color.clear.frame(width: 72, height: 58) }
        } else {
            Menu {
                Button { app.setCaptureChild(nil) } label: {
                    if current == nil { Label("未分類", systemImage: "checkmark") } else { Text("未分類") }
                }
                ForEach(children) { c in
                    Button { app.setCaptureChild(c.id) } label: {
                        if current?.id == c.id { Label(c.displayName, systemImage: "checkmark") } else { Text(verbatim: c.displayName) }
                    }
                }
            } label: {
                switch style {
                case .home: homeLabel
                case .camera: cameraLabel
                }
            }
            .accessibilityLabel(Text("新作品的小朋友"))
            .accessibilityValue(Text(verbatim: name))
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let c = current {
            ChildAvatar(child: c, size: style == .camera ? 44 : 24)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: style == .camera ? 40 : 22, weight: .regular))
                .accessibilityHidden(true)
        }
    }

    private var homeLabel: some View {
        HStack(spacing: 6) {
            avatar
            Text("拍給：\(name)").lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).accessibilityHidden(true)
        }
        .font(.fm(14, bold: true))
        .foregroundStyle(Palette.ink)
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(minHeight: 36)
        .background(Capsule().fill(Palette.surface))
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1.5))
        .contentShape(Capsule())
    }

    private var cameraLabel: some View {
        VStack(spacing: 4) {
            avatar
            Text(verbatim: name)
                .font(.fm(12.5, bold: true))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .frame(width: 72)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.45)))
        .contentShape(Rectangle())
    }
}
