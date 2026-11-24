import SwiftUI
import UniformTypeIdentifiers
import DayDoCore

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.isRegularWindow) private var isRegularWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var task: TodoTask
    var separator: Bool
    var sectionKind: TaskSection.Kind
    var sectionId: String? = nil
    var inTrash = false
    var selectsInline = false
    var showProject = true

    private var usesInlineSelection: Bool {
        selectsInline && isRegularWindow
    }

    private var isSelected: Bool {
        guard usesInlineSelection else { return false }
        if let sectionId, let selectedRow = model.selectedTaskRow {
            return selectedRow == TaskRowSelection(sectionId: sectionId, taskId: task.id)
        }
        return model.selectedTaskId == task.id
    }

    private var isDone: Bool {
        model.displaysCompleted(task)
    }

    var body: some View {
        if Platform.isMac {
            macBody
        } else {
            touchBody
        }
    }

    /// Mac: one dense desktop row, title and description on the left, date and list on the
    /// right (TickTick Mac layout) instead of the stacked three-line touch row.
    private var macBody: some View {
        let compact = model.compact
        let project = showProject ? model.project(task.projectId) : nil
        let line = dateLine
        return HStack(alignment: .top, spacing: 0) {
            Button { toggle() } label: {
                TaskCheckbox(done: isDone, priority: task.priority, size: 15)
                    .padding(.top, 9)
                    .frame(width: 32, alignment: .top)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.9, opacity: 0.85))
            .disabled(inTrash || model.isViewer(projectId: task.projectId))
            .accessibilityLabel((isDone ? "取消完成：" : "完成：") + task.title)

            Button {
                model.openTask(task.id, sectionId: sectionId, inlineAvailable: usesInlineSelection)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .txt(14, .medium)
                            .foregroundStyle(isDone ? Palette.done : Palette.text)
                            .strikethrough(isDone, color: Palette.done)
                            .lineLimit(1)
                        if !compact, !task.content.isEmpty {
                            Text(firstLine(task.content)).txt(12).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 8) {
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
                                Image(systemName: "repeat").font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                            }
                            if let countdown = countdownText {
                                Text(countdown).txt(11, .semibold).foregroundStyle(accent.text)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(accent.soft))
                                    .accessibilityIdentifier("taskCountdownBadge")
                            }
                            if !line.isEmpty && !isDone {
                                Text(line).txt(12, .medium).foregroundStyle(dateColor).lineLimit(1)
                            }
                        }
                        if let project, !compact || line.isEmpty {
                            HStack(spacing: 4) {
                                ListDot(color: project.color)
                                Text(project.name).txt(11).foregroundStyle(Palette.textTertiary).lineLimit(1)
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .opacity(isDone ? 0.75 : 1)
                .animation(Motion.check(reduceMotion), value: isDone)
                .padding(.vertical, 7)
                .padding(.trailing, 10)
                .overlay(alignment: .top) { if separator && !isSelected { Rectangle().fill(Palette.separatorSoft).frame(height: 1) } }
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 1, opacity: 0.95, highlight: Palette.pressHighlightStrong))
        }
        .padding(.leading, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? accent.soft : .clear))
        .hoverEffect(.highlight)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { menu }
    }

    @ViewBuilder
    private var touchBody: some View {
        let compact = model.compact
        let pad: CGFloat = Platform.isMac ? (compact ? 6 : 8) : (compact ? 9 : 12)
        HStack(alignment: .top, spacing: 0) {
            Button { toggle() } label: {
                TaskCheckbox(done: isDone, priority: task.priority, size: Platform.isMac ? 17 : 20)
                    .padding(.top, pad + 1)
                    .frame(width: Platform.isMac ? 38 : 48, alignment: .top)
                    .frame(minHeight: Platform.isMac ? 34 : 44, alignment: .top)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.9, opacity: 0.85))
            .hoverEffect(.highlight)
            .disabled(inTrash || model.isViewer(projectId: task.projectId))
            .accessibilityLabel((isDone ? "取消完成：" : "完成：") + task.title)

            Button {
                model.openTask(task.id, sectionId: sectionId, inlineAvailable: usesInlineSelection)
            } label: {
                VStack(alignment: .leading, spacing: Platform.isMac ? 2 : 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(task.title)
                            .txt(17, .medium)
                            .foregroundStyle(isDone ? Palette.done : Palette.text)
                            .strikethrough(isDone, color: Palette.done)
                            .lineLimit(compact ? 1 : 2)
                            .multilineTextAlignment(.leading)
                        if let countdown = countdownText {
                            Spacer(minLength: 4)
                            Text(countdown)
                                .txt(12, .semibold)
                                .foregroundStyle(accent.text)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(accent.soft))
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                                .accessibilityIdentifier("taskCountdownBadge")
                        }
                    }
                    if !compact, !task.content.isEmpty {
                        Text(firstLine(task.content)).txt(14).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    if hasMeta { meta }
                }
                .opacity(isDone ? 0.75 : 1)
                .animation(Motion.check(reduceMotion), value: isDone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, pad)
                .padding(.trailing, 16)
                .overlay(alignment: .top) { if separator && !isSelected { Rectangle().fill(Palette.separator).frame(height: 1) } }
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.985, opacity: 0.95, highlight: Palette.pressHighlightStrong))
            .hoverEffect(.highlight)
        }
        .background(isSelected ? accent.soft : .clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { menu }
    }

    private var hasMeta: Bool {
        (!dateLine.isEmpty && !isDone) || !task.items.isEmpty || task.commentCount > 0 || !task.attachments.isEmpty
            || (task.repeat != nil && !isDone) || (showProject && model.project(task.projectId) != nil)
    }

    @ViewBuilder var meta: some View {
        let project = showProject ? model.project(task.projectId) : nil
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
            if let project {
                HStack(spacing: 5) {
                    ListDot(color: project.color)
                    Text(project.name).txt(13).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
        }
        .frame(minHeight: 18)
    }

    /// Day a single-day section stands for (明天, 未來 7 天 day groups); its header already names it.
    private var sectionDay: LocalDay? {
        switch sectionKind {
        case .tomorrow: return model.today.adding(days: 1)
        case .day(let day): return day
        default: return nil
        }
    }

    var dateLine: String {
        guard let s = task.schedule else { return "" }
        guard let day = sectionDay else { return DateText.taskLine(s, today: model.today) }
        if s.isAllDay && !s.isMultiDay { return "" }
        return DateText.taskLine(s, on: day, today: model.today)
    }

    var countdownText: String? {
        guard !isDone, !inTrash else { return nil }
        return DateText.countdownLabel(for: task, today: model.today)
    }

    var dateColor: Color {
        guard let s = task.schedule else { return Palette.textMuted }
        if sectionKind == .overdue || TaskGrouping.isOverdue(task, today: model.today) { return Palette.overdue }
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
        TaskContextMenu(task: task, inTrash: inTrash)
    }
}

