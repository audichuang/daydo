import Observation
import SwiftUI
import DayDoCore

extension CalMode {
    var label: String {
        switch self { case .list: "清單"; case .year: "年"; case .month: "月"; case .week: "週"; case .threeDay: "3日"; case .day: "日" }
    }
    var icon: String {
        switch self {
        case .list: "list.bullet.below.rectangle"
        case .year: "square.grid.3x3"
        case .month: "calendar"
        case .week: "rectangle.split.3x1"
        case .threeDay: "rectangle.split.2x1"
        case .day: "rectangle"
        }
    }
    var macShortcutKey: String? {
        switch self {
        case .month: "M"
        case .week: "W"
        case .day: "D"
        case .list, .year, .threeDay: nil
        }
    }
}

/// 日曆: 清單 (date grid + the selected day's items, 2a/2b), 年, 月 (event
/// bars, 2c), and 週／3日／日 time grids.
struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.isRegularWindow) private var isRegular
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isActive: Bool = true

    @AppStorage("calendarViewMode") private var modeRaw = Self.overviewMode.rawValue
    @AppStorage("calendarCollapsed") private var collapsed = false
    @AppStorage("agendaTimeline") private var timelineStyle = false
    @AppStorage("weekAgendaStyle") private var weekAgendaStyle = false
    @AppStorage("calendarShowCompleted") private var showCompleted = true
    @State private var selected: LocalDay?
    @State private var month: LocalDay?
    @State private var memberFilter: String?
    @State private var projectFilter: String?
    @State private var query = ResidentQuery<CalReload, [TodoTask]>(
        initialValue: [],
        isSameQuery: { $0.queryKey == $1.queryKey }
    )
    @State private var drag = CalendarDragState()
    @State private var cache = CalendarDerivedCache()
    @State private var shiftDir = 0
    @State private var pageSequence = 0
    @State private var dateSelectionHaptic = 0
    @State private var pageShiftHaptic = 0
    @State private var pendingMove: PendingBlockMove?
    @State private var gridDragLock = GridDragLock()
    @State private var listScrollPosition = ScrollPosition(edge: .top)
    @State private var yearScrollPosition = ScrollPosition(edge: .top)
    @State private var monthScrollPosition = ScrollPosition(edge: .top)
    @State private var timeGridScrollReset = 0
    @State private var popoverTarget: CalendarTaskPopoverTarget?

    private var tasks: [TodoTask] { query.value }
    private var tasksVersion: Int { query.version }

    private var currentReload: CalReload {
        CalReload(range: range, member: effectiveMemberFilter, completed: showCompleted, revision: model.revision)
    }

    private var activeReload: CalReload? {
        isActive ? currentReload : nil
    }

    /// Mac has no 清單 mode (small month beside a day agenda is a tablet layout); a stored
    /// `list` from before this change opens as the month view instead.
    var mode: CalMode {
        let m = CalMode(rawValue: modeRaw) ?? .list
        return Platform.isMac && m == .list ? .month : m
    }
    /// The overview a year-month tap or deep link lands on.
    static var overviewMode: CalMode { Platform.isMac ? .month : .list }
    var sel: LocalDay { selected ?? model.today }
    var shownMonth: LocalDay { month ?? sel.firstOfMonth }
    private var effectiveMemberFilter: String? {
        MemberFilter.effectiveFilter(memberFilter, among: model.filterMembers)
    }
    private var showOwnerAvatars: Bool {
        model.filterMembers.count > 1 && effectiveMemberFilter == nil
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isRegular {
                Palette.background.ignoresSafeArea()
            }
            VStack(spacing: 0) {
                if Platform.isMac {
                    macHeader
                } else if !isRegular {
                    header
                }
                if model.filterMembers.count > 1 || projectFilter != nil {
                    filters.padding(.horizontal, 16).padding(.top, isRegular && !Platform.isMac ? 8 : 0).padding(.bottom, 6)
                }
                content
            }
            if !Platform.isMac && !model.isViewer(projectId: projectFilter) {
                ComposeFAB { compose(day: sel, minute: nil) }
            }
        }
        .sensoryFeedback(.selection, trigger: dateSelectionHaptic)
        .sensoryFeedback(.selection, trigger: modeRaw)
        .sensoryFeedback(.impact(weight: .light), trigger: pageShiftHaptic)
        .background {
            if Platform.isMac {
                CalendarPopoverPresenter(
                    target: $popoverTarget,
                    tasks: tasks,
                    onOpenDetail: { id in
                        model.openTask(id, inlineAvailable: false)
                    }
                )
                .allowsHitTesting(false)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(Platform.isMac ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if isRegular && !Platform.isMac {
                ToolbarItem(placement: .topBarLeading) {
                    modeMenuButton(useGlass: false)
                }
                ToolbarItem(placement: .principal) {
                    titleButton
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    trailingActions
                }
            }
        }
        .task(id: activeReload) {
            await load(for: activeReload)
        }
        .onAppear { applyPendingCalendarDay() }
        .onChange(of: model.calendarCommandTrigger) { _, _ in
            guard isActive, let action = model.calendarCommandAction else { return }
            model.calendarCommandAction = nil
            closePopover()
            switch action {
            case .previous: shift(-1)
            case .next: shift(1)
            case .today: goToday()
            case .setMode(let targetMode):
                if mode != targetMode {
                    withAnimation(Motion.toggle(reduceMotion)) {
                        modeRaw = targetMode.rawValue
                    }
                }
            }
        }
        .onChange(of: CalActivation(isActive: isActive, navTrigger: model.calendarNavigationTrigger)) { old, new in
            if !new.isActive {
                gridDragLock.isActive = false
                closePopover()
                if drag.horizontalOffset != 0 { drag.horizontalOffset = 0 }
                if drag.collapseY != 0 { drag.collapseY = 0 }
                return
            }
            if !old.isActive {
                resetForTabEntry()
            }
            if model.calendarNavigationDay != nil {
                applyPendingCalendarDay()
            }
        }
        .onChange(of: model.filterMembers) { _, _ in
            if effectiveMemberFilter != memberFilter {
                memberFilter = effectiveMemberFilter
            }
        }
        .onChange(of: showCompleted) { _, newValue in
            model.syncCalendarShowCompletedToWidget(newValue)
        }
    }

    private func resetForTabEntry() {
        gridDragLock.isActive = false
        if drag.horizontalOffset != 0 { drag.horizontalOffset = 0 }
        if drag.collapseY != 0 { drag.collapseY = 0 }
        if pendingMove != nil { pendingMove = nil }
        closePopover()
        if selected != nil { selected = nil }
        if month != nil { month = nil }
        if memberFilter != nil { memberFilter = nil }
        if projectFilter != nil { projectFilter = nil }
        if shiftDir != 0 { shiftDir = 0 }
        switch mode {
        case .list:
            if listScrollPosition.isPositionedByUser || listScrollPosition.edge != .top {
                listScrollPosition.scrollTo(edge: .top)
            }
        case .year:
            if yearScrollPosition.isPositionedByUser || yearScrollPosition.edge != .top {
                yearScrollPosition.scrollTo(edge: .top)
            }
        case .month:
            if monthScrollPosition.isPositionedByUser || monthScrollPosition.edge != .top {
                monthScrollPosition.scrollTo(edge: .top)
            }
        case .week where weekAgendaStyle:
            break
        case .week, .threeDay, .day:
            timeGridScrollReset += 1
        }
    }

    private func applyPendingCalendarDay() {
        guard let day = model.calendarNavigationDay else { return }
        model.calendarNavigationDay = nil
        memberFilter = nil
        projectFilter = nil
        selected = day
        month = day.firstOfMonth
        // Direct jump without animation or haptic on deep-link navigation.
        shiftDir = 0
        pageSequence += 1
        if mode == .year {
            modeRaw = Self.overviewMode.rawValue
        }
    }

    // MARK: Header

    private var macHeader: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .accessibilityIdentifier("calendarTitle")

            Spacer(minLength: 12)

            if !model.isViewer(projectId: projectFilter) {
                MacCalendarIconButton(systemName: "plus", label: "新增任務") {
                    compose(day: sel, minute: nil)
                }
            }

            MacCalendarModeMenu(mode: mode, isActive: isActive) {
                modeMenuItems(showShortcuts: true)
            }

            MacCalendarNavControl(
                onPrev: { shift(-1) },
                onToday: { goToday() },
                onNext: { shift(1) }
            )

            if mode == .list {
                MacCalendarIconButton(
                    systemName: timelineStyle ? "list.bullet.rectangle" : "calendar.day.timeline.left",
                    label: timelineStyle ? "切換為卡片清單" : "切換為時間軸清單"
                ) {
                    withAnimation(Motion.toggle(reduceMotion)) { timelineStyle.toggle() }
                }
            }
            if mode == .week {
                MacCalendarIconButton(
                    systemName: weekAgendaStyle ? "calendar.day.timeline.left" : "square.grid.2x2",
                    label: weekAgendaStyle ? "切換為週時間軸" : "切換為週清單"
                ) {
                    shiftDir = 0
                    withAnimation(Motion.toggle(reduceMotion)) { weekAgendaStyle.toggle() }
                }
                .accessibilityIdentifier("weekLayoutToggle")
            }

            MacCalendarMoreMenu(isActive: isActive) {
                moreMenuContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    var header: some View {
        HStack {
            modeMenuButton(useGlass: true)
            Spacer()
            titleButton
            Spacer()
            HStack(spacing: 0) {
                trailingActions
            }
            .padding(.horizontal, 2)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func modeMenuItems(showShortcuts: Bool) -> some View {
        ForEach(CalMode.allCases.filter { !(Platform.isMac && $0 == .list) }) { m in
            let itemTitle = showShortcuts ? (m.macShortcutKey.map { "\(m.label)  \($0)" } ?? m.label) : m.label
            Button {
                withAnimation(Motion.toggle(reduceMotion)) { modeRaw = m.rawValue }
            } label: {
                if m == mode { Label(itemTitle, systemImage: "checkmark") } else { Label(itemTitle, systemImage: m.icon) }
            }
        }
    }

    @ViewBuilder
    private func modeMenuButton(useGlass: Bool) -> some View {
        let iconLabel = Group {
            if useGlass {
                Image(systemName: mode.icon).font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.text)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: mode.icon).font(.system(size: 16, weight: .medium))
                    Text(mode.label).txt(14, .semibold)
                }
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10)
                .frame(height: 36)
            }
        }
        if isActive {
            Menu {
                modeMenuItems(showShortcuts: false)
            } label: {
                iconLabel
            }
            .menuIndicator(Platform.isMac ? .hidden : .automatic)
            .hoverEffect(.highlight)
            .accessibilityLabel("切換檢視：目前\(mode.label)")
            .accessibilityIdentifier("calendarMode")
        } else {
            iconLabel.accessibilityHidden(true)
        }
    }

    private var titleButton: some View {
        Button { goToday() } label: {
            Text(title).txt(18, .bold).foregroundStyle(Palette.text)
        }
        .buttonStyle(.press)
        .hoverEffect(.highlight)
        .accessibilityLabel(title + "，點兩下回到今天")
        .accessibilityIdentifier("calendarTitle")
    }

    @ViewBuilder
    private var moreMenuContent: some View {
        Button("回到今天", systemImage: "arrow.uturn.backward") { goToday() }
        Button(showCompleted ? "隱藏已完成" : "顯示已完成", systemImage: "checkmark.circle") { showCompleted.toggle() }
        Menu("清單篩選", systemImage: "line.3.horizontal.decrease") {
            Button {
                projectFilter = nil
            } label: { if projectFilter == nil { Label("全部清單", systemImage: "checkmark") } else { Text("全部清單") } }
            ForEach(model.projects) { p in
                Button {
                    projectFilter = p.id
                } label: { if projectFilter == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) } }
            }
        }
        if mode == .list {
            Button(collapsed ? "展開整個月份" : "收合成單週", systemImage: "rectangle.compress.vertical") {
                withAnimation(Motion.layout(reduceMotion)) {
                    collapsed.toggle()
                }
            }
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if mode == .list {
            HeaderAction(systemName: timelineStyle ? "list.bullet.rectangle" : "calendar.day.timeline.left", label: timelineStyle ? "切換為卡片清單" : "切換為時間軸清單") {
                withAnimation(Motion.toggle(reduceMotion)) { timelineStyle.toggle() }
            }
        }
        if mode == .week {
            HeaderAction(
                systemName: weekAgendaStyle ? "calendar.day.timeline.left" : "square.grid.2x2",
                label: weekAgendaStyle ? "切換為週時間軸" : "切換為週清單"
            ) {
                shiftDir = 0
                withAnimation(Motion.toggle(reduceMotion)) { weekAgendaStyle.toggle() }
            }
            .accessibilityIdentifier("weekLayoutToggle")
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
                moreMenuContent
            } label: {
                ellipsisLabel
            }
            .menuIndicator(Platform.isMac ? .hidden : .automatic)
            .hoverEffect(.highlight)
            .accessibilityLabel("更多選項")
        } else {
            ellipsisLabel.accessibilityHidden(true)
        }
    }

    var title: String {
        let thisYear = model.today.year
        let includeYear = Platform.isMac
        switch mode {
        case .year: return "\(String(shownMonth.year)) 年"
        case .week, .threeDay, .day:
            let d = rangeDays.first ?? sel
            return (!includeYear && d.year == thisYear) ? "\(d.month)月" : "\(String(d.year)) 年 \(d.month) 月"
        default:
            return (!includeYear && shownMonth.year == thisYear) ? "\(shownMonth.month)月" : "\(String(shownMonth.year)) 年 \(shownMonth.month) 月"
        }
    }

    var filters: some View {
        HStack(spacing: 6) {
            if model.filterMembers.count > 1 {
                MemberFilterChips(
                    members: model.filterMembers,
                    selection: Binding(get: { effectiveMemberFilter }, set: { memberFilter = $0 })
                )
            }
            if let p = model.project(projectFilter) {
                Button { projectFilter = nil } label: {
                    HStack(spacing: 4) { ListDot(color: p.color); Text(p.name).txt(13, .semibold); Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .foregroundStyle(Palette.textNav).padding(.horizontal, 12).frame(height: 30)
                        .overlay(Capsule().strokeBorder(Palette.separator))
                }
                .buttonStyle(.press)
                .accessibilityLabel("移除清單篩選：\(p.name)")
            }
            Spacer()
        }
    }

    // MARK: Data

    private var viewport: CalendarProjection.Viewport {
        CalendarProjection.Viewport(mode: mode, selected: sel, shownMonth: shownMonth, collapsed: collapsed)
    }

    var rangeDays: [LocalDay] { viewport.visibleDays }

    var range: ClosedRange<LocalDay> {
        let grid = (mode == .list || mode == .month) ? cache.gridDays(for: shownMonth) : nil
        return viewport.queryRange(monthGridDays: grid)
    }

    private func load(for reload: CalReload?) async {
        let outcome = await query.run(activeKey: reload) { key in
            let q = TaskQuery(from: key.range.lowerBound, to: key.range.upperBound, includeCompleted: key.completed, memberId: key.member)
            return try await model.api.listTasks(q)
        } apply: { sameQuery, commit in
            if sameQuery {
                withAnimation(Motion.layout(reduceMotion)) { commit() }
            } else {
                commit()
            }
        }
        if case .failed(let error) = outcome {
            model.errorMessage = error.localizedDescription
        }
    }

    var filtered: [TodoTask] {
        cache.filteredTasks(tasksVersion: tasksVersion, projectFilter: projectFilter, tasks: tasks)
    }

    private enum PageHaptic {
        case none, selection, pageShift
    }

    /// Sets `shiftDir` before entering `withAnimation` so `pageTransition` reads the target direction.
    private func shiftPage(
        direction: Int,
        token: MotionToken = Motion.toggle,
        haptic: PageHaptic = .selection,
        bumpPage: Bool = true,
        update: () -> Void
    ) {
        closePopover()
        shiftDir = direction
        switch haptic {
        case .none: break
        case .selection: dateSelectionHaptic += 1
        case .pageShift: pageShiftHaptic += 1
        }
        withAnimation(token(reduceMotion)) {
            update()
            if bumpPage {
                pageSequence += 1
            }
        }
    }

    func goToday() {
        shiftPage(direction: 0) {
            selected = model.today
            month = model.today.firstOfMonth
        }
    }

    func applyShift(_ dir: Int) {
        let next = viewport.shifted(by: dir)
        month = next.shownMonth
        if mode != .year {
            selected = next.selected
        }
    }

    func shift(_ dir: Int) {
        shiftPage(direction: dir, token: Motion.page, haptic: .pageShift) {
            applyShift(dir)
        }
    }

    func compose(day: LocalDay, minute: Int?, endMinute: Int? = nil) {
        guard !model.isViewer(projectId: projectFilter) else { return }
        model.openComposer(ComposeRequest(projectId: projectFilter, day: day, minute: minute, endMinute: endMinute))
    }

    private func closePopover() {
        if popoverTarget != nil {
            popoverTarget = nil
        }
        if model.isCalendarPopoverPresented {
            model.isCalendarPopoverPresented = false
        }
    }

    private func openTaskOrPopover(_ id: String, rect: CGRect) {
        if Platform.isMac {
            model.isCalendarPopoverPresented = true
            popoverTarget = CalendarTaskPopoverTarget(taskId: id, rect: rect)
        } else {
            model.openTask(id, inlineAvailable: false)
        }
    }

    private func moveTask(_ task: TodoTask, to draft: DateDraft) {
        var input = UpdateTaskInput(taskId: task.id)
        draft.applyChanges(from: task, to: &input)
        guard case .set(let newSchedule) = input.schedule else { return }
        let token = UUID()
        pendingMove = PendingBlockMove(token: token, taskId: task.id, schedule: newSchedule)
        let finalInput = input
        Task {
            _ = await model.perform { try await $0.updateTask(finalInput) }
            await load(for: currentReload)
            if pendingMove?.token == token {
                pendingMove = nil
            }
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion || shiftDir == 0 {
            return .opacity
        }
        return shiftDir > 0
            ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
            : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
    }

    private func finishHorizontalSwipe(tx: CGFloat, vx: CGFloat) {
        let projected = tx + vx * 0.12
        if abs(tx) > 70 || (abs(vx) > 450 && abs(projected) > 40) {
            let dir = projected < 0 ? 1 : -1
            shiftPage(direction: dir, token: Motion.page, haptic: .pageShift) {
                applyShift(dir)
                drag.horizontalOffset = 0
            }
        } else {
            withAnimation(Motion.pageSnapBack(reduceMotion)) {
                drag.horizontalOffset = 0
            }
        }
    }

    private var horizontalOnlySwipe: CalendarPanGesture {
        CalendarPanGesture(
            allowLeftEdgeRightward: isRegular,
            canBegin: { !gridDragLock.isActive },
            allowVertical: { false },
            verticalShouldBegin: { _ in false },
            onHorizontalChanged: { tx in
                if !reduceMotion {
                    drag.horizontalOffset = tx * 0.9
                }
            },
            onHorizontalEnded: { tx, vx in
                finishHorizontalSwipe(tx: tx, vx: vx)
            }
        )
    }

    // MARK: Content

    @ViewBuilder var content: some View {
        Group {
            switch mode {
            case .list:
                if isRegular {
                    GeometryReader { geo in
                        if geo.size.width >= 720 {
                            HStack(alignment: .top, spacing: 20) {
                                ScrollView {
                                    dateGrid
                                }
                                .scrollIndicators(.hidden)
                                .frame(width: 360)

                                ScrollView {
                                    Group {
                                        if timelineStyle { timelineAgenda } else { cardAgenda }
                                    }
                                    .padding(.bottom, 32)
                                }
                                .scrollIndicators(.hidden)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                        } else {
                            ScrollView {
                                VStack(spacing: 12) {
                                    dateGrid
                                    if timelineStyle { timelineAgenda } else { cardAgenda }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 32)
                            }
                            .scrollIndicators(.hidden)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            dateGrid
                            if timelineStyle { timelineAgenda } else { cardAgenda }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 170)
                        .enclosingScrollsToTop(isActive)
                    }
                    .scrollPosition($listScrollPosition)
                    .scrollIndicators(.hidden)
                }
            case .year:
                ScrollView {
                    ZStack {
                        YearGrid(year: shownMonth.year, today: model.today, busy: busyDays, isRegular: isRegular, openMonth: { m in
                            shiftPage(direction: 0) {
                                month = m
                                selected = m
                                modeRaw = Self.overviewMode.rawValue
                                collapsed = false
                            }
                        }, openDay: { d in
                            shiftPage(direction: 0) {
                                selected = d
                                month = d.firstOfMonth
                                modeRaw = CalMode.day.rawValue
                            }
                        })
                        .id("year-\(pageSequence)")
                        .transition(pageTransition)
                    }
                    .modifier(HorizontalDragOffsetModifier(drag: drag, reduceMotion: reduceMotion))
                    .clipped()
                    .padding(.horizontal, isRegular ? 24 : 16)
                    .padding(.bottom, isRegular ? 32 : 170)
                    .enclosingScrollsToTop(isActive)
                }
                .scrollPosition($yearScrollPosition)
                .gesture(horizontalOnlySwipe)
            case .month:
                if Platform.isMac {
                    GeometryReader { geo in
                        ZStack {
                            macEventMonth(availableHeight: geo.size.height)
                                .id("month-\(pageSequence)")
                                .transition(pageTransition)
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .modifier(HorizontalDragOffsetModifier(drag: drag, reduceMotion: reduceMotion))
                        .clipped()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .gesture(horizontalOnlySwipe)
                } else {
                    ScrollView {
                        ZStack {
                            eventMonth
                                .id("month-\(pageSequence)")
                                .transition(pageTransition)
                        }
                        .modifier(HorizontalDragOffsetModifier(drag: drag, reduceMotion: reduceMotion))
                        .clipped()
                        .padding(.horizontal, isRegular ? 16 : 8)
                        .padding(.bottom, isRegular ? 32 : 170)
                        .enclosingScrollsToTop(isActive)
                    }
                    .scrollPosition($monthScrollPosition)
                    .gesture(horizontalOnlySwipe)
                }
            case .week, .threeDay, .day:
                let days = rangeDays
                let timeGrid = cache.timeGridData(
                    tasksVersion: tasksVersion,
                    projectFilter: projectFilter,
                    pendingMove: pendingMove,
                    days: days,
                    tasks: tasks
                )
                ZStack {
                    if mode == .week && weekAgendaStyle {
                        WeekAgendaGrid(
                            weekDays: days,
                            month: (days.first ?? sel).firstOfMonth,
                            selected: sel,
                            tasks: timeGrid.displayedTasks,
                            today: model.today,
                            isRegular: isRegular,
                            showOwnerAvatars: showOwnerAvatars,
                            isViewerFilter: model.isViewer(projectId: projectFilter),
                            openTask: { id, rect in openTaskOrPopover(id, rect: rect) },
                            tapEmpty: { d in compose(day: d, minute: nil) },
                            openDay: { d in
                                shiftPage(direction: 0) {
                                    selected = d
                                    month = d.firstOfMonth
                                    modeRaw = CalMode.day.rawValue
                                }
                            },
                            pickMiniDay: { d in
                                let oldWeekStart = sel.startOfWeek
                                let newWeekStart = d.startOfWeek
                                let weekChanged = newWeekStart != oldWeekStart
                                let dir = weekChanged ? (newWeekStart > oldWeekStart ? 1 : -1) : 0
                                shiftPage(direction: dir, token: Motion.page, haptic: .selection, bumpPage: weekChanged) {
                                    selected = d
                                    month = d.firstOfMonth
                                }
                            }
                        )
                        .id("week-agenda-\(pageSequence)")
                        .transition(pageTransition)
                    } else {
                        TimeGrid(days: days, tasks: timeGrid.displayedTasks, allDayItems: timeGrid.allDayItems, blocksByDay: timeGrid.blocksByDay,
                                 today: model.today, selected: sel, isRegular: isRegular,
                                 isActive: isActive,
                                 scrollResetToken: timeGridScrollReset,
                                 showOwnerAvatars: showOwnerAvatars,
                                 isViewerFilter: model.isViewer(projectId: projectFilter),
                                 dragLock: gridDragLock,
                                 openTask: { id, rect in openTaskOrPopover(id, rect: rect) },
                                 tapSlot: { d, m in compose(day: d, minute: m) },
                                 createRange: { d, s, e in compose(day: d, minute: s, endMinute: e) },
                                 moveTask: { task, draft in moveTask(task, to: draft) },
                                 tapDay: { d in
                                    shiftPage(direction: 0) {
                                        selected = d
                                        modeRaw = CalMode.day.rawValue
                                    }
                                 })
                            .id("\(mode.rawValue)-\(pageSequence)")
                            .transition(pageTransition)
                    }
                }
                .modifier(HorizontalDragOffsetModifier(drag: drag, reduceMotion: reduceMotion))
                .clipped()
                .gesture(horizontalOnlySwipe)
            }
        }
        .onChange(of: modeRaw) { _, _ in
            // Non-animated cleanup when mode changes.
            gridDragLock.isActive = false
            popoverTarget = nil
            drag.horizontalOffset = 0
            drag.collapseY = 0
            shiftDir = 0
            pageSequence += 1
        }
        .onDisappear {
            gridDragLock.isActive = false
        }
    }

    var busyDays: Set<LocalDay> {
        cache.busyDays(tasksVersion: tasksVersion, projectFilter: projectFilter, year: shownMonth.year, tasks: tasks)
    }

    // MARK: 清單 — date grid

    var dateGrid: some View {
        let days = cache.gridDays(for: shownMonth)
        let dotColors = cache.dayDotColors(
            tasksVersion: tasksVersion,
            projectFilter: projectFilter,
            month: shownMonth,
            projects: model.projects,
            tasks: tasks
        )
        return CalendarDateGrid(
            days: days,
            dayDotColors: dotColors,
            shownMonth: shownMonth,
            selected: sel,
            today: model.today,
            collapsed: $collapsed,
            pageSequence: pageSequence,
            pageTransition: pageTransition,
            isRegular: isRegular,
            drag: drag,
            onSelectDay: { d in
                let monthChanged = d.month != shownMonth.month
                let dir = monthChanged ? (d > shownMonth ? 1 : -1) : shiftDir
                shiftPage(direction: dir, bumpPage: monthChanged) {
                    selected = d
                    if monthChanged {
                        month = d.firstOfMonth
                    }
                }
            },
            onHorizontalEnded: { tx, vx in
                finishHorizontalSwipe(tx: tx, vx: vx)
            }
        )
    }

    var dayItems: [TodoTask] {
        cache.dayItems(tasksVersion: tasksVersion, projectFilter: projectFilter, day: sel, tasks: tasks)
    }

    var dayTitle: String { DateText.monthDay(sel).replacingOccurrences(of: " ", with: "") + (sel == model.today ? "・今天" : "") }

    @ViewBuilder var emptyDay: some View {
        if model.isViewer(projectId: projectFilter) {
            Text("這天沒有項目").txt(14).foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, minHeight: 64)
        } else {
            Button { compose(day: sel, minute: nil) } label: {
                Text("這天沒有項目，點這裡新增").txt(14).foregroundStyle(Palette.textSecondary).frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.press)
        }
    }

    private var agendaContext: CalAgendaContext {
        CalAgendaContext(day: sel, member: effectiveMemberFilter, project: projectFilter, completed: showCompleted)
    }

    var cardAgenda: some View {
        let items = dayItems
        return VStack(alignment: .leading, spacing: 0) {
            Text(dayTitle).txt(19, .bold).foregroundStyle(Palette.text).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
            Group {
                if items.isEmpty { emptyDay }
                ForEach(items) { t in
                    AgendaRow(task: t, day: sel, showOwnerAvatar: showOwnerAvatars, showProject: projectFilter == nil, onOpen: openTaskOrPopover)
                        .transition(Motion.rowTransition(reduceMotion))
                }
            }
            // Switching day/filter swaps the list instantly; only same-context reloads play row transitions.
            .transaction(value: agendaContext) { $0.animation = nil }
            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    var timelineAgenda: some View {
        let items = dayItems
        return VStack(alignment: .leading, spacing: 0) {
            Text(dayTitle).txt(17, .bold).foregroundStyle(Palette.text).padding(.vertical, 8)
            Group {
                if items.isEmpty { emptyDay.card(16) }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                    TimelineAgendaRow(task: t, day: sel, last: i == items.count - 1, showOwnerAvatar: showOwnerAvatars, onOpen: openTaskOrPopover)
                        .transition(Motion.rowTransition(reduceMotion))
                }
            }
            // Switching day/filter swaps the list instantly; only same-context reloads play row transitions.
            .transaction(value: agendaContext) { $0.animation = nil }
        }
    }

    // MARK: 月 — event bars

    private static let macMonthWeekdayHeaderHeight: CGFloat = 26

    var eventMonth: some View {
        let weeks = cache.monthWeeks(
            tasksVersion: tasksVersion,
            projectFilter: projectFilter,
            month: shownMonth,
            projects: model.projects,
            tasks: tasks
        )
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) { Text($0).txt(12).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity) }
            }
            .padding(.bottom, 4)
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, w in
                WeekRow(week: w, month: shownMonth, today: model.today, reduceMotion: reduceMotion) { d in
                    shiftPage(direction: 0) {
                        selected = d
                        modeRaw = CalMode.day.rawValue
                    }
                } open: { id, rect in
                    openTaskOrPopover(id, rect: rect)
                }
                .equatable()
            }
        }
    }

    private func macEventMonth(availableHeight: CGFloat) -> some View {
        let weekCount = max(1, cache.gridDays(for: shownMonth).count / 7)
        let gridHeight = max(0, availableHeight - Self.macMonthWeekdayHeaderHeight)
        let cellHeight = gridHeight / CGFloat(weekCount)
        let maxLanes = CalendarMonthMetrics.macMonthMaxLanes(forCellHeight: cellHeight)
        let weeks = cache.monthWeeks(
            tasksVersion: tasksVersion,
            projectFilter: projectFilter,
            month: shownMonth,
            projects: model.projects,
            tasks: tasks,
            maxLanes: maxLanes
        )
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) {
                    Text("週\($0)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.leading, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: Self.macMonthWeekdayHeaderHeight)

            VStack(spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, w in
                    WeekRow(week: w, month: shownMonth, today: model.today, reduceMotion: reduceMotion, fillHeight: true) { d in
                        shiftPage(direction: 0) {
                            selected = d
                            modeRaw = CalMode.day.rawValue
                        }
                    } open: { id, rect in
                        openTaskOrPopover(id, rect: rect)
                    }
                    .equatable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                Rectangle().strokeBorder(Palette.separator, lineWidth: 1)
            }
        }
    }
}

/// High-frequency gesture offsets kept out of `CalendarScreen.body` so dragging
/// does not re-evaluate layouts or diff tasks on every frame.
@MainActor
@Observable
final class CalendarDragState {
    var horizontalOffset: CGFloat = 0
    var collapseY: CGFloat = 0
}

struct HorizontalDragOffsetModifier: ViewModifier {
    var drag: CalendarDragState
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content.offset(x: reduceMotion ? 0 : drag.horizontalOffset)
    }
}

struct CalReload: Hashable {
    var range: ClosedRange<LocalDay>
    var member: String?
    var completed: Bool
    var revision: Int

    fileprivate var queryKey: CalQueryKey {
        CalQueryKey(range: range, member: member, completed: completed)
    }
}

struct CalActivation: Equatable { var isActive: Bool; var navTrigger: Int }

struct TimeGridScrollKey: Equatable { var days: [LocalDay]; var resetToken: Int }

struct CalQueryKey: Equatable { var range: ClosedRange<LocalDay>; var member: String?; var completed: Bool }

struct CalAgendaContext: Hashable { var day: LocalDay; var member: String?; var project: String?; var completed: Bool }
