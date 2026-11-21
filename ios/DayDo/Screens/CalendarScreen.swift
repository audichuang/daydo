import Observation
import SwiftUI
import DayDoCore

enum CalMode: String, CaseIterable, Identifiable {
    case list, year, month, week, threeDay, day
    var id: String { rawValue }
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
    var dayCount: Int { switch self { case .week: 7; case .threeDay: 3; default: 1 } }
}

/// 日曆: 清單 (date grid + the selected day's items, 2a/2b), 年, 月 (event
/// bars, 2c), and 週／3日／日 time grids.
struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.isRegularWindow) private var isRegular
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isActive: Bool = true

    @AppStorage("calendarViewMode") private var modeRaw = CalMode.list.rawValue
    @AppStorage("calendarCollapsed") private var collapsed = false
    @AppStorage("agendaTimeline") private var timelineStyle = false
    @AppStorage("weekAgendaStyle") private var weekAgendaStyle = false
    @AppStorage("calendarShowCompleted") private var showCompleted = true
    @State private var selected: LocalDay?
    @State private var month: LocalDay?
    @State private var memberFilter: String?
    @State private var projectFilter: String?
    @State private var tasks: [TodoTask] = []
    @State private var tasksVersion = 0
    @State private var loadedQuery: CalQueryKey?
    @State private var loadedReload: CalReload?
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

    private var activeReload: CalReload? {
        isActive ? CalReload(range: range, member: effectiveMemberFilter, completed: showCompleted, revision: model.revision) : nil
    }

    var mode: CalMode { CalMode(rawValue: modeRaw) ?? .list }
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
                if !isRegular {
                    header
                }
                if model.filterMembers.count > 1 || projectFilter != nil {
                    filters.padding(.horizontal, 16).padding(.top, isRegular ? 8 : 0).padding(.bottom, 6)
                }
                content
            }
            if !model.isViewer(projectId: projectFilter) {
                ComposeFAB { compose(day: sel, minute: nil) }
            }
        }
        .sensoryFeedback(.selection, trigger: dateSelectionHaptic)
        .sensoryFeedback(.selection, trigger: modeRaw)
        .sensoryFeedback(.impact(weight: .light), trigger: pageShiftHaptic)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRegular {
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
            guard let reload = activeReload, reload != loadedReload else { return }
            await load(for: reload)
        }
        .onAppear { applyPendingCalendarDay() }
        .onChange(of: CalActivation(isActive: isActive, navTrigger: model.calendarNavigationTrigger)) { old, new in
            if !new.isActive {
                gridDragLock.isActive = false
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
            modeRaw = CalMode.list.rawValue
        }
    }

    // MARK: Header

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
                ForEach(CalMode.allCases) { m in
                    Button {
                        withAnimation(Motion.toggle(reduceMotion)) { modeRaw = m.rawValue }
                    } label: {
                        if m == mode { Label(m.label, systemImage: "checkmark") } else { Label(m.label, systemImage: m.icon) }
                    }
                }
            } label: {
                iconLabel
            }
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
        let ellipsisLabel = Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.text).frame(width: 44, height: 40)
        if isActive {
            Menu {
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
            } label: {
                ellipsisLabel
            }
            .hoverEffect(.highlight)
            .accessibilityLabel("更多選項")
        } else {
            ellipsisLabel.accessibilityHidden(true)
        }
    }

    var title: String {
        let thisYear = model.today.year
        switch mode {
        case .year: return "\(String(shownMonth.year)) 年"
        case .week, .threeDay, .day:
            let d = rangeDays.first ?? sel
            return d.year == thisYear ? "\(d.month)月" : "\(String(d.year)) 年 \(d.month) 月"
        default:
            return shownMonth.year == thisYear ? "\(shownMonth.month)月" : "\(String(shownMonth.year)) 年 \(shownMonth.month) 月"
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

    var rangeDays: [LocalDay] {
        switch mode {
        case .week:
            let start = sel.adding(days: -sel.weekday)
            return (0..<7).map { start.adding(days: $0) }
        case .threeDay: return (0..<3).map { sel.adding(days: $0) }
        case .day: return [sel]
        default: return []
        }
    }

    var range: ClosedRange<LocalDay> {
        switch mode {
        case .year:
            return LocalDay(year: shownMonth.year, month: 1, day: 1)...LocalDay(year: shownMonth.year, month: 12, day: 31)
        case .week, .threeDay, .day:
            return rangeDays.first!...rangeDays.last!
        default:
            let g = cache.gridDays(for: shownMonth)
            return g.first!...g.last!
        }
    }

    func load() async {
        await load(for: CalReload(range: range, member: effectiveMemberFilter, completed: showCompleted, revision: model.revision))
    }

    private func load(for reload: CalReload) async {
        let currentQuery = CalQueryKey(range: reload.range, member: reload.member, completed: reload.completed)
        let q = TaskQuery(from: reload.range.lowerBound, to: reload.range.upperBound, includeCompleted: reload.completed, memberId: reload.member)
        do {
            let loaded = try await model.api.listTasks(q)
            guard !Task.isCancelled else { return }
            if loadedQuery == currentQuery {
                withAnimation(Motion.layout(reduceMotion)) {
                    tasks = loaded
                    tasksVersion += 1
                    loadedQuery = currentQuery
                    loadedReload = reload
                }
            } else {
                tasks = loaded
                tasksVersion += 1
                loadedQuery = currentQuery
                loadedReload = reload
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { model.errorMessage = error.localizedDescription }
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
        switch mode {
        case .list where collapsed:
            selected = sel.adding(days: 7 * dir)
            month = selected!.firstOfMonth
        case .list, .month:
            month = shownMonth.adding(months: dir)
            selected = month
        case .year:
            month = shownMonth.adding(months: 12 * dir)
        case .week, .threeDay, .day:
            selected = sel.adding(days: mode.dayCount * dir)
            month = selected!.firstOfMonth
        }
    }

    func shift(_ dir: Int) {
        shiftPage(direction: dir, token: Motion.page, haptic: .pageShift) {
            applyShift(dir)
        }
    }

    func compose(day: LocalDay, minute: Int?, endMinute: Int? = nil) {
        guard !model.isViewer(projectId: projectFilter) else { return }
        model.composing = ComposeRequest(projectId: projectFilter, day: day, minute: minute, endMinute: endMinute)
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
            await load()
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
                                modeRaw = CalMode.list.rawValue
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
                            openTask: { model.openTask($0, inlineAvailable: false) },
                            tapEmpty: { d in compose(day: d, minute: nil) },
                            openDay: { d in
                                shiftPage(direction: 0) {
                                    selected = d
                                    month = d.firstOfMonth
                                    modeRaw = CalMode.day.rawValue
                                }
                            },
                            pickMiniDay: { d in
                                let oldWeekStart = sel.adding(days: -sel.weekday)
                                let newWeekStart = d.adding(days: -d.weekday)
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
                                 openTask: { model.openTask($0, inlineAvailable: false) },
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
                    AgendaRow(task: t, day: sel, showOwnerAvatar: showOwnerAvatars, showProject: projectFilter == nil)
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
                    TimelineAgendaRow(task: t, day: sel, last: i == items.count - 1, showOwnerAvatar: showOwnerAvatars)
                        .transition(Motion.rowTransition(reduceMotion))
                }
            }
            // Switching day/filter swaps the list instantly; only same-context reloads play row transitions.
            .transaction(value: agendaContext) { $0.animation = nil }
        }
    }

    // MARK: 月 — event bars

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
                } open: { id in model.openTask(id, inlineAvailable: false) }
                .equatable()
            }
        }
    }
}

/// High-frequency gesture offsets kept out of `CalendarScreen.body` so dragging
/// does not re-evaluate layouts or diff tasks on every frame.
@MainActor
@Observable
private final class CalendarDragState {
    var horizontalOffset: CGFloat = 0
    var collapseY: CGFloat = 0
}

