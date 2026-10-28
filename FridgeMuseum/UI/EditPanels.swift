import SwiftData
import SwiftUI

/// 裁切四角 (Crop & Rotate): auto-detect / whole photo / rotate left / rotate right, and a straighten slider.
struct CropPanel: View {
    @Bindable var model: EditModel
    var onTurn: () -> Void = {}
    var onCorners: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                knob("viewfinder", String(localized: "重新自動找四角")) {
                    onCorners()
                    Task { await model.redetectCorners() }
                }
                Spacer(minLength: 0)
                knob("arrow.up.left.and.arrow.down.right", String(localized: "用整張照片")) {
                    onCorners()
                    model.useWholePhoto()
                }
                Spacer(minLength: 0)
                knob("rotate.left", String(localized: "向左轉")) {
                    model.rotate(clockwise: false)
                    onTurn()
                }
                Spacer(minLength: 0)
                knob("rotate.right", String(localized: "向右轉")) {
                    model.rotate(clockwise: true)
                    onTurn()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("拉直").font(.fm(16.5, bold: true)).foregroundStyle(Palette.ink)
                    Spacer()
                    ValueBadge(text: "\(Int(model.recipe.straightenDegrees.rounded()))°")
                }
                Slider(value: Binding(get: { model.recipe.straightenDegrees },
                                      set: { model.straighten($0.rounded()); onTurn() }),
                       in: -15...15, step: 1)
                    .tint(Palette.track)
                    .accessibilityLabel(Text("拉直"))
                    .accessibilityValue(Text(verbatim: "\(Int(model.recipe.straightenDegrees))°"))
            }
        }
    }

    private func knob(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundKnob(systemImage: icon, size: 48)
                Text(verbatim: label)
                    .font(.fm(11.5, bold: true))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 74)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// A titled 0...100 slider bound to a 0...1 recipe value; re-renders (debounced) while dragging.
struct RecipeSlider: View {
    let title: String
    var footnote: String?
    @Binding var value: Double
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title).font(.fm(16.5, bold: true)).foregroundStyle(Palette.ink)
                Spacer()
                ValueBadge(text: "\(Int((value * 100).rounded()))")
            }
            Slider(value: $value, in: 0...1)
                .tint(Palette.track)
                .onChange(of: value) { onChange() }
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityValue(Text(verbatim: "\(Int((value * 100).rounded()))"))
            if let footnote {
                Text(verbatim: footnote).font(.fm(13.5)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AdjustPanel: View {
    @Bindable var model: EditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.recipe.kind == .flat {
                RecipeSlider(title: String(localized: "紙張變白"), value: $model.recipe.strength) { model.render(debounceMilliseconds: 120) }
                RecipeSlider(title: String(localized: "保護淡色"), footnote: String(localized: "淡黃蠟筆、水彩、鉛筆不會被洗掉"),
                             value: $model.recipe.protect) { model.render(debounceMilliseconds: 120) }
                RecipeSlider(title: String(localized: "色彩鮮豔"), value: $model.recipe.vivid) { model.render(debounceMilliseconds: 120) }
                Toggle(isOn: $model.recipe.removeSpecks) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自動清掉紙上的小黑點").font(.fm(16.5, bold: true)).foregroundStyle(Palette.ink)
                        if model.recipe.removeSpecks && model.specksRemoved > 0 {
                            Text("這張清掉了 \(model.specksRemoved) 個").font(.fm(13.5)).foregroundStyle(Palette.muted)
                        }
                    }
                }
                .tint(Palette.track)
            } else {
                RecipeSlider(title: String(localized: "去背範圍"), value: $model.recipe.sensitivity) { model.render(debounceMilliseconds: 200) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("背景").font(.fm(16.5, bold: true)).foregroundStyle(Palette.ink)
                    HStack(spacing: 14) {
                        ForEach(CraftBackground.allCases) { bg in
                            Button {
                                model.recipe.background = bg
                                model.render()
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(bg == .gradient
                                              ? AnyShapeStyle(RadialGradient(colors: [.white, Color(bg.edgeColor)], center: .center, startRadius: 2, endRadius: 20))
                                              : AnyShapeStyle(Color(bg.color)))
                                        .frame(width: 38, height: 38)
                                        .overlay(Circle().strokeBorder(model.recipe.background == bg ? Palette.teal : Palette.line,
                                                                       lineWidth: model.recipe.background == bg ? 3 : 1.5))
                                    Text(verbatim: bg.title).font(.fm(12)).foregroundStyle(Palette.muted)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: bg.title))
                            .accessibilityAddTraits(model.recipe.background == bg ? .isSelected : [])
                        }
                    }
                }
                Toggle(isOn: $model.recipe.shadow) {
                    Text("加上自然陰影").font(.fm(16.5, bold: true)).foregroundStyle(Palette.ink)
                }
                .tint(Palette.track)
            }
        }
        .onChange(of: model.recipe.removeSpecks) { model.render() }
        .onChange(of: model.recipe.shadow) { model.render() }
    }
}

