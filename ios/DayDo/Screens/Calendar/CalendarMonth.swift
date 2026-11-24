import Observation
import SwiftUI
import DayDoCore

struct WeekRowBar: Equatable {
    var taskId: String
    var title: String
    var colorHex: String?
    var isCompleted: Bool
    var timedPrefix: String
    var startTimeText: String?
    var startColumn: Int
    var endColumn: Int
    var lane: Int
    var continues: Bool
}

struct WeekRowModel: Equatable {
    var days: [LocalDay]
    var bars: [WeekRowBar]
    var overflow: [Int: Int]
    var rowHeight: CGFloat
}

enum CalendarMonthMetrics {
    static let macMonthLaneHeight: CGFloat = 18
    static let macMonthTopInset: CGFloat = 34
    static let macMonthOverflowReserve: CGFloat = 18

    static func macMonthMaxLanes(forCellHeight cellHeight: CGFloat) -> Int {
        let available = cellHeight - macMonthTopInset - macMonthOverflowReserve
        return max(0, Int(floor(available / macMonthLaneHeight)))
    }
}

/// Caches derived calendar data by lightweight scalar/version keys so body
/// re-evaluations never recompute MonthLayout, DayLayout, dot colors, or busy days.
@MainActor
final class CalendarDerivedCache {
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

    private var monthWeeksKey: (Int, String?, LocalDay, Int, Int)?
    private var cachedMonthWeeks: [WeekRowModel] = []

    private var busyKey: (Int, String?, Int)?
    private var cachedBusyDays: Set<LocalDay> = []