private struct HorizontalDragOffsetModifier: ViewModifier {
    var drag: CalendarDragState
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content.offset(x: reduceMotion ? 0 : drag.horizontalOffset)
    }
}

private struct WeekRowBar: Equatable {
    var taskId: String
    var title: String
    var colorHex: String?
    var isCompleted: Bool
    var timedPrefix: String
    var startColumn: Int
    var endColumn: Int
    var lane: Int
    var continues: Bool
}

private struct WeekRowModel: Equatable {
    var days: [LocalDay]
    var bars: [WeekRowBar]
    var overflow: [Int: Int]
    var rowHeight: CGFloat
}

struct TimeGridAllDayItem {
    var task: TodoTask
    var firstColumn: Int
    var lastColumn: Int
    var lane: Int
}

private struct TimeGridData {
    var displayedTasks: [TodoTask]
    var allDayItems: [TimeGridAllDayItem]
    var blocksByDay: [[DayLayout.Block]]
}

/// Caches derived calendar data by lightweight scalar/version keys so body
/// re-evaluations never recompute MonthLayout, DayLayout, dot colors, or busy days.
@MainActor
private final class CalendarDerivedCache {
    private static let laneHeight: CGFloat = 17

    private var gridMonth: LocalDay?
    private var cachedGridDays: [LocalDay] = []

    private var colorSignature: [(String, String?)] = []
    private var colorMap: [String: String] = [:]
    private var colorVersion = 0

    private var filteredKey: (Int, String?)?
    private var cachedFiltered: [TodoTask] = []

    private var dotColorsKey: (Int, String?, LocalDay, Int)?
    private var cachedDotColors: [LocalDay: [String]] = [:]

    private var dayItemsKey: (Int, String?, LocalDay)?
    private var cachedDayItems: [TodoTask] = []

    private var monthWeeksKey: (Int, String?, LocalDay, Int)?
    private var cachedMonthWeeks: [WeekRowModel] = []

    private var busyKey: (Int, String?, Int)?
    private var cachedBusyDays: Set<LocalDay> = []

    private var timeGridKey: (Int, String?, UUID?, [LocalDay])?
    private var cachedTimeGrid: TimeGridData?

    func gridDays(for month: LocalDay) -> [LocalDay] {
        let first = month.firstOfMonth
        if gridMonth == first, !cachedGridDays.isEmpty {
            return cachedGridDays
        }
        let days = MonthLayout.gridDays(for: first)
        gridMonth = first
        cachedGridDays = days
        return days
    }

    private func resolveColorMap(for projects: [Project]) -> (version: Int, map: [String: String]) {
        let same = projects.count == colorSignature.count
            && zip(projects, colorSignature).allSatisfy { $0.id == $1.0 && $0.color == $1.1 }
        if !same {
            colorSignature = projects.map { ($0.id, $0.color) }
            var map: [String: String] = [:]
            map.reserveCapacity(projects.count)
            for p in projects {
                if let c = p.color { map[p.id] = c }
            }
            colorMap = map
            colorVersion += 1
        }
        return (colorVersion, colorMap)
    }

    func filteredTasks(tasksVersion: Int, projectFilter: String?, tasks: [TodoTask]) -> [TodoTask] {
        if let key = filteredKey, key.0 == tasksVersion, key.1 == projectFilter {
            return cachedFiltered
        }
        let result = projectFilter.map { pf in tasks.filter { $0.projectId == pf } } ?? tasks
        filteredKey = (tasksVersion, projectFilter)
        cachedFiltered = result
        return result
    }

    func dayDotColors(
        tasksVersion: Int,
        projectFilter: String?,
        month: LocalDay,
        projects: [Project],
        tasks: [TodoTask]
    ) -> [LocalDay: [String]] {
        let first = month.firstOfMonth
        let (cVer, map) = resolveColorMap(for: projects)
        if let key = dotColorsKey, key.0 == tasksVersion, key.1 == projectFilter, key.2 == first, key.3 == cVer {
            return cachedDotColors
        }
        let days = gridDays(for: first)
        let items = filteredTasks(tasksVersion: tasksVersion, projectFilter: projectFilter, tasks: tasks)
        var out: [LocalDay: [String]] = [:]
        if let gridFirst = days.first, let gridLast = days.last {
            for t in items where !t.isCompleted {
                guard let s = t.schedule, s.overlaps(gridFirst, gridLast) else { continue }
                let color = map[t.projectId] ?? "#5B6461"
                var d = max(s.startDay, gridFirst)
                let end = min(s.lastDay, gridLast)
                while d <= end {
                    var colors = out[d] ?? []
                    if colors.count < 3 && !colors.contains(color) {
                        colors.append(color)
                        out[d] = colors
                    }
                    d = d.adding(days: 1)
                }
            }
        }
        dotColorsKey = (tasksVersion, projectFilter, first, cVer)
        cachedDotColors = out
        return out
    }

    func dayItems(tasksVersion: Int, projectFilter: String?, day: LocalDay, tasks: [TodoTask]) -> [TodoTask] {
        if let key = dayItemsKey, key.0 == tasksVersion, key.1 == projectFilter, key.2 == day {
            return cachedDayItems
        }
        let items = filteredTasks(tasksVersion: tasksVersion, projectFilter: projectFilter, tasks: tasks)
        let result = TaskGrouping.calendarDayTasks(items, on: day)
        dayItemsKey = (tasksVersion, projectFilter, day)
        cachedDayItems = result
        return result
    }

    func monthWeeks(
        tasksVersion: Int,
        projectFilter: String?,
        month: LocalDay,
        projects: [Project],
        tasks: [TodoTask]
    ) -> [WeekRowModel] {
        let first = month.firstOfMonth
        let (cVer, map) = resolveColorMap(for: projects)
        if let key = monthWeeksKey, key.0 == tasksVersion, key.1 == projectFilter, key.2 == first, key.3 == cVer {
            return cachedMonthWeeks
        }
        let days = gridDays(for: first)
        let items = filteredTasks(tasksVersion: tasksVersion, projectFilter: projectFilter, tasks: tasks)
        let layout = MonthLayout(days: days, tasks: items, maxLanes: 5)
        let weeks = layout.weeks.map { week -> WeekRowModel in
            let bars = week.bars.map { bar in
                WeekRowBar(
                    taskId: bar.task.id,
                    title: bar.task.title,
                    colorHex: map[bar.task.projectId],
                    isCompleted: bar.task.isCompleted,
                    timedPrefix: bar.task.schedule?.startMinute.map { "[\(DateText.hm($0))] " } ?? "",
                    startColumn: bar.startColumn,
                    endColumn: bar.endColumn,
                    lane: bar.lane,
                    continues: bar.continues
                )
            }
            let usedLanes = (bars.map(\.lane).max() ?? -1) + 1
            let visibleLanes = max(1, usedLanes)
            let bottomPad: CGFloat = week.overflow.isEmpty ? 8 : 18
            let rowHeight = 36 + Self.laneHeight * CGFloat(visibleLanes) + bottomPad
            return WeekRowModel(days: week.days, bars: bars, overflow: week.overflow, rowHeight: rowHeight)
        }
        monthWeeksKey = (tasksVersion, projectFilter, first, cVer)
        cachedMonthWeeks = weeks
        return weeks
    }

    func busyDays(tasksVersion: Int, projectFilter: String?, year: Int, tasks: [TodoTask]) -> Set<LocalDay> {
        if let key = busyKey, key.0 == tasksVersion, key.1 == projectFilter, key.2 == year {
            return cachedBusyDays
        }
        let items = filteredTasks(tasksVersion: tasksVersion, projectFilter: projectFilter, tasks: tasks)
        let lower = LocalDay(year: year, month: 1, day: 1)
        let upper = LocalDay(year: year, month: 12, day: 31)
        var s = Set<LocalDay>()
        for t in items {
            guard let sch = t.schedule, sch.overlaps(lower, upper) else { continue }
            var d = max(sch.startDay, lower)
            let end = min(sch.lastDay, upper)
            while d <= end {
                s.insert(d)
                d = d.adding(days: 1)
            }
        }
        busyKey = (tasksVersion, projectFilter, year)
        cachedBusyDays = s
        return s
    }

