import SwiftUI
import DayDoCore

/// 1b / 1c · Task list for a smart list, project or tag, in collapsible
/// section cards. Density toggles between standard and compact.
struct TaskListScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    var scope: TaskScope

    @State private var sections: [TaskSection] = []
    @State private var loaded = false
    @State private var limits: [TaskScope: Int] = [:]
    @AppStorage("closedSections") private var closedRaw = "completed"

    var closed: Set<String> { Set(closedRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.scopeTitle(scope)).txt(30, .bold).foregroundStyle(Palette.text)
                        Text(subtitle).txt(14).foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.horizontal, 4)

                    if loaded && sections.isEmpty {
                        EmptyState(scope: scope)
                    }
                    ForEach(sections) { sec in
                        SectionCard(section: sec, scope: scope, closed: closed.contains(sec.id)) { toggle(sec.id) }
                    }
                    if sections.contains(where: \.hasMore) {
                        Button { loadMore() } label: {
                            Text("載入更多").txt(13, .semibold).foregroundStyle(accent.text)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                    } else if !sections.isEmpty {
                        Text("已顯示全部").txt(12).foregroundStyle(Palette.textFaint).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 60)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)

            ScreenHeader {
                EmptyView()
            } trailing: {
                if scope != .smart(.trash) && scope != .smart(.completed) {
                    HeaderAction(systemName: "plus", label: "新增任務", tint: accent.text) { compose() }
                }
                HeaderAction(systemName: model.compact ? "line.3.horizontal.decrease" : "line.3.horizontal", label: "切換密度：目前\(model.compact ? "緊湊" : "標準")") {
                    withAnimation(.snappy) { model.compact.toggle() }
                }
                Menu {
                    if case .project(let id) = scope {
                        Button("編輯清單", systemImage: "slider.horizontal.3") { model.editingProjectId = id }
                    }
                    if let overdue = sections.first(where: { $0.id == "overdue" }) {
                        Button("全部延到今天", systemImage: "arrow.uturn.forward") { postpone(overdue.tasks.map(\.id)) }
                    }
                    Button(closed.contains("completed") ? "顯示已完成" : "收合已完成", systemImage: "checkmark.circle") { toggle("completed") }
                    Button("設定", systemImage: "gearshape") { model.showSettings = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.text).frame(width: 44, height: 40)
                }
                .accessibilityLabel("更多選項")
            }
        }
        .task(id: TaskReload(scope: scope, revision: model.revision, limit: limits[scope])) { await load() }
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
            sections = loadedSections
            loaded = true
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
        withAnimation(.snappy) { closedRaw = c.sorted().joined(separator: ",") }
    }

    func postpone(_ ids: [String]) { Task { await model.perform { try await $0.postponeOverdue(taskIds: ids) } } }

    func compose() {
        var req = ComposeRequest()
        switch scope {
        case .project(let id): req.projectId = id
        case .tag(let t): req.tag = t
        case .smart(.today): req.day = model.today
        case .smart(.tomorrow): req.day = model.today.adding(days: 1)
        default: break
        }
        model.composing = req
    }
}

struct TaskReload: Hashable { var scope: TaskScope; var revision: Int; var limit: Int? }

struct SectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
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

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(section.title).txt(15, .bold).foregroundStyle(titleColor)
                    Spacer()
                    if section.id == "overdue" {
                        Button("全部延到今天") {
                            let ids = section.tasks.map(\.id)
                            Task { await model.perform { try await $0.postponeOverdue(taskIds: ids) } }
                        }
                        .txt(13, .semibold).foregroundStyle(accent.text).padding(.trailing, 6).buttonStyle(.plain)
                    }
                    Text("\(section.tasks.count)").txt(13).foregroundStyle(Palette.textTertiary)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                        .rotationEffect(.degrees(closed ? -90 : 0))
                }
                .padding(.leading, 16).padding(.trailing, 14)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(closed ? "已收合" : "已展開")

            if !closed {
                ForEach(Array(section.tasks.enumerated()), id: \.element.id) { i, t in
                    TaskRow(task: t, separator: i > 0, sectionId: section.id, inTrash: scope == .smart(.trash))
                }
            }
        }
        .card()
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    var task: TodoTask
    var separator: Bool
    var sectionId: String
    var inTrash = false

    var body: some View {
        let compact = model.compact
        let pad: CGFloat = compact ? 9 : 12
        HStack(alignment: .top, spacing: 0) {
            Button { toggle() } label: {
                TaskCheckbox(done: task.isCompleted, priority: task.priority)
                    .padding(.top, pad + 1)
                    .frame(width: 48, alignment: .top)
                    .frame(minHeight: 44, alignment: .top)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(inTrash)
            .accessibilityLabel((task.isCompleted ? "取消完成：" : "完成：") + task.title)

            Button { model.detailTaskId = task.id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .txt(17, .medium)
                        .foregroundStyle(task.isCompleted ? Palette.done : Palette.text)
                        .strikethrough(task.isCompleted, color: Palette.done)
                        .lineLimit(compact ? 1 : 2)
                        .multilineTextAlignment(.leading)
                    if !compact, !task.content.isEmpty {
                        Text(firstLine(task.content)).txt(14).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    meta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, pad)
                .padding(.trailing, 16)
                .overlay(alignment: .top) { if separator { Rectangle().fill(Palette.separator).frame(height: 1) } }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu { menu }
    }

    @ViewBuilder var meta: some View {
        let project = model.project(task.projectId)
        let line = dateLine
        HStack(spacing: 10) {
            if !line.isEmpty && !task.isCompleted {
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
            if task.repeat != nil && !task.isCompleted {
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
        if inTrash {
            Button("還原", systemImage: "arrow.uturn.backward") { Task { await model.perform { try await $0.restoreTask(id: id) } } }
            Button("永久刪除", systemImage: "trash", role: .destructive) { Task { await model.perform { try await $0.purgeTask(id: id) } } }
        } else {
            Menu("優先級", systemImage: "flag") {
                ForEach([Priority.high, .medium, .low, .none], id: \.self) { p in
                    Button(p.label) { model.updateTask(id) { $0.priority = p } }
                }
            }
            Menu("移到清單", systemImage: "folder") {
                ForEach(model.projects) { p in
                    Button(p.name) { Task { await model.perform { try await $0.moveTask(id: id, toProjectId: p.id) } } }
                }
            }
            Menu("日期", systemImage: "calendar") {
                Button("今天") { setDay(model.today) }
                Button("明天") { setDay(model.today.adding(days: 1)) }
                Button("下週一") { setDay(nextMonday) }
                Button("清除日期") { model.updateTask(id) { $0.schedule = .clear } }
            }
            Button("刪除", systemImage: "trash", role: .destructive) { Task { await model.perform { try await $0.deleteTask(id: id) } } }
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
