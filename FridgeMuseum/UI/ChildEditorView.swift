import SwiftData
import SwiftUI

/// Create or edit a child profile (name, birthday, color).
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

    init(child: Child?, onCreate: ((Child) -> Void)? = nil) {
        self.child = child
        self.onCreate = onCreate
        _name = State(initialValue: child?.name ?? "")
        _hasBirthday = State(initialValue: child?.birthday != nil)
        _birthday = State(initialValue: child?.birthday ?? Calendar.current.date(byAdding: .year, value: -4, to: Date()) ?? Date())
        _colorHex = State(initialValue: child?.avatarColorHex ?? Palette.avatarHexes[0])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字或暱稱（例：小明）", text: $name)
                    Toggle("填生日（算出作品當時幾歲）", isOn: $hasBirthday)
                    if hasBirthday {
                        DatePicker("生日", selection: $birthday, in: ...Date(), displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "zh-Hant-TW"))
                    }
                }
                Section("代表色") {
                    HStack(spacing: 10) {
                        ForEach(Palette.avatarHexes, id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Palette.ink, lineWidth: colorHex == hex ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if child != nil {
                    Section {
                        Button("刪除這位小朋友", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("作品不會被刪除，會移到「未分類」。")
                    }
                }
            }
            .navigationTitle(child == nil ? "新增小朋友" : "編輯小朋友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("確定刪除？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let child { modelContext.delete(child); try? modelContext.save() }
                    dismiss()
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let child {
            child.name = trimmed
            child.birthday = hasBirthday ? birthday : nil
            child.avatarColorHex = colorHex
        } else {
            let c = Child(name: trimmed, birthday: hasBirthday ? birthday : nil, avatarColorHex: colorHex)
            modelContext.insert(c)
            onCreate?(c)
        }
        try? modelContext.save()
        dismiss()
    }
}
