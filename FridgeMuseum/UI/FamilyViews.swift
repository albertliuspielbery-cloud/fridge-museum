import SwiftData
import SwiftUI

/// 設定 › 家庭美術館 (1.3.0): create / invite / members / leave / stop sharing, and this launch's status.
/// Hidden in builds that can't use CloudKit (simulator, screenshot demos). Every switch takes effect at the next
/// launch (FamilySync); the personal museum is never deleted.
struct FamilySection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// Artworks in the museum this launch opened (copied when creating).
    let museumCount: Int
    @State private var confirmCreate = false
    @State private var confirmStop = false
    @State private var confirmLeave = false
    @State private var problem: String?

    private var family: FamilySync { app.family }

    var body: some View {
        if family.isAvailable || family.isFamilyMode {
            Section {
                content
            } header: {
                Text("家庭美術館")
            } footer: {
                footer
            }
            .disabled(family.isWorking)
            .alert(Text("建立家庭美術館？"), isPresented: $confirmCreate) {
                Button { perform(.create) } label: { Text("建立") }
                Button(role: .cancel) {} label: { Text("取消") }
            } message: {
                Text("你手機上的 \(museumCount) 件作品會複製一份到家庭美術館，原本的美術館會留在手機上，不會動到。建好之後可以馬上邀請家人；重新打開 App 就會進入家庭美術館。")
            }
            .alert(Text("停止分享？"), isPresented: $confirmStop) {
                Button(role: .destructive) { perform(.stop) } label: { Text("停止分享") }
                Button(role: .cancel) {} label: { Text("取消") }
            } message: {
                Text("家人就看不到這個家庭美術館了。家庭美術館的作品會複製一份到你自己的美術館；家人手機上的也會各自留一份。")
            }
            .confirmationDialog(Text("離開家庭美術館？"), isPresented: $confirmLeave, titleVisibility: .visible) {
                Button { perform(.leave(copyWorks: true)) } label: { Text("複製作品到我的美術館，再離開") }
                Button(role: .destructive) { perform(.leave(copyWorks: false)) } label: { Text("直接離開") }
                Button(role: .cancel) {} label: { Text("取消") }
            } message: {
                Text("離開後會回到你自己的美術館（重新打開 App 生效）。家庭美術館裡的作品，可以先複製一份到你的美術館。")
            }
            .alert(Text("家庭美術館"), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button(role: .cancel) {} label: { Text("好") }
            } message: {
                Text(verbatim: problem ?? "")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let status = family.status
        let membership = family.membership
        if status != .off {
            LabeledContent {
                HStack(spacing: 6) {
                    if family.isWorking || status == .syncing || status == .starting { ProgressView().controlSize(.small) }
                    Text(verbatim: status.label).multilineTextAlignment(.trailing)
                }
            } label: {
                Text("狀態")
            }
            if case .family = family.mode, family.endedThisSession == nil, let last = family.lastSyncedAt {
                LabeledContent {
                    Text(verbatim: last.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                } label: {
                    Text("上次同步")
                }
            }
            if let detail = status.detail {
                Text(verbatim: detail)
                    .font(.fm(13.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if family.endedThisSession != nil {
            EmptyView()
        } else if let membership, membership.pendingEnd == nil {
            if case .family = family.mode {
                if let owner = membership.ownerDisplayName, membership.role == .member {
                    LabeledContent {
                        Text(verbatim: owner)
                    } label: {
                        Text("館長")
                    }
                }
                Button { perform(.share) } label: {
                    if membership.role == .owner {
                        Label("邀請家人／管理成員", systemImage: "person.2")
                    } else {
                        Label("家庭成員", systemImage: "person.2")
                    }
                }
                if membership.role == .owner {
                    Button(role: .destructive) { confirmStop = true } label: {
                        Label("停止分享", systemImage: "xmark.circle")
                    }
                } else {
                    Button(role: .destructive) { confirmLeave = true } label: {
                        Label("離開家庭美術館", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } else if family.mode == .personal, membership.role == .owner {
                // Created this session: inviting already works before the switch.
                Button { perform(.share) } label: {
                    Label("邀請家人", systemImage: "person.badge.plus")
                }
            }
        } else if membership == nil, family.mode == .personal {
            if app.store.isPurchased {
                Button { confirmCreate = true } label: {
                    Label("建立家庭美術館", systemImage: "house")
                }
            } else {
                Button {
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        app.paywall = PaywallRequest(kind: .flat, artworkID: nil, action: .browse)
                    }
                } label: {
                    HStack {
                        Label {
                            Text("家庭美術館（完整版）")
                        } icon: {
                            Image(systemName: "house")
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.faint)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case .family = family.mode, family.endedThisSession == nil {
            Text("家人都可以新增、編輯、刪除作品和小朋友。只有收進美術館的作品會分享；在家庭美術館裡，大家都是完整版。你自己的美術館留在手機上，離開後就會回來。")
        } else if family.membership == nil && family.endedThisSession == nil {
            Text("用 iCloud 邀請家人，不同的 Apple 帳號也能一起收作品、一起看。館長要有完整版，家人不用買。")
        }
    }

    private enum Action {
        case create, share, stop
        case leave(copyWorks: Bool)
    }

    /// Runs a family action; a returned message is shown in an alert.
    private func perform(_ action: Action) {
        let family = app.family
        let container = modelContext.container
        let purchased = app.store.isPurchased
        Task {
            let message: String?
            switch action {
            case .create: message = await family.create(personal: container, isPurchased: purchased)
            case .share: message = await family.showSharing()
            case .stop: message = await family.stopSharing()
            case .leave(let copy): message = await family.leave(copyWorks: copy)
            }
            if let message { problem = message }
        }
    }
}

/// 加入「○○」的家庭美術館？ — shown when an invitation link opens the app. Nothing changes until 加入.
struct FamilyJoinSheet: View {
    let invite: FamilyInvite
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Artwork> { $0.isKept && !$0.isSample }) private var museum: [Artwork]
    @State private var copyMine = false
    @State private var joined = false
    @State private var problem: String?

    private var alreadyInFamily: Bool { app.family.membership != nil || app.family.mode != .personal }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("bibi-wave").resizable().scaledToFit().frame(width: 116, height: 116)
                    .accessibilityHidden(true)
                title
                    .font(.fmDisplay(26))
                    .foregroundStyle(Palette.title)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if joined {
                    Text("加入好了！從背景把 App 滑掉再打開，就會進入家庭美術館。")
                        .font(.fm(16)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    doneButton
                } else if alreadyInFamily {
                    Text("你已經在家庭美術館裡了。要加入別的家庭美術館，請先到設定離開。")
                        .font(.fm(16)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    doneButton
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        point("person.2", "加入後，你和家人都可以新增、編輯作品和小朋友，大家看到的是同一個美術館。")
                        point("checkmark.seal", "在家庭美術館裡，大家都是完整版，不用另外購買。")
                        point("lock", "你自己的美術館會留在手機上，不會刪掉；離開家庭美術館後就會回來。")
                    }
                    if !museum.isEmpty {
                        Toggle(isOn: $copyMine) {
                            Text("也把我手機上的 \(museum.count) 件作品放進家庭美術館")
                                .font(.fm(16)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tint(Palette.teal)
                    }
                    Button { join() } label: {
                        HStack(spacing: 8) {
                            if app.family.isWorking { ProgressView().tint(.white) }
                            Text("加入").font(.fm(17, bold: true))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.teal)
                    .disabled(app.family.isWorking)
                    Button { dismiss() } label: {
                        Text("先不要").font(.fm(16))
                    }
                    .disabled(app.family.isWorking)
                }
            }
            .padding(24)
        }
        .background(Palette.surface)
        .interactiveDismissDisabled(app.family.isWorking)
        .presentationDetents([.large])
        .presentationBackground(Palette.surface)
        .presentationCornerRadius(32)
        .alert(Text("家庭美術館"), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(role: .cancel) {} label: { Text("好") }
        } message: {
            Text(verbatim: problem ?? "")
        }
    }

    @ViewBuilder
    private var title: some View {
        if let name = invite.ownerName, !invite.isOwnShare {
            Text("加入「\(name)」的家庭美術館？")
        } else {
            Text("加入家庭美術館？")
        }
    }

    private var doneButton: some View {
        Button { dismiss() } label: {
            Text("好").font(.fm(17, bold: true)).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.teal)
    }

    private func join() {
        let container = modelContext.container
        let copy = copyMine
        let family = app.family
        Task { @MainActor in
            if let message = await family.join(invite, copyMyWorks: copy, personal: container) {
                problem = message
            } else {
                joined = true
            }
        }
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
