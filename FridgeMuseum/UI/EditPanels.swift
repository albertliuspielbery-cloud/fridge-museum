import SwiftData
import SwiftUI

struct CropPanel: View {
    let model: EditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("裁切").font(.headline)
            HStack(spacing: 10) {
                Button {
                    Task { await model.redetectCorners() }
                } label: {
                    Label("重新自動找四角", systemImage: "viewfinder")
                }
                .buttonStyle(.bordered)
                Button("用整張照片") { model.useWholePhoto() }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// A labeled 0...100 slider bound to a 0...1 recipe value; re-renders (debounced) while dragging.
struct RecipeSlider: View {
    let title: String
    var footnote: String?
    @Binding var value: Double
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))")
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
            }
            .font(.subheadline)
            Slider(value: $value, in: 0...1)
                .onChange(of: value) { onChange() }
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

struct AdjustPanel: View {
    @Bindable var model: EditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.recipe.kind == .flat {
                RecipeSlider(title: "紙張變白", value: $model.recipe.strength) { model.render(debounceMilliseconds: 120) }
                RecipeSlider(title: "保護淡色", footnote: "淡黃蠟筆、水彩、鉛筆不會被洗掉", value: $model.recipe.protect) {
                    model.render(debounceMilliseconds: 120)
                }
                RecipeSlider(title: "色彩鮮豔", value: $model.recipe.vivid) { model.render(debounceMilliseconds: 120) }
                Toggle(isOn: $model.recipe.removeSpecks) {
                    VStack(alignment: .leading) {
                        Text("自動清掉紙上的小黑點")
                        if model.recipe.removeSpecks && model.specksRemoved > 0 {
                            Text("這張清掉了 \(model.specksRemoved) 個").font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
            } else {
                RecipeSlider(title: "去背範圍", value: $model.recipe.sensitivity) { model.render(debounceMilliseconds: 200) }
                Text("背景").font(.subheadline)
                HStack(spacing: 12) {
                    ForEach(CraftBackground.allCases) { bg in
                        Button {
                            model.recipe.background = bg
                            model.render()
                        } label: {
                            Circle()
                                .fill(bg == .gradient
                                      ? AnyShapeStyle(RadialGradient(colors: [.white, Color(bg.edgeColor)], center: .center, startRadius: 2, endRadius: 18))
                                      : AnyShapeStyle(Color(bg.color)))
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(model.recipe.background == bg ? Palette.blue : Palette.line,
                                                         lineWidth: model.recipe.background == bg ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(bg.label)
                    }
                }
                Toggle("加上自然陰影", isOn: $model.recipe.shadow)
            }
        }
        .onChange(of: model.recipe.removeSpecks) { model.render() }
        .onChange(of: model.recipe.shadow) { model.render() }
    }
}

struct BrushPanel: View {
    let model: EditModel
    @Binding var brushMode: BrushStroke.Mode
    @Binding var brushSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.recipe.kind == .craft {
                Picker("筆刷種類", selection: $brushMode) {
                    Text("擦掉背景").tag(BrushStroke.Mode.erase)
                    Text("補回作品").tag(BrushStroke.Mode.restore)
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Text("筆刷大小")
                Slider(value: $brushSize, in: 1...10, step: 1)
                Text("\(Int(brushSize))").monospacedDigit().foregroundStyle(Palette.muted)
            }
            .font(.subheadline)
            HStack(spacing: 10) {
                Button {
                    model.undoStroke()
                } label: {
                    Label("復原一筆", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(!model.hasActiveStrokes)
                Button("清除所有筆刷") { model.clearStrokes() }
                    .buttonStyle(.bordered)
                    .disabled(!model.hasActiveStrokes)
            }
        }
    }
}

/// 資料: who made it, when (→ age, semester, grade), title, tags, favorite, note, voice note, caption.
struct InfoPanel: View {
    @Bindable var artwork: Artwork
    @Bindable var model: EditModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Child.createdAt) private var children: [Child]
    @State private var showNewChild = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("小朋友")
                    Spacer()
                    Menu {
                        Button("未分類") { setChild(nil) }
                        ForEach(children) { c in
                            Button(c.displayName) { setChild(c) }
                        }
                        Divider()
                        Button("新增小朋友…", systemImage: "plus") { showNewChild = true }
                    } label: {
                        HStack(spacing: 6) {
                            if let c = artwork.child { AvatarDot(hex: c.avatarColorHex, name: c.displayName, size: 20) }
                            Text(artwork.child?.displayName ?? "未分類")
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }
                    }
                }
                DatePicker("作品日期", selection: $artwork.capturedAt, in: ...Date(), displayedComponents: .date)
                if let summary = ageSummary {
                    Text(summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.green)
                }
                TextField("作品名稱（例：我的家）", text: $artwork.title)
                    .textFieldStyle(.roundedBorder)
                TagEditor(tags: $artwork.tags)
                TextField("備註（孩子說了什麼？）", text: $artwork.note, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                VoiceNoteRow(artwork: artwork)
                Toggle("在圖片下方加上名字、年齡、日期", isOn: $model.recipe.caption)
            }
        }
        .frame(maxHeight: 320)
        .onChange(of: artwork.capturedAt) { try? modelContext.save() }
        .onChange(of: artwork.title) { try? modelContext.save() }
        .onChange(of: artwork.tags) { try? modelContext.save() }
        .sheet(isPresented: $showNewChild) {
            ChildEditorView(child: nil) { created in setChild(created) }
        }
    }