    func timeGridData(
        tasksVersion: Int,
        projectFilter: String?,
        pendingMove: PendingBlockMove?,
        days: [LocalDay],
        tasks: [TodoTask]
    ) -> TimeGridData {
        let token = pendingMove?.token
        if let key = timeGridKey, let cached = cachedTimeGrid,
           key.0 == tasksVersion, key.1 == projectFilter, key.2 == token, key.3 == days {
            return cached
        }
        let base = filteredTasks(tasksVersion: tasksVersion, projectFilter: projectFilter, tasks: tasks)
        let displayed: [TodoTask]
        if let pending = pendingMove {
            displayed = base.map { task in
                guard task.id == pending.taskId else { return task }
                var copy = task
                copy.schedule = pending.schedule
                return copy
            }
        } else {
            displayed = base
        }

        var allDay: [TimeGridAllDayItem] = []
        if let first = days.first, let last = days.last {
            var lanes: [[ClosedRange<Int>]] = []
            for t in displayed {
                guard let s = t.schedule, s.isAllDay, s.overlaps(first, last) else { continue }
                let a = max(0, first.days(until: s.startDay))
                let b = min(days.count - 1, first.days(until: s.lastDay))
                var lane = 0
                while lane < lanes.count, lanes[lane].contains(where: { $0.overlaps(a...b) }) { lane += 1 }
                if lane == lanes.count { lanes.append([]) }
                lanes[lane].append(a...b)
                allDay.append(TimeGridAllDayItem(task: t, firstColumn: a, lastColumn: b, lane: lane))
            }
        }

        let blocksByDay = days.map { DayLayout.blocks(for: displayed, on: $0) }
        let data = TimeGridData(displayedTasks: displayed, allDayItems: allDay, blocksByDay: blocksByDay)
        timeGridKey = (tasksVersion, projectFilter, token, days)
        cachedTimeGrid = data
        return data
    }
}

/// Isolated date grid for 清單 mode: reads `drag.collapseY` without invalidating
/// `CalendarScreen.body`, and isolates `drag.horizontalOffset` via modifier.
private struct CalendarDateGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var days: [LocalDay]
    var dayDotColors: [LocalDay: [String]]
    var shownMonth: LocalDay
    var selected: LocalDay
    var today: LocalDay
    @Binding var collapsed: Bool
    var pageSequence: Int
    var pageTransition: AnyTransition
    var isRegular: Bool
    var drag: CalendarDragState
    var onSelectDay: (LocalDay) -> Void
    var onHorizontalEnded: (CGFloat, CGFloat) -> Void

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let rowCount = max(1, days.count / 7)
        let rowH: CGFloat = 50
        let rowSpacing: CGFloat = 2
        let fullGridHeight = CGFloat(rowCount) * rowH + CGFloat(rowCount - 1) * rowSpacing
        let collapsedGridHeight = rowH
        let travel = max(1, fullGridHeight - collapsedGridHeight)
        let restProgress: CGFloat = collapsed ? 0 : 1
        let progress: CGFloat = reduceMotion ? restProgress : min(1, max(0, restProgress + drag.collapseY / travel))
        let visibleGridHeight = collapsedGridHeight + (fullGridHeight - collapsedGridHeight) * progress
        let selectedRow = days.firstIndex(of: selected).map { $0 / 7 } ?? 0
        let gridOffsetY = -CGFloat(selectedRow) * (rowH + rowSpacing) * (1 - progress)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) { Text($0).txt(12).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity) }
            }
            .padding(.bottom, 6)
            ZStack(alignment: .top) {
                LazyVGrid(columns: Self.columns, spacing: rowSpacing) {
                    ForEach(Array(days.enumerated()), id: \.element) { idx, d in
                        let inMonth = d.month == shownMonth.month
                        let cellOpacity = inMonth ? 1.0 : (1.0 - 0.62 * Double(progress))
                        CalendarDayCell(
                            day: d,
                            isSelected: d == selected,
                            isToday: d == today,
                            dotColors: dayDotColors[d] ?? [],
                            reduceMotion: reduceMotion,
                            onTap: { onSelectDay(d) }
                        )
                        .equatable()
                        .opacity(cellOpacity)
                        .allowsHitTesting(progress > 0 || idx / 7 == selectedRow)
                        .accessibilityHidden(progress == 0 && idx / 7 != selectedRow)
                    }
                }
                .offset(y: gridOffsetY)
                .id("list-\(pageSequence)")
                .transition(pageTransition)
            }
            .modifier(HorizontalDragOffsetModifier(drag: drag, reduceMotion: reduceMotion))
            .frame(height: visibleGridHeight, alignment: .top)
            .clipped()

            Button {
                withAnimation(Motion.layout(reduceMotion)) {
                    collapsed.toggle()
                    drag.collapseY = 0
                }
            } label: {
                Capsule().fill(Palette.handle).frame(width: 36, height: 4).frame(maxWidth: .infinity, minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel(collapsed ? "展開整個月份" : "收合成單週")
        }
        .padding(.top, 4)
        .gesture(
            CalendarPanGesture(
                allowLeftEdgeRightward: isRegular,
                allowVertical: { true },
                verticalShouldBegin: { vy in (!collapsed && vy < 0) || (collapsed && vy > 0) },
                onHorizontalChanged: { tx in
                    if !reduceMotion {
                        drag.horizontalOffset = tx * 0.9
                    }
                },
                onHorizontalEnded: onHorizontalEnded,
                onVerticalChanged: { ty in
                    if !reduceMotion {
                        drag.collapseY = ty
                    }
                },
                onVerticalEnded: { ty, vy in
                    withAnimation(Motion.layout(reduceMotion)) {
                        if !collapsed && (ty < -45 || vy < -350) {
                            collapsed = true
                        } else if collapsed && (ty > 45 || vy > 350) {
                            collapsed = false
                        }
                        drag.collapseY = 0
                    }
                }
            )
        )
    }
}

