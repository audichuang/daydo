import Foundation

/// Pure functions that turn task lists into the sections the screens show.
public enum TaskGrouping {
    /// Ordering inside a section: all-day/undated first, then timed items by
    /// start (clipped to `day` when provided so cross-midnight continuations
    /// sort at 00:00), then priority, then manual sort key.
    public static func sortForDay(_ tasks: [TodoTask], on day: LocalDay? = nil) -> [TodoTask] {
        func startMinute(of task: TodoTask) -> Int? {
            guard let s = task.schedule else { return nil }
            if let day { return DayLayout.clippedRange(for: s, on: day)?.start }
            return s.startMinute
        }
        return tasks.sorted { a, b in
            let am = startMinute(of: a), bm = startMinute(of: b)
            switch (am, bm) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return true // all-day first, like the agenda (2a)
            case (_?, nil): return false
            default: break
            }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.sortKey < b.sortKey
        }
    }

    /// Tasks occurring on `day`: active tasks sorted by day time first, then completed.
    public static func calendarDayTasks(_ tasks: [TodoTask], on day: LocalDay) -> [TodoTask] {
        let items = tasks.filter { $0.schedule?.occurs(on: day) == true }
        return sortForDay(items.filter { !$0.isCompleted }, on: day) + items.filter(\.isCompleted)
    }

    public static func isOverdue(_ t: TodoTask, today: LocalDay) -> Bool {
        guard !t.isCompleted, let s = t.schedule else { return false }
        return s.lastDay < today
    }

    /// Sections for a list screen. `smart(.today)` mirrors design 1b:
    /// 已逾期 / 今天 / 明天 / 已完成 (completed today).
    public static func sections(for scope: TaskScope, tasks: [TodoTask], completed: [TodoTask], today: LocalDay) -> [TaskSection] {
        let tomorrow = today.adding(days: 1)
        let active = tasks.filter { !$0.isCompleted }
        func on(_ day: LocalDay) -> [TodoTask] {
            sortForDay(active.filter { t in t.schedule.map { $0.occurs(on: day) && !isOverdue(t, today: today) } ?? false })
        }
        let overdue = active.filter { isOverdue($0, today: today) }.sorted { ($0.schedule!.lastDay, $0.sortKey) < ($1.schedule!.lastDay, $1.sortKey) }
        var out: [TaskSection] = []
        func add(_ kind: TaskSection.Kind, _ title: String, _ list: [TodoTask]) {
            if !list.isEmpty { out.append(TaskSection(kind: kind, title: title, tasks: list)) }
        }
        switch scope {
        case .smart(.today):
            add(.overdue, "已逾期", overdue)
            add(.today, "今天", on(today))
            add(.tomorrow, "明天", on(tomorrow))
            add(.completed, "已完成", completed)
        case .smart(.tomorrow):
            add(.tomorrow, "明天", on(tomorrow))
            add(.completed, "已完成", completed)
        case .smart(.next7):
            add(.overdue, "已逾期", overdue)
            for i in 0..<7 {
                let d = today.adding(days: i)
                add(.day(d), DateText.dayTitle(d, today: today), on(d))
            }
        case .smart(.completed):
            add(.completed, "已完成", completed)
        case .smart(.trash):
            add(.trash, "垃圾桶", tasks)
        case .smart(.all), .smart(.inbox), .smart(.assigned), .project, .tag:
            let later = sortForDay(active.filter { t in t.schedule.map { $0.startDay > tomorrow } ?? false })
                .sorted { ($0.schedule!.startDay, $0.schedule!.startMinute ?? -1) < ($1.schedule!.startDay, $1.schedule!.startMinute ?? -1) }
            let noDate = active.filter { $0.schedule == nil }.sorted { a, b in
                a.priority != b.priority ? a.priority > b.priority : a.sortKey < b.sortKey
            }
            add(.overdue, "已逾期", overdue)
            add(.today, "今天", on(today))
            add(.tomorrow, "明天", on(tomorrow))
            add(.later, "之後", later)
            add(.noDate, "無日期", noDate)
            add(.completed, "已完成", completed)
        }
        return out
    }

    /// Expands list sections into Kanban columns in list order: optional 已逾期,
    /// fixed 今天/明天, optional 之後, and fixed 無日期/已完成 (empty when absent).
    public static func kanbanColumns(from sections: [TaskSection]) -> [TaskSection] {
        let byKind = Dictionary(sections.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [TaskSection] = []
        if let overdue = byKind[.overdue], !overdue.tasks.isEmpty {
            out.append(overdue)
        }
        out.append(byKind[.today] ?? TaskSection(kind: .today, title: "今天", tasks: []))
        out.append(byKind[.tomorrow] ?? TaskSection(kind: .tomorrow, title: "明天", tasks: []))
        if let later = byKind[.later], !later.tasks.isEmpty {
            out.append(later)
        }
        out.append(byKind[.noDate] ?? TaskSection(kind: .noDate, title: "無日期", tasks: []))
        out.append(byKind[.completed] ?? TaskSection(kind: .completed, title: "已完成", tasks: []))
        let known: Set<TaskSection.Kind> = [.overdue, .today, .tomorrow, .later, .noDate, .completed]
        for sec in sections where !known.contains(sec.kind) && !sec.tasks.isEmpty {
            out.append(sec)
        }
        return out
    }
}

