import Foundation

/// Deep links produced by home-screen widgets and handled by `DayDoApp`.
public enum WidgetDeepLink: Equatable, Sendable {
    case today
    case task(String)
    case calendar(LocalDay?)

    public var url: URL {
        switch self {
        case .today:
            return URL(string: "daydo://today")!
        case .task(let id):
            var comps = URLComponents()
            comps.scheme = "daydo"
            comps.host = "task"
            comps.path = "/\(id)"
            return comps.url!
        case .calendar(let day):
            if let day {
                return URL(string: "daydo://calendar/\(day.description)")!
            }
            return URL(string: "daydo://calendar")!
        }
    }

    /// Parses widget deep links (`daydo://today`, `daydo://task/<id>`,
    /// `daydo://calendar`, `daydo://calendar/<yyyy-MM-dd>`). Invite links
    /// (`daydo://invite/<code>`) are intentionally ignored so
    /// `SyncEngine.parseInviteCode(from:)` handles them exclusively.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "daydo",
              let host = url.host?.lowercased() else {
            return nil
        }
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        switch host {
        case "today":
            guard segments.isEmpty else { return nil }
            self = .today
        case "task":
            guard segments.count == 1, !segments[0].isEmpty else { return nil }
            self = .task(segments[0])
        case "calendar":
            if segments.isEmpty {
                self = .calendar(nil)
            } else if segments.count == 1, let day = LocalDay(segments[0]) {
                self = .calendar(day)
            } else {
                return nil
            }
        default:
            return nil
        }
    }
}

/// Snapshot for the 今日任務 widget. Mirrors the App's "今天" smart list.
public struct WidgetTodayData: Equatable, Sendable {
    public struct Item: Hashable, Sendable, Identifiable {
        public var task: TodoTask
        public var isOverdue: Bool
        public var timeLabel: String
        public var id: String { task.id }

        public init(task: TodoTask, isOverdue: Bool, timeLabel: String) {
            self.task = task
            self.isOverdue = isOverdue
            self.timeLabel = timeLabel
        }
    }

    public var today: LocalDay
    public var overdueItems: [Item]
    public var todayItems: [Item]

    public var allItems: [Item] { overdueItems + todayItems }
    public var totalCount: Int { overdueItems.count + todayItems.count }

    public init(today: LocalDay, overdueItems: [Item], todayItems: [Item]) {
        self.today = today
        self.overdueItems = overdueItems
        self.todayItems = todayItems
    }

    public static func build(sections: [TaskSection], today: LocalDay) -> WidgetTodayData {
        let overdue = (sections.first(where: { $0.kind == .overdue })?.tasks ?? []).map { t in
            Item(task: t, isOverdue: true, timeLabel: "逾期")
        }
        let todayTasks = (sections.first(where: { $0.kind == .today })?.tasks ?? []).map { t in
            Item(task: t, isOverdue: false, timeLabel: todayTimeLabel(for: t.schedule))
        }
        return WidgetTodayData(today: today, overdueItems: overdue, todayItems: todayTasks)
    }

    private static func todayTimeLabel(for schedule: Schedule?) -> String {
        guard let schedule else { return "" }
        if let sm = schedule.startMinute {
            return DateText.hm(sm)
        }
        return schedule.isMultiDay ? "全天" : ""
    }

    public static func load(from api: any DayDoAPI, today: LocalDay) async throws -> WidgetTodayData {
        let sections = try await api.listSections(.smart(.today))
        return build(sections: sections, today: today)
    }

    /// Loads today's data and a midnight-rollover snapshot for tomorrow using
    /// the same smart-list rules as `LocalDayDoAPI.listSections(.smart(.today))`.
    public static func loadTimeline(
        from api: any DayDoAPI,
        now: Date,
        timeZone: TimeZone
    ) async throws -> [(date: Date, data: WidgetTodayData)] {
        let today = LocalDay(date: now, in: timeZone)
        let todayData = try await load(from: api, today: today)

        let tomorrow = today.adding(days: 1)
        let nextMidnight = tomorrow.date(minute: 0, in: timeZone)

        let smartProjectIds = Set(
            try await api.listProjects(includeArchived: false)
                .filter { $0.showInSmart == "all" }
                .map(\.id)
        )
        let activeScheduled = try await api.listTasks(TaskQuery(includeCompleted: false))
            .filter { $0.schedule != nil && smartProjectIds.contains($0.projectId) }
        let tomorrowSections = TaskGrouping.sections(
            for: .smart(.today),
            tasks: activeScheduled,
            completed: [],
            today: tomorrow
        )
        let tomorrowData = build(sections: tomorrowSections, today: tomorrow)
        return [(now, todayData), (nextMidnight, tomorrowData)]
    }
}

