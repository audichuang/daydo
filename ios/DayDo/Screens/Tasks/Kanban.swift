import SwiftUI
import UniformTypeIdentifiers
import DayDoCore

/// Drag payload for a Kanban card carrying its actual source column so cross-midnight
/// tasks can move from Today to Tomorrow, and conditionally exporting `.propertyList`
/// only when clearing the schedule is safe (no repeat rule or reminders).
struct KanbanDragPayload: Codable, Equatable, Sendable, Transferable {
    var sourceSectionId: String
    var taskId: String
    var canClearSchedule: Bool

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .propertyList) { payload in
            try JSONEncoder().encode(payload)
        }
        .exportingCondition { $0.canClearSchedule }
        CodableRepresentation(for: KanbanDragPayload.self, contentType: .json)
    }
}

/// Drop target payload used exclusively by the 無日期 column so cards with repeat
/// rules, reminders, or no schedule are rejected before hover highlight activates.
struct KanbanNoDateDropPayload: Codable, Equatable, Sendable, Transferable {
    var sourceSectionId: String
    var taskId: String
    var canClearSchedule: Bool

    var asDragPayload: KanbanDragPayload {
        KanbanDragPayload(sourceSectionId: sourceSectionId, taskId: taskId, canClearSchedule: canClearSchedule)
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .propertyList) { data in
            try JSONDecoder().decode(KanbanNoDateDropPayload.self, from: data)
        }
    }
}

/// Pure drag-and-drop rules for Kanban columns, shared by the UI and unit tests.
enum KanbanDrop {
    enum Action: Equatable, Sendable {
        case moveSchedule(Schedule)
        case clearSchedule
        case complete
    }

    /// Clearing a schedule in LocalDayDoAPI also clears repeat rules and reminders;
    /// disallow silent data loss when dragging to 無日期.
    static func canClearSchedule(_ task: TodoTask) -> Bool {
        task.schedule != nil && task.repeat == nil && task.reminders.isEmpty
    }

    static func acceptsDrops(sectionKind: TaskSection.Kind) -> Bool {
        switch sectionKind {
        case .today, .tomorrow, .noDate, .completed:
            return true
        case .overdue, .later, .trash, .day, .other:
            return false
        }
    }

    static func acceptsDrops(
        sectionKind: TaskSection.Kind,
        for task: TodoTask,
        from sourceSection: TaskSection.Kind?
    ) -> Bool {
        guard acceptsDrops(sectionKind: sectionKind) else { return false }
        if sourceSection == sectionKind { return false }
        if sourceSection == .completed || task.isCompleted { return false }
        if sectionKind == .noDate && !canClearSchedule(task) { return false }
        return true
    }

    static func action(
        for task: TodoTask,
        from sourceSection: TaskSection.Kind?,
        to targetSection: TaskSection.Kind,
        today: LocalDay
    ) -> Action? {
        guard acceptsDrops(sectionKind: targetSection, for: task, from: sourceSection) else { return nil }

        switch targetSection {
        case .today:
            return .moveSchedule(Schedule.moved(task.schedule, to: today))
        case .tomorrow:
            return .moveSchedule(Schedule.moved(task.schedule, to: today.adding(days: 1)))
        case .noDate:
            return .clearSchedule
        case .completed:
            return .complete
        case .overdue, .later, .trash, .day, .other:
            return nil
        }
    }
}