/// Packs ordered inclusive column ranges into non-overlapping horizontal lanes
/// using first-fit placement, optionally capping the lane count and recording
/// per-column overflow counts.
public enum LanePacker {
    public struct Result: Equatable, Sendable {
        /// Assigned lane index per input item, or `nil` when the item overflowed `maxLanes`.
        public var lanes: [Int?]
        /// Column index -> hidden item count for that column.
        public var overflow: [Int: Int]

        public init(lanes: [Int?], overflow: [Int: Int]) {
            self.lanes = lanes
            self.overflow = overflow
        }
    }

    /// Canonical bar/all-day lane order shared by month and time-grid layouts:
    /// longer spans first, then earlier start day, then earlier start minute.
    public static func spanOrder(_ a: Schedule, _ b: Schedule) -> Bool {
        let la = a.startDay.days(until: a.lastDay), lb = b.startDay.days(until: b.lastDay)
        if la != lb { return la > lb }
        if a.startDay != b.startDay { return a.startDay < b.startDay }
        return (a.startMinute ?? -1) < (b.startMinute ?? -1)
    }

    public static func pack(_ ranges: [ClosedRange<Int>], maxLanes: Int? = nil) -> Result {
        var lanes: [[ClosedRange<Int>]] = []
        var assigned: [Int?] = []
        assigned.reserveCapacity(ranges.count)
        var overflow: [Int: Int] = [:]

        for range in ranges {
            var lane = 0
            while lane < lanes.count, lanes[lane].contains(where: { $0.overlaps(range) }) {
                lane += 1
            }
            if let maxLanes, lane >= maxLanes {
                for c in range { overflow[c, default: 0] += 1 }
                assigned.append(nil)
                continue
            }
            if lane == lanes.count { lanes.append([]) }
            lanes[lane].append(range)
            assigned.append(lane)
        }
        return Result(lanes: assigned, overflow: overflow)
    }
}

/// Month layout for the event calendar (2c): spanning bars in up to 3 lanes
/// per week, overflow counted as "+N".
public struct MonthLayout: Sendable {
    public struct Bar: Hashable, Sendable {
        public var task: TodoTask
        /// Column 0…6 inside the week.
        public var startColumn: Int
        public var endColumn: Int
        public var lane: Int
        /// Continues from the previous week.
        public var continues: Bool
    }

    public struct Week: Hashable, Sendable {
        public var days: [LocalDay]
        public var bars: [Bar]
        /// column → hidden item count
        public var overflow: [Int: Int]
    }

    public var weeks: [Week]

    /// Sunday-first grid covering the month of `month`.
    public static func gridDays(for month: LocalDay) -> [LocalDay] {
        let first = month.firstOfMonth
        let start = first.startOfWeek
        let lastOfMonth = first.adding(days: first.daysInMonth - 1)
        let end = lastOfMonth.adding(days: 6 - lastOfMonth.weekday)
        return (0...start.days(until: end)).map { start.adding(days: $0) }
    }

    public init(month: LocalDay, tasks: [TodoTask], maxLanes: Int = 3) {
        self.init(days: MonthLayout.gridDays(for: month), tasks: tasks, maxLanes: maxLanes)
    }

