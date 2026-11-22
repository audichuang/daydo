import Foundation

/// Calendar view mode stored under the `calendarViewMode` AppStorage key.
public enum CalMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case list, year, month, week, threeDay, day

    public var id: String { rawValue }

    public var dayCount: Int {
        switch self {
        case .week: 7
        case .threeDay: 3
        default: 1
        }
    }
}

/// Pure calendar projection rules shared across calendar views:
/// viewport geometry/navigation, per-day dot colours, yearly busy days,
/// and time-grid layout data.
public enum CalendarProjection {
    public static let fallbackDotColor = "#5B6461"

    /// Calendar viewport state (mode, selected day, shown month, collapsed list grid).
    public struct Viewport: Equatable, Sendable {
        public var mode: CalMode
        public var selected: LocalDay
        public var shownMonth: LocalDay
        public var collapsed: Bool

        public init(mode: CalMode, selected: LocalDay, shownMonth: LocalDay, collapsed: Bool = false) {
            self.mode = mode
            self.selected = selected
            self.shownMonth = shownMonth
            self.collapsed = collapsed
        }

        /// Visible day columns for time-grid modes (`week`, `threeDay`, `day`);
        /// empty for `list`, `month`, and `year`.
        public var visibleDays: [LocalDay] {
            switch mode {
            case .week:
                let start = selected.startOfWeek
                return (0..<7).map { start.adding(days: $0) }
            case .threeDay:
                return (0..<3).map { selected.adding(days: $0) }
            case .day:
                return [selected]
            case .list, .month, .year:
                return []
            }
        }

        /// Inclusive task query range covering this viewport.
        public func queryRange(monthGridDays: [LocalDay]? = nil) -> ClosedRange<LocalDay> {
            switch mode {
            case .year:
                return LocalDay(year: shownMonth.year, month: 1, day: 1)...LocalDay(year: shownMonth.year, month: 12, day: 31)
            case .week:
                let start = selected.startOfWeek
                return start...start.adding(days: 6)
            case .threeDay:
                return selected...selected.adding(days: 2)
            case .day:
                return selected...selected
            case .list, .month:
                let grid = (monthGridDays?.isEmpty == false) ? monthGridDays! : MonthLayout.gridDays(for: shownMonth)
                return grid.first!...grid.last!
            }
        }

        /// Returns the viewport shifted by `direction` pages (+1 next, -1 previous).
        public func shifted(by direction: Int) -> Viewport {
            var next = self
            switch mode {
            case .list where collapsed:
                let target = selected.adding(days: 7 * direction)
                next.selected = target
                next.shownMonth = target.firstOfMonth
            case .list, .month:
                let target = shownMonth.adding(months: direction)
                next.shownMonth = target
                next.selected = target
            case .year:
                next.shownMonth = shownMonth.adding(months: 12 * direction)
            case .week, .threeDay, .day:
                let target = selected.adding(days: mode.dayCount * direction)
                next.selected = target
                next.shownMonth = target.firstOfMonth
            }
            return next
        }
    }

    /// Optimistic schedule override applied to a single task before a drag-move reload settles.
    public struct ScheduleOverride: Hashable, Sendable {
        public var taskId: String
        public var schedule: Schedule

        public init(taskId: String, schedule: Schedule) {
            self.taskId = taskId
            self.schedule = schedule
        }
    }

    public struct TimeGridAllDayItem: Hashable, Sendable {
        public var task: TodoTask
        public var firstColumn: Int
        public var lastColumn: Int
        public var lane: Int

        public init(task: TodoTask, firstColumn: Int, lastColumn: Int, lane: Int) {
            self.task = task
            self.firstColumn = firstColumn
            self.lastColumn = lastColumn
            self.lane = lane
        }
    }

    public struct TimeGridData: Hashable, Sendable {
        public var displayedTasks: [TodoTask]
        public var allDayItems: [TimeGridAllDayItem]
        public var blocksByDay: [[DayLayout.Block]]

