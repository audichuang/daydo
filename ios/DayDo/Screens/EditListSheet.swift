import SwiftUI
import DayDoCore

/// 5 · Edit (or create) a list: name, color & view mode, members/notifications/transfer owner,
/// folder, type, smart-list visibility; archive / delete at the bottom.
struct EditListSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    var projectId: String?

    @State private var name = ""
    @State private var color: String? = "#4AA8E8"
    @State private var viewMode = "list"
    @State private var folderId: String?
    @State private var kind = "TASK"
    @State private var showInSmart = "all"
    @State private var notifyMode = "all"
    @State private var original: Project?
    @State private var confirmDelete = false
    @State private var showTransferOwner = false
    @State private var showSharing = false
    @FocusState private var nameFocused: Bool

    var isNew: Bool { projectId == nil }
    var isViewer: Bool { original?.isViewer ?? false }
    var isOwner: Bool { original?.isOwner ?? true }

    var dirty: Bool {
        guard !isViewer else { return false }
        guard let o = original else { return !name.trimmingCharacters(in: .whitespaces).isEmpty }
        return o.name != name || o.color != color || o.viewMode != viewMode || o.folderId != folderId
            || o.kind != kind || o.showInSmart != showInSmart || o.notifyMode != notifyMode
    }

    var body: some View {
        let iconHex = color ?? "#5B6461"
        VStack(spacing: 0) {
            HStack {
                PillButton(title: "取消") { dismiss() }
                Spacer()
                Text(isNew ? "新增清單" : "編輯清單").txt(17, .bold).foregroundStyle(Palette.text)
                Spacer()
                PillButton(title: "儲存", kind: dirty && !name.trimmingCharacters(in: .whitespaces).isEmpty ? .primary : .disabled) { save() }
            }
            .padding(.horizontal, 14).padding(.top, 16).frame(height: 68)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: (original?.isShared ?? false) ? "person.2" : "list.bullet")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(hex: iconHex))
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: iconHex).opacity(0.2)))
                        TextField("清單名稱", text: $name)
                            .txt(19, .bold).foregroundStyle(Palette.text)
                            .focused($nameFocused)
                        if !name.isEmpty {
                            Button { name = "" } label: {
                                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.textSecondary)
                                    .frame(width: 28, height: 28).background(Circle().fill(Palette.control))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除名稱")
                        }
                    }
                    .padding(10)
                    .card(16, color: Palette.raised)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("清單顏色").txt(13, .semibold).foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
                        HStack(spacing: 0) {
                            ForEach(Palette.listColors, id: \.1) { c in
                                let target: String? = c.0 == "無" ? nil : c.1
                                let selected = color == target
                                Button { color = target } label: {
                                    Group {
                                        if c.0 == "無" {
                                            ZStack {
                                                Circle().stroke(Palette.textSecondary, lineWidth: 1.8).frame(width: 22, height: 22)
                                                Rectangle().fill(Palette.textSecondary).frame(width: 24, height: 1.8).rotationEffect(.degrees(-45))
                                            }
                                            .frame(width: 26, height: 26)
                                        } else {
                                            Circle().fill(Color(hex: c.1)).frame(width: 26, height: 26)
                                        }
                                    }
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(selected ? Palette.text : .clear, lineWidth: 2))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(c.0)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 10)

                        Rectangle().fill(Palette.separatorSoft).frame(height: 1).padding(.horizontal, 14)

                        Text("視圖類型").txt(13, .semibold).foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
                        HStack(spacing: 10) {
                            viewOption("list", "列表")
                            viewOption("kanban", "看板")
                            viewOption("timeline", "時間軸")
                        }
                        .padding(.horizontal, 14).padding(.bottom, 14)
                    }
                    .card(16, color: Palette.raised)

                    if let original, !original.isInbox {
                        let owner = model.members.first { $0.id == original.ownerId } ?? model.me
                        let others = model.members.filter { original.memberIds.contains($0.id) && $0.id != original.ownerId }
                        VStack(spacing: 0) {
                            Button { openSharing(original.id) } label: {
                                HStack(spacing: 8) {
                                    Text("成員數量").txt(15).foregroundStyle(Palette.text)
                                    Spacer()
                                    Text("\(original.memberIds.count) 位成員").txt(14).foregroundStyle(Palette.textSecondary)
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                                }
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button { openSharing(original.id) } label: {
                                HStack(spacing: 10) {
                                    AvatarView(member: owner, size: 30, fallbackColor: accent.hex)
                                    Rectangle().fill(Palette.separatorSoft).frame(width: 1, height: 20)
                                    ForEach(others) { m in
                                        AvatarView(member: m, size: 30)
                                    }
                                    Image(systemName: "plus")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(accent.text)
                                        .frame(width: 30, height: 30)
                                        .background(Circle().fill(accent.color.opacity(0.18)))
                                    Spacer()
                                }
                                .padding(.bottom, 12)
                                .overlay(alignment: .bottom) { Rectangle().fill(Palette.separatorSoft).frame(height: 1) }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("管理清單成員")

                            let canTransferOwner = isOwner && !model.syncEnabled
                            Menu {
                                Button("有變更時通知") { notifyMode = "all" }
                                Button("不通知") { notifyMode = "none" }
                            } label: {
                                rowLabel("提醒與通知", value: notifyMode == "all" ? "有變更時通知" : "不通知", last: !canTransferOwner)
                            }

                            if canTransferOwner {
                                Button { showTransferOwner = true } label: {
                                    rowLabel("轉移清單擁有者", value: "", last: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .card(16, color: Palette.raised)
                    }

                    section("整理") {
                        Menu {
                            Button("不放資料夾") { folderId = nil }
                            ForEach(model.folders) { f in Button(f.name) { folderId = f.id } }
                        } label: { rowLabel("資料夾", value: model.folders.first { $0.id == folderId }?.name ?? "無") }
                        Menu {
                            Button("任務清單") { kind = "TASK" }
                            Button("筆記清單") { kind = "NOTE" }
                        } label: { rowLabel("清單類型", value: kind == "NOTE" ? "筆記清單（顯示同任務清單）" : "任務清單") }
                        Menu {
                            Button("所有任務") { showInSmart = "all" }
                            Button("不顯示") { showInSmart = "none" }
                        } label: { rowLabel("在智慧清單中顯示", value: showInSmart == "all" ? "所有任務" : "不顯示", last: true) }
                    }

                    if let original, !original.isInbox, isOwner {
                        VStack(spacing: 4) {
                            Button("歸檔清單") {
                                var u = UpdateProjectInput(projectId: original.id)
                                u.archived = true
                                let input = u
                                Task { await model.perform { try await $0.updateProject(input) }; leave(original.id) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .foregroundStyle(Palette.text)

                            Button("刪除清單") { confirmDelete = true }
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .foregroundStyle(Palette.danger)
                        }
                        .txt(16, .medium)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 40)
            }
        }
        .background(Palette.card)
        .presentationDetents([.large])
        .presentationBackground(Palette.card)
        .presentationCornerRadius(28)
        .confirmationDialog("刪除「\(name)」？清單內的任務會移到垃圾桶。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除清單", role: .destructive) {
                guard let id = original?.id else { return }
                Task { await model.perform { try await $0.deleteProject(id: id) }; leave(id) }
            }
        }
        .sheet(isPresented: $showTransferOwner) {
            if let original {
                TransferOwnerSheet(project: original) { updated in
                    self.original = updated
                }
            }
        }
        .sheet(isPresented: $showSharing, onDismiss: {
            Task {
                if let projectId, let p = try? await model.api.getProject(id: projectId) {
                    original = p
                }
            }
        }) {
            if let original {
                ShareListSheet(projectId: original.id)
            }
        }
        .task {
            guard let projectId, let p = try? await model.api.getProject(id: projectId) else {
                nameFocused = true
                return
            }
            original = p
            name = p.name; color = p.color; viewMode = p.viewMode; folderId = p.folderId
            kind = p.kind; showInSmart = p.showInSmart; notifyMode = p.notifyMode
        }
    }

    func openSharing(_ id: String) {
        showSharing = true
    }

    func leave(_ id: String) {
        if model.scope == .project(id) { model.scope = .smart(.today) }
        dismiss()
    }

    func save() {
        let n = name, c = color, v = viewMode, f = folderId, k = kind, s = showInSmart, nm = notifyMode
        Task {
            if let original {
                var u = UpdateProjectInput(projectId: original.id)
                u.name = n; u.color = c.map { .set($0) } ?? .clear
                u.viewMode = v; u.folderId = f.map { .set($0) } ?? .clear
                u.kind = k; u.showInSmart = s; u.notifyMode = nm
                let input = u
                if await model.perform({ try await $0.updateProject(input) }) != nil { dismiss() }
            } else if let p = await model.perform({ try await $0.createProject(CreateProjectInput(name: n, color: c, folderId: f, viewMode: v, kind: k)) }) {
                model.scope = .project(p.id)
                model.tab = .tasks
                dismiss()
            }
        }
    }

    func viewOption(_ id: String, _ label: String) -> some View {
        let on = viewMode == id
        let tone = on ? accent.color.opacity(0.65) : Palette.handle
        return Button { viewMode = id } label: {
            VStack(spacing: 6) {
                Group {
                    if id == "kanban" {
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { col in
                                VStack(spacing: 3) {
                                    RoundedRectangle(cornerRadius: 2).fill(tone).frame(height: 10)
                                    if col < 2 { RoundedRectangle(cornerRadius: 2).fill(tone.opacity(0.75)).frame(height: 8) }
                                    Spacer(minLength: 0)
                                }
                                .padding(3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.raised))
                            }
                        }
                    } else if id == "timeline" {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 0) {
                                ForEach(19...24, id: \.self) { day in
                                    Text("\(day)").font(.system(size: 6, weight: .medium)).foregroundStyle(Palette.textTertiary)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            ForEach(0..<3, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 3).fill(tone)
                                    .frame(height: 8)
                                    .padding(.leading, [0, 18, 8][i])
                                    .padding(.trailing, [16, 4, 22][i])
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(0..<3, id: \.self) { _ in
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 2).strokeBorder(tone, lineWidth: 1.2).frame(width: 7, height: 7)
                                    RoundedRectangle(cornerRadius: 2.5).fill(tone).frame(height: 6)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? accent.color : Palette.chip, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(accent.onAccent)
                            .frame(width: 18, height: 18).background(Circle().fill(accent.color)).offset(x: 6, y: -6)
                    }
                }
                Text(label).txt(13, on ? .bold : .regular).foregroundStyle(on ? accent.text : Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).txt(12, .semibold).foregroundStyle(Palette.textTertiary).padding(.leading, 4)
            VStack(spacing: 0) { content() }.padding(.horizontal, 14).card(16, color: Palette.raised)
        }
    }

    func rowLabel(_ label: String, value: String, last: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).txt(15).foregroundStyle(Palette.text)
            Spacer()
            if !value.isEmpty {
                Text(value).txt(14).foregroundStyle(Palette.textSecondary)
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
        }
        .frame(minHeight: 50)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Palette.separatorSoft).frame(height: 1) } }
        .contentShape(Rectangle())
    }
}