    public init(days: [LocalDay], tasks: [TodoTask], maxLanes: Int = 3) {
        var weeks: [Week] = []
        for w in stride(from: 0, to: days.count, by: 7) {
            let endIdx = min(w + 7, days.count)
            guard endIdx - w == 7 else { continue }
            let wd = Array(days[w..<endIdx])
            let first = wd[0], last = wd[6]
            let items = tasks.compactMap { t -> (TodoTask, Schedule)? in
                guard let s = t.schedule, s.overlaps(first, last) else { return nil }
                return (t, s)
            }.sorted { LanePacker.spanOrder($0.1, $1.1) }
            let spans: [(task: TodoTask, schedule: Schedule, range: ClosedRange<Int>)] = items.map { t, s in
                let a = max(0, first.days(until: s.startDay))
                let b = min(6, first.days(until: s.lastDay))
                return (t, s, a...b)
            }
            let packed = LanePacker.pack(spans.map(\.range), maxLanes: maxLanes)
            var bars: [Bar] = []
            bars.reserveCapacity(spans.count)
            for (span, lane) in zip(spans, packed.lanes) {
                guard let lane else { continue }
                bars.append(Bar(
                    task: span.task,
                    startColumn: span.range.lowerBound,
                    endColumn: span.range.upperBound,
                    lane: lane,
                    continues: span.schedule.startDay < first
                ))
            }
            weeks.append(Week(days: wd, bars: bars, overflow: packed.overflow))
        }
        self.weeks = weeks
    }
}

/// Chinese date/time strings used across the UI (kept here so they are
/// unit-tested and shared with widgets).
public enum DateText {
    public static func hm(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    public static func monthDay(_ d: LocalDay) -> String { "\(d.month) 月 \(d.day) 日" }

    public static func full(_ d: LocalDay) -> String { "\(d.month) 月 \(d.day) 日 週\(LocalDay.weekdaySymbols[d.weekday])" }

    public static func relative(_ d: LocalDay, today: LocalDay) -> String {
        switch today.days(until: d) {
        case 0: return "今天"
        case 1: return "明天"
        case -1: return "昨天"
        case 2: return "後天"
        default: return monthDay(d)
        }
    }

    public static func dayTitle(_ d: LocalDay, today: LocalDay) -> String {
        let rel = today.days(until: d)
        let wd = "週" + LocalDay.weekdaySymbols[d.weekday]
        if rel == 0 { return "今天" }
        if rel == 1 { return "明天" }
        return "\(monthDay(d)) \(wd)"
    }

    public static func duration(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) 小時" : "\(h) 小時 \(m) 分"
        }
        return "\(minutes) 分鐘"
    }

    /// Time range for a block; the end is prefixed with 隔日 when it is on
    /// the next day.
    public static func range(_ s: Schedule, separator: String = " – ") -> String {
        guard let sm = s.startMinute else { return "全天" }
        guard let end = s.endOffsetMinutes else { return hm(sm) }
        return hm(sm) + separator + (end >= 1440 ? "隔日 " : "") + hm(end)
    }

    /// The meta line under a task title.
    /// - list mode (`viewDay == nil`, 1b): "18:00 – 18:30", "明天 10:00 – 11:00",
    ///   "昨天 17:00", "全天・第 3/4 天", "12 月 24 日 起・5 天"; a single all-day task today shows "".
    /// - agenda mode (`viewDay` set, 2a): no day prefix, "全天" spelled out.
    public static func taskLine(_ s: Schedule, on viewDay: LocalDay? = nil, today: LocalDay) -> String {
        let dayPart = (viewDay == nil && !s.isMultiDay && s.startDay != today) ? relative(s.startDay, today: today) : ""
        if s.isAllDay {
            if s.isMultiDay {
                let probe = viewDay ?? (s.occurs(on: today) ? today : s.startDay)
                let (i, n) = s.dayPosition(on: probe) ?? (1, s.startDay.days(until: s.lastDay) + 1)
                if viewDay == nil && today < s.startDay {
                    return "\(monthDay(s.startDay)) 起・\(n) 天"
                }
                return "全天・第 \(i)/\(n) 天"
            }
            return viewDay != nil ? "全天" : dayPart
        }
        let r = range(s)
        return dayPart.isEmpty ? r : dayPart + " " + r
    }

    /// Agenda row subtitle: "11月13日, 11:00 – 12:00", "11月13日 – 11月17日", "全天", or "已完成".
    public static func agendaLine(_ task: TodoTask, includeDay: Bool = true) -> String {
        if task.isCompleted { return "已完成" }
        guard let s = task.schedule else { return "" }
        func md(_ d: LocalDay) -> String { "\(d.month)月\(d.day)日" }
        if s.isAllDay {
            return s.isMultiDay ? md(s.startDay) + " – " + md(s.lastDay) : (includeDay ? md(s.startDay) : "全天")
        }
        let r = range(s)
        return includeDay ? md(s.startDay) + ", " + r : r
    }

    /// Calendar-day countdown badge text for a schedule relative to `today`.
    /// Returns nil when `lastDay < today`.
    public static func countdownLabel(_ s: Schedule, today: LocalDay) -> String? {
        if s.lastDay < today { return nil }
        let daysUntilStart = today.days(until: s.startDay)
        if daysUntilStart > 0 {
            return daysUntilStart == 1 ? "明天" : "還有 \(daysUntilStart) 天"
        }
        if s.isAllDay && s.isMultiDay {
            if today == s.lastDay { return "最後一天" }
            let remaining = today.days(until: s.lastDay) + 1
            return "還剩 \(remaining) 天"
        }
        return "今天"
    }

    public static func countdownLabel(for task: TodoTask, today: LocalDay) -> String? {
        guard task.countdown, !task.isCompleted, task.deletedAt == nil, let s = task.schedule else {
            return nil
        }
        return countdownLabel(s, today: today)
    }
}

