import PhotosUI
import SwiftData
import SwiftUI

/// Create or edit a child profile (name, birthday, avatar, color).
struct ChildEditorView: View {
    let child: Child?
    var onCreate: ((Child) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var hasBirthday: Bool
    @State private var birthday: Date
    @State private var colorHex: String
    @State private var confirmDelete = false
    /// Photo avatar (≤ 512 px square JPEG) or nil for the colour circle; written to the child on 儲存.
    @State private var avatarData: Data?
    @State private var avatarImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoCrop: AvatarCropRequest?
    @State private var showArtworkPicker = false

    init(child: Child?, onCreate: ((Child) -> Void)? = nil) {
        self.child = child
        self.onCreate = onCreate
        _name = State(initialValue: child?.name ?? "")
        _hasBirthday = State(initialValue: child?.birthday != nil)
        _birthday = State(initialValue: child?.birthday ?? Calendar.current.date(byAdding: .year, value: -4, to: Date()) ?? Date())
        _colorHex = State(initialValue: child?.avatarColorHex ?? Palette.avatarHexes[0])
        _avatarData = State(initialValue: child?.avatarImageData)
        _avatarImage = State(initialValue: (child?.avatarImageData).flatMap { UIImage(data: $0) })
    }

    /// This child's artworks in the museum, newest first (for 用他的作品).
    private var keptArtworks: [Artwork] {
        (child?.artworks ?? []).filter(\.isInMuseum).sorted { ($0.keptAt ?? $0.createdAt) > ($1.keptAt ?? $1.createdAt) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        AvatarDot(hex: colorHex, name: name.isEmpty ? "?" : name, size: 72, image: avatarImage)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("名字或暱稱（例：小明）", text: $name)
                    Toggle("填生日（算出作品當時幾歲）", isOn: $hasBirthday)
                    if hasBirthday {
                        DatePicker("生日", selection: $birthday, in: ...Date(), displayedComponents: .date)
                    }
                }
                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("從照片選", systemImage: "photo.on.rectangle")
                    }
                    Button { showArtworkPicker = true } label: {
                        Label("用他的作品", systemImage: "paintpalette")
                    }
                    .disabled(keptArtworks.isEmpty)
                    Button { setAvatar(nil) } label: {
                        Label("用顏色", systemImage: "circle.fill")
                    }
                    .disabled(avatarData == nil)
                } header: {
                    Text("頭像")
                } footer: {
                    Text("頭像只存在這支手機裡。")
                }
                Section {
                    HStack(spacing: 8) {
                        ForEach(Palette.avatarHexes, id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: colorHex == hex ? 3 : 0))
                                    .overlay(Circle().stroke(Palette.ink, lineWidth: colorHex == hex ? 2 : 0).padding(-2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("代表色"))
                            .accessibilityAddTraits(colorHex == hex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("代表色")
                }
                if child != nil {
                    Section {
                        Button("刪除這位小朋友", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("作品不會被刪除，會移到「未分類」。")
                    }
                }
            }
            .font(.fm(16))
            .tint(Palette.teal)
            .scrollContentBackground(.hidden)
            .background(Palette.wall)
            .navigationTitle(child == nil ? Text("新增小朋友") : Text("編輯小朋友"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            .sheet(item: $photoCrop) { request in
                NavigationStack {
                    AvatarCropView(imageData: request.data) { data in
                        setAvatar(data)
                        photoCrop = nil
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { photoCrop = nil } }
                    }
                }
            }
            .sheet(isPresented: $showArtworkPicker) {
                AvatarArtworkPicker(artworks: keptArtworks) { data in setAvatar(data) }
            }
            .confirmationDialog(Text("確定刪除？"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let child { modelContext.delete(child); try? modelContext.save() }
                    dismiss()
                }
            }
        }
    }

    private func setAvatar(_ data: Data?) {
        avatarData = data
        avatarImage = data.flatMap { UIImage(data: $0) }
    }

    /// The picked photo goes to the crop screen (which says so if it can't be opened).
    private func loadPhoto(_ item: PhotosPickerItem) async {
        let data = try? await item.loadTransferable(type: Data.self)
        photoItem = nil
        photoCrop = AvatarCropRequest(data: data)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let child {
            child.name = trimmed
            child.birthday = hasBirthday ? birthday : nil
            child.avatarColorHex = colorHex
            if child.avatarImageData != avatarData { child.avatarImageData = avatarData }
        } else {
            let c = Child(name: trimmed, birthday: hasBirthday ? birthday : nil, avatarColorHex: colorHex)
            c.avatarImageData = avatarData
            modelContext.insert(c)
            onCreate?(c)
        }
        try? modelContext.save()
        dismiss()
    }
}

struct AvatarCropRequest: Identifiable {
    let id = UUID()
    var data: Data?
}

/// 用他的作品: a grid of the child's kept artworks; tapping one opens the crop screen.
struct AvatarArtworkPicker: View {
    let artworks: [Artwork]
    var onPick: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Artwork?

