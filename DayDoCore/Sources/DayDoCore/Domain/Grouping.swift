import Foundation

/// Pure functions that turn task lists into the sections the screens show.
public enum TaskGrouping {
    /// Ordering inside a section: timed items by start, then all-day/undated
    /// by priority, then manual sort key.
    public static func sortForDay(_ tasks: [TodoTask]) -> [TodoTask] {
        tasks.sorted { a, b in
            let am = a.schedule?.startMinute, bm = b.schedule?.startMinute
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
        func add(_ id: String, _ title: String, _ list: [TodoTask]) {
            if !list.isEmpty { out.append(TaskSection(id: id, title: title, tasks: list)) }
        }
        switch scope {
        case .smart(.today):
            add("overdue", "已逾期", overdue)
            add("today", "今天", on(today))
            add("tomorrow", "明天", on(tomorrow))
            add("completed", "已完成", completed)
        case .smart(.tomorrow):
            add("tomorrow", "明天", on(tomorrow))
            add("completed", "已完成", completed)
        case .smart(.next7):
            add("overdue", "已逾期", overdue)
            for i in 0..<7 {
                let d = today.adding(days: i)
                add("day:\(d)", DateText.dayTitle(d, today: today), on(d))
            }
        case .smart(.completed):
            add("completed", "已完成", completed)
        case .smart(.trash):
            add("trash", "垃圾桶", tasks)
        case .smart(.all), .smart(.inbox), .smart(.assigned), .project, .tag:
            let later = sortForDay(active.filter { t in t.schedule.map { $0.startDay > tomorrow } ?? false })
                .sorted { ($0.schedule!.startDay, $0.schedule!.startMinute ?? -1) < ($1.schedule!.startDay, $1.schedule!.startMinute ?? -1) }
            let noDate = active.filter { $0.schedule == nil }.sorted { a, b in
                a.priority != b.priority ? a.priority > b.priority : a.sortKey < b.sortKey
            }
            add("overdue", "已逾期", overdue)
            add("today", "今天", on(today))
            add("tomorrow", "明天", on(tomorrow))
            add("later", "之後", later)
            add("nodate", "無日期", noDate)
            add("completed", "已完成", completed)
        }
        return out
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
        let start = first.adding(days: -first.weekday)
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
            }.sorted { a, b in
                let la = a.1.startDay.days(until: a.1.lastDay), lb = b.1.startDay.days(until: b.1.lastDay)
                if la != lb { return la > lb }
                if a.1.startDay != b.1.startDay { return a.1.startDay < b.1.startDay }
                return (a.1.startMinute ?? -1) < (b.1.startMinute ?? -1)
            }
            var lanes: [[ClosedRange<Int>]] = []
            var bars: [Bar] = []
            var overflow: [Int: Int] = [:]
            for (t, s) in items {
                let a = max(0, first.days(until: s.startDay))
                let b = min(6, first.days(until: s.lastDay))
                let range = a...b
                var lane = 0
                while lane < lanes.count, lanes[lane].contains(where: { $0.overlaps(range) }) { lane += 1 }
                if lane >= maxLanes {
                    for c in range { overflow[c, default: 0] += 1 }
                    continue
                }
                if lane == lanes.count { lanes.append([]) }
                lanes[lane].append(range)
                bars.append(Bar(task: t, startColumn: a, endColumn: b, lane: lane, continues: s.startDay < first))
            }
            weeks.append(Week(days: wd, bars: bars, overflow: overflow))
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
    public static func range(_ s: Schedule) -> String {
        guard let sm = s.startMinute else { return "全天" }
        guard let end = s.endOffsetMinutes else { return hm(sm) }
        return hm(sm) + " – " + (end >= 1440 ? "隔日 " : "") + hm(end)
    }

    /// The meta line under a task title.
    /// - list mode (`viewDay == nil`, 1b): "18:00 – 18:30", "明天 10:00 – 11:00",
    ///   "昨天 17:00", "全天・第 3/4 天"; a single all-day task today shows "".
    /// - agenda mode (`viewDay` set, 2a): no day prefix, "全天" spelled out.
    public static func taskLine(_ s: Schedule, on viewDay: LocalDay? = nil, today: LocalDay) -> String {
        let dayPart = (viewDay == nil && !s.isMultiDay && s.startDay != today) ? relative(s.startDay, today: today) : ""
        if s.isAllDay {
            if s.isMultiDay {
                let probe = viewDay ?? (s.occurs(on: today) ? today : s.startDay)
                let (i, n) = s.dayPosition(on: probe) ?? (1, s.startDay.days(until: s.lastDay) + 1)
                return "全天・第 \(i)/\(n) 天"
            }
            return viewDay != nil ? "全天" : dayPart
        }
        let r = range(s)
        return dayPart.isEmpty ? r : dayPart + " " + r
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

    public static func blocks(for tasks: [TodoTask], on day: LocalDay) -> [Block] {
        var items: [(TodoTask, Int, Int)] = []
        for t in tasks {
            guard let s = t.schedule, let sm = s.startMinute, s.occurs(on: day) else { continue }
            let offset = s.startDay.days(until: day) * 1440
            let rawEnd = s.endOffsetMinutes ?? (sm + 30)
            let start = max(0, sm - offset)
            let end = min(1440, max(rawEnd, sm + 15) - offset)
            guard end > start else { continue }
            items.append((t, start, end))
        }
        items.sort { ($0.1, -$0.2) < ($1.1, -$1.2) }
        var out: [Block] = []
        var cluster: [Block] = []
        var clusterEnd = -1
        func flush() {
            let n = (cluster.map(\.lane).max() ?? -1) + 1
            out += cluster.map { var b = $0; b.lanes = n; return b }
            cluster = []
        }
        for (t, s, e) in items {
            if s >= clusterEnd { flush() }
            var lane = 0
            while cluster.contains(where: { $0.lane == lane && $0.end > s }) { lane += 1 }
            cluster.append(Block(task: t, start: s, end: e, lane: lane, lanes: 1))
            clusterEnd = max(clusterEnd, e)
        }
        flush()
        return out
    }
}
