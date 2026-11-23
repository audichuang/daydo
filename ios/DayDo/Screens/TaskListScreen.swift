import SwiftUI
import UniformTypeIdentifiers
import DayDoCore

/// 1b / 1c · Task list for a smart list, project or tag, in collapsible
/// section cards. Density toggles between standard and compact.
struct TaskListScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.isRegularWindow) private var isRegular
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scope: TaskScope
    var isActive: Bool = true

    @State private var query = ResidentQuery<TaskReload, [TaskSection]>(
        initialValue: [],
        isStale: { $0.scope != $1.scope },
        isSameQuery: { $0.scope == $1.scope }
    )
    @State private var limits: [TaskScope: Int] = [:]
    @State private var shareText: String?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var kanbanHorizontalScroll = ScrollPosition(edge: .leading)
    @State private var kanbanScrollResetToken = 0
    @State private var quickAddText = ""
    @State private var quickAddSubmitting = false
    @State private var quickAddKeepFocus = false
    @FocusState private var quickAddFocused: Bool
    @AppStorage("closedSections") private var closedRaw = TaskSection.Kind.completed.id

    private var activeReload: TaskReload? {
        isActive ? TaskReload(scope: scope, revision: model.revision, limit: limits[scope], memberId: activeMemberFilter) : nil
    }

    /// Only expose sections matching the current `scope` so switching lists while
    /// hidden (or while a load is in flight / fails) never shows or acts on old rows.
    private var visibleSections: [TaskSection] {
        query.loadedKey?.scope == scope ? query.value : []
    }

    private var isKanbanMode: Bool {
        model.isKanbanScope(scope)
    }

    private var kanbanSections: [TaskSection] {
        guard isScopeLoaded else { return [] }
        return TaskGrouping.kanbanColumns(from: visibleSections)
    }

    private var selectedScrollTarget: TaskRowSelection? {
        model.selectedTaskRow ?? model.selectedTaskId.flatMap { id in
            orderedVisibleTaskRows.first { $0.taskId == id }
        }
    }

    private var orderedVisibleTaskRows: [TaskRowSelection] {
        if isKanbanMode {
            return kanbanSections.flatMap { sec in
                sec.tasks.map { TaskRowSelection(sectionId: sec.id, taskId: $0.id) }
            }
        }
        let closedSet = closed
        return visibleSections
            .filter { !closedSet.contains($0.id) }
            .flatMap { sec in sec.tasks.map { TaskRowSelection(sectionId: sec.id, taskId: $0.id) } }
    }

    private var isScopeLoaded: Bool {
        query.loadedKey?.scope == scope
    }

    var closed: Set<String> { Set(closedRaw.split(separator: ",").map(String.init)) }

    var isViewerScope: Bool {
        if case .project(let id) = scope { return model.isViewer(projectId: id) }
        return false
    }

    private var showComposeFAB: Bool {
        !Platform.isMac && model.canCompose(in: scope)
    }

    private var showQuickAdd: Bool {
        Platform.isMac && model.canCompose(in: scope)
    }

    private var editableCustomProject: Project? {
        guard case .project(let id) = scope,
              let proj = model.project(id),
              !proj.isInbox,
              !proj.isViewer else { return nil }
        return proj
    }

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottomTrailing) {
            if isRegular {
                Palette.background.ignoresSafeArea()
            }
            ZStack(alignment: .top) {
                if isKanbanMode {
                    kanbanContent
                } else {
                    listContent
                }

                if !isRegular {
                    ScreenHeader {
                        if isDuplicatingCurrentProject {
                            duplicatingStatusView
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .glassEffect(.regular, in: .capsule)
                        }
                    } trailing: {
                        trailingActions
                    }
                }
            }

            if showComposeFAB {
                ComposeFAB { compose() }
            }
        }
        .navigationTitle(Platform.isMac ? model.scopeTitle(scope) : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRegular {
                if !Platform.isMac && isDuplicatingCurrentProject {
                    ToolbarItem(placement: .principal) {
                        duplicatingStatusView
                    }
                }
                if Platform.isMac, let proj = editableCustomProject {
                    ToolbarItem(placement: .topBarLeading) {
                        projectViewModeSwitcher(for: proj)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if Platform.isMac && isDuplicatingCurrentProject {
                        duplicatingStatusView
                    }
                    trailingActions
                }
            }
        }
        .task(id: activeReload) {
            await load(for: activeReload)
        }
        .onChange(of: orderedVisibleTaskRows, initial: true) { _, rows in
            if isActive {
                model.visibleTaskRows = rows
            }
        }
        .onChange(of: showQuickAdd) { _, allowed in
            if !allowed && quickAddFocused {
                quickAddKeepFocus = false
                quickAddFocused = false
            }
        }
        .onChange(of: quickAddFocused) { _, focused in
            if !focused {
                quickAddKeepFocus = false
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                // Looks redundant with ResidentQuery's isStale, but removing it left the app never
                // idle after a tab round-trip (UI tests hung waiting for idle); keep it.
                if let loaded = query.loadedKey, loaded.scope != scope {
                    query.reset()
                }
                if !limits.isEmpty { limits = [:] }
                if scrollPosition.isPositionedByUser || scrollPosition.edge != .top {
                    scrollPosition.scrollTo(edge: .top)
                }
                if kanbanHorizontalScroll.isPositionedByUser || kanbanHorizontalScroll.edge != .leading {
                    kanbanHorizontalScroll.scrollTo(edge: .leading)
                }
                kanbanScrollResetToken += 1
                model.visibleTaskRows = orderedVisibleTaskRows
            } else if quickAddFocused {
                quickAddKeepFocus = false
                quickAddFocused = false
            }
        }
    }

    private var listContent: some View {
        @Bindable var model = model
        return ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Platform.isMac ? 10 : 16) {
                    if Platform.isMac {
                        Text(subtitle)
                            .txt(12)
                            .foregroundStyle(Palette.textSecondary)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .animation(isScopeLoaded ? Motion.count(reduceMotion) : nil, value: subtitle)
                            .padding(.horizontal, 4)
                        if scope == .smart(.all) && model.filterMembers.count > 1 {
                            MemberFilterChips(
                                members: model.filterMembers,
                                selection: Binding(get: { model.effectiveAllMemberFilter }, set: { model.allMemberFilter = $0 })
                            )
                        }
                        if showQuickAdd {
                            quickAddBar
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.scopeTitle(scope)).txt(30, .bold).foregroundStyle(Palette.text)
                            Text(subtitle)
                                .txt(14)
                                .foregroundStyle(Palette.textSecondary)
                                .contentTransition(reduceMotion ? .identity : .numericText())
                                .animation(isScopeLoaded ? Motion.count(reduceMotion) : nil, value: subtitle)
                            if scope == .smart(.all) && model.filterMembers.count > 1 {
                                MemberFilterChips(
                                    members: model.filterMembers,
                                    selection: Binding(get: { model.effectiveAllMemberFilter }, set: { model.allMemberFilter = $0 })
                                )
                                    .padding(.top, 10)
                            }
                        }
                        .padding(.horizontal, 4)
                    }

                    if isScopeLoaded && visibleSections.isEmpty {
                        EmptyState(scope: scope)
                            .id(SectionViewID(scope: query.loadedKey?.scope, sectionId: "__empty"))
                            .transition(.opacity)
                    }
                    ForEach(visibleSections) { sec in
                        SectionCard(section: sec, scope: scope, closed: closed.contains(sec.id)) { toggle(sec.id) }
                            .id(SectionViewID(scope: query.loadedKey?.scope, sectionId: sec.id))
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                    if visibleSections.contains(where: \.hasMore) {
                        Button { loadMore() } label: {
                            Text("載入更多").txt(13, .semibold).foregroundStyle(accent.text)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.press)
                        .hoverEffect(.highlight)
                    } else if !visibleSections.isEmpty {
                        Text("已顯示全部").txt(12).foregroundStyle(Palette.textFaint).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, Platform.isMac ? 12 : 16)
                .padding(.top, isRegular ? (Platform.isMac ? 8 : 12) : 60)
                .padding(.bottom, isRegular ? (showComposeFAB ? 96 : 24) : 170)
                .enclosingScrollsToTop(isActive)
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            .onChange(of: model.selectionScrollTrigger) { _, _ in
                guard isActive, let target = selectedScrollTarget else { return }
                withAnimation(Motion.layout(reduceMotion)) {
                    scrollProxy.scrollTo(target)
                }
            }
        }
    }

    private var kanbanContent: some View {
        VStack(alignment: .leading, spacing: Platform.isMac ? 10 : 12) {
            VStack(alignment: .leading, spacing: Platform.isMac ? 10 : 2) {
                if Platform.isMac {
                    Text(subtitle)
                        .txt(12)
                        .foregroundStyle(Palette.textSecondary)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(isScopeLoaded ? Motion.count(reduceMotion) : nil, value: subtitle)
                        .padding(.horizontal, 4)
                    if showQuickAdd {
                        quickAddBar
                    }
                } else {
                    Text(model.scopeTitle(scope)).txt(30, .bold).foregroundStyle(Palette.text)
                    Text(subtitle)
                        .txt(14)
                        .foregroundStyle(Palette.textSecondary)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(isScopeLoaded ? Motion.count(reduceMotion) : nil, value: subtitle)
                }
            }
            .padding(.horizontal, Platform.isMac ? 12 : 16)
            .padding(.top, isRegular ? (Platform.isMac ? 8 : 12) : 60)

            GeometryReader { geo in
                let colWidth: CGFloat = isRegular ? 272 : max(240, min(320, geo.size.width * 0.8))
                ScrollViewReader { horizontalProxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(kanbanSections) { sec in
                                KanbanColumn(
                                    section: sec,
                                    columnWidth: colWidth,
                                    isViewerScope: isViewerScope,
                                    isActive: isActive,
                                    scrollResetToken: kanbanScrollResetToken,
                                    selectedScrollTarget: selectedScrollTarget,
                                    bottomPadding: isRegular ? (showComposeFAB ? 96 : 16) : 150,
                                    onLoadMore: sec.hasMore ? { loadMore() } : nil,
                                    onDropPayload: { payload in handleKanbanDrop(payload: payload, onto: sec) }
                                )
                                .id(SectionViewID(scope: query.loadedKey?.scope, sectionId: sec.id))
                            }
                        }
                        .padding(.horizontal, Platform.isMac ? 12 : 16)
                        .padding(.bottom, 12)
                    }
                    .scrollPosition($kanbanHorizontalScroll)
                    .scrollIndicators(.hidden)
                    .onChange(of: model.selectionScrollTrigger) { _, _ in
                        guard isActive, let target = selectedScrollTarget else { return }
                        withAnimation(Motion.layout(reduceMotion)) {
                            horizontalProxy.scrollTo(SectionViewID(scope: query.loadedKey?.scope, sectionId: target.sectionId))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func handleKanbanDrop(payload: KanbanDragPayload, onto targetSection: TaskSection) -> Bool {
        guard !isViewerScope else { return false }
        let sourceKind = TaskSection.Kind(id: payload.sourceSectionId)
        guard sourceKind != targetSection.kind else { return false }
        let task = visibleSections.first(where: { $0.id == payload.sourceSectionId })?.tasks.first(where: { $0.id == payload.taskId })
            ?? visibleSections.lazy.flatMap(\.tasks).first(where: { $0.id == payload.taskId })
        guard let task else { return false }
        guard !model.isViewer(projectId: task.projectId) else { return false }
        guard let action = KanbanDrop.action(
            for: task,
            from: sourceKind,
            to: targetSection.kind,
            today: model.today
        ) else {
            return false
        }
        switch action {
        case .moveSchedule(let schedule):
            Task { await model.moveTask(task, to: schedule) }
        case .clearSchedule:
            model.updateTask(task.id) { $0.schedule = .clear }
        case .complete:
            guard !model.displaysCompleted(task) else { return false }
            model.toggleComplete(task)
        }
        return true
    }

    private var quickAddBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(quickAddFocused ? accent.text : Palette.textTertiary)
            TextField("新增任務至 \(model.scopeTitle(scope))", text: $quickAddText)
                .txt(14)
                .foregroundStyle(Palette.text)
                .tint(accent.color)
                .focused($quickAddFocused)
                .submitLabel(.return)
                .onSubmit { submitQuickAdd() }
                .onKeyPress(.escape) {
                    quickAddKeepFocus = false
                    quickAddFocused = false
                    return .handled
                }
                .accessibilityIdentifier("taskList.quickAdd")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(quickAddFocused ? accent.color : Palette.separator, lineWidth: 1)
        )
    }

    private func submitQuickAdd() {
        let submitted = quickAddText
        let title = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !quickAddSubmitting else {
            return
        }
        let targetScope = scope
        quickAddSubmitting = true
        quickAddKeepFocus = true
        quickAddFocused = true
        Task {
            defer {
                quickAddSubmitting = false
            }
            let created = await model.createQuickTask(title: title, in: targetScope)
            if created != nil, quickAddText == submitted {
                quickAddText = ""
            }
            if quickAddKeepFocus && showQuickAdd && isActive && !model.hasActiveRootSheet {
                quickAddFocused = true
            }
        }
    }

    private var activeMemberFilter: String? {
        scope == .smart(.all) ? model.effectiveAllMemberFilter : nil
    }

    @ViewBuilder
    private var trailingActions: some View {
        if case .project(let id) = scope, !(model.project(id)?.isInbox ?? false) {
            HeaderAction(systemName: "person.crop.circle.badge.plus", label: "共享") { model.sharingProjectId = id }
        }
        let ellipsisLabel = Group {
            if Platform.isMac {
                Image(systemName: "ellipsis")
            } else {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.text).frame(width: 44, height: 40)
            }
        }
        if isActive {
            Menu {
                if case .project(let id) = scope {
                    let proj = model.project(id)
                    let currentView = proj?.viewMode ?? "list"
                    if !(proj?.isViewer ?? false) {
                        Button("編輯", systemImage: "slider.horizontal.3") { model.editingProjectId = id }
                        if !Platform.isMac {
                            Menu("視圖", systemImage: "rectangle.grid.1x2") {
                                viewMenuItem("列表", mode: "list", current: currentView, projectId: id)
                                viewMenuItem("看板", mode: "kanban", current: currentView, projectId: id)
                                viewMenuItem("時間軸", mode: "timeline", current: currentView, projectId: id)
                            }
                        }
                    }
                }
                Button(model.compact ? "顯示詳情" : "隱藏詳情", systemImage: model.compact ? "eye" : "eye.slash") {
                    withAnimation(Motion.toggle(reduceMotion)) { model.compact.toggle() }
                }
                if !isKanbanMode {
                    Button(closed.contains(TaskSection.Kind.completed.id) ? "顯示已完成" : "隱藏已完成", systemImage: "checkmark.circle") { toggle(TaskSection.Kind.completed.id) }
                }
                if let overdue = visibleSections.first(where: { $0.kind == .overdue }),
                   !isViewerScope,
                   !model.editableTaskIds(in: overdue.tasks).isEmpty {
                    Divider()
                    Button("全部延到今天", systemImage: "arrow.uturn.forward") { model.postponeOverdue(tasks: overdue.tasks) }
                }
                if case .project(let id) = scope, let proj = model.project(id), !proj.isInbox {
                    Divider()
                    let isDuplicating = model.isDuplicatingProject(id)
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button("共享協作", systemImage: "person.2") { model.sharingProjectId = id }
                        Button("分享", systemImage: "square.and.arrow.up") { shareText = projectShareText(proj) }
                        Button(isDuplicating ? "複製中…" : "複製清單", systemImage: "doc.on.doc") {
                            model.duplicateProject(id: id)
                        }
                        .disabled(isDuplicating)
                    }
                }
            } label: {
                ellipsisLabel
            }
            .menuIndicator(Platform.isMac ? .hidden : .automatic)
            .hoverEffect(.highlight)
            .background(ActivityAnchor(text: $shareText))
            .accessibilityLabel("更多選項")
        } else {
            ellipsisLabel.accessibilityHidden(true)
        }
    }

    var subtitle: String {
        // A multi-day task sits in both 今天 and 明天; count it once.
        let active = Set(visibleSections.filter { $0.kind != .completed && $0.kind != .trash }.flatMap { $0.tasks.map(\.id) }).count
        switch scope {
        case .smart(.today): return "\(DateText.full(model.today)) · \(model.counts.today) 項待辦"
        case .smart(.completed): return "\(visibleSections.first?.tasks.count ?? 0) 項"
        case .smart(.trash): return "刪除的任務可在這裡還原"
        default: return "\(active) 項待辦"
        }
    }

    func load(for reload: TaskReload?) async {
        let outcome = await query.run(activeKey: reload) { key in
            try await model.api.listSections(key.scope, limit: key.limit, memberId: key.memberId)
        } apply: { sameQuery, commit in
            if sameQuery {
                withAnimation(Motion.layout(reduceMotion)) { commit() }
            } else {
                commit()
            }
        }
        if case .failed(let error) = outcome {
            // A list deleted from another screen: fall back to Today.
            if case DayDoError.notFound = error { model.scope = .smart(.today) } else { model.errorMessage = error.localizedDescription }
        }
    }

    func loadMore() {
        let current = visibleSections.first(where: \.hasMore)?.tasks.count ?? 0
        let step = (scope == .smart(.completed) || scope == .smart(.trash)) ? 300 : 30
        limits[scope] = current + step
    }

    func toggle(_ id: String) {
        var c = closed
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        withAnimation(Motion.layout(reduceMotion)) { closedRaw = c.sorted().joined(separator: ",") }
    }

    private func setProjectViewMode(_ mode: String, projectId: String) {
        var u = UpdateProjectInput(projectId: projectId)
        u.viewMode = mode
        let input = u
        Task { await model.perform { try await $0.updateProject(input) } }
    }

    @ViewBuilder
    private func projectViewModeSwitcher(for project: Project) -> some View {
        let current = project.viewMode == "kanban" ? "kanban" : "list"
        Picker("視圖", selection: Binding(
            get: { current },
            set: { mode in
                guard mode != current else { return }
                setProjectViewMode(mode, projectId: project.id)
            }
        )) {
            Image(systemName: "list.bullet")
                .help("列表")
                .accessibilityLabel("列表")
                .tag("list")
            Image(systemName: "rectangle.split.3x1")
                .help("看板")
                .accessibilityLabel("看板")
                .tag("kanban")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("taskList.viewModeSwitcher")
    }

    @ViewBuilder
    func viewMenuItem(_ title: String, mode: String, current: String, projectId: String) -> some View {
        Button {
            setProjectViewMode(mode, projectId: projectId)
        } label: {
            if current == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var isDuplicatingCurrentProject: Bool {
        if case .project(let id) = scope {
            return model.isDuplicatingProject(id)
        }
        return false
    }

    private var duplicatingStatusView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .tint(Palette.textSecondary)
            Text("複製中…")
                .txt(13, .medium)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityIdentifier("taskList.duplicatingStatus")
    }

    func projectShareText(_ project: Project) -> String {
        let active = visibleSections.filter { $0.kind != .completed && $0.kind != .trash }.flatMap(\.tasks)
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

struct TaskReload: Hashable { var scope: TaskScope; var revision: Int; var limit: Int?; var memberId: String? }
private struct SectionViewID: Hashable { var scope: TaskScope?; var sectionId: String }

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

private struct KanbanColumn: View {
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

private struct KanbanColumnDropModifier: ViewModifier {
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

private extension View {
    @ViewBuilder
    func kanbanDraggable(_ payload: KanbanDragPayload, enabled: Bool) -> some View {
        if enabled {
            self.draggable(payload)
        } else {
            self
        }
    }
}

struct SectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var section: TaskSection
    var scope: TaskScope
    var closed: Bool
    var toggle: () -> Void

    var titleColor: Color {
        switch section.kind {
        case .overdue: Palette.overdue
        case .completed, .trash: Palette.textSecondary
        default: Palette.text
        }
    }

    var isViewerScope: Bool {
        if case .project(let id) = scope { return model.isViewer(projectId: id) }
        return false
    }

    /// Inside a single list the title already names it; rows skip the list label.
    var isProjectScope: Bool {
        switch scope {
        case .project, .smart(.inbox): return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(section.title).txt(15, .bold).foregroundStyle(titleColor)
                    Spacer()
                    if section.kind == .overdue,
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
                .padding(.leading, Platform.isMac ? 12 : 16).padding(.trailing, Platform.isMac ? 12 : 14)
                .frame(minHeight: Platform.isMac ? 34 : 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.99, opacity: 0.92))
            .hoverEffect(.highlight)
            .accessibilityValue(closed ? "已收合" : "已展開")

            if !closed {
                let firstId = section.tasks.first?.id
                LazyVStack(spacing: 0) {
                    ForEach(section.tasks) { t in
                        TaskRow(
                            task: t,
                            separator: t.id != firstId,
                            sectionKind: section.kind,
                            sectionId: section.id,
                            inTrash: scope == .smart(.trash),
                            selectsInline: true,
                            showProject: !isProjectScope
                        )
                        .id(TaskRowSelection(sectionId: section.id, taskId: t.id))
                        .transition(Motion.rowTransition(reduceMotion))
                    }
                }
                .transition(Motion.expandTransition(reduceMotion))
            }
        }
        .card(Platform.isMac ? 12 : 16)
        .clipShape(RoundedRectangle(cornerRadius: Platform.isMac ? 12 : 16, style: .continuous))
    }
}

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
        let id = task.id
        let isViewer = model.isViewer(projectId: task.projectId)
        if inTrash {
            if !isViewer {
                Button("還原", systemImage: "arrow.uturn.backward") { Task { await model.restoreTask(id: id) } }
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
        case .smart(.today): Platform.isMac ? "今天沒有待辦。在上方輸入框新增一項。" : "今天沒有待辦。按右下角 ＋ 新增一項。"
        case .smart(.trash): "垃圾桶是空的"
        case .smart(.completed): "還沒有完成的任務"
        default: "這裡還沒有任務"
        }
    }
}
