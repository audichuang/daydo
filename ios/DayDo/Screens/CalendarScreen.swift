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

    @AppStorage("calendarViewMode") private var modeRaw = CalMode.list.rawValue
    @AppStorage("calendarCollapsed") private var collapsed = false
    @AppStorage("agendaTimeline") private var timelineStyle = false
    @AppStorage("calendarShowCompleted") private var showCompleted = true
    @State private var selected: LocalDay?
    @State private var month: LocalDay?
    @State private var memberFilter: String?
    @State private var projectFilter: String?
    @State private var tasks: [TodoTask] = []
    @State private var hDragOffset: CGFloat = 0
    @State private var collapseDragY: CGFloat = 0
    @State private var shiftDir = 0
    @State private var pageSequence = 0
    @State private var dateSelectionHaptic = 0
    @State private var pageShiftHaptic = 0

    var mode: CalMode { CalMode(rawValue: modeRaw) ?? .list }
    var sel: LocalDay { selected ?? model.today }
    var shownMonth: LocalDay { month ?? sel.firstOfMonth }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isRegular {
                Palette.background.ignoresSafeArea()
            }
            VStack(spacing: 0) {
                if !isRegular {
                    header
                }
                if model.members.count > 1 || projectFilter != nil {
                    filters.padding(.horizontal, 16).padding(.top, isRegular ? 8 : 0).padding(.bottom, 6)
                }
                content
            }
            if !model.isViewer(projectId: projectFilter) {
                Button { compose(day: sel, minute: nil) } label: {
                    Image(systemName: "plus").font(.system(size: 24, weight: .semibold)).foregroundStyle(accent.onAccent)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(accent.color))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                }
                .buttonStyle(.press(scale: 0.94, opacity: 0.9))
                .hoverEffect(.lift)
                .padding(.trailing, isRegular ? 24 : 18)
                .padding(.bottom, isRegular ? 24 : 92)
                .accessibilityLabel("新增任務")
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
        .task(id: CalReload(range: range, member: memberFilter, completed: showCompleted, revision: model.revision)) { await load() }
        .onAppear { applyPendingCalendarDay() }
        .onChange(of: model.calendarNavigationTrigger) { _, _ in applyPendingCalendarDay() }
        .onChange(of: showCompleted) { _, newValue in
            model.syncCalendarShowCompletedToWidget(newValue)
        }
    }

    private func applyPendingCalendarDay() {
        guard let day = model.calendarNavigationDay else { return }
        model.calendarNavigationDay = nil
        memberFilter = nil
        projectFilter = nil
        selected = day
        month = day.firstOfMonth
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
        Menu {
            ForEach(CalMode.allCases) { m in
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) { modeRaw = m.rawValue }
                } label: {
                    if m == mode { Label(m.label, systemImage: "checkmark") } else { Label(m.label, systemImage: m.icon) }
                }
            }
        } label: {
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
        .hoverEffect(.highlight)
        .accessibilityLabel("切換檢視：目前\(mode.label)")
        .accessibilityIdentifier("calendarMode")
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
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) { timelineStyle.toggle() }
            }
        }
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
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
                        collapsed.toggle()
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.text).frame(width: 44, height: 40)
        }
        .hoverEffect(.highlight)
        .accessibilityLabel("更多選項")
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
            if model.members.count > 1 {
                chip("全部", on: memberFilter == nil) { memberFilter = nil }
                ForEach(model.members) { m in chip(m.isMe ? "我參與" : m.name, on: memberFilter == m.id) { memberFilter = m.id } }
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

    func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).txt(13, .semibold)
                .foregroundStyle(on ? Palette.background : Palette.textNav)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(on ? Palette.text : .clear))
                .overlay(Capsule().strokeBorder(on ? Palette.text : Palette.separator))
        }
        .buttonStyle(.press)
        .accessibilityAddTraits(on ? .isSelected : [])
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
            let g = MonthLayout.gridDays(for: shownMonth)
            return g.first!...g.last!
        }
    }

    func load() async {
        let q = TaskQuery(from: range.lowerBound, to: range.upperBound, includeCompleted: showCompleted, memberId: memberFilter)
        do {
            let loaded = try await model.api.listTasks(q)
            guard !Task.isCancelled else { return }
            tasks = loaded
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { model.errorMessage = error.localizedDescription }
        }
    }

    var filtered: [TodoTask] {
        guard let projectFilter else { return tasks }
        return tasks.filter { $0.projectId == projectFilter }
    }

    func goToday() {
        dateSelectionHaptic += 1
        shiftDir = 0
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) {
            selected = model.today
            month = model.today.firstOfMonth
            pageSequence += 1
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
        shiftDir = dir
        pageShiftHaptic += 1
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.86)) {
            applyShift(dir)
            pageSequence += 1
        }
    }

    func compose(day: LocalDay, minute: Int?) {
        guard !model.isViewer(projectId: projectFilter) else { return }
        model.composing = ComposeRequest(projectId: projectFilter, day: day, minute: minute)
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
            shiftDir = dir
            pageShiftHaptic += 1
            let anim: Animation = reduceMotion
                ? .easeOut(duration: 0.18)
                : .spring(response: 0.34, dampingFraction: 0.86)
            withAnimation(anim) {
                applyShift(dir)
                pageSequence += 1
                hDragOffset = 0
            }
        } else {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.78)) {
                hDragOffset = 0
            }
        }
    }

    private var horizontalOnlySwipe: CalendarPanGesture {
        CalendarPanGesture(
            allowLeftEdgeRightward: isRegular,
            allowVertical: { false },
            verticalShouldBegin: { _ in false },
            onHorizontalChanged: { tx in
                if !reduceMotion {
                    hDragOffset = tx * 0.9
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
                    }
                    .scrollIndicators(.hidden)
                }
            case .year:
                ScrollView {
                    ZStack {
                        YearGrid(year: shownMonth.year, today: model.today, busy: busyDays, isRegular: isRegular, openMonth: { m in
                            dateSelectionHaptic += 1
                            shiftDir = 0
                            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) {
                                month = m
                                selected = m
                                modeRaw = CalMode.list.rawValue
                                collapsed = false
                                pageSequence += 1
                            }
                        }, openDay: { d in
                            dateSelectionHaptic += 1
                            shiftDir = 0
                            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) {
                                selected = d
                                month = d.firstOfMonth
                                modeRaw = CalMode.day.rawValue
                                pageSequence += 1
                            }
                        })
                        .id("year-\(pageSequence)")
                        .transition(pageTransition)
                    }
                    .offset(x: reduceMotion ? 0 : hDragOffset)
                    .clipped()
                    .padding(.horizontal, isRegular ? 24 : 16)
                    .padding(.bottom, isRegular ? 32 : 170)
                }
                .gesture(horizontalOnlySwipe)
            case .month:
                ScrollView {
                    ZStack {
                        eventMonth
                            .id("month-\(pageSequence)")
                            .transition(pageTransition)
                    }
                    .offset(x: reduceMotion ? 0 : hDragOffset)
                    .clipped()
                    .padding(.horizontal, isRegular ? 16 : 8)
                    .padding(.bottom, isRegular ? 32 : 170)
                }
                .gesture(horizontalOnlySwipe)
            case .week, .threeDay, .day:
                ZStack {
                    TimeGrid(days: rangeDays, tasks: filtered, today: model.today, selected: sel, isRegular: isRegular,
                             openTask: { model.openTask($0, inlineAvailable: false) },
                             tapSlot: { d, m in compose(day: d, minute: m) },
                             tapDay: { d in
                                dateSelectionHaptic += 1
                                shiftDir = 0
                                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) {
                                    selected = d
                                    modeRaw = CalMode.day.rawValue
                                    pageSequence += 1
                                }
                             })
                        .id("\(mode.rawValue)-\(pageSequence)")
                        .transition(pageTransition)
                }
                .offset(x: reduceMotion ? 0 : hDragOffset)
                .clipped()
                .gesture(horizontalOnlySwipe)
            }
        }
        .onChange(of: modeRaw) { _, _ in
            hDragOffset = 0
            collapseDragY = 0
            shiftDir = 0
            pageSequence += 1
        }
    }

    var busyDays: Set<LocalDay> {
        var s = Set<LocalDay>()
        for t in filtered {
            guard let sch = t.schedule else { continue }
            var d = max(sch.startDay, range.lowerBound)
            let end = min(sch.lastDay, range.upperBound)
            while d <= end { s.insert(d); d = d.adding(days: 1) }
        }
        return s
    }

    // MARK: 清單 — date grid

    var dateGrid: some View {
        let days = MonthLayout.gridDays(for: shownMonth)
        let rowCount = max(1, days.count / 7)
        let rowH: CGFloat = 50
        let rowSpacing: CGFloat = 2
        let fullGridHeight = CGFloat(rowCount) * rowH + CGFloat(rowCount - 1) * rowSpacing
        let collapsedGridHeight = rowH
        let travel = max(1, fullGridHeight - collapsedGridHeight)
        let restProgress: CGFloat = collapsed ? 0 : 1
        let progress: CGFloat = reduceMotion ? restProgress : min(1, max(0, restProgress + collapseDragY / travel))
        let visibleGridHeight = collapsedGridHeight + (fullGridHeight - collapsedGridHeight) * progress
        let selectedRow = days.firstIndex(of: sel).map { $0 / 7 } ?? 0
        let gridOffsetY = -CGFloat(selectedRow) * (rowH + rowSpacing) * (1 - progress)

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) { Text($0).txt(12).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity) }
            }
            .padding(.bottom, 6)
            ZStack(alignment: .top) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: rowSpacing) {
                    ForEach(Array(days.enumerated()), id: \.element) { idx, d in
                        dayCell(d, progress: progress)
                            .accessibilityHidden(progress == 0 && idx / 7 != selectedRow)
                    }
                }
                .offset(y: gridOffsetY)
                .id("list-\(pageSequence)")
                .transition(pageTransition)
            }
            .offset(x: reduceMotion ? 0 : hDragOffset)
            .frame(height: visibleGridHeight, alignment: .top)
            .clipped()

            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
                    collapsed.toggle()
                    collapseDragY = 0
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
                        hDragOffset = tx * 0.9
                    }
                },
                onHorizontalEnded: { tx, vx in
                    finishHorizontalSwipe(tx: tx, vx: vx)
                },
                onVerticalChanged: { ty in
                    if !reduceMotion {
                        collapseDragY = ty
                    }
                },
                onVerticalEnded: { ty, vy in
                    let anim: Animation = reduceMotion
                        ? .easeOut(duration: 0.15)
                        : .spring(response: 0.34, dampingFraction: 0.86)
                    withAnimation(anim) {
                        if !collapsed && (ty < -45 || vy < -350) {
                            collapsed = true
                        } else if collapsed && (ty > 45 || vy > 350) {
                            collapsed = false
                        }
                        collapseDragY = 0
                    }
                }
            )
        )
    }

    func dayCell(_ d: LocalDay, progress: CGFloat) -> some View {
        let isSel = d == sel, isToday = d == model.today, inMonth = d.month == shownMonth.month
        let cellOpacity = inMonth ? 1.0 : (1.0 - 0.62 * Double(progress))
        var colors: [String] = []
        for t in filtered where t.schedule?.occurs(on: d) == true && !t.isCompleted {
            let c = model.project(t.projectId)?.color ?? "#5B6461"
            if !colors.contains(c) { colors.append(c) }
        }
        return Button {
            dateSelectionHaptic += 1
            let monthChanged = d.month != shownMonth.month
            if monthChanged {
                shiftDir = d > shownMonth ? 1 : -1
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) {
                selected = d
                if monthChanged {
                    month = d.firstOfMonth
                    pageSequence += 1
                }
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(d.day)")
                    .txt(17, isSel || isToday ? .bold : .medium)
                    .foregroundStyle(isSel ? accent.onAccent : (isToday ? accent.color : Color(hex: "#E6E9E8")))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(isSel ? accent.color : (isToday ? Color.white : .clear)))
                HStack(spacing: 3) {
                    ForEach(colors.prefix(3), id: \.self) { c in Circle().fill(Color(hex: c)).frame(width: 4, height: 4) }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press(scale: 0.92, opacity: 0.85))
        .hoverEffect(.highlight)
        .opacity(cellOpacity)
        .accessibilityLabel(DateText.full(d) + (colors.isEmpty ? "" : "，有項目"))
        .accessibilityAddTraits(isSel ? .isSelected : [])
    }

    var dayItems: [TodoTask] {
        let items = filtered.filter { $0.schedule?.occurs(on: sel) == true }
        return TaskGrouping.sortForDay(items.filter { !$0.isCompleted }) + items.filter(\.isCompleted)
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

    var cardAgenda: some View {
        let items = dayItems
        return VStack(alignment: .leading, spacing: 0) {
            Text(dayTitle).txt(19, .bold).foregroundStyle(Palette.text).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
            if items.isEmpty { emptyDay }
            ForEach(items) { t in AgendaRow(task: t, day: sel) }
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
            if items.isEmpty { emptyDay.card(16) }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                TimelineAgendaRow(task: t, day: sel, last: i == items.count - 1)
            }
        }
    }

    // MARK: 月 — event bars

    var eventMonth: some View {
        let layout = MonthLayout(month: shownMonth, tasks: filtered, maxLanes: 5)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(LocalDay.weekdaySymbols, id: \.self) { Text($0).txt(12).foregroundStyle(Palette.textTertiary).frame(maxWidth: .infinity) }
            }
            .padding(.bottom, 4)
            ForEach(Array(layout.weeks.enumerated()), id: \.offset) { _, w in
                WeekRow(week: w, month: shownMonth, selected: sel, today: model.today) { d in
                    dateSelectionHaptic += 1
                    shiftDir = 0
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy) {
                        selected = d
                        modeRaw = CalMode.day.rawValue
                        pageSequence += 1
                    }
                } open: { id in model.openTask(id, inlineAvailable: false) }
            }
        }
    }
}