/// Cream segmented control (擦掉背景 / 補回作品).
struct SoftSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = selection == option.0
                Button {
                    withAnimation(.spring(duration: 0.25)) { selection = option.0 }
                } label: {
                    Text(verbatim: option.1)
                        .font(.fm(15.5, bold: true))
                        .foregroundStyle(selected ? Palette.tealInk : Palette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background {
                            if selected { Capsule().fill(Palette.surface).shadow(color: Palette.shadow, radius: 3, y: 2) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Palette.surface2))
    }
}

struct BrushPanel: View {
    let model: EditModel
    @Binding var brushMode: BrushStroke.Mode
    @Binding var brushSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.recipe.kind == .craft {
                SoftSegmented(selection: $brushMode, options: [
                    (BrushStroke.Mode.erase, String(localized: "擦掉背景")),
                    (BrushStroke.Mode.restore, String(localized: "補回作品")),
                ])
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("筆刷大小").font(.fm(16.5, bold: true)).foregroundStyle(Palette.ink)
                    Spacer()
                    ValueBadge(text: "\(Int(brushSize))")
                }
                Slider(value: $brushSize, in: 1...10, step: 1)
                    .tint(Palette.track)
                    .accessibilityLabel(Text("筆刷大小"))
            }
            HStack(spacing: 10) {
                Button {
                    model.undoStroke()
                } label: {
                    Label("復原一筆", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(SoftPillStyle())
                .disabled(!model.hasActiveStrokes)
                Button("清除所有筆刷") { model.clearStrokes() }
                    .buttonStyle(SoftPillStyle())
                    .disabled(!model.hasActiveStrokes)
            }
        }
    }
}

// MARK: 作品說明牌 (museum label) — a sheet with detents

struct LabelSheet: View {
    @Bindable var artwork: Artwork
    @Bindable var model: EditModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Child.createdAt) private var children: [Child]
    @State private var showNewChild = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Placard(artwork: artwork)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 26)
                        .frame(maxWidth: .infinity)
                        .background(FridgeDoorShape(top: 22, bottom: 22, handleHeight: 50).padding(.trailing, 10))
                        .overlay(alignment: .top) { Tape(style: .dots, width: 110, angle: -3).offset(y: 12) }
                    Text("這是掛在冰箱上的作品說明牌。名字和生日只會記在這支手機上，下次不用再填。")
                        .font(.fm(14.5)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 12) {
                        field("小朋友") { childMenu }
                        field("生日") { birthdayField }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("作品名稱") {
                            TextField("例：我的家", text: $artwork.title).kitchenField()
                        }
                        field("用什麼做的") {
                            TextField("例：蠟筆、紙", text: $artwork.medium).kitchenField()
                        }
                    }
                    field("作品日期") {
                        DatePicker(selection: $artwork.capturedAt, in: ...Date(), displayedComponents: .date) {
                            Text(verbatim: artwork.placardTerm).font(.fm(14.5, bold: true)).foregroundStyle(Palette.teal)
                        }
                        .tint(Palette.teal)
                    }
                    field("標籤") { TagEditor(tags: $artwork.tags) }
                    field("備註") {
                        TextField("孩子說了什麼？", text: $artwork.note, axis: .vertical)
                            .lineLimit(2...5)
                            .kitchenField()
                    }
                    field("錄音") { VoiceNoteRow(artwork: artwork) }
                    Toggle(isOn: $model.recipe.caption) {
                        Text("在圖片下方加上名字、年齡、日期").font(.fm(15.5, bold: true)).foregroundStyle(Palette.ink)
                    }
                    .tint(Palette.track)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.surface)
            .navigationTitle(Text("作品說明牌"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("完成").font(.fm(17, bold: true)) }
                        .tint(Palette.tealInk)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
        .overlay(alignment: .topLeading) { if DemoMode.scene("label") { ReadyMarker() } }
        .onChange(of: artwork.capturedAt) { try? modelContext.save() }
        .onChange(of: artwork.title) { try? modelContext.save() }
        .onChange(of: artwork.medium) { try? modelContext.save() }
        .onChange(of: artwork.tags) { try? modelContext.save() }
        .onChange(of: artwork.note) { try? modelContext.save() }
        .onChange(of: model.recipe.caption) { _, on in
            // The caption band only matters on export, so persist it right away (no re-render needed).
            var r = artwork.recipe
            r.caption = on
            artwork.recipe = r
            try? modelContext.save()
        }
        .sheet(isPresented: $showNewChild) {
            ChildEditorView(child: nil) { created in setChild(created) }
        }
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.fm(14.5)).foregroundStyle(Palette.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var childMenu: some View {
        Menu {
            Button { setChild(nil) } label: { Text("小畫家（不指定）") }
            ForEach(children) { c in
                Button { setChild(c) } label: { Text(verbatim: c.displayName) }
            }
            Divider()
            Button { showNewChild = true } label: { Label("新增小朋友…", systemImage: "plus") }
        } label: {
            HStack(spacing: 8) {
                if let c = artwork.child { AvatarDot(hex: c.avatarColorHex, name: c.displayName, size: 24) }
                Text(verbatim: artwork.child?.displayName ?? String(localized: "選擇"))
                    .foregroundStyle(artwork.child == nil ? Palette.faint : Palette.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.muted)
            }
            .font(.fm(16))
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface2))
        }
    }

    @ViewBuilder
    private var birthdayField: some View {
        if let child = artwork.child {
            BirthdayEditor(child: child)
        } else {
            Text("先選小朋友")
                .font(.fm(15)).foregroundStyle(Palette.faint)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface2))
        }
    }

    private func setChild(_ child: Child?) {
        artwork.child = child
        try? modelContext.save()
    }
}