        public init(displayedTasks: [TodoTask], allDayItems: [TimeGridAllDayItem], blocksByDay: [[DayLayout.Block]]) {
            self.displayedTasks = displayedTasks
            self.allDayItems = allDayItems
            self.blocksByDay = blocksByDay
        }
    }

    /// Per-day dot colours for the list-mode date grid: active tasks only,
    /// at most `maxPerDay` distinct colours per day in input task order,
    /// falling back to `fallbackColor`, clipped to `gridDays.first...gridDays.last`.
    public static func dayDotColors(
        tasks: [TodoTask],
        gridDays: [LocalDay],
        projectColors: [String: String],
        fallbackColor: String = fallbackDotColor,
        maxPerDay: Int = 3
    ) -> [LocalDay: [String]] {
        guard let gridFirst = gridDays.first, let gridLast = gridDays.last, maxPerDay > 0 else {
            return [:]
        }
        var out: [LocalDay: [String]] = [:]
        for t in tasks where !t.isCompleted {
            guard let s = t.schedule, s.overlaps(gridFirst, gridLast) else { continue }
            let color = projectColors[t.projectId] ?? fallbackColor
            var d = max(s.startDay, gridFirst)
            let end = min(s.lastDay, gridLast)
            while d <= end {
                var colors = out[d] ?? []
                if colors.count < maxPerDay && !colors.contains(color) {
                    colors.append(color)
                    out[d] = colors
                }
                d = d.adding(days: 1)
            }
        }
        return out
    }

    /// Days in `year` that have at least one task (completed included),
    /// with multi-day spans clipped to `year`.
    public static func busyDays(tasks: [TodoTask], year: Int) -> Set<LocalDay> {
        let lower = LocalDay(year: year, month: 1, day: 1)
        let upper = LocalDay(year: year, month: 12, day: 31)
        var result = Set<LocalDay>()
        for t in tasks {
            guard let sch = t.schedule, sch.overlaps(lower, upper) else { continue }
            var d = max(sch.startDay, lower)
            let end = min(sch.lastDay, upper)
            while d <= end {
                result.insert(d)
                d = d.adding(days: 1)
            }
        }
        return result
    }

    /// Time-grid projection: applies an optional pending-move schedule override,
    /// packs all-day items in input order with no lane cap, and lays out timed
    /// blocks per day via `DayLayout.blocks`.
    public static func timeGridData(
        tasks: [TodoTask],
        days: [LocalDay],
        pendingMove: ScheduleOverride? = nil
    ) -> TimeGridData {
        let displayed: [TodoTask]
        if let pending = pendingMove {
            displayed = tasks.map { task in
                guard task.id == pending.taskId else { return task }
                var copy = task
                copy.schedule = pending.schedule
                return copy
            }
        } else {
            displayed = tasks
        }

        var allDay: [TimeGridAllDayItem] = []
        if let first = days.first, let last = days.last {
            let maxCol = days.count - 1
            var spans: [(task: TodoTask, range: ClosedRange<Int>)] = []
            for t in displayed {
                guard let s = t.schedule, s.isAllDay, s.overlaps(first, last) else { continue }
                let a = max(0, first.days(until: s.startDay))
                let b = min(maxCol, first.days(until: s.lastDay))
                spans.append((t, a...b))
            }
            let packed = LanePacker.pack(spans.map(\.range))
            allDay.reserveCapacity(spans.count)
            for (span, lane) in zip(spans, packed.lanes) {
                guard let lane else { continue }
                allDay.append(TimeGridAllDayItem(
                    task: span.task,
                    firstColumn: span.range.lowerBound,
                    lastColumn: span.range.upperBound,
                    lane: lane
                ))
            }
        }

        let blocksByDay = days.map { DayLayout.blocks(for: displayed, on: $0) }
        return TimeGridData(displayedTasks: displayed, allDayItems: allDay, blocksByDay: blocksByDay)
    }
}
