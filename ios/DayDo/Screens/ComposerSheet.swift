import SwiftUI
import DayDoCore

/// Quick add docked above the keyboard: title, description and one row of
/// tools (date/time, priority, tags, list, more). Return or the send button
/// adds the task and clears the fields for the next one.
struct ComposerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    var request: ComposeRequest

    @State private var title = ""
    @State private var note = ""
    @State private var draft = DateDraft()
    @State private var panelDraft = DateDraft()
    @State private var priority: Priority = .none
    @State private var projectId: String?
    @State private var tags: [String] = []
    @State private var showDate = false
    @State private var addingTag = false
    @State private var tagText = ""
    @State private var added = 0
    @FocusState private var focus: Field?
    enum Field { case title, note }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("輸入任務？", text: $title, axis: .vertical)
                .txt(18, .medium)
                .foregroundStyle(Palette.text)
                .tint(accent.color)
                .focused($focus, equals: .title)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onChange(of: title) { _, v in
                    // Return key on a vertical field inserts a newline: treat it as send.
                    if v.hasSuffix("\n") { title.removeLast(); submit() }
                }
                .accessibilityIdentifier("composerTitle")
            TextField("描述", text: $note, axis: .vertical)
                .txt(15)
                .foregroundStyle(Palette.textBody)
                .tint(accent.color)
                .focused($focus, equals: .note)
                .lineLimit(1...4)
            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { t in
                        Button { tags.removeAll { $0 == t } } label: {
                            TagChip(name: t.lowercased(), label: t, color: model.tags.first { $0.name == t.lowercased() }?.color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除標籤 \(t)")
                    }
                }
            }
            toolbar
                .padding(.top, 6)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(tags.isEmpty ? 168 : 206)])
        .presentationBackground(Palette.card)
        .presentationCornerRadius(28)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showDate) {
            DateEditorFlow(draft: $panelDraft, today: model.today, title: title, excludeTaskId: nil,
                           cancel: { showDate = false }, confirm: { draft = panelDraft; showDate = false })
                .presentationDetents([.large])
                .presentationBackground(Palette.card)
                .presentationCornerRadius(28)
                .onDisappear { focus = .title }
        }
        .alert("新增標籤", isPresented: $addingTag) {
            TextField("標籤名稱", text: $tagText)
            Button("取消", role: .cancel) {}
            Button("新增") {
                let t = tagText.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                if !t.isEmpty && !tags.contains(t) { tags.append(t) }
            }
        }
        .onAppear {
            projectId = request.projectId ?? model.inbox?.id
            if let t = request.tag { tags = [model.tags.first { $0.name == t }?.label ?? t] }
            if let d = request.day {
                draft.day = d
                if let m = request.minute {
                    draft.allDay = false
                    draft.start = m
                    draft.end = m + 60
                    draft.timeZone = TimeZone.current.identifier
                }
            }
            focus = .title
        }
    }

    var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                panelDraft = draft
                showDate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 19))
                    if !dateLabel.isEmpty { Text(dateLabel).txt(15, .semibold).lineLimit(1) }
                }
                .foregroundStyle(dateColor)
                .padding(.horizontal, 8)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("日期與時間：" + (dateLabel.isEmpty ? "無" : dateLabel))
            .accessibilityIdentifier("composerDate")

            Menu {
                ForEach([Priority.high, .medium, .low, .none], id: \.self) { p in
                    Button {
                        priority = p
                    } label: {
                        if priority == p { Label(p.label + "優先", systemImage: "checkmark") } else { Text(p.label + "優先") }
                    }
                }
            } label: {
                tool(priority == .none ? "flag" : "flag.fill", tint: priority == .none ? Palette.textSecondary : Palette.priority(priority))
            }
            .accessibilityLabel("優先級：\(priority.label)")

            Menu {
                Button("新標籤…", systemImage: "plus") { tagText = ""; addingTag = true }
                if !model.tags.isEmpty {
                    Section("既有標籤") {
                        ForEach(model.tags) { t in
                            Button {
                                if tags.contains(t.label) { tags.removeAll { $0 == t.label } } else { tags.append(t.label) }
                            } label: {
                                if tags.contains(t.label) { Label("# " + t.label, systemImage: "checkmark") } else { Text("# " + t.label) }
                            }
                        }
                    }
                }
            } label: {
                tool("tag", tint: tags.isEmpty ? Palette.textSecondary : accent.text)
            }
            .accessibilityLabel("標籤")

            Menu {
                ForEach(model.projects) { p in
                    Button {
                        projectId = p.id
                    } label: {
                        if projectId == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 18))
                    Text(model.project(projectId)?.name ?? "收件匣").txt(13).lineLimit(1)
                }
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 40)
            }
            .accessibilityLabel("清單：\(model.project(projectId)?.name ?? "收件匣")")

            Menu {
                Button("新增並開啟詳細設定", systemImage: "square.and.pencil") { submit(openDetail: true) }
                    .disabled(!canSave)
                Button("關閉", systemImage: "xmark") { dismiss() }
            } label: {
                tool("ellipsis", tint: Palette.textSecondary)
            }
            .accessibilityLabel("更多")
            .accessibilityIdentifier("composerMore")

            Spacer(minLength: 0)

            Button { submit() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(canSave ? accent.onAccent : Palette.textFaint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSave ? accent.color : Palette.control))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityLabel("新增")
        }
    }

    func tool(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon).font(.system(size: 19)).foregroundStyle(tint).frame(width: 40, height: 40).contentShape(Rectangle())
    }

    var dateLabel: String {
        guard let d = draft.day else { return "" }
        var s = DateText.relative(d, today: model.today)
        if model.today.days(until: d) == -2 { s = "前天" }
        if draft.allDay, let e = draft.endDay, e > d { s += " – " + DateText.monthDay(e) }
        if !draft.allDay { s += " " + DateText.hm(draft.start) + (draft.end > draft.start ? "–" + DateText.hm(draft.end) : "") }
        if draft.repeatRule != nil { s += " ↻" }
        return s
    }

    var dateColor: Color {
        guard let d = draft.day else { return Palette.textSecondary }
        return d < model.today ? Palette.overdue : accent.text
    }

    func submit(openDetail: Bool = false) {
        guard canSave else { return }
        let input = CreateTaskInput(projectId: projectId, title: title, content: note, priority: priority,
                                    schedule: draft.schedule, reminders: draft.schedule == nil ? [] : draft.reminders,
                                    repeat: draft.schedule == nil ? nil : draft.repeatRule, tags: tags)
        Task {
            guard let t = await model.perform({ try await $0.createTask(input) }) else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if openDetail {
                dismiss()
                try? await Task.sleep(for: .milliseconds(350))
                model.detailTaskId = t.id
            } else {
                // Keep the composer open for the next task, like a quick-capture bar.
                title = ""
                note = ""
                added += 1
                focus = .title
            }
        }
    }
}