struct BirthdayEditor: View {
    @Bindable var child: Child
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack {
            if let b = child.birthday {
                DatePicker("生日", selection: Binding(get: { b }, set: { child.birthday = $0; try? modelContext.save() }),
                           in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .tint(Palette.teal)
            } else {
                Button {
                    child.birthday = Calendar.current.date(byAdding: .year, value: -4, to: Date())
                    try? modelContext.save()
                } label: {
                    Label("填生日", systemImage: "birthday.cake")
                        .font(.fm(15, bold: true))
                        .foregroundStyle(Palette.tealInk)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface2))
    }
}

extension View {
    /// Cream rounded field (the web's form inputs).
    func kitchenField() -> some View {
        self
            .font(.fm(16))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface2))
    }
}

/// Free tags + suggested common ones (家人 / 動物 / 節日 / 母親節 …).
struct TagEditor: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Chip(title: "#\(tag)", systemImage: "xmark", selected: true, tint: Palette.green) {
                            tags.removeAll { $0 == tag }
                        }
                        .accessibilityLabel(Text("移除標籤 \(tag)"))
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("新增標籤", text: $draft)
                    .kitchenField()
                    .onSubmit(addDraft)
                    .submitLabel(.done)
                Button(action: addDraft) {
                    Text("加入").font(.fm(15, bold: true))
                }
                .buttonStyle(SoftPillStyle())
                .frame(width: 80)
                .disabled(TagSuggestions.normalize(draft) == nil)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TagSuggestions.localizedCommon.filter { !tags.contains($0) }, id: \.self) { tag in
                        Chip(title: tag, systemImage: "plus", selected: false) { tags.append(tag) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func addDraft() {
        guard let t = TagSuggestions.normalize(draft) else { return }
        if !tags.contains(t) { tags.append(t) }
        draft = ""
    }
}

extension TagSuggestions {
    /// Suggested tags in the UI language (stored as typed; tags are free text).
    static var localizedCommon: [String] {
        if AppLanguage.isChinese { return common }
        return ["Family", "Animals", "Holidays", "Mother’s Day", "Father’s Day", "Birthday", "School", "Self-Portrait",
                "Landscape", "Dinosaurs", "Vehicles", "Christmas", "Lunar New Year", "Flowers"]
    }
}

/// Simple wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

struct VoiceNoteRow: View {
    @Bindable var artwork: Artwork
    @Environment(\.modelContext) private var modelContext
    @State private var recorder = VoiceNoteRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    if recorder.isRecording {
                        stopAndTranscribe()
                    } else {
                        Task { await recorder.start() }
                    }
                } label: {
                    Label(recorder.isRecording ? "停止錄音" as LocalizedStringKey : "錄下孩子的介紹",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.fm(15.5, bold: true))
                        .foregroundStyle(recorder.isRecording ? Color.white : Palette.ink)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Capsule().fill(recorder.isRecording ? Palette.red : Palette.surface2))
                }
                .buttonStyle(.plain)

                if let data = artwork.voiceNoteData, !recorder.isRecording {
                    Button {
                        if recorder.isPlaying { recorder.stopPlaying() } else { recorder.play(data) }
                    } label: {
                        Image(systemName: recorder.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Palette.teal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(recorder.isPlaying ? Text("暫停") : Text("播放錄音"))
                }
                if recorder.isTranscribing { ProgressView() }
            }
            if !artwork.voiceTranscript.isEmpty {
                Text(verbatim: "「\(artwork.voiceTranscript)」").font(.fm(14)).foregroundStyle(Palette.muted)
            }
            if let msg = recorder.message {
                Text(verbatim: msg).font(.fm(13)).foregroundStyle(Palette.warn)
            }
        }
    }

    private func stopAndTranscribe() {
        guard let data = recorder.stop() else { return }
        artwork.voiceNoteData = data
        try? modelContext.save()
        let artwork = self.artwork, recorder = self.recorder, context = modelContext
        Task {
            if let text = await recorder.transcribe(data) {
                artwork.voiceTranscript = text
                try? context.save()
            }
        }
    }
}