/// Snapshot for the 下一個行程 widget (timed upcoming/ongoing items + today's
/// 5-hour timeline with all-day items).
public struct WidgetNextData: Equatable, Sendable {
    public struct TimedItem: Hashable, Sendable, Identifiable {
        public var task: TodoTask
        public var projectName: String?
        public var projectColorHex: String?
        public var startDate: Date
        public var endDate: Date
        public var isOngoing: Bool
        public var startTimeText: String
        public var timeRangeText: String
        public var id: String { task.id }
    }

    public struct AllDayItem: Hashable, Sendable, Identifiable {
        public var task: TodoTask
        public var projectColorHex: String?
        public var displayTitle: String
        public var id: String { task.id }
    }

    public struct TimelineBlock: Hashable, Sendable, Identifiable {
        public var task: TodoTask
        public var projectColorHex: String?
        public var startMinute: Int
        public var endMinute: Int
        public var lane: Int
        public var lanes: Int
        public var isPrimary: Bool
        public var timeText: String
        public var id: String { task.id }
    }

    public var now: Date
    public var today: LocalDay
    public var currentOrNext: TimedItem?
    public var after: [TimedItem]
    public var allDayToday: [AllDayItem]
    public var windowStartHour: Int
    public var windowEndHour: Int
    public var timelineBlocks: [TimelineBlock]

