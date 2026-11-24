import SwiftUI
import DayDoCore

/// Quick add docked above the keyboard: title, description and one row of
/// tools (date/time, priority, tags, list, more). Return or the send button
/// adds the task and clears the fields for the next one.
struct ComposerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRegularWindow) private var isRegularWindow
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
    @State private var createdHaptic = 0
    @State private var isSubmitting = false
    @State private var contentHeight: CGFloat = 168
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
        .sensoryFeedback(.impact(weight: .light), trigger: createdHaptic)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            let clamped = min(max(height, 168), 340)
            if abs(contentHeight - clamped) > 1 {
                contentHeight = clamped
            }
        }
        .frame(maxHeight: Platform.isMac ? nil : .infinity, alignment: .top)
        .frame(minHeight: isRegularWindow && !Platform.isMac ? 220 : nil)
        .adaptiveSheet(detents: [.height(contentHeight)], dragIndicator: .hidden, macSize: CGSize(width: 460, height: 176))
        .sheet(isPresented: $showDate) {
            DateEditorFlow(draft: $panelDraft, today: model.today, title: title, excludeTaskId: nil,
                           cancel: { showDate = false }, confirm: { draft = panelDraft; showDate = false })
                .environment(model)
                .adaptiveSheet(detents: [.large], macSize: CGSize(width: 420, height: 560))
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
            projectId = model.resolvedProjectId(for: request)
            tags = model.resolvedTags(for: request)
            if let d = request.day {
                draft.day = d
                if let m = request.minute {
                    draft.allDay = false
                    draft.start = m
                    draft.end = request.endMinute ?? (m + 60)
                    draft.stampTimeZoneIfFloating(TimeZone.current.identifier)
                }
            }
            focus = .title
        }
    }

    var canSave: Bool { !isSubmitting && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
            .buttonStyle(.press)
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
                ForEach(model.editableProjects) { p in
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
                if Platform.isMac {
                    // Desktop dialog button (Return also submits), not the phone send arrow.
                    Text("新增")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canSave ? accent.onAccent : Palette.textFaint)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(canSave ? accent.color : Palette.control))
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(canSave ? accent.onAccent : Palette.textFaint)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(canSave ? accent.color : Palette.control))
                }
            }
            .buttonStyle(.press)
            .hoverEffect(.highlight)
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
        let snapTitle = title
        let snapNote = note
        isSubmitting = true
        let input = CreateTaskInput(projectId: projectId, title: snapTitle, content: snapNote, priority: priority,
                                    schedule: draft.schedule, reminders: draft.schedule == nil ? [] : draft.reminders,
                                    repeat: draft.schedule == nil ? nil : draft.repeatRule, tags: tags,
                                    assigneeId: request.assigneeId)
        Task {
            let created = await model.perform { try await $0.createTask(input) }
            isSubmitting = false
            guard let t = created else { return }
            await model.revealCreatedTaskInAll(t)
            createdHaptic += 1
            if openDetail {
                dismiss()
                try? await Task.sleep(for: .milliseconds(350))
                model.openTask(t.id, inlineAvailable: isRegularWindow)
            } else {
                // Keep the composer open for the next task, like a quick-capture bar.
                if title == snapTitle { title = "" }
                if note == snapNote { note = "" }
                added += 1
                focus = .title
            }
        }
    }
}
