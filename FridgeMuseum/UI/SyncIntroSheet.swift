import SwiftUI

/// Shown once to Full Version users (after buying, or the first 1.2.0 launch of an existing buyer): what iCloud sync
/// does, before it starts. 開啟 starts it at the next launch; 先不要 leaves it off (Settings can turn it on later).
struct SyncIntroSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("bibi-wave").resizable().scaledToFit().frame(width: 116, height: 116)
                    .accessibilityHidden(true)
                Text("iCloud 同步").font(.fmDisplay(28)).foregroundStyle(Palette.title)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    point("arrow.triangle.2.circlepath",
                          "作品會同步到你自己的 iCloud，用同一個 Apple 帳號的 iPhone、iPad 都看得到，換手機也不怕。")
                    point("lock",
                          "照片還是只在手機上處理；作品存在你自己的 iCloud，開發者看不到。")
                    point("icloud",
                          "會用到你的 iCloud 空間。下次打開 App 時開始同步，隨時可以在「設定」關掉；關掉不會刪掉手機上的作品。")
                }
                .padding(.vertical, 4)
                Button {
                    app.sync.answerIntro(enable: true)
                    dismiss()
                } label: {
                    Text("開啟 iCloud 同步")
                        .font(.fm(17, bold: true))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.teal)
                Button {
                    app.sync.answerIntro(enable: false)
                    dismiss()
                } label: {
                    Text("先不要").font(.fm(16))
                }
            }
            .padding(24)
        }
        .background(Palette.surface)
        .interactiveDismissDisabled()
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Palette.surface)
        .presentationCornerRadius(32)
    }

    private func point(_ systemImage: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.teal)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(text)
                .font(.fm(16))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