private struct CalendarDayCell: View, Equatable {
    @Environment(\.accent) private var accent
    var day: LocalDay
    var isSelected: Bool
    var isToday: Bool
    var dotColors: [String]
    var reduceMotion: Bool
    var onTap: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.day == rhs.day
            && lhs.isSelected == rhs.isSelected
            && lhs.isToday == rhs.isToday
            && lhs.dotColors == rhs.dotColors
            && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(day.day)")
                    .txt(17, isSelected || isToday ? .bold : .medium)
                    .foregroundStyle(isSelected ? accent.onAccent : (isToday ? Palette.todayText(accent: accent) : Palette.textDay))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(isSelected ? accent.color : (isToday ? Palette.todayFill(accent: accent) : .clear)))
                HStack(spacing: 3) {
                    ForEach(dotColors, id: \.self) { c in Circle().fill(Palette.listColor(c)).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press(scale: 0.92, opacity: 0.85))
        .hoverEffect(.highlight)
        .accessibilityLabel(DateText.full(day) + (dotColors.isEmpty ? "" : "，有項目"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CalReload: Hashable { var range: ClosedRange<LocalDay>; var member: String?; var completed: Bool; var revision: Int }
private struct CalActivation: Equatable { var isActive: Bool; var navTrigger: Int }
private struct TimeGridScrollKey: Equatable { var days: [LocalDay]; var resetToken: Int }
private struct CalQueryKey: Equatable { var range: ClosedRange<LocalDay>; var member: String?; var completed: Bool }
private struct CalAgendaContext: Hashable { var day: LocalDay; var member: String?; var project: String?; var completed: Bool }

func partnerOwner(for task: TodoTask, show: Bool, members: [Member]) -> Member? {
    guard show, !task.ownerId.isEmpty,
          let member = members.first(where: { $0.id == task.ownerId }),
          !member.isMe else { return nil }
    return member
}

struct OwnerAvatarBadge: View {
    var member: Member
    var size: CGFloat = 18
    var strokeWidth: CGFloat = 1.5

    var body: some View {
        AvatarView(member: member, size: size)
            .overlay(Circle().stroke(Palette.card, lineWidth: strokeWidth))
            .accessibilityHidden(true)
    }
}

/// Card-style agenda row with a checkbox (清單 view).
struct AgendaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var task: TodoTask
    var day: LocalDay
    var showOwnerAvatar = false
    var showProject = true

    private var isDone: Bool {
        model.displaysCompleted(task)
    }

    var body: some View {
        let project = model.project(task.projectId)
        let owner = partnerOwner(for: task, show: showOwnerAvatar, members: model.members)
        HStack(alignment: .top, spacing: 12) {
            Button { toggle() } label: {
                TaskCheckbox(done: isDone, priority: task.priority, size: 22).frame(width: 32, height: 34)
            }
            .buttonStyle(.press(scale: 0.9, opacity: 0.85))
            .hoverEffect(.highlight)
            .disabled(model.isViewer(projectId: task.projectId))
            .accessibilityLabel((isDone ? "取消完成：" : "完成：") + task.title)
            Button { model.openTask(task.id, inlineAvailable: false) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(task.title).txt(17, .medium).foregroundStyle(isDone ? Palette.done : Palette.text)
                            .strikethrough(isDone, color: Palette.done).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if let owner {
                            OwnerAvatarBadge(member: owner)
                                .padding(.top, 2)
                        }
                    }
                    if !task.content.isEmpty {
                        Text(task.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").txt(14).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(AgendaText.line(task, today: model.today, includeDay: task.schedule?.isMultiDay ?? false)).txt(14, .medium).foregroundStyle(AgendaText.color(task, today: model.today, accent: accent))
                        Spacer(minLength: 4)
                        if showProject {
                            Text(project?.name ?? "").txt(14).foregroundStyle(Palette.textTertiary).lineLimit(1)
                        }
                    }
                }
                .opacity(isDone ? 0.75 : 1)
                .animation(Motion.check(reduceMotion), value: isDone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.985, opacity: 0.95, highlight: Palette.pressHighlightStrong))
            .hoverEffect(.highlight)
            .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
        }
        .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.listColor(project?.color)).frame(width: 4) }
    }

    func toggle() {
        model.toggleComplete(task)
    }
}

/// Timeline-style agenda row: date/time on the left, a connector, the card.
struct TimelineAgendaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    var task: TodoTask
    var day: LocalDay
    var last: Bool
    var showOwnerAvatar = false

    var body: some View {
        let owner = partnerOwner(for: task, show: showOwnerAvatar, members: model.members)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                if let m = task.schedule.flatMap({ DayLayout.clippedRange(for: $0, on: day)?.start }) {
                    Text(DateText.hm(m)).font(.system(size: 15)).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 48, alignment: .trailing)
            .padding(.top, 12)
            VStack(spacing: 0) {
                Circle().strokeBorder(Palette.textSecondary, lineWidth: 1.5).frame(width: 14, height: 14).padding(.top, 16)
                if !last { Rectangle().fill(Palette.separator).frame(width: 1.5).frame(maxHeight: .infinity) }
            }
            .frame(width: 14)
            Button { model.openTask(task.id, inlineAvailable: false) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(AgendaText.line(task, today: model.today, includeDay: task.schedule?.isMultiDay ?? false))
                            .txt(15, .medium).foregroundStyle(AgendaText.color(task, today: model.today, accent: accent))
                        Spacer(minLength: 0)
                        if let owner {
                            OwnerAvatarBadge(member: owner)
                                .opacity(task.isCompleted ? 0.75 : 1)
                        }
                    }
                    Text(task.title).txt(17, .medium).foregroundStyle(task.isCompleted ? Palette.done : Palette.text)
                        .strikethrough(task.isCompleted, color: Palette.done).multilineTextAlignment(.leading)
                    if !task.content.isEmpty {
                        Text(task.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").txt(14).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .card(14)
            }
            .buttonStyle(.press(scale: 0.98, opacity: 0.92))
            .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
            .padding(.bottom, 12)
        }
    }
}

enum AgendaText {
    /// "11月13日, 11:00 – 12:00", "11月13日 – 11月17日", "全天".
    static func line(_ t: TodoTask, today: LocalDay, includeDay: Bool = true) -> String {
        if t.isCompleted { return "已完成" }
        guard let s = t.schedule else { return "" }
        func md(_ d: LocalDay) -> String { "\(d.month)月\(d.day)日" }
        if s.isAllDay {
            return s.isMultiDay ? md(s.startDay) + " – " + md(s.lastDay) : (includeDay ? md(s.startDay) : "全天")
        }
        let r = DateText.range(s)
        return includeDay ? md(s.startDay) + ", " + r : r
    }

    static func color(_ t: TodoTask, today: LocalDay, accent: AccentTheme) -> Color {
        if t.isCompleted { return Palette.done }
        return TaskGrouping.isOverdue(t, today: today) ? Palette.overdue : accent.text
    }
}

/// 年: twelve mini months; tapping month title opens it in 清單, tapping a day opens 日 view.
struct YearGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var year: Int
    var today: LocalDay
    var busy: Set<LocalDay>
    var isRegular: Bool = false
    var openMonth: (LocalDay) -> Void
    var openDay: (LocalDay) -> Void

    var body: some View {
        let cols = isRegular ? 4 : 3
        let masks: [UInt32] = {
            var out = [UInt32](repeating: 0, count: 12)
            for d in busy where d.year == year && (1...12).contains(d.month) && (1...31).contains(d.day) {
                out[d.month - 1] |= 1 << UInt32(d.day)
            }
            return out
        }()
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isRegular ? 20 : 14), count: cols), spacing: isRegular ? 22 : 18) {
            ForEach(1...12, id: \.self) { m in
                YearMonthCell(
                    year: year,
                    month: m,
                    today: today,
                    busyMask: masks[m - 1],
                    isRegular: isRegular,
                    reduceMotion: reduceMotion,
                    openMonth: openMonth,
                    openDay: openDay
                )
                .equatable()
            }
        }
        .padding(.top, 8)
    }
}

private struct YearMonthCell: View, Equatable {
    @Environment(\.accent) private var accent
    var year: Int
    var month: Int
    var today: LocalDay
    var busyMask: UInt32
    var isRegular: Bool
    var reduceMotion: Bool
    var openMonth: (LocalDay) -> Void
    var openDay: (LocalDay) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.year == rhs.year
            && lhs.month == rhs.month
            && lhs.today == rhs.today
            && lhs.busyMask == rhs.busyMask
            && lhs.isRegular == rhs.isRegular
            && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        let first = LocalDay(year: year, month: month, day: 1)
        let days = MonthLayout.gridDays(for: first)
        let weekCount = days.count / 7
        let dayFontSize: CGFloat = isRegular ? 11 : 8.5
        let circleSize: CGFloat = isRegular ? 18 : 13
        let rowHeight: CGFloat = isRegular ? 20 : 14