struct KanbanColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var section: TaskSection
    var columnWidth: CGFloat
    var isViewerScope: Bool
    var isActive: Bool
    var scrollResetToken: Int
    var selectedScrollTarget: TaskRowSelection?
    var bottomPadding: CGFloat
    var onLoadMore: (() -> Void)?
    var onDropPayload: (KanbanDragPayload) -> Bool

    @State private var isDropTargeted = false
    @State private var verticalScroll = ScrollPosition(edge: .top)

    private var cornerRadius: CGFloat { Platform.isMac ? 12 : 16 }
    private var cardRadius: CGFloat { Platform.isMac ? 8 : 12 }

    private var titleColor: Color {
        switch section.kind {
        case .overdue: Palette.overdue
        case .completed, .trash: Palette.textSecondary
        default: Palette.text
        }
    }

    private var acceptsDrops: Bool {
        !isViewerScope && KanbanDrop.acceptsDrops(sectionKind: section.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(section.title).txt(15, .bold).foregroundStyle(titleColor)
                Spacer()
                if section.kind == .overdue,
                   !isViewerScope,
                   !model.editableTaskIds(in: section.tasks).isEmpty {
                    Button("全部延到今天") {
                        model.postponeOverdue(tasks: section.tasks)
                    }
                    .txt(12, .semibold).foregroundStyle(accent.text).buttonStyle(.press)
                    .hoverEffect(.highlight)
                }
                Text("\(section.tasks.count)")
                    .txt(13)
                    .foregroundStyle(Palette.textTertiary)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            .padding(.horizontal, Platform.isMac ? 12 : 14)
            .frame(minHeight: Platform.isMac ? 38 : 44)

            ScrollViewReader { verticalProxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8) {
                        if section.tasks.isEmpty {
                            Text(acceptsDrops ? "拖曳任務到這裡" : "沒有任務")
                                .txt(13)
                                .foregroundStyle(Palette.textFaint)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        }
                        ForEach(section.tasks) { t in
                            let draggable = !isViewerScope
                                && !model.isViewer(projectId: t.projectId)
                                && section.kind != .completed
                                && !t.isCompleted
                            let payload = KanbanDragPayload(
                                sourceSectionId: section.id,
                                taskId: t.id,
                                canClearSchedule: KanbanDrop.canClearSchedule(t)
                            )
                            TaskRow(
                                task: t,
                                separator: false,
                                sectionKind: section.kind,
                                sectionId: section.id,
                                inTrash: false,
                                selectsInline: true,
                                showProject: false
                            )
                            .background(Palette.raised, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                                    .strokeBorder(Palette.separatorSoft, lineWidth: 1)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                            .kanbanDraggable(payload, enabled: draggable)
                            .id(TaskRowSelection(sectionId: section.id, taskId: t.id))
                            .transition(Motion.rowTransition(reduceMotion))
                        }
                        if let onLoadMore {
                            Button(action: onLoadMore) {
                                Text("載入更多").txt(13, .semibold).foregroundStyle(accent.text)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                            }
                            .buttonStyle(.press)
                            .hoverEffect(.highlight)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, bottomPadding)
                }
                .scrollPosition($verticalScroll)
                .scrollIndicators(.hidden)
                .onChange(of: scrollResetToken) { _, _ in
                    if verticalScroll.isPositionedByUser || verticalScroll.edge != .top {
                        verticalScroll.scrollTo(edge: .top)
                    }
                }
                .onChange(of: model.selectionScrollTrigger) { _, _ in
                    guard isActive,
                          let target = selectedScrollTarget,
                          target.sectionId == section.id else { return }
                    withAnimation(Motion.layout(reduceMotion)) {
                        verticalProxy.scrollTo(target)
                    }
                }
            }
        }
        .frame(width: columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(isDropTargeted ? accent.soft.opacity(0.6) : Palette.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(accent.color, lineWidth: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(Motion.toggle(reduceMotion), value: isDropTargeted)
        .modifier(KanbanColumnDropModifier(
            enabled: acceptsDrops,
            noDateOnly: section.kind == .noDate,
            isTargeted: $isDropTargeted,
            onDropPayload: onDropPayload
        ))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban.column.\(section.id)")
    }
}

struct KanbanColumnDropModifier: ViewModifier {
    var enabled: Bool
    var noDateOnly: Bool
    @Binding var isTargeted: Bool
    var onDropPayload: (KanbanDragPayload) -> Bool

    func body(content: Content) -> some View {
        if enabled && noDateOnly {
            content.dropDestination(for: KanbanNoDateDropPayload.self) { items, _ in
                guard let item = items.first else { return false }
                return onDropPayload(item.asDragPayload)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        } else if enabled {
            content.dropDestination(for: KanbanDragPayload.self) { items, _ in
                guard let item = items.first else { return false }
                return onDropPayload(item)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func kanbanDraggable(_ payload: KanbanDragPayload, enabled: Bool) -> some View {
        if enabled {
            self.draggable(payload)
        } else {
            self
        }
    }
}
