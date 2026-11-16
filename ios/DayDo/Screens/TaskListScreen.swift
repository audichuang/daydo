import SwiftUI
import DayDoCore

/// 1b / 1c · Task list for a smart list, project or tag, in collapsible
/// section cards. Density toggles between standard and compact.
struct TaskListScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.isRegularWindow) private var isRegular
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scope: TaskScope

    @State private var sections: [TaskSection] = []
    @State private var loaded = false
    @State private var loadedScope: TaskScope?
    @State private var limits: [TaskScope: Int] = [:]
    @State private var shareText: String?
    @AppStorage("closedSections") private var closedRaw = "completed"

    var closed: Set<String> { Set(closedRaw.split(separator: ",").map(String.init)) }

    var isViewerScope: Bool {
        if case .project(let id) = scope { return model.isViewer(projectId: id) }
        return false
    }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            if isRegular {
                Palette.background.ignoresSafeArea()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.scopeTitle(scope)).txt(30, .bold).foregroundStyle(Palette.text)
                        Text(subtitle)
                            .txt(14)
                            .foregroundStyle(Palette.textSecondary)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .animation(
                                loadedScope == scope
                                    ? (reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.25))
                                    : nil,
                                value: subtitle
                            )
                    }
                    .padding(.horizontal, 4)

                    Group {
                        if loaded && sections.isEmpty {
                            EmptyState(scope: scope)
                                .transition(.opacity)
                        }
                        ForEach(sections) { sec in
                            SectionCard(section: sec, scope: scope, closed: closed.contains(sec.id)) { toggle(sec.id) }
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        }
                    }
                    .id(loadedScope)
                    if sections.contains(where: \.hasMore) {
                        Button { loadMore() } label: {
                            Text("載入更多").txt(13, .semibold).foregroundStyle(accent.text)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.press)
                        .hoverEffect(.highlight)
                    } else if !sections.isEmpty {
                        Text("已顯示全部").txt(12).foregroundStyle(Palette.textFaint).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, isRegular ? 12 : 60)
                .padding(.bottom, isRegular ? 32 : 140)
            }
            .scrollIndicators(.hidden)

            if !isRegular {
                ScreenHeader {
                    EmptyView()
                } trailing: {
                    trailingActions
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRegular {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    trailingActions
                }
            }
        }
        .task(id: TaskReload(scope: scope, revision: model.revision, limit: limits[scope])) { await load() }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if scope != .smart(.trash) && scope != .smart(.completed) && !isViewerScope {
            HeaderAction(systemName: "plus", label: "新增任務", tint: accent.text) { compose() }
        }
        if case .project(let id) = scope, !(model.project(id)?.isInbox ?? false) {
            HeaderAction(systemName: "person.crop.circle.badge.plus", label: "共享") { model.sharingProjectId = id }
        }
        Menu {
            if case .project(let id) = scope {
                let proj = model.project(id)
                let currentView = proj?.viewMode ?? "list"
                if !(proj?.isViewer ?? false) {
                    Button("編輯", systemImage: "slider.horizontal.3") { model.editingProjectId = id }
                    Menu("視圖", systemImage: "rectangle.grid.1x2") {
                        viewMenuItem("列表", mode: "list", current: currentView, projectId: id)
                        viewMenuItem("看板", mode: "kanban", current: currentView, projectId: id)
                        viewMenuItem("時間軸", mode: "timeline", current: currentView, projectId: id)
                    }
                }
            }
            Button(model.compact ? "顯示詳情" : "隱藏詳情", systemImage: model.compact ? "eye" : "eye.slash") {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) { model.compact.toggle() }
            }
            Button(closed.contains("completed") ? "顯示已完成" : "隱藏已完成", systemImage: "checkmark.circle") { toggle("completed") }
            if let overdue = sections.first(where: { $0.id == "overdue" }),
               !isViewerScope,
               !model.editableTaskIds(in: overdue.tasks).isEmpty {
                Divider()
                Button("全部延到今天", systemImage: "arrow.uturn.forward") { model.postponeOverdue(tasks: overdue.tasks) }
            }
            if case .project(let id) = scope, let proj = model.project(id), !proj.isInbox {
                Divider()
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button("共享協作", systemImage: "person.2") { model.sharingProjectId = id }
                    Button("分享", systemImage: "square.and.arrow.up") { shareText = projectShareText(proj) }
                    Button("複製清單", systemImage: "doc.on.doc") { duplicate(id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.text).frame(width: 44, height: 40)
        }
        .hoverEffect(.highlight)
        .background(ActivityAnchor(text: $shareText))
        .accessibilityLabel("更多選項")
    }

    var subtitle: String {
        let active = sections.filter { $0.id != "completed" && $0.id != "trash" }.reduce(0) { $0 + $1.tasks.count }
        switch scope {
        case .smart(.today): return "\(DateText.full(model.today)) · \(model.counts.today) 項待辦"
        case .smart(.completed): return "\(sections.first?.tasks.count ?? 0) 項"
        case .smart(.trash): return "刪除的任務可在這裡還原"
        default: return "\(active) 項待辦"
        }
    }

    func load() async {
        do {
            let loadedSections = try await model.api.listSections(scope, limit: limits[scope])
            guard !Task.isCancelled else { return }
            let shouldAnimate = loaded && loadedScope == scope
            if shouldAnimate {
                let anim: Animation = reduceMotion
                    ? .easeOut(duration: 0.18)
                    : .spring(response: 0.36, dampingFraction: 0.86)
                withAnimation(anim) {
                    sections = loadedSections
                    loaded = true
                    loadedScope = scope
                }
            } else {
                sections = loadedSections
                loaded = true
                loadedScope = scope
            }
        } catch is CancellationError {
            return
        } catch {
            // A list deleted from another screen: fall back to Today.
            if case DayDoError.notFound = error { model.scope = .smart(.today) } else { model.errorMessage = error.localizedDescription }
        }
    }

    func loadMore() {
        let current = sections.first(where: \.hasMore)?.tasks.count ?? 0
        let step = (scope == .smart(.completed) || scope == .smart(.trash)) ? 300 : 30
        limits[scope] = current + step
    }

    func toggle(_ id: String) {
        var c = closed
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        let anim: Animation = reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)
        withAnimation(anim) { closedRaw = c.sorted().joined(separator: ",") }
    }

    @ViewBuilder
    func viewMenuItem(_ title: String, mode: String, current: String, projectId: String) -> some View {
        Button {
            var u = UpdateProjectInput(projectId: projectId)
            u.viewMode = mode
            let input = u
            Task { await model.perform { try await $0.updateProject(input) } }
        } label: {
            if current == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    func duplicate(_ projectId: String) {
        Task {
            if let copy = await model.perform({ try await $0.duplicateProject(id: projectId) }) {
                model.scope = .project(copy.id)
            }
        }
    }

    func projectShareText(_ project: Project) -> String {
        let active = sections.filter { $0.id != "completed" && $0.id != "trash" }.flatMap(\.tasks)
        let lines = active.map { t in
            if let sched = t.schedule {
                return "□ \(t.title)  \(DateText.taskLine(sched, today: model.today))"
            }
            return "□ \(t.title)"
        }
        return ([project.name] + lines).joined(separator: "\n")
    }

    func compose() {
        model.openComposerForCurrentScope()
    }
}

struct TaskReload: Hashable { var scope: TaskScope; var revision: Int; var limit: Int? }

struct SectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var section: TaskSection
    var scope: TaskScope
    var closed: Bool
    var toggle: () -> Void

    var titleColor: Color {
        switch section.id {
        case "overdue": Palette.overdue
        case "completed", "trash": Palette.textSecondary
        default: Palette.text
        }
    }

    var isViewerScope: Bool {
        if case .project(let id) = scope { return model.isViewer(projectId: id) }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(section.title).txt(15, .bold).foregroundStyle(titleColor)
                    Spacer()
                    if section.id == "overdue",
                       !isViewerScope,
                       !model.editableTaskIds(in: section.tasks).isEmpty {
                        Button("全部延到今天") {
                            model.postponeOverdue(tasks: section.tasks)
                        }
                        .txt(13, .semibold).foregroundStyle(accent.text).padding(.trailing, 6).buttonStyle(.press)
                        .hoverEffect(.highlight)
                    }
                    Text("\(section.tasks.count)")
                        .txt(13)
                        .foregroundStyle(Palette.textTertiary)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                        .rotationEffect(.degrees(closed ? -90 : 0))
                }
                .padding(.leading, 16).padding(.trailing, 14)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.99, opacity: 0.92))
            .hoverEffect(.highlight)
            .accessibilityValue(closed ? "已收合" : "已展開")

            if !closed {
                VStack(spacing: 0) {
                    ForEach(Array(section.tasks.enumerated()), id: \.element.id) { i, t in
                        TaskRow(task: t, separator: i > 0, sectionId: section.id, inTrash: scope == .smart(.trash), selectsInline: true)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            ))
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .card()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.isRegularWindow) private var isRegularWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var task: TodoTask
    var separator: Bool
    var sectionId: String
    var inTrash = false
    var selectsInline = false

    private var usesInlineSelection: Bool {
        selectsInline && isRegularWindow
    }

    private var isSelected: Bool {
        usesInlineSelection && model.selectedTaskId == task.id
    }

    private var isDone: Bool {
        task.isCompleted || model.isCompleting(task)
    }

    var body: some View {
        let compact = model.compact
        let pad: CGFloat = compact ? 9 : 12
        HStack(alignment: .top, spacing: 0) {
            Button { toggle() } label: {
                TaskCheckbox(done: isDone, priority: task.priority)
                    .padding(.top, pad + 1)
                    .frame(width: 48, alignment: .top)
                    .frame(minHeight: 44, alignment: .top)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.9, opacity: 0.85))
            .hoverEffect(.highlight)
            .disabled(inTrash || model.isViewer(projectId: task.projectId))
            .accessibilityLabel((isDone ? "取消完成：" : "完成：") + task.title)

            Button {
                model.openTask(task.id, inlineAvailable: usesInlineSelection)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .txt(17, .medium)
                        .foregroundStyle(isDone ? Palette.done : Palette.text)
                        .strikethrough(isDone, color: Palette.done)
                        .lineLimit(compact ? 1 : 2)
                        .multilineTextAlignment(.leading)
                    if !compact, !task.content.isEmpty {
                        Text(firstLine(task.content)).txt(14).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    meta
                }
                .opacity(isDone ? 0.75 : 1)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.75), value: isDone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, pad)
                .padding(.trailing, 16)
                .overlay(alignment: .top) { if separator && !isSelected { Rectangle().fill(Palette.separator).frame(height: 1) } }
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.985, opacity: 0.95, highlight: Color.white.opacity(0.05)))
            .hoverEffect(.highlight)
        }
        .background(isSelected ? accent.soft : .clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { menu }
    }

    @ViewBuilder var meta: some View {
        let project = model.project(task.projectId)
        let line = dateLine
        HStack(spacing: 10) {
            if !line.isEmpty && !isDone {
                Text(line).txt(13, .semibold).foregroundStyle(dateColor).lineLimit(1)
            }
            if !task.items.isEmpty {
                Label("\(task.completedItemCount)/\(task.items.count)", systemImage: "list.bullet").labelStyle(MetaLabel())
            }
            if task.commentCount > 0 {
                Label("\(task.commentCount)", systemImage: "bubble.left").labelStyle(MetaLabel())
            }
            if !task.attachments.isEmpty {
                Label("\(task.attachments.count)", systemImage: "paperclip").labelStyle(MetaLabel())
            }
            if task.repeat != nil && !isDone {
                Image(systemName: "repeat").font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 0)
            if let project, project.isShared {
                AvatarStack(members: model.members.filter { project.memberIds.contains($0.id) })
            }
            if let project {
                HStack(spacing: 5) {
                    ListDot(color: project.color)
                    Text(project.name).txt(13).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
        }
        .frame(minHeight: 18)
    }

    var dateLine: String {
        guard let s = task.schedule else { return "" }
        return DateText.taskLine(s, today: model.today)
    }

    var dateColor: Color {
        guard let s = task.schedule else { return Palette.textMuted }
        if sectionId == "overdue" || TaskGrouping.isOverdue(task, today: model.today) { return Palette.overdue }
        if s.occurs(on: model.today) { return accent.text }
        return s.startDay > model.today ? accent.text.opacity(0.85) : Palette.textMuted
    }

    func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
    }

    func toggle() {
        model.toggleComplete(task)
    }

    @ViewBuilder var menu: some View {
        let id = task.id
        let isViewer = model.isViewer(projectId: task.projectId)
        if inTrash {
            if !isViewer {
                Button("還原", systemImage: "arrow.uturn.backward") { Task { await model.perform { try await $0.restoreTask(id: id) } } }
                Button("永久刪除", systemImage: "trash", role: .destructive) { Task { await model.purgeTask(id: id) } }
            }
        } else if !isViewer {
            Menu("優先級", systemImage: "flag") {
                ForEach([Priority.high, .medium, .low, .none], id: \.self) { p in
                    Button(p.label) { model.updateTask(id) { $0.priority = p } }
                }
            }
            Menu("移到清單", systemImage: "folder") {
                ForEach(model.editableProjects) { p in
                    Button(p.name) { Task { await model.perform { try await $0.moveTask(id: id, toProjectId: p.id) } } }
                }
            }
            Menu("日期", systemImage: "calendar") {
                Button("今天") { setDay(model.today) }
                Button("明天") { setDay(model.today.adding(days: 1)) }
                Button("下週一") { setDay(nextMonday) }
                Button("清除日期") { model.updateTask(id) { $0.schedule = .clear } }
            }
            Button("刪除", systemImage: "trash", role: .destructive) {
                Task {
                    await model.perform { try await $0.deleteTask(id: id) }
                    if model.selectedTaskId == id { model.selectedTaskId = nil }
                }
            }
        }
    }

    var nextMonday: LocalDay {
        let t = model.today
        return t.adding(days: ((8 - t.weekday) % 7 == 0) ? 7 : (8 - t.weekday) % 7)
    }

    func setDay(_ d: LocalDay) {
        let s = task.schedule?.moved(to: d) ?? .allDay(d)
        model.updateTask(task.id) { $0.schedule = .set(s) }
    }
}

struct MetaLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 11))
            configuration.title.txt(13)
        }
        .foregroundStyle(Palette.textTertiary)
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    var scope: TaskScope

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: scope == .smart(.trash) ? "trash" : "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.textFaint)
            Text(message).txt(15).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .card()
    }

    var message: String {
        switch scope {
        case .smart(.today): "今天沒有待辦。按右上角 ＋ 新增一項。"
        case .smart(.trash): "垃圾桶是空的"
        case .smart(.completed): "還沒有完成的任務"
        default: "這裡還沒有任務"
        }
    }
}