        VStack(alignment: .leading, spacing: 4) {
            Button { openMonth(first) } label: {
                Text("\(month)月").txt(isRegular ? 16 : 15, .bold).foregroundStyle(month == today.month && year == today.year ? accent.text : Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.press)
            .hoverEffect(.highlight)
            .accessibilityLabel("\(year) 年 \(month) 月")

            VStack(spacing: 2) {
                ForEach(0..<weekCount, id: \.self) { w in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { c in
                            let d = days[w * 7 + c]
                            if d.month == month {
                                let isToday = d == today
                                let isBusy = (busyMask & (1 << UInt32(d.day))) != 0
                                Button { openDay(d) } label: {
                                    Text("\(d.day)")
                                        .font(.system(size: dayFontSize, weight: isToday ? .bold : .regular))
                                        .foregroundStyle(isToday ? accent.onAccent : (isBusy ? accent.text : Palette.textSecondary))
                                        .frame(width: circleSize, height: circleSize)
                                        .background(Circle().fill(isToday ? accent.color : .clear))
                                        .frame(maxWidth: .infinity, minHeight: rowHeight)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.press(scale: 0.9, opacity: 0.85))
                                .hoverEffect(.highlight)
                                .accessibilityIdentifier("yearDay.\(d)")
                                .accessibilityLabel(DateText.full(d))
                            } else {
                                Color.clear.frame(maxWidth: .infinity, minHeight: rowHeight)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One week of the event month: day numbers on top, bars in lanes.
private struct WeekRow: View, Equatable {
    @Environment(\.accent) private var accent
    var week: WeekRowModel
    var month: LocalDay
    var today: LocalDay
    var reduceMotion: Bool
    var pick: (LocalDay) -> Void
    var open: (String) -> Void

    let laneH: CGFloat = 17

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.week == rhs.week
            && lhs.month == rhs.month
            && lhs.today == rhs.today
            && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        GeometryReader { geo in
            let colW = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(week.days.enumerated()), id: \.offset) { i, d in
                        let isToday = d == today
                        Button { pick(d) } label: {
                            VStack(spacing: 0) {
                                Text("\(d.day)")
                                    .font(.system(size: 14, weight: isToday ? .bold : .semibold))
                                    .foregroundStyle(isToday ? accent.onAccent : Palette.textDay)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(isToday ? accent.color : .clear))
                                    .padding(.top, 4)
                                Spacer()
                                if let n = week.overflow[i] {
                                    Text("+\(n)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4).padding(.bottom, 2)
                                }
                            }
                            .frame(width: colW, height: geo.size.height)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.press(scale: 0.94, opacity: 0.88))
                        .opacity(d.month == month.month ? 1 : 0.4)
                        .accessibilityLabel(DateText.full(d))
                    }
                }
                ForEach(Array(week.bars.enumerated()), id: \.offset) { _, bar in
                    let color = Palette.listColor(bar.colorHex)
                    let done = bar.isCompleted
                    Button { open(bar.taskId) } label: {
                        HStack(spacing: 0) {
                            Rectangle().fill(color).frame(width: 2)
                            Text((bar.continues ? "‹ " : "") + (bar.startColumn == bar.endColumn ? bar.timedPrefix : "") + bar.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(done ? Palette.done : Palette.text.opacity(0.92))
                                .strikethrough(done)
                                .lineLimit(1)
                                .padding(.horizontal, 3)
                            Spacer(minLength: 0)
                        }
                        .frame(width: colW * CGFloat(bar.endColumn - bar.startColumn + 1) - 3, height: laneH - 2, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(done ? 0.1 : 0.28)))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.press(scale: 0.96, opacity: 0.88))
                    .offset(x: colW * CGFloat(bar.startColumn) + 1.5, y: 36 + CGFloat(bar.lane) * laneH)
                }
            }
        }
        .frame(height: week.rowHeight)
    }
}

/// Scroll target for a time-grid hour row. A distinct type so it can never match the
/// Int offsets other ForEach rows in the same ScrollView use (0...6 for the week columns).
private struct HourRowID: Hashable { var hour: Int }

private struct PendingBlockMove {
    var token: UUID
    var taskId: String
    var schedule: Schedule
}

@MainActor
private final class GridDragLock {
    var isActive = false
}

/// 週／3日／日 time grid with an all-day strip, overlapping blocks side by
/// side, a now line on today, and tap/long-press-drag interactions.
struct TimeGrid: View {
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    var days: [LocalDay]
    var tasks: [TodoTask]
    var allDayItems: [TimeGridAllDayItem]
    var blocksByDay: [[DayLayout.Block]]
    var today: LocalDay
    var selected: LocalDay
    var isRegular: Bool = false
    var isActive: Bool = true
    var scrollResetToken: Int = 0
    var showOwnerAvatars: Bool = false
    var isViewerFilter: Bool = false
    fileprivate var dragLock: GridDragLock
    var openTask: (String) -> Void
    var tapSlot: (LocalDay, Int) -> Void
    var createRange: (LocalDay, Int, Int) -> Void
    var moveTask: (TodoTask, DateDraft) -> Void
    var tapDay: (LocalDay) -> Void

    @State private var dragMode: DragMode?
    @State private var moveStartHaptic = 0
    @State private var snapHaptic = 0
    @State private var suppressTapUntil: ContinuousClock.Instant?

    private enum DragMode {
        case move(task: TodoTask, sourceColumnDay: LocalDay, anchorPoint: CGPoint, targetColumnIndex: Int, moveResult: TimeGridDrag.MoveResult)
        case create(day: LocalDay, columnIndex: Int, anchorY: CGFloat, range: TimeGridDrag.RangeResult)
    }

    private var draggedTaskId: String? {
        if case .move(let task, _, _, _, _) = dragMode { return task.id }
        return nil
    }

    private var isTapSuppressed: Bool {
        guard let until = suppressTapUntil else { return false }
        return ContinuousClock.now < until
    }

    var hourH: CGFloat { isRegular ? 64 : 56 }
    var gutter: CGFloat { isRegular ? 52 : 40 }

    var body: some View {
        GeometryReader { geo in
            let colW = (geo.size.width - gutter - 8) / CGFloat(days.count)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: gutter)
                    ForEach(days, id: \.self) { d in
                        Button { tapDay(d) } label: {
                            VStack(spacing: 2) {
                                Text(LocalDay.weekdaySymbols[d.weekday]).font(.system(size: 12)).foregroundStyle(Palette.textTertiary)
                                Text("\(d.day)").font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(d == today ? accent.onAccent : Palette.text)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(d == today ? accent.color : .clear))
                            }
                            .frame(width: colW)
                        }
                        .buttonStyle(.press(scale: 0.94, opacity: 0.88))
                        .accessibilityLabel(DateText.full(d))
                    }
                }
                .padding(.bottom, 4)

                let ad = allDayItems
                let isDay = days.count == 1
                let totalLanes = (ad.map(\.lane).max() ?? -1) + 1
                let maxVisibleLanes = isDay ? 4 : 3
                let laneCount = min(maxVisibleLanes, totalLanes)
                let overflowByCol: [Int: Int] = {
                    guard !isDay else { return [:] }
                    var counts: [Int: Int] = [:]
                    for item in ad where item.lane >= maxVisibleLanes {
                        for col in item.firstColumn...item.lastColumn { counts[col, default: 0] += 1 }
                    }
                    return counts
                }()
                if laneCount > 0 {
                    if isDay {
                        let visibleHeight = CGFloat(laneCount) * 21 + 6
                        HStack(alignment: .top, spacing: 0) {
                            Text("全天")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textFaint)
                                .frame(width: gutter)
                                .padding(.top, 4)
                            ScrollView(.vertical, showsIndicators: totalLanes > maxVisibleLanes) {
                                ZStack(alignment: .topLeading) {
                                    ForEach(Array(ad.enumerated()), id: \.offset) { _, item in
                                        allDayChip(item.task, width: colW * CGFloat(item.lastColumn - item.firstColumn + 1) - 3)
                                            .offset(x: colW * CGFloat(item.firstColumn) + 1.5, y: CGFloat(item.lane) * 21 + 2)
                                    }
                                }
                                .frame(width: colW, height: CGFloat(totalLanes) * 21 + 4, alignment: .topLeading)
                                .enclosingScrollsToTop(false)
                            }
                            .frame(height: visibleHeight)
                        }
                        .frame(height: visibleHeight, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
                    } else {
                        ZStack(alignment: .topLeading) {
                            Text("全天").font(.system(size: 10)).foregroundStyle(Palette.textFaint).frame(width: gutter).padding(.top, 4)
                            ForEach(Array(ad.filter { $0.lane < maxVisibleLanes }.enumerated()), id: \.offset) { _, item in
                                allDayChip(item.task, width: colW * CGFloat(item.lastColumn - item.firstColumn + 1) - 3)
                                    .offset(x: gutter + colW * CGFloat(item.firstColumn) + 1.5, y: CGFloat(item.lane) * 21 + 2)
                            }
                            ForEach(overflowByCol.keys.sorted(), id: \.self) { col in
                                let n = overflowByCol[col]!
                                Button { tapDay(days[col]) } label: {
                                    Text("+\(n)")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(accent.text)
                                        .frame(width: colW - 3, height: 16, alignment: .leading)
                                        .padding(.leading, 4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .offset(x: gutter + colW * CGFloat(col) + 1.5, y: CGFloat(laneCount) * 21 + 2)
                                .accessibilityLabel("還有 \(n) 項全天任務，點按切換至單日檢視")
                            }
                        }
                        .frame(height: CGFloat(laneCount) * 21 + (overflowByCol.isEmpty ? 6 : 20), alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ForEach(0..<25, id: \.self) { h in
                                    HStack(alignment: .top, spacing: 0) {
                                        Text(h == 24 ? "00" : String(format: "%02d", h)).font(.system(size: 12)).foregroundStyle(Palette.textTertiary)
                                            .frame(width: gutter, alignment: .center).offset(y: -7)
                                        Rectangle().fill(Palette.gridLine).frame(height: 1)
                                    }
                                    .frame(height: h == 24 ? 1 : hourH, alignment: .top)
                                    .id(HourRowID(hour: h))
                                }
                            }
                            // Column separators + tap-to-create
                            HStack(spacing: 0) {
                                Spacer().frame(width: gutter)
                                ForEach(days, id: \.self) { d in
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .frame(width: colW, height: hourH * 24)
                                        .overlay(alignment: .leading) { Rectangle().fill(Palette.gridColumnLine).frame(width: 1) }
                                        .allowsHitTesting(dragMode == nil)
                                        .onTapGesture(coordinateSpace: .local) { p in
                                            guard dragMode == nil, !isTapSuppressed else { return }
                                            let m = Int(p.y / hourH * 60) / 30 * 30
                                            tapSlot(d, min(m, 23 * 60 + 30))
                                        }
                                        .accessibilityLabel("\(DateText.full(d)) 空白時段，點兩下新增")
                                }
                            }
                            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                                let dayBlocks = i < blocksByDay.count ? blocksByDay[i] : []
                                ForEach(dayBlocks, id: \.self) { b in
                                    block(b, colW: colW)
                                        .opacity(draggedTaskId == b.task.id ? 0.35 : 1)
                                        .allowsHitTesting(dragMode == nil)
                                        .offset(x: gutter + colW * CGFloat(i) + colW / CGFloat(b.lanes) * CGFloat(b.lane) + 1, y: CGFloat(b.start) / 60 * hourH)
                                }
                                if d == today { nowLine(colW: colW).offset(x: gutter + colW * CGFloat(i), y: nowY - 4) }
                            }
                            if let dragMode {
                                dragPreview(dragMode, colW: colW)
                            }
                        }
                        .frame(height: hourH * 24 + 10, alignment: .topLeading)
                        .gesture(
                            TimeGridLongPressGesture(
                                dragLock: dragLock,
                                shouldBegin: { point in canBeginDrag(at: point, colW: colW) },
                                onBegan: { point in beginDrag(at: point, colW: colW) },
                                onChanged: { point in updateDrag(at: point, colW: colW) },
                                onEnded: { point in endDrag(at: point, colW: colW) },
                                onCancelled: { cancelDrag() }
                            )
                        )
                        .padding(.top, 8)
                        .padding(.bottom, isRegular ? 24 : 160)
                        .enclosingScrollsToTop(isActive)
                    }
                    .accessibilityIdentifier("timeGridScroll")
                    .scrollDisabled(dragMode != nil)
                    .defaultScrollAnchor(UnitPoint(x: 0, y: min(1, CGFloat(initialHour) * hourH / 900)), for: .initialOffset)
                    .scrollIndicators(.hidden)
                    .task(id: TimeGridScrollKey(days: days, resetToken: scrollResetToken)) {
                        guard isActive else { return }
                        // Wait for menu dismiss / transition & initial layout, then snap accurately.
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(HourRowID(hour: initialHour), anchor: .top)
                    }
                }
            }
            .padding(.trailing, 8)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: moveStartHaptic)
        .sensoryFeedback(.selection, trigger: snapHaptic)
        .onChange(of: isActive) { _, active in
            if !active { cancelDrag() }
        }
        .onDisappear { cancelDrag() }
    }

    var initialHour: Int {
        max(0, (days.contains(today) ? nowMinute / 60 : 8) - 2)
    }

    var nowMinute: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return c.hour! * 60 + c.minute!
    }
    var nowY: CGFloat { CGFloat(nowMinute) / 60 * hourH }

    /// Title width kept (~4 CJK characters) before an owner avatar may take
    /// room in timed blocks and all-day chips: narrow cells drop the avatar
    /// (VoiceOver still reads the owner) rather than truncating titles such as
    /// 學校接小安／學校接小明 to the same prefix.
    static let ownerAvatarMinTitleWidth: CGFloat = 56

    func allDayChip(_ t: TodoTask, width: CGFloat) -> some View {
        let color = Palette.listColor(model.project(t.projectId)?.color)
        let owner = partnerOwner(for: t, show: showOwnerAvatars, members: model.members)
        // Same title-first rule as timed blocks: color bar 2 + leading 4 + title
        // + trailing 2 + avatar 14 + stroke 1 + trailing 3.
        let showAvatar = owner != nil && width >= 2 + 4 + Self.ownerAvatarMinTitleWidth + 2 + 14 + 1 + 3
        return Button { openTask(t.id) } label: {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 2)
                Text(t.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(t.isCompleted ? Palette.done : Palette.text)
                    .lineLimit(1)
                    .padding(.leading, 4)
                    .padding(.trailing, showAvatar ? 2 : 4)
                Spacer(minLength: 0)
                if showAvatar, let owner {
                    OwnerAvatarBadge(member: owner, size: 14, strokeWidth: 1)
                        .opacity(t.isCompleted ? 0.75 : 1)
                        .padding(.trailing, 3)
                }
            }
            .frame(width: width, height: 19)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.28)))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.press(scale: 0.96, opacity: 0.88))
        .hoverEffect(.highlight)
        .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
    }

    func nowLine(colW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle().fill(Palette.overdue).frame(width: 8, height: 8)
            Rectangle().fill(Palette.overdue).frame(width: colW - 8, height: 1.5)
        }
        .allowsHitTesting(false)
    }

    func block(_ b: DayLayout.Block, colW: CGFloat) -> some View {
        let color = Palette.listColor(model.project(b.task.projectId)?.color)
        let w = colW / CGFloat(b.lanes) - 2
        let h = max(CGFloat(b.end - b.start) / 60 * hourH - 2, CGFloat(TimeGridDrag.minBlockHeight))
        let done = b.task.isCompleted
        let owner = partnerOwner(for: b.task, show: showOwnerAvatars, members: model.members)
        return blockContent(task: b.task, schedule: b.task.schedule, color: color, owner: owner, width: w, height: h)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(done ? 0.12 : 0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .onTapGesture {
                guard dragMode == nil, !isTapSuppressed else { return }
                openTask(b.task.id)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(b.task.title + "，" + (b.task.schedule.map(DateText.range) ?? ""))
            .accessibilityValue(owner.map { "\($0.name)的" } ?? "")
    }

    private func blockContent(task: TodoTask, schedule: Schedule?, color: Color, owner: Member?, width w: CGFloat, height h: CGFloat) -> some View {
        let done = task.isCompleted
        let avatarSize: CGFloat = (w >= 84 && h >= 32) ? 16 : 14
        let strokeWidth: CGFloat = 1
        let topInset: CGFloat = h >= 24 ? 3 : 2
        let neededWidth: CGFloat = 3 + 4 + Self.ownerAvatarMinTitleWidth + 4 + avatarSize + strokeWidth + 4
        let neededHeight: CGFloat = avatarSize + strokeWidth + topInset
        let showAvatar = owner != nil && w >= neededWidth && h >= neededHeight
        return HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(done ? Palette.done : Palette.text)
                    .strikethrough(done).lineLimit(h > 40 ? 3 : 1).multilineTextAlignment(.leading)
                if h > 34, let s = schedule { Text(DateText.range(s)).font(.system(size: 10)).foregroundStyle(Palette.textSecondary).lineLimit(1) }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, h >= 24 ? 3 : 2)
            Spacer(minLength: 0)
            if showAvatar, let owner {
                OwnerAvatarBadge(member: owner, size: avatarSize, strokeWidth: strokeWidth)
                    .opacity(done ? 0.75 : 1)
                    .padding(.top, topInset)
                    .padding(.trailing, 4)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }

    // MARK: Drag & Drop

    private func hitBlock(at point: CGPoint, colW: CGFloat) -> TimeGridDrag.BlockHit? {
        TimeGridDrag.hitTestBlock(
            x: Double(point.x),
            y: Double(point.y),
            days: days,
            tasks: tasks,
            gutter: Double(gutter),
            columnWidth: Double(colW),
            hourHeight: Double(hourH)
        )
    }

    private func canBeginDrag(at point: CGPoint, colW: CGFloat) -> Bool {
        guard colW > 0, !days.isEmpty else { return false }
        guard point.x >= gutter, point.x < gutter + colW * CGFloat(days.count),
              point.y >= 0, point.y <= hourH * 24 else { return false }
        if let hit = hitBlock(at: point, colW: colW) {
            return !model.isViewer(projectId: hit.block.task.projectId)
        }
        return !isViewerFilter
    }

    private func beginDrag(at point: CGPoint, colW: CGFloat) {
        guard canBeginDrag(at: point, colW: colW) else {
            dragLock.isActive = false
            return
        }
        if let hit = hitBlock(at: point, colW: colW),
           let schedule = hit.block.task.schedule,
           let moveResult = TimeGridDrag.moveSchedule(schedule, sourceColumnDay: hit.day, targetColumnDay: hit.day, minuteDelta: 0) {
            dragMode = .move(
                task: hit.block.task,
                sourceColumnDay: hit.day,
                anchorPoint: point,
                targetColumnIndex: hit.columnIndex,
                moveResult: moveResult
            )
            moveStartHaptic += 1
        } else {
            let colIdx = TimeGridDrag.columnIndex(x: Double(point.x), gutter: Double(gutter), columnWidth: Double(colW), columnCount: days.count)
            let range = TimeGridDrag.createRange(anchorY: Double(point.y), currentY: Double(point.y), hourHeight: Double(hourH))
            dragMode = .create(day: days[colIdx], columnIndex: colIdx, anchorY: point.y, range: range)
            moveStartHaptic += 1
        }
    }

    private func updateDrag(at point: CGPoint, colW: CGFloat) {
        guard let current = dragMode else { return }
        switch current {
        case .move(let task, let sourceDay, let anchor, let prevColIdx, let prevMove):
            guard let schedule = task.schedule else { return }
            let targetColIdx = TimeGridDrag.columnIndex(x: Double(point.x), gutter: Double(gutter), columnWidth: Double(colW), columnCount: days.count)
            let minuteDelta = TimeGridDrag.snappedMinuteDelta(dy: Double(point.y - anchor.y), hourHeight: Double(hourH))
            guard let nextMove = TimeGridDrag.moveSchedule(schedule, sourceColumnDay: sourceDay, targetColumnDay: days[targetColIdx], minuteDelta: minuteDelta) else { return }
            if targetColIdx != prevColIdx || nextMove != prevMove {
                snapHaptic += 1
                dragMode = .move(task: task, sourceColumnDay: sourceDay, anchorPoint: anchor, targetColumnIndex: targetColIdx, moveResult: nextMove)
            }
        case .create(let day, let colIdx, let anchorY, let prevRange):
            let nextRange = TimeGridDrag.createRange(anchorY: Double(anchorY), currentY: Double(point.y), hourHeight: Double(hourH))
            if nextRange != prevRange {
                snapHaptic += 1
                dragMode = .create(day: day, columnIndex: colIdx, anchorY: anchorY, range: nextRange)
            }
        }
    }

    private func endDrag(at point: CGPoint, colW: CGFloat) {
        updateDrag(at: point, colW: colW)
        let finished = dragMode
        dragMode = nil
        suppressTapUntil = ContinuousClock.now + .milliseconds(150)
        switch finished {
        case .move(let task, _, _, _, let moveResult):
            moveTask(task, moveResult.applied(to: task))
        case .create(let day, _, _, let range):
            createRange(day, range.startMinute, range.endMinute)
        case nil:
            break
        }
    }

    private func cancelDrag() {
        dragLock.isActive = false
        dragMode = nil
    }

    @ViewBuilder
    private func dragPreview(_ mode: DragMode, colW: CGFloat) -> some View {
        switch mode {
        case .move(let task, _, _, let targetColIdx, let moveResult):
            if let previewSchedule = moveResult.applied(to: task).schedule {
                let previewTask: TodoTask = {
                    var copy = task
                    copy.schedule = previewSchedule
                    return copy
                }()
                let color = Palette.listColor(model.project(task.projectId)?.color)
                let owner = partnerOwner(for: task, show: showOwnerAvatars, members: model.members)
                let segments: [(Int, DayLayout.Block)] = days.enumerated().flatMap { colIdx, d in
                    DayLayout.blocks(for: [previewTask], on: d).map { (colIdx, $0) }
                }
                let primarySegment = segments.first(where: { $0.0 == targetColIdx }) ?? segments.first
                ZStack(alignment: .topLeading) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, entry in
                        let (colIdx, seg) = entry
                        let w = colW - 2
                        let h = max(CGFloat(seg.end - seg.start) / 60 * hourH - 2, CGFloat(TimeGridDrag.minBlockHeight))
                        let x = gutter + colW * CGFloat(colIdx) + 1
                        let y = CGFloat(seg.start) / 60 * hourH
                        blockContent(task: previewTask, schedule: previewSchedule, color: color, owner: owner, width: w, height: h)
                            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.42)))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: Palette.navShadow, radius: 6, y: 3)
                            .scaleEffect(reduceMotion ? 1 : 1.03)
                            .animation(reduceMotion ? nil : Motion.press(reduceMotion), value: moveResult)
                            .offset(x: x, y: y)
                    }
                    if let (colIdx, seg) = primarySegment {
                        let w = colW - 2
                        let h = max(CGFloat(seg.end - seg.start) / 60 * hourH - 2, CGFloat(TimeGridDrag.minBlockHeight))
                        let x = gutter + colW * CGFloat(colIdx) + 1
                        let y = CGFloat(seg.start) / 60 * hourH
                        previewTimePill(DateText.range(previewSchedule), blockX: x, blockY: y, blockW: w, blockH: h, colW: colW)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

        case .create(_, let colIdx, _, let range):
            let x = gutter + colW * CGFloat(colIdx) + 1
            let y = CGFloat(range.startMinute) / 60 * hourH
            let w = colW - 2
            let h = max(CGFloat(range.endMinute - range.startMinute) / 60 * hourH - 2, CGFloat(TimeGridDrag.minBlockHeight))
            let timeText = DateText.hm(range.startMinute) + " – " + (range.endMinute >= 1440 ? "隔日 " : "") + DateText.hm(range.endMinute)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("新任務").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent.text).lineLimit(1)
                    if h > 34 {
                        Text(timeText).font(.system(size: 10)).foregroundStyle(accent.text.opacity(0.85)).lineLimit(1)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, h >= 24 ? 3 : 2)
                .frame(width: w, height: h, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 4).fill(accent.color.opacity(0.24)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent.color, lineWidth: 1.5))
                .scaleEffect(reduceMotion ? 1 : 1.02)
                .animation(reduceMotion ? nil : Motion.press(reduceMotion), value: range)
                .offset(x: x, y: y)

                previewTimePill(timeText, blockX: x, blockY: y, blockW: w, blockH: h, colW: colW)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func previewTimePill(_ text: String, blockX: CGFloat, blockY: CGFloat, blockW: CGFloat, blockH: CGFloat, colW: CGFloat) -> some View {
        let estWidth: CGFloat = 96
        let maxX = max(gutter, gutter + colW * CGFloat(days.count) - estWidth)
        let pillX = max(gutter, min(maxX, blockX + blockW / 2 - estWidth / 2))
        let pillY = blockY >= 26 ? blockY - 24 : blockY + blockH + 4
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.card))
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
            .shadow(color: Palette.navShadow, radius: 4, y: 2)
            .fixedSize()
            .offset(x: pillX, y: pillY)
    }
}