    public static func build(
        tasks: [TodoTask],
        projectsById: [String: Project],
        now: Date,
        timeZone: TimeZone
    ) -> WidgetNextData {
        let today = LocalDay(date: now, in: timeZone)
        let horizon = today.adding(days: 7)
        let active = tasks.filter { !$0.isCompleted && $0.schedule != nil }

        var timedItems: [TimedItem] = []
        for task in active {
            guard let sched = task.schedule, let sm = sched.startMinute else { continue }
            guard sched.startDay <= horizon else { continue }
            let startDate = sched.startDay.date(minute: sm, in: timeZone)
            let endDate: Date
            if let ed = sched.endDay, let em = sched.endMinute {
                endDate = ed.date(minute: em, in: timeZone)
            } else {
                endDate = startDate
            }
            guard endDate > now else { continue }
            let project = projectsById[task.projectId]
            timedItems.append(TimedItem(
                task: task,
                projectName: project?.name,
                projectColorHex: project?.color,
                startDate: startDate,
                endDate: endDate,
                isOngoing: startDate <= now && now < endDate,
                startTimeText: DateText.hm(sm),
                timeRangeText: DateText.range(sched)
            ))
        }
        timedItems.sort { a, b in
            if a.startDate != b.startDate { return a.startDate < b.startDate }
            if a.endDate != b.endDate { return a.endDate < b.endDate }
            return a.task.sortKey < b.task.sortKey
        }

        let currentOrNext = timedItems.first
        let after = Array(timedItems.dropFirst())

        let allDayToday: [AllDayItem] = active.compactMap { task in
            guard let sched = task.schedule, sched.isAllDay, sched.occurs(on: today) else { return nil }
            let title: String
            if let (idx, total) = sched.dayPosition(on: today) {
                title = "\(task.title) \(idx)/\(total)"
            } else {
                title = task.title
            }
            return AllDayItem(
                task: task,
                projectColorHex: projectsById[task.projectId]?.color,
                displayTitle: title
            )
        }.sorted { a, b in
            if a.task.priority != b.task.priority { return a.task.priority > b.task.priority }
            return a.task.sortKey < b.task.sortKey
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let currentHour = comps.hour ?? 0

        let todayTimed = timedItems.filter { $0.task.schedule?.occurs(on: today) == true }
        let hasOngoingToday = todayTimed.contains { $0.isOngoing }
        let rawStartHour: Int
        if hasOngoingToday {
            rawStartHour = currentHour
        } else if let firstUpcoming = todayTimed.first(where: { !$0.isOngoing }) {
            let firstStartHour = cal.component(.hour, from: firstUpcoming.startDate)
            rawStartHour = max(currentHour, firstStartHour - 1)
        } else {
            rawStartHour = currentHour
        }
        let windowStartHour = min(19, max(0, rawStartHour))
        let windowEndHour = windowStartHour + 5
        let winStartMin = windowStartHour * 60
        let winEndMin = windowEndHour * 60

        let todayBlocks = DayLayout.blocks(for: active, on: today)

        let clippedBlocks: [TimelineBlock] = todayBlocks.compactMap { b in
            guard b.end > winStartMin && b.start < winEndMin else { return nil }
            let origStart = b.task.schedule?.startMinute ?? b.start
            return TimelineBlock(
                task: b.task,
                projectColorHex: projectsById[b.task.projectId]?.color,
                startMinute: max(b.start, winStartMin),
                endMinute: min(b.end, winEndMin),
                lane: b.lane,
                lanes: b.lanes,
                isPrimary: b.task.id == currentOrNext?.task.id,
                timeText: DateText.hm(origStart)
            )
        }

        return WidgetNextData(
            now: now,
            today: today,
            currentOrNext: currentOrNext,
            after: after,
            allDayToday: allDayToday,
            windowStartHour: windowStartHour,
            windowEndHour: windowEndHour,
            timelineBlocks: clippedBlocks
        )
    }

    /// Returns timeline entry dates from `now` through the next local midnight,
    /// inserting a boundary whenever a timed event starts or ends.
    public static func timelineDates(
        tasks: [TodoTask],
        from now: Date,
        timeZone: TimeZone
    ) -> [Date] {
        let today = LocalDay(date: now, in: timeZone)
        let nextMidnight = today.adding(days: 1).date(minute: 0, in: timeZone)
        var dates: Set<Date> = [now, nextMidnight]
        // The large timeline window follows the current hour while an item is
        // ongoing, so refresh at every local top of the hour until midnight.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var hour = now
        while let next = cal.nextDate(
            after: hour,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ), next < nextMidnight {
            dates.insert(next)
            hour = next
        }
        for task in tasks where !task.isCompleted {
            guard let sched = task.schedule, let sm = sched.startMinute else { continue }
            let start = sched.startDay.date(minute: sm, in: timeZone)
            let end: Date
            if let ed = sched.endDay, let em = sched.endMinute {
                end = ed.date(minute: em, in: timeZone)
            } else {
                end = start
            }
            if start > now && start < nextMidnight {
                dates.insert(start)
            }
            if end > now && end < nextMidnight {
                dates.insert(end)
            }
        }
        return dates.sorted()
    }

    public static func loadTimeline(
        from api: any DayDoAPI,
        now: Date,
        timeZone: TimeZone
    ) async throws -> [(date: Date, data: WidgetNextData)] {
        let today = LocalDay(date: now, in: timeZone)
        let projects = try await api.listProjects(includeArchived: false)
        let projectsById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let tasks = try await api.listTasks(TaskQuery(
            from: today.adding(days: -1),
            to: today.adding(days: 8),
            includeCompleted: false
        ))
        let dates = timelineDates(tasks: tasks, from: now, timeZone: timeZone)
        return dates.map { d in
            (d, build(tasks: tasks, projectsById: projectsById, now: d, timeZone: timeZone))
        }
    }
}

/// Snapshot for the 日曆 widget. Mirrors the App's "日曆" view.
public struct WidgetCalendarData: Sendable {
    public var today: LocalDay
    public var month: LocalDay
    public var miniDays: [LocalDay]
    public var daysWithEvents: Set<LocalDay>
    public var twoWeekLayout: MonthLayout
    public var monthLayout: MonthLayout
    public var projectColorsById: [String: String]
    private let orderedTasks: [TodoTask]

    public func twoWeekLayout(maxLanes: Int) -> MonthLayout {
        let twoWeekStart = today.startOfWeek
        let twoWeekDays = (0..<14).map { twoWeekStart.adding(days: $0) }
        return MonthLayout(days: twoWeekDays, tasks: orderedTasks, maxLanes: max(1, maxLanes))
    }

