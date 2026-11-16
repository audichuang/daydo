import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import DayDoCore

/// 3a / 3b · Task detail as a half-height sheet that expands to full on iPhone,
/// or as an inline editor pane on iPad. Title and description edits are buffered
/// and committed with 儲存 (which lights up once something changed); toggles apply immediately.
struct TaskDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var taskId: String

    @State private var detent: PresentationDetent = .fraction(0.56)
    @State private var dirty = false

    var body: some View {
        TaskDetailContent(
            taskId: taskId,
            isInline: false,
            isLargeDetent: detent == .large,
            onToggleDetent: {
                withAnimation(Motion.toggle(reduceMotion)) { detent = detent == .large ? .fraction(0.56) : .large }
            },
            onExpandForDate: {
                withAnimation(Motion.toggle(reduceMotion)) { detent = .large }
            },
            onDirtyChange: { dirty = $0 },
            onClose: { dismiss() }
        )
        .interactiveDismissDisabled(dirty)
        .adaptiveSheet(detents: [.fraction(0.56), .large], selection: $detent, dragIndicator: .visible)
    }
}

struct TaskDetailEmptyState: View {
    var body: some View {
        ZStack {
            Palette.card.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "checkmark.square")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Palette.textFaint)
                Text("選擇一項任務查看詳情")
                    .txt(15)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

struct TaskDetailContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var taskId: String
    var isInline: Bool = false
    var isLargeDetent: Bool = false
    var onToggleDetent: (() -> Void)? = nil
    var onExpandForDate: (() -> Void)? = nil
    var onDirtyChange: ((Bool) -> Void)? = nil
    var onClose: () -> Void

    enum Page { case detail, date, time }

    @State private var task: TodoTask?
    @State private var title = ""
    @State private var titleBaseline = ""
    @State private var content = ""
    @State private var contentBaseline = ""
    @State private var page: Page = .detail
    @State private var draft = DateDraft()
    @State private var newItem = ""
    @State private var showRaw = false
    @State private var addingTag = false
    @State private var tagText = ""
    @State private var importing = false
    @State private var preview: URL?
    @State private var savedFlash = false
    @State private var isSavingText = false
    @State private var isDeleting = false
    @FocusState private var focus: Field?
    enum Field { case title, content, item }

    private var titleDirty: Bool { title != titleBaseline }
    private var contentDirty: Bool { content != contentBaseline }

    var dirty: Bool {
        guard let task, !model.isViewer(projectId: task.projectId) else { return false }
        return titleDirty || contentDirty
    }

    var body: some View {
        ZStack {
            Palette.card.ignoresSafeArea()
            switch page {
            case .detail: detail
            case .date, .time:
                DateEditorFlow(draft: $draft, today: model.today, title: task?.title ?? "", excludeTaskId: task?.id,
                               cancel: { page = .detail }, confirm: commitDate)
            }
        }
        .onChange(of: dirty) { _, newValue in
            onDirtyChange?(newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            if isInline && phase == .background {
                saveText(auto: true)
            }
        }
        .onDisappear {
            saveText(auto: true)
            if isInline {
                if model.inlineDetailSubpageTaskId == taskId {
                    model.inlineDetailSubpageTaskId = nil
                }
                if model.inlineDetailFocusedTaskId == taskId {
                    model.inlineDetailFocusedTaskId = nil
                }
            }
        }
        .onChange(of: page, initial: true) { _, newPage in
            guard isInline else { return }
            if newPage == .detail {
                if model.inlineDetailSubpageTaskId == taskId {
                    model.inlineDetailSubpageTaskId = nil
                }
            } else {
                model.inlineDetailSubpageTaskId = taskId
            }
        }
        .onChange(of: focus, initial: true) { _, newFocus in
            guard isInline else { return }
            if newFocus == nil {
                if model.inlineDetailFocusedTaskId == taskId {
                    model.inlineDetailFocusedTaskId = nil
                }
            } else {
                model.inlineDetailFocusedTaskId = taskId
            }
        }
        .onChange(of: model.detailFocusTrigger) { _, _ in
            guard isInline, page == .detail, let task, !model.isViewer(projectId: task.projectId) else { return }
            focus = .title
        }
        .task(id: model.revision) { await load() }
        .quickLookPreview($preview)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            addFiles(urls)
        }
        .alert("新增標籤", isPresented: $addingTag) {
            TextField("標籤名稱", text: $tagText)
            Button("取消", role: .cancel) {}
            Button("新增") { addTag(tagText) }
        } message: {
            Text("輸入新標籤，或從下方既有標籤選擇")
        }
    }