/// UIKit long-press recognizer (0.3s) for dragging blocks and creating ranges
/// on `TimeGrid`, disabling enclosing scroll panning immediately upon activation.
private struct TimeGridLongPressGesture: UIGestureRecognizerRepresentable {
    var dragLock: GridDragLock
    var shouldBegin: (CGPoint) -> Bool
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(
            converter: converter,
            dragLock: dragLock,
            shouldBegin: shouldBegin,
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let lp = UILongPressGestureRecognizer()
        lp.minimumPressDuration = 0.3
        lp.allowableMovement = 10
        lp.delegate = context.coordinator
        return lp
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.converter = context.converter
        context.coordinator.dragLock = dragLock
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let point = context.converter.localLocation
        switch recognizer.state {
        case .began:
            context.coordinator.lockScroll(for: recognizer.view)
            onBegan(point)
        case .changed:
            onChanged(point)
        case .ended:
            context.coordinator.unlockScroll()
            onEnded(point)
        case .cancelled, .failed:
            context.coordinator.unlockScroll()
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var converter: CoordinateSpaceConverter
        var dragLock: GridDragLock
        var shouldBegin: (CGPoint) -> Bool
        var onBegan: (CGPoint) -> Void
        var onChanged: (CGPoint) -> Void
        var onEnded: (CGPoint) -> Void
        var onCancelled: () -> Void
        private weak var lockedPan: UIPanGestureRecognizer?

        init(
            converter: CoordinateSpaceConverter,
            dragLock: GridDragLock,
            shouldBegin: @escaping (CGPoint) -> Bool,
            onBegan: @escaping (CGPoint) -> Void,
            onChanged: @escaping (CGPoint) -> Void,
            onEnded: @escaping (CGPoint) -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.converter = converter
            self.dragLock = dragLock
            self.shouldBegin = shouldBegin
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let point = converter.convert(globalPoint: gestureRecognizer.location(in: nil), to: .local)
            return shouldBegin(point)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }

        func lockScroll(for view: UIView?) {
            dragLock.isActive = true
            if let scrollView = view?.enclosingScrollView {
                lockedPan = scrollView.panGestureRecognizer
                scrollView.panGestureRecognizer.isEnabled = false
            }
        }

        func unlockScroll() {
            dragLock.isActive = false
            lockedPan?.isEnabled = true
            lockedPan = nil
        }
    }
}

/// UIKit pan recognizer for calendar horizontal paging and vertical grid
/// collapse/expand, keeping ScrollView vertical scrolling and taps responsive.
private struct CalendarPanGesture: UIGestureRecognizerRepresentable {
    var allowLeftEdgeRightward: Bool
    var canBegin: () -> Bool = { true }
    var allowVertical: () -> Bool
    var verticalShouldBegin: (CGFloat) -> Bool
    var onHorizontalChanged: (CGFloat) -> Void
    var onHorizontalEnded: (CGFloat, CGFloat) -> Void
    var onVerticalChanged: ((CGFloat) -> Void)? = nil
    var onVerticalEnded: ((CGFloat, CGFloat) -> Void)? = nil

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(
            allowLeftEdgeRightward: allowLeftEdgeRightward,
            canBegin: canBegin,
            allowVertical: allowVertical,
            verticalShouldBegin: verticalShouldBegin,
            onHorizontalChanged: onHorizontalChanged,
            onHorizontalEnded: onHorizontalEnded,
            onVerticalChanged: onVerticalChanged,
            onVerticalEnded: onVerticalEnded
        )
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.allowLeftEdgeRightward = allowLeftEdgeRightward
        context.coordinator.canBegin = canBegin
        context.coordinator.allowVertical = allowVertical
        context.coordinator.verticalShouldBegin = verticalShouldBegin
        context.coordinator.onHorizontalChanged = onHorizontalChanged
        context.coordinator.onHorizontalEnded = onHorizontalEnded
        context.coordinator.onVerticalChanged = onVerticalChanged
        context.coordinator.onVerticalEnded = onVerticalEnded
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let t = recognizer.translation(in: recognizer.view)
        let v = recognizer.velocity(in: recognizer.view)
        switch recognizer.state {
        case .began, .changed:
            switch context.coordinator.activeAxis {
            case .horizontal: onHorizontalChanged(t.x)
            case .vertical: onVerticalChanged?(t.y)
            case .none: break
            }
        case .ended, .cancelled, .failed:
            let axis = context.coordinator.activeAxis
            context.coordinator.activeAxis = .none
            switch axis {
            case .horizontal: onHorizontalEnded(t.x, v.x)
            case .vertical: onVerticalEnded?(t.y, v.y)
            case .none: break
            }
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        enum Axis { case none, horizontal, vertical }
        var activeAxis: Axis = .none
        var allowLeftEdgeRightward: Bool
        var canBegin: () -> Bool
        var allowVertical: () -> Bool
        var verticalShouldBegin: (CGFloat) -> Bool
        var onHorizontalChanged: (CGFloat) -> Void
        var onHorizontalEnded: (CGFloat, CGFloat) -> Void
        var onVerticalChanged: ((CGFloat) -> Void)?
        var onVerticalEnded: ((CGFloat, CGFloat) -> Void)?

        init(
            allowLeftEdgeRightward: Bool,
            canBegin: @escaping () -> Bool,
            allowVertical: @escaping () -> Bool,
            verticalShouldBegin: @escaping (CGFloat) -> Bool,
            onHorizontalChanged: @escaping (CGFloat) -> Void,
            onHorizontalEnded: @escaping (CGFloat, CGFloat) -> Void,
            onVerticalChanged: ((CGFloat) -> Void)?,
            onVerticalEnded: ((CGFloat, CGFloat) -> Void)?
        ) {
            self.allowLeftEdgeRightward = allowLeftEdgeRightward
            self.canBegin = canBegin
            self.allowVertical = allowVertical
            self.verticalShouldBegin = verticalShouldBegin
            self.onHorizontalChanged = onHorizontalChanged
            self.onHorizontalEnded = onHorizontalEnded
            self.onVerticalChanged = onVerticalChanged
            self.onVerticalEnded = onVerticalEnded
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard canBegin(), let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            if abs(v.x) > abs(v.y) * 1.25 {
                let startX = pan.location(in: nil).x - pan.translation(in: nil).x
                if !allowLeftEdgeRightward && startX <= DrawerMetrics.edgeWidth && v.x > 0 {
                    return false
                }
                activeAxis = .horizontal
                return true
            }
            if allowVertical(), abs(v.y) > abs(v.x) * 1.25, verticalShouldBegin(v.y) {
                activeAxis = .vertical
                return true
            }
            return false
        }
    }
}
