import SwiftUI
import DayDoCore

/// TickTick-style sharing sheet for a non-inbox list: owner, current members /
/// pending invites (stored locally + queued in outbox), and add-member form.
struct ShareListSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    var projectId: String

    @State private var project: Project?
    @State private var projectMembers: [ProjectMemberInfo] = []
    @State private var invites: [ProjectInvite] = []
    @State private var showInviteSheet = false
    @State private var editingMember: ProjectMemberInfo?
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
                        let ownerIsMe = ownerMember?.isMe ?? fallbackOwner?.isMe ?? true
                        let ownerInitial = ownerMember?.initial ?? fallbackOwner?.initial ?? "我"
                        let ownerColor = ownerMember?.color ?? fallbackOwner?.color ?? accent.hex
                        let ownerName = ownerIsMe ? "我" : (ownerMember?.name ?? fallbackOwner?.name ?? "我")
                        section("所有者") {
                            HStack(spacing: 12) {
                                memberAvatar(
                                    initial: ownerInitial,
                                    fill: Color(hex: ownerColor),
                                    textColor: Palette.background
                                )
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
                            ForEach(realMembers) { m in
                                Button { editingMember = m } label: {
                                    HStack(spacing: 12) {
                                        memberAvatar(initial: m.initial, fill: Color(hex: m.color), textColor: Palette.background)
                                        Text(m.name).txt(15, .medium).foregroundStyle(Palette.text)
                                        Spacer()
                                        Text(m.role == "viewer" ? "唯讀" : "可編輯")
                                            .txt(14)
                                            .foregroundStyle(Palette.textSecondary)
                                        ZStack(alignment: .bottomTrailing) {
                                            Image(systemName: "person").font(.system(size: 14, weight: .medium))
                                            Image(systemName: "pencil").font(.system(size: 8, weight: .bold)).offset(x: 4, y: 2)
                                        }
                                        .foregroundStyle(Palette.textSecondary)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Palette.textTertiary)
                                    }
                                    .frame(minHeight: 54)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(Palette.separatorSoft).frame(height: 1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }

                            ForEach(invites) { inv in
                                Menu {
                                    Button {
                                        updateRole(inv, to: "editor")
                                    } label: {
                                        if inv.role == "editor" {
                                            Label("可編輯", systemImage: "checkmark")
                                        } else {
                                            Text("可編輯")
                                        }
                                    }
                                    Button {
                                        updateRole(inv, to: "viewer")
                                    } label: {
                                        if inv.role == "viewer" {
                                            Label("唯讀", systemImage: "checkmark")
                                        } else {
                                            Text("唯讀")
                                        }
                                    }
                                    Divider()
                                    Button("取消邀請", role: .destructive) {
                                        cancel(inv)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        memberAvatar(
                                            initial: String(inv.email.prefix(1)).uppercased(),
                                            fill: Palette.chip,
                                            textColor: Palette.textSecondary
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(inv.email)
                                                .txt(15)
                                                .foregroundStyle(Palette.text)
                                                .lineLimit(1)
                                            Text("等待同步")
                                                .txt(12)
                                                .foregroundStyle(Palette.textTertiary)
                                        }
                                        Spacer()
                                        Text(inv.role == "viewer" ? "唯讀" : "可編輯")
                                            .txt(14)
                                            .foregroundStyle(Palette.textSecondary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Palette.textTertiary)
                                    }
                                    .frame(minHeight: 58)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(Palette.separatorSoft).frame(height: 1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("shareInvite.\(inv.email)")
                            }

                            Button { showInviteSheet = true } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("新增新成員")
                                        .txt(15, .medium)
                                    Spacer()
                                }
                                .foregroundStyle(accent.text)
                                .frame(minHeight: 50)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .background(Palette.card)
        .presentationDetents([.large])
        .presentationBackground(Palette.card)
        .presentationCornerRadius(28)
        .sheet(isPresented: $showInviteSheet) {
            InviteMemberSheet(projectId: projectId) { created in
                invites.append(created)
            }
        }
        .sheet(item: $editingMember) { member in
            MemberDetailSheet(projectId: projectId, member: member) {
                Task {
                    await model.refreshLookups()
                    await load()
                }
            }
        }
        .alert("出了點問題", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task {
            await load()
        }
    }

    private func load() async {
        project = (try? await model.api.getProject(id: projectId)) ?? model.project(projectId)
        projectMembers = (try? await model.api.listProjectMembers(projectId: projectId)) ?? []
        invites = (try? await model.api.listInvites(projectId: projectId)) ?? []
    }

    private func updateRole(_ invite: ProjectInvite, to role: String) {
        guard invite.role != role else { return }
        Task {
            do {
                let updated = try await model.api.updateInviteRole(id: invite.id, role: role)
                if let idx = invites.firstIndex(where: { $0.id == invite.id }) {
                    invites[idx] = updated
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func cancel(_ invite: ProjectInvite) {
        Task {
            do {
                try await model.api.cancelInvite(id: invite.id)
                invites.removeAll { $0.id == invite.id }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func memberAvatar(initial: String, fill: Color, textColor: Color) -> some View {
        Text(initial)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(textColor)
            .frame(width: 32, height: 32)
            .background(Circle().fill(fill))
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

private struct InviteMemberSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var projectId: String
    var onInvited: (ProjectInvite) -> Void

    @State private var email = ""
    @State private var role = "editor"
    @State private var errorText: String?
    @State private var submitting = false
    @FocusState private var emailFocused: Bool

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submitting
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PillButton(title: "取消") { dismiss() }
                Spacer()
                Text("新增新成員").txt(17, .bold).foregroundStyle(Palette.text)
                Spacer()
                PillButton(title: "邀請", kind: canSubmit ? .primary : .disabled) { submit() }
            }
            .padding(.horizontal, 14).padding(.top, 16).frame(height: 68)

            VStack(alignment: .leading, spacing: 12) {
                TextField("電子郵件", text: $email)
                    .txt(16)
                    .foregroundStyle(Palette.text)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($emailFocused)
                    .submitLabel(.done)
                    .onSubmit { submit() }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .card(16, color: Palette.raised)

                HStack {
                    Text("權限").txt(15).foregroundStyle(Palette.text)
                    Spacer()
                    Picker("權限", selection: $role) {
                        Text("可編輯").tag("editor")
                        Text("唯讀").tag("viewer")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .card(16, color: Palette.raised)

                if let errorText {
                    Text(errorText)
                        .txt(13)
                        .foregroundStyle(Palette.danger)
                        .padding(.horizontal, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .onAppear { emailFocused = true }
        .background(Palette.card)
        .presentationDetents([.height(290), .medium])
        .presentationBackground(Palette.card)
        .presentationCornerRadius(28)
    }

    private func submit() {
        guard canSubmit else { return }
        errorText = nil
        submitting = true
        let targetEmail = email
        let selectedRole = role
        Task {
            defer { submitting = false }
            do {
                let created = try await model.api.inviteMember(
                    projectId: projectId,
                    email: targetEmail,
                    role: selectedRole
                )
                onInvited(created)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
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

    init(projectId: String, member: ProjectMemberInfo, onChanged: @escaping () -> Void) {
        self.projectId = projectId
        self.member = member
        self.onChanged = onChanged
        _role = State(initialValue: member.role == "viewer" ? "viewer" : "editor")
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(member.name).txt(17, .bold).foregroundStyle(Palette.text)
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
                .padding(.horizontal, 14)
                .card(16, color: Palette.raised)

                Button("移除成員") {
                    Task {
                        do {
                            try await model.api.removeMember(projectId: projectId, memberId: member.memberId)
                            onChanged()
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                }
                .txt(16, .medium)
                .foregroundStyle(Palette.danger)
                .frame(maxWidth: .infinity, minHeight: 50)
                .card(16, color: Palette.raised)
                .buttonStyle(.plain)

                if let errorText {
                    Text(errorText).txt(13).foregroundStyle(Palette.danger).padding(.horizontal, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .background(Palette.card)
        .presentationDetents([.height(300)])
        .presentationBackground(Palette.card)
        .presentationCornerRadius(28)
    }

    private func setRole(_ newRole: String) {
        role = newRole
        Task {
            do {
                try await model.api.updateMemberRole(projectId: projectId, memberId: member.memberId, role: newRole)
                onChanged()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