struct CalReload: Hashable { var range: ClosedRange<LocalDay>; var member: String?; var completed: Bool; var revision: Int }

/// Card-style agenda row with a checkbox (清單 view).
struct AgendaRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var task: TodoTask
    var day: LocalDay

    private var isDone: Bool {
        task.isCompleted || model.completingIds.contains(task.id)
    }

    var body: some View {
        let project = model.project(task.projectId)
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
                    Text(task.title).txt(17, .medium).foregroundStyle(isDone ? Palette.done : Palette.text)
                        .strikethrough(isDone, color: Palette.done).lineLimit(2).multilineTextAlignment(.leading)
                    if !task.content.isEmpty {
                        Text(task.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").txt(14).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(AgendaText.line(task, today: model.today)).txt(14, .medium).foregroundStyle(AgendaText.color(task, today: model.today, accent: accent))
                        Spacer(minLength: 4)
                        if let project, project.isShared { AvatarStack(members: model.members.filter { project.memberIds.contains($0.id) }) }
                        Text(project?.name ?? "").txt(14).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    }
                }
                .opacity(isDone ? 0.75 : 1)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.75), value: isDone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press(scale: 0.985, opacity: 0.95, highlight: Color.white.opacity(0.05)))
            .hoverEffect(.highlight)
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                if let s = task.schedule {
                    Text(String(format: "%02d-%02d", s.startDay.month, s.startDay.day)).font(.system(size: 13)).foregroundStyle(Palette.textFaint)
                    if let m = s.startMinute { Text(DateText.hm(m)).font(.system(size: 15)).foregroundStyle(Palette.textSecondary) }
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
                    Text(AgendaText.line(task, today: model.today, includeDay: task.schedule?.isMultiDay ?? false))
                        .txt(15, .medium).foregroundStyle(AgendaText.color(task, today: model.today, accent: accent))
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
    @Environment(\.accent) private var accent
    var year: Int
    var today: LocalDay
    var busy: Set<LocalDay>
    var isRegular: Bool = false
    var openMonth: (LocalDay) -> Void
    var openDay: (LocalDay) -> Void

    var body: some View {
        let cols = isRegular ? 4 : 3
        let dayFontSize: CGFloat = isRegular ? 11 : 8.5
        let circleSize: CGFloat = isRegular ? 18 : 13
        let rowHeight: CGFloat = isRegular ? 20 : 14
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isRegular ? 20 : 14), count: cols), spacing: isRegular ? 22 : 18) {
            ForEach(1...12, id: \.self) { m in
                let first = LocalDay(year: year, month: m, day: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Button { openMonth(first) } label: {
                        Text("\(m)月").txt(isRegular ? 16 : 15, .bold).foregroundStyle(first.month == today.month && year == today.year ? accent.text : Palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.press)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("\(year) 年 \(m) 月")

                    let days = MonthLayout.gridDays(for: first)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                        ForEach(days, id: \.self) { d in
                            if d.month == m {
                                let isToday = d == today
                                Button { openDay(d) } label: {
                                    Text("\(d.day)")
                                        .font(.system(size: dayFontSize, weight: isToday ? .bold : .regular))
                                        .foregroundStyle(isToday ? accent.onAccent : (busy.contains(d) ? accent.text : Palette.textSecondary))
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
                                Color.clear.frame(height: rowHeight)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

/// One week of the event month: day numbers on top, bars in lanes.
struct WeekRow: View {
    @Environment(\.accent) private var accent
    @Environment(AppModel.self) private var model
    var week: MonthLayout.Week
    var month: LocalDay
    var selected: LocalDay
    var today: LocalDay
    var pick: (LocalDay) -> Void
    var open: (String) -> Void

    let laneH: CGFloat = 17

    private var rowHeight: CGFloat {
        let usedLanes = (week.bars.map(\.lane).max() ?? -1) + 1
        let visibleLanes = max(1, usedLanes)
        let bottomPad: CGFloat = week.overflow.isEmpty ? 8 : 18
        return 36 + laneH * CGFloat(visibleLanes) + bottomPad
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
                                    .foregroundStyle(isToday ? accent.onAccent : Color(hex: "#E6E9E8"))
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
                    let color = Color(hex: model.project(bar.task.projectId)?.color ?? "#5B6461")
                    let done = bar.task.isCompleted
                    let timed = bar.task.schedule?.startMinute.map { "[\(DateText.hm($0))] " } ?? ""
                    Button { open(bar.task.id) } label: {
                        HStack(spacing: 0) {
                            Rectangle().fill(color).frame(width: 2)
                            Text((bar.continues ? "‹ " : "") + (bar.startColumn == bar.endColumn ? timed : "") + bar.task.title)
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
        .frame(height: rowHeight)
    }
}

/// 週／3日／日 time grid with an all-day strip, overlapping blocks side by
/// side, a now line on today, and tap-to-create on empty slots.
struct TimeGrid: View {
    @Environment(\.accent) private var accent
    @Environment(AppModel.self) private var model
    var days: [LocalDay]
    var tasks: [TodoTask]
    var today: LocalDay
    var selected: LocalDay
    var isRegular: Bool = false
    var openTask: (String) -> Void
    var tapSlot: (LocalDay, Int) -> Void
    var tapDay: (LocalDay) -> Void

    var hourH: CGFloat { isRegular ? 64 : 56 }
    var gutter: CGFloat { isRegular ? 52 : 40 }

    var allDayItems: [(TodoTask, Int, Int, Int)] {
        // (task, firstColumn, lastColumn, lane)
        guard let first = days.first, let last = days.last else { return [] }
        var lanes: [[ClosedRange<Int>]] = []
        var out: [(TodoTask, Int, Int, Int)] = []
        for t in tasks {
            guard let s = t.schedule, s.isAllDay, s.overlaps(first, last) else { continue }
            let a = max(0, first.days(until: s.startDay)), b = min(days.count - 1, first.days(until: s.lastDay))
            var lane = 0
            while lane < lanes.count, lanes[lane].contains(where: { $0.overlaps(a...b) }) { lane += 1 }
            if lane == lanes.count { lanes.append([]) }
            lanes[lane].append(a...b)
            out.append((t, a, b, lane))
        }
        return out
    }

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
                let totalLanes = (ad.map(\.3).max() ?? -1) + 1
                let maxVisibleLanes = isDay ? 4 : 3
                let laneCount = min(maxVisibleLanes, totalLanes)
                let overflowByCol: [Int: Int] = {
                    guard !isDay else { return [:] }
                    var counts: [Int: Int] = [:]
                    for (_, a, b, lane) in ad where lane >= maxVisibleLanes {
                        for col in a...b { counts[col, default: 0] += 1 }
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
                                        let (t, a, b, lane) = item
                                        allDayChip(t, width: colW * CGFloat(b - a + 1) - 3)
                                            .offset(x: colW * CGFloat(a) + 1.5, y: CGFloat(lane) * 21 + 2)
                                    }
                                }
                                .frame(width: colW, height: CGFloat(totalLanes) * 21 + 4, alignment: .topLeading)
                            }
                            .frame(height: visibleHeight)
                        }
                        .frame(height: visibleHeight, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
                    } else {
                        ZStack(alignment: .topLeading) {
                            Text("全天").font(.system(size: 10)).foregroundStyle(Palette.textFaint).frame(width: gutter).padding(.top, 4)
                            ForEach(Array(ad.filter { $0.3 < maxVisibleLanes }.enumerated()), id: \.offset) { _, item in
                                let (t, a, b, lane) = item
                                allDayChip(t, width: colW * CGFloat(b - a + 1) - 3)
                                    .offset(x: gutter + colW * CGFloat(a) + 1.5, y: CGFloat(lane) * 21 + 2)
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
                                        Rectangle().fill(Color(hex: "#222426")).frame(height: 1)
                                    }
                                    .frame(height: h == 24 ? 1 : hourH, alignment: .top)
                                    .id(h)
                                }
                            }
                            // Column separators + tap-to-create
                            HStack(spacing: 0) {
                                Spacer().frame(width: gutter)
                                ForEach(days, id: \.self) { d in
                                    Rectangle().fill(Color.white.opacity(0.001))
                                        .frame(width: colW, height: hourH * 24)
                                        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: "#1E2022")).frame(width: 1) }
                                        .onTapGesture(coordinateSpace: .local) { p in
                                            let m = Int(p.y / hourH * 60) / 30 * 30
                                            tapSlot(d, min(m, 23 * 60 + 30))
                                        }
                                        .accessibilityLabel("\(DateText.full(d)) 空白時段，點兩下新增")
                                }
                            }
                            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                                ForEach(DayLayout.blocks(for: tasks, on: d), id: \.self) { b in
                                    block(b, colW: colW).offset(x: gutter + colW * CGFloat(i) + colW / CGFloat(b.lanes) * CGFloat(b.lane) + 1, y: CGFloat(b.start) / 60 * hourH)
                                }
                                if d == today { nowLine(colW: colW).offset(x: gutter + colW * CGFloat(i), y: nowY - 4) }
                            }
                        }
                        .frame(height: hourH * 24 + 10, alignment: .topLeading)
                        .padding(.top, 8)
                        .padding(.bottom, isRegular ? 24 : 160)
                    }
                    .defaultScrollAnchor(UnitPoint(x: 0, y: min(1, CGFloat(initialHour) * hourH / 900)), for: .initialOffset)
                    .scrollIndicators(.hidden)
                    .task(id: days) {
                        // Wait for menu dismiss / transition & initial layout, then snap accurately.
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(initialHour, anchor: .top)
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    var initialHour: Int {
        max(0, (days.contains(today) ? nowMinute / 60 : 8) - 2)
    }

    var nowMinute: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return c.hour! * 60 + c.minute!
    }
    var nowY: CGFloat { CGFloat(nowMinute) / 60 * hourH }

    func allDayChip(_ t: TodoTask, width: CGFloat) -> some View {
        let color = Color(hex: model.project(t.projectId)?.color ?? "#5B6461")
        return Button { openTask(t.id) } label: {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 2)
                Text(t.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(t.isCompleted ? Palette.done : Palette.text)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                Spacer(minLength: 0)
            }
            .frame(width: width, height: 19)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.28)))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.press(scale: 0.96, opacity: 0.88))
        .hoverEffect(.highlight)
    }

    func nowLine(colW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle().fill(Palette.overdue).frame(width: 8, height: 8)
            Rectangle().fill(Palette.overdue).frame(width: colW - 8, height: 1.5)
        }
        .allowsHitTesting(false)
    }

    func block(_ b: DayLayout.Block, colW: CGFloat) -> some View {
        let color = Color(hex: model.project(b.task.projectId)?.color ?? "#5B6461")
        let w = colW / CGFloat(b.lanes) - 2
        let h = max(CGFloat(b.end - b.start) / 60 * hourH - 2, 18)
        let done = b.task.isCompleted
        return Button { openTask(b.task.id) } label: {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.task.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(done ? Palette.done : Palette.text)
                        .strikethrough(done).lineLimit(h > 40 ? 3 : 1).multilineTextAlignment(.leading)
                    if h > 34, let s = b.task.schedule { Text(DateText.range(s)).font(.system(size: 10)).foregroundStyle(Palette.textSecondary).lineLimit(1) }
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
                Spacer(minLength: 0)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(done ? 0.12 : 0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.press(scale: 0.96, opacity: 0.88))
        .hoverEffect(.highlight)
        .accessibilityLabel(b.task.title + "，" + (b.task.schedule.map(DateText.range) ?? ""))
    }
}