/// Time-grid layout for the 週／3日／日 views: timed items of one day placed in
/// side-by-side lanes when they overlap. Blocks crossing midnight are clipped
/// to the day; point-in-time items get a 30-minute block.
public enum DayLayout {
    public struct Block: Hashable, Sendable {
        public var task: TodoTask
        public var start: Int
        public var end: Int
        public var lane: Int
        public var lanes: Int
    }

    public enum BlockOrder: Sendable {
        /// Clipped start ascending, longer clipped end first (calendar time grid).
        case clippedStartLongestFirst
        /// Pre-clip schedule start ascending, preserving input order on ties (time-block editor).
        case scheduleStart
    }

    /// Clips a timed schedule to `day` (0..<`dayEnd` minutes, default 1440),
    /// returning `nil` for all-day tasks or schedules outside the window.
    public static func clippedRange(
        for schedule: Schedule,
        on day: LocalDay,
        dayEnd: Int = 1440,
        minDuration: Int = 15
    ) -> (start: Int, end: Int)? {
        guard dayEnd > 0, let sm = schedule.startMinute else { return nil }
        let windowLastDay = day.adding(days: (dayEnd - 1) / 1440)
        guard schedule.overlaps(day, windowLastDay) else { return nil }
        let offset = schedule.startDay.days(until: day) * 1440
        let rawEnd = schedule.endOffsetMinutes ?? (sm + 30)
        let start = max(0, sm - offset)
        let end = min(dayEnd, max(rawEnd, sm + max(1, minDuration)) - offset)
        guard end > start else { return nil }
        return (start, end)
    }

    public static func blocks(
        for tasks: [TodoTask],
        on day: LocalDay,
        dayEnd: Int = 1440,
        minDuration: Int = 15,
        order: BlockOrder = .clippedStartLongestFirst
    ) -> [Block] {
        var items: [(task: TodoTask, rawStart: Int, start: Int, end: Int)] = []
        for t in tasks {
            guard let s = t.schedule,
                  let sm = s.startMinute,
                  let (start, end) = clippedRange(for: s, on: day, dayEnd: dayEnd, minDuration: minDuration) else { continue }
            let rawStart = sm - s.startDay.days(until: day) * 1440
            items.append((t, rawStart, start, end))
        }
        switch order {
        case .clippedStartLongestFirst:
            items.sort { ($0.start, -$0.end) < ($1.start, -$1.end) }
        case .scheduleStart:
            items.sort { $0.rawStart < $1.rawStart }
        }
        var out: [Block] = []
        var cluster: [Block] = []
        var clusterEnd = -1
        func flush() {
            let n = (cluster.map(\.lane).max() ?? -1) + 1
            out += cluster.map { var b = $0; b.lanes = n; return b }
            cluster = []
        }
        for item in items {
            let s = item.start, e = item.end
            if s >= clusterEnd { flush() }
            var lane = 0
            while cluster.contains(where: { $0.lane == lane && $0.end > s }) { lane += 1 }
            cluster.append(Block(task: item.task, start: s, end: e, lane: lane, lanes: 1))
            clusterEnd = max(clusterEnd, e)
        }
        flush()
        return out
    }
}