    private var timeGridKey: (Int, String?, UUID?, [LocalDay])?
    private var cachedTimeGrid: CalendarProjection.TimeGridData?

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
        let out = CalendarProjection.dayDotColors(tasks: items, gridDays: days, projectColors: map)
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
        tasks: [TodoTask],
        maxLanes: Int = 5
    ) -> [WeekRowModel] {
        let first = month.firstOfMonth
        let (cVer, map) = resolveColorMap(for: projects)
        let clampedLanes = max(0, maxLanes)
        if let key = monthWeeksKey,
           key.0 == tasksVersion,
           key.1 == projectFilter,
           key.2 == first,
           key.3 == cVer,
           key.4 == clampedLanes {
            return cachedMonthWeeks
        }
        let days = gridDays(for: first)
        let items = filteredTasks(tasksVersion: tasksVersion, projectFilter: projectFilter, tasks: tasks)
        let layout = MonthLayout(days: days, tasks: items, maxLanes: clampedLanes)
        let weeks = layout.weeks.map { week -> WeekRowModel in
            let bars = week.bars.map { bar in
                WeekRowBar(
                    taskId: bar.task.id,
                    title: bar.task.title,
                    colorHex: map[bar.task.projectId],
                    isCompleted: bar.task.isCompleted,
                    timedPrefix: bar.task.schedule?.startMinute.map { "[\(DateText.hm($0))] " } ?? "",
                    startTimeText: bar.task.schedule?.startMinute.map { DateText.hm($0) },
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
        monthWeeksKey = (tasksVersion, projectFilter, first, cVer, clampedLanes)
        cachedMonthWeeks = weeks
        return weeks
    }

    func busyDays(tasksVersion: Int, projectFilter: String?, year: Int, tasks: [TodoTask]) -> Set<LocalDay> {
        if let key = busyKey, key.0 == tasksVersion, key.1 == projectFilter, key.2 == year {
            return cachedBusyDays
        }
        let items = filteredTasks(tasksVersion: tasksVersion, projectFilter: projectFilter, tasks: tasks)
        let result = CalendarProjection.busyDays(tasks: items, year: year)
        busyKey = (tasksVersion, projectFilter, year)
        cachedBusyDays = result
        return result
    }

    func timeGridData(
        tasksVersion: Int,
        projectFilter: String?,
        pendingMove: PendingBlockMove?,
        days: [LocalDay],
        tasks: [TodoTask]
    ) -> CalendarProjection.TimeGridData {
        let token = pendingMove?.token
        if let key = timeGridKey, let cached = cachedTimeGrid,
           key.0 == tasksVersion, key.1 == projectFilter, key.2 == token, key.3 == days {
            return cached
        }
        let base = filteredTasks(tasksVersion: tasksVersion, projectFilter: projectFilter, tasks: tasks)
        let pending = pendingMove.map { CalendarProjection.ScheduleOverride(taskId: $0.taskId, schedule: $0.schedule) }
        let data = CalendarProjection.timeGridData(tasks: base, days: days, pendingMove: pending)
        timeGridKey = (tasksVersion, projectFilter, token, days)
        cachedTimeGrid = data
        return data
    }
}

/// One week of the event month: day numbers on top, bars in lanes.
struct WeekRow: View, Equatable {
    @Environment(\.accent) private var accent
    var week: WeekRowModel
    var month: LocalDay
    var today: LocalDay
    var reduceMotion: Bool
    var fillHeight: Bool = false
    var pick: (LocalDay) -> Void
    var open: (String) -> Void
    /// Looks up a bar's task for the Mac right-click menu (bars only carry the id).
    var task: (String) -> TodoTask? = { _ in nil }
    /// Mac: double-clicking a day cell adds a task on that day.
    var create: (LocalDay) -> Void = { _ in }

    private var laneH: CGFloat {
        fillHeight ? CalendarMonthMetrics.macMonthLaneHeight : 17
    }

    private var topInset: CGFloat {
        fillHeight ? CalendarMonthMetrics.macMonthTopInset : 36
    }

    /// Mac month cell: clicking the date number (or "+N") opens the day, double-clicking the
    /// cell adds a task on it; the cell itself is not a press-to-shrink touch button.
    @ViewBuilder
    private func macDayCell(_ d: LocalDay, column i: Int, isToday: Bool, inMonth: Bool, width colW: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { pick(d) } label: {
                if isToday {
                    if d.day == 1 {
                        Text("\(d.month)月1日")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent.onAccent)
                            .padding(.horizontal, 6)
                            .frame(height: 22)
                            .background(Capsule().fill(accent.color))
                    } else {
                        Text("\(d.day)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent.onAccent)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(accent.color))
                    }
                } else {
                    Text(d.day == 1 ? "\(d.month)月1日" : "\(d.day)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(inMonth ? Palette.textDay : Palette.textDisabled)
                        .frame(minWidth: 22, minHeight: 22, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .help("開啟單日檢視")
            .padding(.top, 5)
            .padding(.leading, 6)
            Spacer(minLength: 0)
            if let n = week.overflow[i] {
                Button { pick(d) } label: {
                    Text("+\(n)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .opacity(inMonth ? 1 : 0.6)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 2)
                .padding(.bottom, 2)
            }
        }
        .frame(width: colW, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { create(d) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "新增任務") { create(d) }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.week == rhs.week
            && lhs.month == rhs.month
            && lhs.today == rhs.today
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.fillHeight == rhs.fillHeight
    }

    var body: some View {
        GeometryReader { geo in
            let colW = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(week.days.enumerated()), id: \.offset) { i, d in
                        let isToday = d == today
                        let inMonth = d.month == month.month
                        let overflowValue = week.overflow[i].map { n in
                            let hasBar = week.bars.contains { $0.startColumn <= i && i <= $0.endColumn }
                            return hasBar ? "還有 \(n) 項任務，點按切換至單日檢視" : "\(n) 項任務，點按切換至單日檢視"
                        } ?? ""
                        Group {
                            if fillHeight {
                                macDayCell(d, column: i, isToday: isToday, inMonth: inMonth, width: colW, height: geo.size.height)
                            } else {
                                Button { pick(d) } label: {
                                VStack(spacing: 0) {
                                    Text("\(d.day)")
                                        .font(.system(size: 14, weight: isToday ? .bold : .semibold))
                                        .foregroundStyle(isToday ? accent.onAccent : Palette.textDay)
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(isToday ? accent.color : .clear))
                                        .padding(.top, 4)
                                    Spacer(minLength: 0)
                                    if let n = week.overflow[i] {
                                        Text("+\(n)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                                            .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4).padding(.bottom, 2)
                                    }
                                }
                                .frame(width: colW, height: geo.size.height)
                                .contentShape(Rectangle())
                            
                                }
                                .buttonStyle(.press(scale: 0.94, opacity: 0.88))
                            }
                        }
                        .opacity(fillHeight ? 1 : (inMonth ? 1 : 0.4))
                        .overlay(alignment: .leading) {
                            if fillHeight && i > 0 {
                                Rectangle().fill(Palette.separator).frame(width: 1)
                            }
                        }
                        .accessibilityLabel(DateText.full(d))
                        .accessibilityValue(overflowValue)
                    }
                }
                ForEach(Array(week.bars.enumerated()), id: \.offset) { _, bar in
                    let color = Palette.listColor(bar.colorHex)
                    let done = bar.isCompleted
                    let barWidth = max(0, colW * CGFloat(bar.endColumn - bar.startColumn + 1) - 3)
                    let showTrailingTime = fillHeight
                        && !bar.continues
                        && bar.startTimeText != nil
                        && barWidth >= (bar.startColumn == bar.endColumn ? 104 : 96)
                    let showLeadingTimePrefix = bar.startColumn == bar.endColumn && !showTrailingTime
                    Button(action: { open(bar.taskId) }) {
                        HStack(spacing: 0) {
                            Rectangle().fill(color).frame(width: 2)
                            Text((bar.continues ? "‹ " : "") + (showLeadingTimePrefix ? bar.timedPrefix : "") + bar.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(done ? Palette.done : Palette.text.opacity(0.92))
                                .strikethrough(done)
                                .lineLimit(1)
                                .padding(.leading, 3)
                                .padding(.trailing, showTrailingTime ? 4 : 3)
                            Spacer(minLength: 0)
                            if showTrailingTime, let timeText = bar.startTimeText {
                                Text(timeText)
                                    .font(.system(size: 10, weight: .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.trailing, 4)
                            }
                        }
                        .frame(width: barWidth, height: laneH - 2, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(done ? 0.1 : 0.28)))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.press(scale: 0.96, opacity: 0.88))
                    .macTaskContextMenu(task(bar.taskId))
                    .offset(x: colW * CGFloat(bar.startColumn) + 1.5, y: topInset + CGFloat(bar.lane) * laneH)
                }
            }
            .clipped()
        }
        .frame(height: fillHeight ? nil : week.rowHeight)
        .frame(maxHeight: fillHeight ? .infinity : nil)
        .clipped()
        .overlay(alignment: .top) {
            if fillHeight {
                Rectangle().fill(Palette.separator).frame(height: 1)
            }
        }
    }
}
