import SwiftUI
import UIKit
import DayDoCore

/// TickTick-style sharing sheet for a non-inbox list: owner, members with roles,
/// invite link creation/sharing for owners, and leave-list for non-owners.
struct ShareListSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    var projectId: String

    @State private var project: Project?
    @State private var projectMembers: [ProjectMemberInfo] = []
    @State private var inviteRole = "editor"
    @State private var createdInvite: CreatedInvite?
    @State private var creatingInvite = false
    @State private var revokingInvite = false
    @State private var copiedLink = false
    @State private var editingMember: ProjectMemberInfo?
    @State private var confirmLeave = false
    @State private var leaving = false
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("共享清單").txt(17, .bold).foregroundStyle(Palette.text)
                HStack {
                    Spacer()
                    PillButton(title: "完成") { dismiss() }
                }
            }
            .padding(.horizontal, 14).padding(.top, 16).frame(height: 68)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let project {
                        let ownerMember = projectMembers.first { $0.memberId == project.ownerId }
                        let fallbackOwner = model.members.first { $0.id == project.ownerId } ?? model.me
                        let ownerIsMe = ownerMember?.isMe ?? fallbackOwner?.isMe ?? project.isOwner
                        let ownerColor = ownerMember?.color ?? fallbackOwner?.color ?? accent.hex
                        let ownerAvatarMember = ownerMember?.asMember ?? fallbackOwner
                        let rawOwnerName = ownerMember?.name ?? fallbackOwner?.name ?? "擁有者"
                        let ownerName = ownerIsMe ? "\(rawOwnerName)（你）" : rawOwnerName

                        section("所有者") {
                            HStack(spacing: 12) {
                                AvatarView(member: ownerAvatarMember, size: 32, fallbackColor: ownerColor)
                                    .accessibilityIdentifier("share.ownerAvatar")
                                    .accessibilityValue(ownerColor)
                                Text(ownerName)
                                    .txt(15, .medium)
                                    .foregroundStyle(Palette.text)
                                Spacer()
                                Text("所有者")
                                    .txt(14)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .frame(minHeight: 54)
                        }

                        let realMembers = projectMembers.filter { $0.memberId != project.ownerId }
                        section("成員") {
                            if realMembers.isEmpty {
                                HStack {
                                    Text("目前沒有其他成員")
                                        .txt(14)
                                        .foregroundStyle(Palette.textSecondary)
                                    Spacer()
                                }
                                .frame(minHeight: 50)
                            } else {
                                ForEach(Array(realMembers.enumerated()), id: \.element.id) { idx, m in
                                    let rowContent = HStack(spacing: 12) {
                                        AvatarView(member: m.asMember, size: 32)
                                            .accessibilityIdentifier("share.memberAvatar.\(m.memberId)")
                                            .accessibilityValue(m.color)
                                        Text(m.isMe ? "\(m.name)（你）" : m.name)
                                            .txt(15, .medium)
                                            .foregroundStyle(Palette.text)
                                        Spacer()
                                        Text(roleLabel(m.role))
                                            .txt(14)
                                            .foregroundStyle(Palette.textSecondary)
                                        if project.isOwner {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(Palette.textTertiary)
                                        }
                                    }
                                    .frame(minHeight: 54)
                                    .overlay(alignment: .bottom) {
                                        if idx < realMembers.count - 1 {
                                            Rectangle().fill(Palette.separatorSoft).frame(height: 1)
                                        }
                                    }
                                    .contentShape(Rectangle())

                                    if project.isOwner {
                                        Button { editingMember = m } label: { rowContent }
                                            .buttonStyle(.plain)
                                            .accessibilityIdentifier("share.member.\(m.memberId)")
                                    } else {
                                        rowContent
                                    }
                                }
                            }
                        }

                        if project.isOwner {
                            section("邀請連結") {
                                HStack {
                                    Text("加入權限").txt(15).foregroundStyle(Palette.text)
                                    Spacer()
                                    Picker("加入權限", selection: $inviteRole) {
                                        Text("可編輯").tag("editor")
                                        Text("唯讀").tag("viewer")
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 170)
                                    .onChange(of: inviteRole) { _, _ in
                                        createdInvite = nil
                                        copiedLink = false
                                    }
                                }
                                .frame(minHeight: 54)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Palette.separatorSoft).frame(height: 1)
                                }

                                if let invite = createdInvite {
                                    let shareText = inviteShareText(for: invite.url)
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(invite.url)
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundStyle(Palette.textBody)
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                        Text("7 天內有效・加入者將取得「\(roleLabel(inviteRole))」權限")
                                            .txt(12)
                                            .foregroundStyle(Palette.textSecondary)

                                        HStack(spacing: 10) {
                                            ShareLink(item: shareText) {
                                                Label("分享邀請連結", systemImage: "square.and.arrow.up")
                                                    .txt(14, .semibold)
                                                    .foregroundStyle(accent.onAccent)
                                                    .frame(maxWidth: .infinity)
                                                    .frame(height: 42)
                                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.color))
                                            }
                                            .buttonStyle(.plain)
                                            .hoverEffect(.highlight)
                                            .accessibilityIdentifier("share.shareLink")

                                            Button {
                                                UIPasteboard.general.string = shareText
                                                copiedLink = true
                                            } label: {
                                                Label(copiedLink ? "已複製" : "複製", systemImage: copiedLink ? "checkmark" : "doc.on.doc")
                                                    .txt(14, .semibold)
                                                    .foregroundStyle(Palette.text)
                                                    .padding(.horizontal, 14)
                                                    .frame(height: 42)
                                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.chip))
                                            }
                                            .buttonStyle(.plain)
                                            .hoverEffect(.highlight)
                                            .accessibilityIdentifier("share.copyLink")
                                        }

                                        Button {
                                            revokeInvite(code: invite.code)
                                        } label: {
                                            HStack {
                                                if revokingInvite {
                                                    ProgressView().tint(Palette.danger)
                                                }
                                                Text(revokingInvite ? "撤銷中…" : "撤銷此邀請連結")
                                                    .txt(13, .medium)
                                                    .foregroundStyle(Palette.danger)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 34)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(revokingInvite)
                                        .accessibilityIdentifier("share.revokeLink")
                                    }
                                    .padding(.vertical, 12)
                                } else {
                                    Button {
                                        createInviteLink()
                                    } label: {
                                        HStack(spacing: 10) {
                                            if creatingInvite {
                                                ProgressView().tint(accent.text)
                                            } else {
                                                Image(systemName: "link.badge.plus")
                                                    .font(.system(size: 16, weight: .semibold))
                                            }
                                            Text(creatingInvite ? "正在建立邀請連結…" : "建立邀請連結")
                                                .txt(15, .medium)
                                            Spacer()
                                        }
                                        .foregroundStyle(accent.text)
                                        .frame(minHeight: 52)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .hoverEffect(.highlight)
                                    .disabled(creatingInvite)
                                    .accessibilityIdentifier("share.createInviteLink")
                                }
                            }
                        } else {
                            Button {
                                confirmLeave = true
                            } label: {
                                HStack {
                                    if leaving {
                                        ProgressView().tint(Palette.danger)
                                    }
                                    Text(leaving ? "離開中…" : "離開清單")
                                        .txt(16, .medium)
                                        .foregroundStyle(Palette.danger)
                                }
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .card(16, color: Palette.raised)
                            }
                            .buttonStyle(.plain)
                            .disabled(leaving)
                            .accessibilityIdentifier("share.leaveProject")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .background(Palette.card)
        .adaptiveSheet(detents: [.large], macSize: CGSize(width: 440, height: 500))
        .sheet(item: $editingMember) { member in
            MemberDetailSheet(projectId: projectId, member: member) {
                Task {
                    await model.reloadData()
                    await load()
                }
            }
            .environment(model)
        }
        .confirmationDialog(
            "確定要離開「\(project?.name ?? "此清單")」？離開後將無法再存取其中的任務。",
            isPresented: $confirmLeave,
            titleVisibility: .visible
        ) {
            Button("離開清單", role: .destructive) {
                leaveProject()
            }
        }
        .alert("出了點問題", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task(id: model.revision) {
            await load()
        }
    }

    private func load() async {
        project = (try? await model.api.getProject(id: projectId)) ?? model.project(projectId)
        projectMembers = (try? await model.api.listProjectMembers(projectId: projectId)) ?? []
    }

    private func inviteShareText(for url: String) -> String {
        let name = (project?.name ?? model.project(projectId)?.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "加入我在 DayDo 的共享清單\n\(url)"
        }
        return "加入我在 DayDo 的共享清單「\(name)」\n\(url)"
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "owner": "所有者"
        case "viewer": "唯讀"
        default: "可編輯"
        }
    }

    private func createInviteLink() {
        guard !creatingInvite else { return }
        creatingInvite = true
        copiedLink = false
        let role = inviteRole
        Task {
            defer { creatingInvite = false }
            do {
                createdInvite = try await model.sharing.createInvite(projectId: projectId, role: role)
            } catch {
                if await model.handleErrorIfSignedOut(error) {
                    dismiss()
                } else {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    private func revokeInvite(code: String) {
        guard !revokingInvite else { return }
        revokingInvite = true
        Task {
            defer { revokingInvite = false }
            do {
                try await model.sharing.revokeInvite(code: code)
                createdInvite = nil
                copiedLink = false
            } catch {
                if await model.handleErrorIfSignedOut(error) {
                    dismiss()
                } else {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    private func leaveProject() {
        guard !leaving else { return }
        leaving = true
        Task {
            defer { leaving = false }
            do {
                try await model.sharing.leaveList(projectId: projectId)
                await model.runSyncNow()
                await model.reloadData()
                if model.scope == .project(projectId) {
                    model.scope = .smart(.today)
                }
                dismiss()
            } catch {
                if await model.handleErrorIfSignedOut(error) {
                    dismiss()
                } else {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).txt(12, .semibold).foregroundStyle(Palette.textTertiary).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .card(16, color: Palette.raised)
        }
    }
}

private struct MemberDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var projectId: String
    var member: ProjectMemberInfo
    var onChanged: () -> Void

    @State private var role: String
    @State private var errorText: String?
    @State private var busy = false

    init(projectId: String, member: ProjectMemberInfo, onChanged: @escaping () -> Void) {
        self.projectId = projectId
        self.member = member
        self.onChanged = onChanged
        _role = State(initialValue: member.role == "viewer" ? "viewer" : "editor")
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(member.isMe ? "\(member.name)（你）" : member.name).txt(17, .bold).foregroundStyle(Palette.text)
                HStack {
                    PillButton(title: "完成") { dismiss() }
                    Spacer()
                }
            }
            .padding(.horizontal, 14).padding(.top, 16).frame(height: 68)

            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    Button { setRole("editor") } label: {
                        HStack {
                            Text("可編輯").txt(15).foregroundStyle(Palette.text)
                            Spacer()
                            if role == "editor" { Image(systemName: "checkmark").foregroundStyle(Palette.text) }
                        }
                        .frame(minHeight: 50)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separatorSoft).frame(height: 1) }
                        .contentShape(Rectangle())
                    }
                    Button { setRole("viewer") } label: {
                        HStack {
                            Text("唯讀").txt(15).foregroundStyle(Palette.text)
                            Spacer()
                            if role == "viewer" { Image(systemName: "checkmark").foregroundStyle(Palette.text) }
                        }
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .padding(.horizontal, 14)
                .card(16, color: Palette.raised)

                Button("移除成員") {
                    removeMember()
                }
                .txt(16, .medium)
                .foregroundStyle(Palette.danger)
                .frame(maxWidth: .infinity, minHeight: 50)
                .card(16, color: Palette.raised)
                .buttonStyle(.plain)
                .disabled(busy)

                if let errorText {
                    Text(errorText).txt(13).foregroundStyle(Palette.danger).padding(.horizontal, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .background(Palette.card)
        .adaptiveSheet(detents: [.height(300)], macSize: CGSize(width: 380, height: 280))
    }

    private func setRole(_ newRole: String) {
        guard !busy, role != newRole else { return }
        let previousRole = role
        role = newRole
        errorText = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.sharing.changeMemberRole(projectId: projectId, member: member, role: newRole)
                await model.runSyncNow()
                onChanged()
            } catch {
                role = previousRole
                if await model.handleErrorIfSignedOut(error) {
                    dismiss()
                } else {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func removeMember() {
        guard !busy else { return }
        errorText = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.sharing.removeMember(projectId: projectId, member: member)
                await model.runSyncNow()
                onChanged()
                dismiss()
            } catch {
                if await model.handleErrorIfSignedOut(error) {
                    dismiss()
                } else {
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