    init(artworks: [Artwork], onPick: @escaping (Data) -> Void) {
        self.artworks = artworks
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(artworks) { a in
                        Button { picked = a } label: { cell(a) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: Self.label(for: a)))
                    }
                }
                .padding(Metrics.gutter)
            }
            .background(Palette.wall)
            .navigationTitle(Text("選一件作品"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .navigationDestination(item: $picked) { a in
                AvatarCropView(imageData: a.renderedImageData ?? a.thumbnailData) { data in
                    onPick(data)
                    dismiss()
                }
            }
        }
    }

    /// VoiceOver: the title, or 作品 + its date so untitled artworks can be told apart.
    static func label(for a: Artwork) -> String {
        if !a.title.isEmpty { return a.title }
        return String(localized: "作品") + " " + AppLanguage.placardDate(a.capturedAt)
    }

    private func cell(_ a: Artwork) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = ThumbnailCache.shared.image(for: a) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Palette.surface2
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// Square crop with a circular mask: drag to move, pinch (or the slider) to zoom. 使用 makes the 512 px JPEG
/// off the main actor and hands it back.
struct AvatarCropView: View {
    let imageData: Data?
    var onDone: (Data) -> Void

    @State private var preview: UIImage?
    @State private var pixelWidth = 1
    @State private var pixelHeight = 1
    @State private var failed = false
    @State private var saving = false
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let side: CGFloat = 280

    init(imageData: Data?, onDone: @escaping (Data) -> Void) {
        self.imageData = imageData
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 20) {
            if let preview {
                cropArea(preview)
                Slider(value: zoomBinding, in: 1...CGFloat(AvatarCrop.maxZoom)) {
                    Text("縮放")
                } minimumValueLabel: {
                    Image(systemName: "minus.magnifyingglass")
                } maximumValueLabel: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .frame(maxWidth: side)
                Text("拖曳移動，兩指縮放")
                    .font(.fm(14))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
            } else if failed {
                Text("這張照片打不開，請換一張再試一次。")
                    .font(.fm(16))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: side, minHeight: side)
            } else {
                ProgressView().frame(width: side, height: side)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .padding(.horizontal, Metrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.wall)
        .navigationTitle(Text("調整頭像"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("使用", action: save).disabled(preview == nil)
                }
            }
        }
        .task { await loadPreview() }
    }

    private func cropArea(_ image: UIImage) -> some View {
        let fill = side / CGFloat(max(min(pixelWidth, pixelHeight), 1))
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        return Image(uiImage: image)
            .resizable()
            .frame(width: CGFloat(pixelWidth) * fill * zoom, height: CGFloat(pixelHeight) * fill * zoom)
            .offset(offset)
            .frame(width: side, height: side)
            .clipped()
            .overlay {
                Path { p in
                    p.addRect(square)
                    p.addEllipse(in: square)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            }
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        offset = clampedOffset(CGSize(width: baseOffset.width + v.translation.width,
                                                      height: baseOffset.height + v.translation.height))
                    }
                    .onEnded { _ in baseOffset = offset }
                    .simultaneously(with:
                        MagnifyGesture()
                            .onChanged { v in
                                zoom = min(max(baseZoom * v.magnification, 1), CGFloat(AvatarCrop.maxZoom))
                                offset = clampedOffset(offset)
                            }
                            .onEnded { _ in
                                baseZoom = zoom
                                baseOffset = offset
                            }
                    )
            )
            .accessibilityHidden(true)
    }

    private var zoomBinding: Binding<CGFloat> {
        Binding(get: { zoom }, set: { z in
            zoom = z
            baseZoom = z
            offset = clampedOffset(offset)
            baseOffset = offset
        })
    }

    private var crop: AvatarCrop {
        AvatarCrop(zoom: Double(zoom), offsetX: Double(offset.width / side), offsetY: Double(offset.height / side))
    }

    private func clampedOffset(_ o: CGSize) -> CGSize {
        let c = AvatarImage.clamped(AvatarCrop(zoom: Double(zoom), offsetX: Double(o.width / side), offsetY: Double(o.height / side)),
                                    width: pixelWidth, height: pixelHeight)
        return CGSize(width: CGFloat(c.offsetX) * side, height: CGFloat(c.offsetY) * side)
    }

    private func loadPreview() async {
        guard preview == nil, !failed else { return }
        guard let data = imageData else { failed = true; return }
        let result = await Task.detached(priority: .userInitiated) {
            AvatarImage.preview(of: data)
        }.value
        guard let result, let image = UIImage(data: result.jpeg) else { failed = true; return }
        pixelWidth = result.width
        pixelHeight = result.height
        preview = image
    }

    private func save() {
        guard let data = imageData else { return }
        let window = crop
        saving = true
        Task {
            let avatar = await Task.detached(priority: .userInitiated) {
                AvatarImage.make(from: data, crop: window)
            }.value
            saving = false
            if let avatar { onDone(avatar) } else { failed = true; preview = nil }
        }
    }
}