/// Right-click / long-press actions for a task, shared by list rows and Mac calendar blocks.
struct TaskContextMenu: View {
    @Environment(AppModel.self) private var model
    var task: TodoTask
    var inTrash = false

    var body: some View {
        menu
    }

    @ViewBuilder var menu: some View {
        let id = task.id
        let isViewer = model.isViewer(projectId: task.projectId)
        if inTrash {
            if !isViewer {
                Button("還原", systemImage: "arrow.uturn.backward") { Task { await model.restoreTask(id: id) } }
                Button("永久刪除", systemImage: "trash", role: .destructive) { Task { await model.purgeTask(id: id) } }
            }
        } else if !isViewer {
            if Platform.isMac {
                let done = model.displaysCompleted(task)
                Button(done ? "取消完成" : "完成", systemImage: done ? "circle" : "checkmark.circle") { model.toggleComplete(task) }
            }
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
                Task { await model.deleteTask(id: id) }
            }
        }
    }

    var nextMonday: LocalDay {
        let t = model.today
        return t.adding(days: ((8 - t.weekday) % 7 == 0) ? 7 : (8 - t.weekday) % 7)
    }

    func setDay(_ d: LocalDay) {
        let s = Schedule.moved(task.schedule, to: d)
        let task = task
        Task { await model.moveTask(task, to: s) }
    }
}

extension View {
    /// Mac only: on iPad a context menu would take the long press that drags calendar blocks.
    @ViewBuilder
    func macTaskContextMenu(_ task: TodoTask?) -> some View {
        if Platform.isMac, let task {
            contextMenu { TaskContextMenu(task: task) }
        } else {
            self
        }
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
