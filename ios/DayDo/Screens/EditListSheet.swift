import SwiftUI
import DayDoCore

/// 5 · Edit (or create) a list: name, view, color, members & notifications,
/// folder, type, smart-list visibility; archive / delete at the bottom.
struct EditListSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    var projectId: String?

    @State private var name = ""
    @State private var color = "#4AA8E8"
    @State private var viewMode = "list"
    @State private var folderId: String?
    @State private var kind = "TASK"
    @State private var showInSmart = "all"
    @State private var notifyMode = "all"
    @State private var original: Project?
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var isNew: Bool { projectId == nil }

    var dirty: Bool {
        guard let o = original else { return !name.trimmingCharacters(in: .whitespaces).isEmpty }
        return o.name != name || (o.color ?? "#5B6461") != color || o.viewMode != viewMode || o.folderId != folderId
            || o.kind != kind || o.showInSmart != showInSmart || o.notifyMode != notifyMode
    }

    var body: some View {
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
                            .foregroundStyle(Color(hex: color))
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: color).opacity(0.2)))
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

                    group("檢視") {
                        HStack(spacing: 10) {
                            viewOption("list", "列表")
                            viewOption("kanban", "看板")
                            viewOption("timeline", "時間軸")
                        }
                        .padding(12)
                    }

                    group("顏色") {
                        HStack(spacing: 0) {
                            ForEach(Palette.listColors, id: \.1) { c in
                                Button { color = c.1 } label: {
                                    Circle().fill(Color(hex: c.1)).frame(width: 26, height: 26)
                                        .padding(3)
                                        .overlay(Circle().strokeBorder(color == c.1 ? Palette.text : .clear, lineWidth: 2))
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(c.0)
                                .accessibilityAddTraits(color == c.1 ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 6)
                    }

                    section("成員與通知") {
                        row("成員", value: "\(original?.memberIds.count ?? 1) 位", members: true) {}
                        Menu {
                            Button("有變更時通知") { notifyMode = "all" }
                            Button("不通知") { notifyMode = "none" }
                        } label: { rowLabel("提醒與通知", value: notifyMode == "all" ? "有變更時通知" : "不通知") }
                        Text("邀請成員與轉移擁有者會在同步功能上線後開放").txt(12).foregroundStyle(Palette.textFaint).padding(.vertical, 10)
                    }

                    section("整理") {
                        Menu {
                            Button("不放資料夾") { folderId = nil }
                            ForEach(model.folders) { f in Button(f.name) { folderId = f.id } }
                        } label: { rowLabel("資料夾", value: model.folders.first { $0.id == folderId }?.name ?? "無") }
                        Menu {
                            Button("任務清單") { kind = "TASK" }
                            Button("筆記清單") { kind = "NOTE" }
                        } label: { rowLabel("清單類型", value: kind == "NOTE" ? "筆記清單" : "任務清單") }
                        Menu {
                            Button("所有任務") { showInSmart = "all" }
                            Button("不顯示") { showInSmart = "none" }
                        } label: { rowLabel("在智慧清單中顯示", value: showInSmart == "all" ? "所有任務" : "不顯示", last: true) }
                    }

                    if let original, !original.isInbox {
                        HStack(spacing: 10) {
                            Button("封存清單") {
                                var u = UpdateProjectInput(projectId: original.id)
                                u.archived = true
                                let input = u
                                Task { await model.perform { try await $0.updateProject(input) }; leave(original.id) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44).card(12, color: Palette.raised).foregroundStyle(Palette.textBody)
                            Button("刪除清單") { confirmDelete = true }
                                .frame(maxWidth: .infinity, minHeight: 44).card(12, color: Palette.raised).foregroundStyle(Palette.danger)
                        }
                        .txt(15, .semibold)
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
        .task {
            guard let projectId, let p = try? await model.api.getProject(id: projectId) else {
                nameFocused = true
                return
            }
            original = p
            name = p.name; color = p.color ?? "#5B6461"; viewMode = p.viewMode; folderId = p.folderId
            kind = p.kind; showInSmart = p.showInSmart; notifyMode = p.notifyMode
        }
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
                u.name = n; u.color = .set(c); u.viewMode = v; u.folderId = f.map { .set($0) } ?? .clear
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
        let barColor = on ? Color(hex: color).opacity(0.55) : Palette.handle
        return Button { viewMode = id } label: {
            VStack(spacing: 6) {
                Group {
                    if id == "kanban" {
                        HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 3).fill(barColor) } }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<3, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 3).fill(barColor)
                                    .padding(.leading, id == "timeline" ? [0, 18, 8][i] : 0)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? accent.color : Palette.chip, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(accent.onAccent)
                            .frame(width: 18, height: 18).background(Circle().fill(accent.color)).offset(x: 6, y: -6)
                    }
                }
                Text(label).txt(13, on ? .bold : .regular).foregroundStyle(on ? Palette.text : Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).txt(12, .semibold).foregroundStyle(Palette.textTertiary).padding(.leading, 12).padding(.top, 10)
            content()
        }
        .card(16, color: Palette.raised)
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
            Text(value).txt(14).foregroundStyle(Palette.textSecondary)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
        }
        .frame(minHeight: 50)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Palette.separatorSoft).frame(height: 1) } }
        .contentShape(Rectangle())
    }

    func row(_ label: String, value: String, members: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).txt(15).foregroundStyle(Palette.text)
            Spacer()
            if members, let o = original {
                AvatarStack(members: model.members.filter { o.memberIds.contains($0.id) }, size: 22)
            }
            Text(value).txt(14).foregroundStyle(Palette.textSecondary)
        }
        .frame(minHeight: 50)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separatorSoft).frame(height: 1) }
    }
}