private struct TransferOwnerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var project: Project
    var onTransferred: (Project) -> Void

    var otherMembers: [Member] {
        model.members.filter { project.memberIds.contains($0.id) && $0.id != model.me?.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("轉移清單擁有者").txt(17, .bold).foregroundStyle(Palette.text)
                HStack {
                    PillButton(title: "取消") { dismiss() }
                    Spacer()
                }
            }
            .padding(.horizontal, 14).padding(.top, 16).frame(height: 68)

            if otherMembers.isEmpty {
                Spacer()
                Text("目前沒有其他成員")
                    .txt(15)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(otherMembers.enumerated()), id: \.element.id) { idx, member in
                            Button {
                                Task {
                                    if let updated = await model.perform({ try await $0.transferProjectOwner(projectId: project.id, toMemberId: member.id) }) {
                                        onTransferred(updated)
                                        dismiss()
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarView(member: member, size: 32)
                                    Text(member.name).txt(15, .medium).foregroundStyle(Palette.text)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                                }
                                .frame(minHeight: 54)
                                .overlay(alignment: .bottom) {
                                    if idx < otherMembers.count - 1 {
                                        Rectangle().fill(Palette.separatorSoft).frame(height: 1)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .card(16, color: Palette.raised)
                    .padding(.horizontal, 16)
                }
            }
        }
        .background(Palette.card)
        .presentationDetents([.medium])
        .presentationBackground(Palette.card)
        .presentationCornerRadius(28)
    }
}