/// UIKit pan recognizer for calendar horizontal paging and vertical grid
/// collapse/expand, keeping ScrollView vertical scrolling and taps responsive.
private struct CalendarPanGesture: UIGestureRecognizerRepresentable {
    var allowLeftEdgeRightward: Bool
    var allowVertical: () -> Bool
    var verticalShouldBegin: (CGFloat) -> Bool
    var onHorizontalChanged: (CGFloat) -> Void
    var onHorizontalEnded: (CGFloat, CGFloat) -> Void
    var onVerticalChanged: ((CGFloat) -> Void)? = nil
    var onVerticalEnded: ((CGFloat, CGFloat) -> Void)? = nil

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(
            allowLeftEdgeRightward: allowLeftEdgeRightward,
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
        var allowVertical: () -> Bool
        var verticalShouldBegin: (CGFloat) -> Bool
        var onHorizontalChanged: (CGFloat) -> Void
        var onHorizontalEnded: (CGFloat, CGFloat) -> Void
        var onVerticalChanged: ((CGFloat) -> Void)?
        var onVerticalEnded: ((CGFloat, CGFloat) -> Void)?

        init(
            allowLeftEdgeRightward: Bool,
            allowVertical: @escaping () -> Bool,
            verticalShouldBegin: @escaping (CGFloat) -> Bool,
            onHorizontalChanged: @escaping (CGFloat) -> Void,
            onHorizontalEnded: @escaping (CGFloat, CGFloat) -> Void,
            onVerticalChanged: ((CGFloat) -> Void)?,
            onVerticalEnded: ((CGFloat, CGFloat) -> Void)?
        ) {
            self.allowLeftEdgeRightward = allowLeftEdgeRightward
            self.allowVertical = allowVertical
            self.verticalShouldBegin = verticalShouldBegin
            self.onHorizontalChanged = onHorizontalChanged
            self.onHorizontalEnded = onHorizontalEnded
            self.onVerticalChanged = onVerticalChanged
            self.onVerticalEnded = onVerticalEnded
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            if abs(v.x) > abs(v.y) * 1.25 {
                let startX = pan.location(in: nil).x - pan.translation(in: nil).x
                if !allowLeftEdgeRightward && startX <= 24 && v.x > 0 {
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