    public func monthLayout(maxLanes: Int) -> MonthLayout {
        MonthLayout(days: miniDays, tasks: orderedTasks, maxLanes: max(1, maxLanes))
    }

    public static func queryRange(for today: LocalDay) -> ClosedRange<LocalDay> {
        let grid = MonthLayout.gridDays(for: today)
        let twoWeekStart = today.startOfWeek
        let twoWeekEnd = twoWeekStart.adding(days: 13)
        let lower = min(grid.first ?? today, twoWeekStart)
        let upper = max(grid.last ?? today, twoWeekEnd)
        return lower...upper
    }

    public static func build(
        tasks: [TodoTask],
        projectsById: [String: Project],
        today: LocalDay,
        includeCompleted: Bool = true
    ) -> WidgetCalendarData {
        let filtered = includeCompleted ? tasks : tasks.filter { !$0.isCompleted }
        // Put active tasks ahead of completed ones so active items win lanes on ties.
        let orderedTasks = filtered.filter { !$0.isCompleted } + filtered.filter(\.isCompleted)
        let month = today.firstOfMonth
        let miniDays = MonthLayout.gridDays(for: month)
        var daysWithEvents: Set<LocalDay> = []
        for day in miniDays {
            if orderedTasks.contains(where: { $0.schedule?.occurs(on: day) == true }) {
                daysWithEvents.insert(day)
            }
        }

        let twoWeekStart = today.startOfWeek
        let twoWeekDays = (0..<14).map { twoWeekStart.adding(days: $0) }
        let twoWeekLayout = MonthLayout(days: twoWeekDays, tasks: orderedTasks, maxLanes: 2)

        let weekCount = miniDays.count / 7
        let monthMaxLanes = weekCount >= 6 ? 2 : 3
        let monthLayout = MonthLayout(days: miniDays, tasks: orderedTasks, maxLanes: monthMaxLanes)

        var colors: [String: String] = [:]
        for (id, p) in projectsById {
            if let c = p.color { colors[id] = c }
        }

        return WidgetCalendarData(
            today: today,
            month: month,
            miniDays: miniDays,
            daysWithEvents: daysWithEvents,
            twoWeekLayout: twoWeekLayout,
            monthLayout: monthLayout,
            projectColorsById: colors,
            orderedTasks: orderedTasks
        )
    }

    public static func loadTimeline(
        from api: any DayDoAPI,
        now: Date,
        timeZone: TimeZone,
        includeCompleted: Bool = true
    ) async throws -> [(date: Date, data: WidgetCalendarData)] {
        let today = LocalDay(date: now, in: timeZone)
        let tomorrow = today.adding(days: 1)
        let nextMidnight = tomorrow.date(minute: 0, in: timeZone)

        let r1 = queryRange(for: today)
        let r2 = queryRange(for: tomorrow)
        let range = min(r1.lowerBound, r2.lowerBound)...max(r1.upperBound, r2.upperBound)

        let projects = try await api.listProjects(includeArchived: false)
        let projectsById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let tasks = try await api.listTasks(TaskQuery(
            from: range.lowerBound,
            to: range.upperBound,
            includeCompleted: includeCompleted
        ))

        let todayData = build(tasks: tasks, projectsById: projectsById, today: today, includeCompleted: includeCompleted)
        let tomorrowData = build(tasks: tasks, projectsById: projectsById, today: tomorrow, includeCompleted: includeCompleted)
        return [(now, todayData), (nextMidnight, tomorrowData)]
    }
}

/// User-selected color appearance stored in UserDefaults and the App Group.
public enum AppAppearance: String, CaseIterable, Sendable {
    case dark
    case light
    case system

    public static let defaultsKey = "appearance"

    public static func from(defaults: UserDefaults?) -> AppAppearance {
        guard let raw = defaults?.string(forKey: defaultsKey),
              let value = AppAppearance(rawValue: raw) else {
            return .dark
        }
        return value
    }

    public static func override(from arguments: [String]) -> AppAppearance? {
        guard let i = arguments.lastIndex(of: "-appearance"), i + 1 < arguments.count else {
            return nil
        }
        return AppAppearance(rawValue: arguments[i + 1].lowercased())
    }
}
