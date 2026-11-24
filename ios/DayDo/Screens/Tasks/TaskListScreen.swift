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
    @Environment(\.macSidebarToggle) private var macSidebarToggle
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
    private var quickAddText: String {
        get { model.quickAddDrafts[scope] ?? "" }
        nonmutating set { model.quickAddDrafts[scope] = newValue.isEmpty ? nil : newValue }
    }
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
                VStack(spacing: 0) {
                    if Platform.isMac {
                        macHeader
                    }
                    if isKanbanMode {
                        kanbanContent
                    } else {
                        listContent
                    }
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
        .toolbar(Platform.isMac ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if isRegular && !Platform.isMac {
                if isDuplicatingCurrentProject {
                    ToolbarItem(placement: .principal) {
                        duplicatingStatusView
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
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
            TextField("新增任務至 \(model.scopeTitle(scope))", text: Binding(get: { quickAddText }, set: { quickAddText = $0 }))
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
            if created != nil, model.quickAddDrafts[targetScope] == submitted {
                model.quickAddDrafts[targetScope] = nil
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
    private var moreMenuItems: some View {
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
    }

    /// Phone header and iPad toolbar only; the Mac uses `macHeader`.
    @ViewBuilder
    private var trailingActions: some View {
        if case .project(let id) = scope, !(model.project(id)?.isInbox ?? false) {
            HeaderAction(systemName: "person.crop.circle.badge.plus", label: "共享") { model.sharingProjectId = id }
        }
        let ellipsisLabel = Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.text).frame(width: 44, height: 40)
        if isActive {
            Menu {
                moreMenuItems
            } label: {
                ellipsisLabel
            }
            .hoverEffect(.highlight)
            .background(ActivityAnchor(text: $shareText))
            .accessibilityLabel("更多選項")
        } else {
            ellipsisLabel.accessibilityHidden(true)
        }
    }

    /// Mac top bar inside the list column: sidebar toggle and left-aligned title, small
    /// square buttons on the right (same chrome as the calendar), no navigation bar.
    private var macHeader: some View {
        HStack(spacing: 8) {
            if let toggleSidebar = macSidebarToggle {
                MacCalendarIconButton(systemName: "sidebar.left", label: "顯示／隱藏清單欄", action: toggleSidebar)
            }
            Text(model.scopeTitle(scope))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if isDuplicatingCurrentProject {
                duplicatingStatusView
            }
            Spacer(minLength: 12)
            if let proj = editableCustomProject {
                projectViewModeSwitcher(for: proj)
            }
            if case .project(let id) = scope, !(model.project(id)?.isInbox ?? false) {
                MacCalendarIconButton(systemName: "person.crop.circle.badge.plus", label: "共享") { model.sharingProjectId = id }
            }
            MacCalendarMoreMenu(isActive: isActive) { moreMenuItems }
                .background(ActivityAnchor(text: $shareText))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
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

struct SectionViewID: Hashable { var scope: TaskScope?; var sectionId: String }