    // MARK: Detail page

    @ViewBuilder var detail: some View {
        if let task {
            let readOnly = model.isViewer(projectId: task.projectId)
            let isDone = model.displaysCompleted(task)
            VStack(spacing: 0) {
                header(task, readOnly: readOnly)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusRow(task, readOnly: readOnly, isDone: isDone)
                        TextField("任務標題", text: $title, axis: .vertical)
                            .txt(22, .bold)
                            .foregroundStyle(isDone ? Palette.done : Palette.text)
                            .strikethrough(isDone, color: Palette.done)
                            .lineLimit(1...6)
                            .focused($focus, equals: .title)
                            .disabled(readOnly)
                            .accessibilityIdentifier("taskTitleField")
                        tagsRow(task, readOnly: readOnly)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("描述").txt(12, .semibold).foregroundStyle(Palette.textTertiary)
                            TextField("新增描述", text: $content, axis: .vertical)
                                .txt(15)
                                .lineSpacing(6)
                                .foregroundStyle(Palette.textBody)
                                .lineLimit(2...30)
                                .focused($focus, equals: .content)
                                .disabled(readOnly)
                                .accessibilityIdentifier("taskContentField")
                        }
                        checklist(task, readOnly: readOnly)
                        attachments(task, readOnly: readOnly)
                        if task.importNote != nil || task.sourceRaw != nil { importCard(task) }
                        Text(footer(task)).txt(12).foregroundStyle(Color(hex: "#737B78"))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 48)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        } else {
            ProgressView().tint(Palette.textSecondary)
        }
    }

    func header(_ task: TodoTask, readOnly: Bool) -> some View {
        HStack(spacing: 8) {
            if let onToggleDetent {
                Button(action: onToggleDetent) {
                    Image(systemName: isLargeDetent ? "chevron.down" : "chevron.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "#E6E9E8"))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Palette.control))
                }
                .buttonStyle(.press)
                .hoverEffect(.highlight)
                .accessibilityLabel(isLargeDetent ? "收合為半屏" : "展開為全屏")
            }

            Menu {
                ForEach(model.editableProjects) { p in
                    Button(p.name) {
                        let id = task.id
                        Task { await model.perform { try await $0.moveTask(id: id, toProjectId: p.id) } }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    ListDot(color: model.project(task.projectId)?.color, size: 9)
                    Text(model.project(task.projectId)?.name ?? "清單").txt(15, .semibold).lineLimit(1)
                    if !readOnly {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(Color(hex: "#E6E9E8"))
                .frame(height: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .disabled(readOnly)
            .accessibilityLabel("所屬清單：\(model.project(task.projectId)?.name ?? "")" + (readOnly ? "" : "，點擊更換"))

            if !readOnly {
                PillButton(title: !dirty && savedFlash ? "已儲存" : "儲存", kind: dirty ? .primary : .disabled) { saveText() }

                Menu {
                    Menu("優先級", systemImage: "flag") {
                        ForEach([Priority.high, .medium, .low, .none], id: \.self) { p in
                            Button(p.label) { model.updateTask(task.id) { $0.priority = p } }
                        }
                    }
                    Button("複製任務", systemImage: "plus.square.on.square") { duplicate(task) }
                    Button("刪除", systemImage: "trash", role: .destructive) {
                        let id = task.id
                        isDeleting = true
                        Task {
                            let deleted = await model.perform { try await $0.deleteTask(id: id) } != nil
                            if deleted {
                                onClose()
                            } else {
                                isDeleting = false
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "#E6E9E8"))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Palette.control))
                }
                .hoverEffect(.highlight)
                .accessibilityLabel("更多選項")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, isInline ? 8 : 16)
        .frame(height: isInline ? 56 : 68)
    }

    func statusRow(_ task: TodoTask, readOnly: Bool, isDone: Bool) -> some View {
        HStack(spacing: 4) {
            Button { toggleDone(task) } label: {
                TaskCheckbox(done: isDone, priority: task.priority, size: 22).frame(width: 44, height: 44)
            }
            .buttonStyle(.press(scale: 0.9, opacity: 0.85))
            .hoverEffect(.highlight)
            .disabled(readOnly)
            .accessibilityLabel(isDone ? "取消完成" : "完成任務")

            Button { openDate(task) } label: {
                HStack(spacing: 8) {
                    Text(dateSummary(task)).txt(15, .semibold).foregroundStyle(dateColor(task)).lineLimit(1)
                    if !task.reminders.isEmpty { Image(systemName: "bell").font(.system(size: 13)).foregroundStyle(Palette.textSecondary) }
                    if task.repeat != nil { Image(systemName: "repeat").font(.system(size: 13)).foregroundStyle(Palette.textSecondary) }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.985, opacity: 0.92))
            .hoverEffect(.highlight)
            .disabled(readOnly)
            .accessibilityLabel("設定日期與時間：\(dateSummary(task))")

            Menu {
                ForEach([Priority.high, .medium, .low, .none], id: \.self) { p in
                    Button(p.label + "優先") { model.updateTask(task.id) { $0.priority = p } }
                }
            } label: {
                Image(systemName: task.priority == .none ? "flag" : "flag.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.priority(task.priority))
                    .frame(width: 36, height: 36)
            }
            .hoverEffect(.highlight)
            .disabled(readOnly)
            .accessibilityLabel("優先級：\(task.priority.label)")
        }
        .padding(.leading, -12)
    }

    func tagsRow(_ task: TodoTask, readOnly: Bool) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(task.tags, id: \.self) { name in
                let tag = model.tags.first { $0.name == name }
                Menu {
                    if !readOnly {
                        Button("移除標籤", systemImage: "xmark", role: .destructive) {
                            let rest = task.tags.filter { $0 != name }
                            model.updateTask(task.id) { $0.tags = rest }
                        }
                    }
                    Button("查看此標籤的任務", systemImage: "number") {
                        model.scope = .tag(name); model.tab = .tasks
                        if !isInline { onClose() }
                    }
                } label: {
                    TagChip(name: name, label: tag?.label ?? name, color: tag?.color)
                }
            }
            if !readOnly {
                Menu {
                    Button("新標籤…", systemImage: "plus") { tagText = ""; addingTag = true }
                    let others = model.tags.filter { !task.tags.contains($0.name) }
                    if !others.isEmpty {
                        Section("既有標籤") {
                            ForEach(others) { t in Button("# " + t.label) { addTag(t.label) } }
                        }
                    }
                } label: {
                    Text("＋ 標籤").txt(12).foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(Palette.handle, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
            }
        }
    }

    func checklist(_ task: TodoTask, readOnly: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("子任務").txt(12, .semibold)
                Spacer()
                if !task.items.isEmpty { Text("\(task.completedItemCount) / \(task.items.count)").txt(12, .semibold) }
            }
            .foregroundStyle(Palette.textTertiary)
            .padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(task.items.enumerated()), id: \.element.id) { i, item in
                HStack(spacing: 12) {
                    Button {
                        let id = item.id, done = !item.isDone
                        Task { await model.perform { try await $0.updateChecklistItem(id: id, title: nil, done: done) } }
                    } label: {
                        Circle()
                            .strokeBorder(item.isDone ? accent.color : Color(hex: "#5B6461"), lineWidth: 2)
                            .background(Circle().fill(item.isDone ? accent.color : .clear))
                            .frame(width: 18, height: 18)
                            .frame(width: 30, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.press(scale: 0.9, opacity: 0.85))
                    .hoverEffect(.highlight)
                    .disabled(readOnly)
                    .accessibilityLabel((item.isDone ? "取消完成：" : "完成：") + item.title)
                    Text(item.title).txt(15).foregroundStyle(item.isDone ? Palette.done : Palette.text)
                        .strikethrough(item.isDone, color: Palette.done)
                    Spacer()
                }
                .frame(minHeight: 44)
                .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Palette.separatorSoft).frame(height: 1) } }
                .contextMenu {
                    if !readOnly {
                        Button("刪除子任務", systemImage: "trash", role: .destructive) {
                            let id = item.id
                            Task { await model.perform { try await $0.deleteChecklistItem(id: id) } }
                        }
                    }
                }
            }
            if !readOnly {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.textTertiary).frame(width: 30)
                    TextField("新增子任務", text: $newItem)
                        .txt(15)
                        .foregroundStyle(Palette.text)
                        .focused($focus, equals: .item)
                        .submitLabel(.next)
                        .onSubmit { addItem(task) }
                }
                .frame(minHeight: 44)
                .overlay(alignment: .top) { if !task.items.isEmpty { Rectangle().fill(Palette.separatorSoft).frame(height: 1) } }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .card(14, color: Palette.raised)
    }

    func attachments(_ task: TodoTask, readOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.attachments.isEmpty ? "附件" : "附件 \(task.attachments.count)").txt(12, .semibold).foregroundStyle(Palette.textTertiary)
                Spacer()
                if !readOnly {
                    Button { importing = true } label: {
                        Label("加入", systemImage: "paperclip").txt(12, .semibold).foregroundStyle(accent.text)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
            ForEach(task.attachments) { a in
                Button { preview = model.api.attachmentURL(a) } label: {
                    HStack(spacing: 12) {
                        let ext = (a.fileName as NSString).pathExtension.uppercased()
                        Text(ext.isEmpty ? "FILE" : String(ext.prefix(4)))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.background)
                            .frame(width: 34, height: 40, alignment: .bottom)
                            .padding(.bottom, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(fileColor(ext)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.fileName).txt(14, .semibold).foregroundStyle(Palette.text).lineLimit(1)
                            if let p = a.originalPath {
                                Text(p).txt(12).foregroundStyle(Palette.textTertiary).lineLimit(1).truncationMode(.head)
                            }
                        }
                        Spacer()
                        Text(a.size.byteText).txt(12).foregroundStyle(Palette.textTertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .card(12, color: Palette.raised)
                }
                .buttonStyle(.press(scale: 0.985, opacity: 0.92))
                .hoverEffect(.highlight)
                .contextMenu {
                    if !readOnly {
                        Button("移除附件", systemImage: "trash", role: .destructive) {
                            let id = a.id
                            Task { await model.perform { try await $0.deleteAttachment(id: id) } }
                        }
                    }
                }
            }
        }
    }

    func importCard(_ task: TodoTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note = task.importNote {
                Text(note).txt(13).foregroundStyle(Palette.textMuted).lineSpacing(3)
            }
            if let raw = task.sourceRaw {
                Button(showRaw ? "收合原文" : "查看原文") { withAnimation(Motion.toggle(reduceMotion)) { showRaw.toggle() } }
                    .txt(13, .semibold).foregroundStyle(accent.text)
                    .padding(.horizontal, 12).frame(height: 34)
                    .overlay(Capsule().strokeBorder(Color(hex: "#33363A")))
                    .buttonStyle(.plain)
                if showRaw {
                    ScrollView {
                        Text(raw).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.textNav)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .card(10, color: Color(hex: "#121314"))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(14, color: Palette.raised)
    }

    // MARK: Behaviour

    func load() async {
        let t: TodoTask
        do {
            t = try await model.api.getTask(id: taskId)
        } catch is CancellationError {
            return
        } catch DayDoError.notFound {
            onClose()
            return
        } catch {
            model.errorMessage = error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }
        let first = task == nil
        task = t
        if first, let p = UserDefaults.standard.string(forKey: "debugDetailPage") {
            UserDefaults.standard.removeObject(forKey: "debugDetailPage")
            openDate(t)
            if p == "time" { page = .time }
        }
        if first || !titleDirty {
            title = t.title
            titleBaseline = t.title
        }
        if first || !contentDirty {
            content = t.content
            contentBaseline = t.content
        }
    }

    func saveText(auto: Bool = false) {
        guard let task, !isSavingText, !isDeleting else { return }
        if auto && task.deletedAt != nil { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let saveTitle = titleDirty && (!auto || !trimmedTitle.isEmpty)
        let saveContent = contentDirty
        guard saveTitle || saveContent, !model.isViewer(projectId: task.projectId) else { return }
        let t = title, c = content
        var input = UpdateTaskInput(taskId: task.id)
        if saveTitle { input.title = t }
        if saveContent { input.content = c }
        let finalInput = input
        if !auto { focus = nil }
        isSavingText = true
        Task {
            defer { isSavingText = false }
            if auto {
                guard let current = try? await model.api.getTask(id: finalInput.taskId),
                      current.deletedAt == nil else { return }
            }
            if await model.perform({ try await $0.updateTask(finalInput) }) != nil {
                if saveTitle { titleBaseline = t }
                if saveContent { contentBaseline = c }
                savedFlash = true
            }
        }
    }

    func toggleDone(_ task: TodoTask) {
        model.toggleComplete(task)
    }

    func addItem(_ task: TodoTask) {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        newItem = ""
        let id = task.id
        Task {
            await model.perform { try await $0.addChecklistItem(taskId: id, title: text) }
            focus = .item
        }
    }

    func addTag(_ label: String) {
        guard let task else { return }
        let tags = task.tags + [label]
        model.updateTask(task.id) { $0.tags = tags }
    }

    func duplicate(_ task: TodoTask) {
        let input = CreateTaskInput(projectId: task.projectId, title: task.title, content: task.content, priority: task.priority,
                                    schedule: task.schedule, reminders: task.reminders, repeat: task.repeat,
                                    subtasks: task.items.map(\.title), tags: task.tags)
        Task { await model.perform { try await $0.createTask(input) } }
    }

    func addFiles(_ urls: [URL]) {
        guard let task else { return }
        let id = task.id
        Task {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let name = url.lastPathComponent
                let path = url.path
                await model.perform { try await $0.uploadAttachment(taskId: id, fileName: name, data: data, mimeType: mime, originalPath: path) }
            }
        }
    }

    func openDate(_ task: TodoTask) {
        draft = DateDraft(task: task, today: model.today)
        onExpandForDate?()
        withAnimation(Motion.toggle(reduceMotion)) {
            page = .date
        }
    }

    func commitDate() {
        guard let task else { return }
        let d = draft
        model.updateTask(task.id) { u in
            d.applyChanges(from: task, to: &u)
        }
        page = .detail
    }

    func dateSummary(_ task: TodoTask) -> String {
        guard let s = task.schedule else { return "設定日期" }
        let day = DateText.relative(s.startDay, today: model.today)
        if s.isAllDay {
            if s.isMultiDay { return "\(DateText.monthDay(s.startDay)) – \(DateText.monthDay(s.lastDay))・全天" }
            return day + "・全天"
        }
        return day + " " + DateText.range(s)
    }

    func dateColor(_ task: TodoTask) -> Color {
        guard task.schedule != nil else { return Palette.textSecondary }
        return TaskGrouping.isOverdue(task, today: model.today) ? Palette.overdue : accent.text
    }

    func footer(_ task: TodoTask) -> String {
        func fmt(_ ms: EpochMillis) -> String {
            let d = Date(epochMillis: ms)
            let day = LocalDay(date: d, in: .current)
            let hm = DateText.hm(Calendar.current.component(.hour, from: d) * 60 + Calendar.current.component(.minute, from: d))
            return (day == model.today ? "今天" : DateText.monthDay(day)) + " " + hm
        }
        var s = "建立於 \(fmt(task.createdAt))・最後修改 \(fmt(task.updatedAt))"
        if let c = task.completedAt { s += "・完成於 \(fmt(c))" }
        return s
    }

    func fileColor(_ ext: String) -> Color {
        switch ext {
        case "PDF": Color(hex: "#E98A5B")
        case "KEY", "PPT", "PPTX": Color(hex: "#4AA8E8")
        case "PNG", "JPG", "JPEG", "HEIC", "GIF": Color(hex: "#4FC3A1")
        case "DOC", "DOCX", "PAGES", "TXT", "MD": Color(hex: "#9BB8FF")
        default: Color(hex: "#C9CFCC")
        }
    }
}