    private var ageSummary: String? {
        let term = artwork.schoolTerm
        var parts: [String] = []
        if let age = artwork.ageAtCreation {
            parts.append("\(artwork.child?.displayName ?? "小朋友")畫這張時 \(age.label)")
        }
        var termText = term.label
        if let grade = artwork.gradeLabel { termText += "（\(grade)）" }
        parts.append(termText)
        return parts.joined(separator: " · ")
    }

    private func setChild(_ child: Child?) {
        artwork.child = child
        try? modelContext.save()
    }
}

/// Free tags + suggested common ones (家人 / 動物 / 節日 / 母親節 …).
struct TagEditor: View {
    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("標籤").font(.subheadline)
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Chip(title: "#\(tag)", systemImage: "xmark", selected: true, tint: Palette.green) {
                                tags.removeAll { $0 == tag }
                            }
                        }
                    }
                }
            }
            HStack {
                TextField("新增標籤", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDraft)
                Button("加入", action: addDraft).disabled(TagSuggestions.normalize(draft) == nil)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TagSuggestions.common.filter { !tags.contains($0) }, id: \.self) { tag in
                        Chip(title: tag, systemImage: "plus", selected: false) { tags.append(tag) }
                    }
                }
            }
        }
    }

    private func addDraft() {
        guard let t = TagSuggestions.normalize(draft) else { return }
        if !tags.contains(t) { tags.append(t) }
        draft = ""
    }
}

struct VoiceNoteRow: View {
    @Bindable var artwork: Artwork
    @Environment(\.modelContext) private var modelContext
    @State private var recorder = VoiceNoteRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if recorder.isRecording {
                        stopAndTranscribe()
                    } else {
                        Task { await recorder.start() }
                    }
                } label: {
                    Label(recorder.isRecording ? "停止錄音" : "錄下孩子的介紹",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle")
                }
                .buttonStyle(.bordered)
                .tint(recorder.isRecording ? Palette.coral : Palette.blue)

                if let data = artwork.voiceNoteData, !recorder.isRecording {
                    Button {
                        if recorder.isPlaying { recorder.stopPlaying() } else { recorder.play(data) }
                    } label: {
                        Image(systemName: recorder.isPlaying ? "pause.circle" : "play.circle").font(.title2)
                    }
                    .accessibilityLabel("播放錄音")
                }
                if recorder.isTranscribing { ProgressView() }
            }
            if !artwork.voiceTranscript.isEmpty {
                Text("「\(artwork.voiceTranscript)」").font(.footnote).foregroundStyle(Palette.muted)
            }
            if let msg = recorder.message {
                Text(msg).font(.caption).foregroundStyle(Palette.coral)
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
