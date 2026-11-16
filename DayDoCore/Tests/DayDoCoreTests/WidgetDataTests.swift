import Foundation
import Testing
@testable import DayDoCore

extension FileBackedDatabaseTests {
@Suite struct WidgetDataTests {
    private func makeProject(_ id: String, name: String, color: String, showInSmart: String = "all") -> Project {
        Project(
            id: id,
            name: name,
            color: color,
            viewMode: "list",
            kind: "TASK",
            isInbox: false,
            ownerId: "me",
            sortKey: id,
            showInSmart: showInSmart,
            notifyMode: "all",
            archived: false,
            memberIds: ["me"],
            activeCount: 0,
            createdAt: 0,
            updatedAt: 0
        )
    }

    private func makeTask(
        _ id: String,
        title: String = "T",
        projectId: String = "p1",
        priority: Priority = .none,
        status: Int = 0,
        schedule: Schedule? = nil,
        sortKey: String? = nil
    ) -> TodoTask {
        TodoTask(
            id: id,
            projectId: projectId,
            title: title,
            content: "",
            priority: priority,
            status: status,
            schedule: schedule,
            start: nil,
            due: nil,
            allDay: schedule?.isAllDay ?? false,
            timeZone: nil,
            reminders: [],
            repeat: nil,
            tags: [],
            items: [],
            assigneeId: nil,
            sortKey: sortKey ?? id,
            completedAt: nil,
            createdAt: 0,
            updatedAt: 0,
            deletedAt: nil,
            attachments: [],
            commentCount: 0,
            sourceRaw: nil,
            importNote: nil
        )
    }

    @Test func deepLinksRoundTripAndDoNotCollideWithInvites() {
        #expect(WidgetDeepLink(url: WidgetDeepLink.today.url) == .today)
        #expect(WidgetDeepLink(url: WidgetDeepLink.task("t-123").url) == .task("t-123"))
        #expect(WidgetDeepLink(url: WidgetDeepLink.calendar(nil).url) == .calendar(nil))
        #expect(WidgetDeepLink(url: WidgetDeepLink.calendar(day("2026-11-15")).url) == .calendar(day("2026-11-15")))

        // Invite links must not parse as widget links, and widget links must not parse as invites.
        #expect(WidgetDeepLink(url: URL(string: "daydo://invite/abc123")!) == nil)
        #expect(SyncEngine.parseInviteCode(from: WidgetDeepLink.today.url) == nil)
        #expect(SyncEngine.parseInviteCode(from: WidgetDeepLink.task("t-123").url) == nil)
        #expect(SyncEngine.parseInviteCode(from: WidgetDeepLink.calendar(day("2026-11-15")).url) == nil)
        #expect(SyncEngine.parseInviteCode(from: URL(string: "daydo://invite/abc123")!) == "abc123")
    }

    @Test func todayDataOrdersOverdueFirstAndRollsOverAtMidnight() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daydo-widget-today-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = day("2026-11-15").date(minute: 17 * 60, in: taipei)
        let clock = Clock.fixed(now, timeZone: taipei)

        do {
            let store = try DayDoStorage.openForApp(in: dir, clock: clock)
            try await store.bootstrap()
            _ = try await store.api.createTask(CreateTaskInput(
                title: "Yesterday task",
                start: "2026-11-14T17:00:00+0800",
                timeZone: "Asia/Taipei"
            ))
            _ = try await store.api.createTask(CreateTaskInput(
                title: "Today meeting",
                start: "2026-11-15T18:00:00+0800",
                due: "2026-11-15T18:30:00+0800",
                timeZone: "Asia/Taipei"
            ))
            _ = try await store.api.createTask(CreateTaskInput(
                title: "Today single all-day",
                start: "2026-11-15",
                allDay: true
            ))
            _ = try await store.api.createTask(CreateTaskInput(
                title: "Multi-day trip",
                start: "2026-11-13",
                due: "2026-11-16",
                allDay: true
            ))
            _ = try await store.api.createTask(CreateTaskInput(
                title: "Tomorrow task",
                start: "2026-11-16T09:00:00+0800",
                timeZone: "Asia/Taipei"
            ))
        }

        let readAPI = try DayDoStorage.openReadOnly(in: dir, clock: clock)
        let entries = try await WidgetTodayData.loadTimeline(from: readAPI, now: now, timeZone: taipei)
        #expect(entries.count == 2)

        let todaySnap = entries[0].data
        #expect(todaySnap.today == day("2026-11-15"))
        #expect(todaySnap.totalCount == 4)
        #expect(todaySnap.overdueItems.map(\.task.title) == ["Yesterday task"])
        #expect(todaySnap.overdueItems.first?.timeLabel == "逾期")
        #expect(todaySnap.todayItems.first(where: { $0.task.title == "Today meeting" })?.timeLabel == "18:00")
        #expect(todaySnap.todayItems.first(where: { $0.task.title == "Multi-day trip" })?.timeLabel == "全天")
        #expect(todaySnap.todayItems.first(where: { $0.task.title == "Today single all-day" })?.timeLabel == "")

        // At midnight 2026-11-16 00:00, unfinished Nov 15 tasks become overdue and Tomorrow task moves to today.
        let midnightSnap = entries[1]
        #expect(midnightSnap.date == day("2026-11-16").date(minute: 0, in: taipei))
        #expect(midnightSnap.data.today == day("2026-11-16"))
        #expect(midnightSnap.data.overdueItems.count == 3)
        #expect(midnightSnap.data.todayItems.map(\.task.title).contains("Multi-day trip"))
        #expect(midnightSnap.data.todayItems.map(\.task.title).contains("Tomorrow task"))
    }

    @Test func nextDataSelectsUpcomingOngoingAndTimelineBoundaries() {
        let today = day("2026-11-15")
        let projects = [
            "work": makeProject("work", name: "工作", color: "#4AA8E8"),
            "ours": makeProject("ours", name: "我們的行程", color: "#E8C14E"),
            "life": makeProject("life", name: "個人", color: "#E98A5B"),
        ]
        let tasks = [
            makeTask("trip", title: "花蓮小旅行", projectId: "ours", schedule: .allDay(day("2026-11-13"), through: day("2026-11-16"))),
            makeTask("brief", title: "產品會議簡報", projectId: "work", schedule: .timed(today, start: 1080, end: 1110, timeZone: "Asia/Taipei")),
            makeTask("dinner", title: "巷口火鍋", projectId: "ours", schedule: .timed(today, start: 1140, end: 1260, timeZone: "Asia/Taipei")),
            makeTask("gym", title: "健身房", projectId: "life", schedule: .timed(today, start: 1170, end: 1230, timeZone: "Asia/Taipei")),
            makeTask("done", title: "已完成", projectId: "work", status: 2, schedule: .timed(today, start: 1050, end: 1070, timeZone: "Asia/Taipei")),
        ]

        // At 17:30 -> 18:00 brief is upcoming, window is 17:00-22:00
        let t1730 = today.date(minute: 17 * 60 + 30, in: taipei)
        let s1 = WidgetNextData.build(tasks: tasks, projectsById: projects, now: t1730, timeZone: taipei)
        #expect(s1.currentOrNext?.task.id == "brief")
        #expect(s1.currentOrNext?.isOngoing == false)
        #expect(s1.after.map(\.task.id) == ["dinner", "gym"])
        #expect(s1.allDayToday.map(\.displayTitle) == ["花蓮小旅行 3/4"])
        #expect(s1.windowStartHour == 17 && s1.windowEndHour == 22)
        #expect(s1.timelineBlocks.count == 3)
        #expect(s1.timelineBlocks.first(where: { $0.task.id == "brief" })?.isPrimary == true)

        // At 18:10 -> 18:00-18:30 brief is ongoing
        let t1810 = today.date(minute: 18 * 60 + 10, in: taipei)
        let s2 = WidgetNextData.build(tasks: tasks, projectsById: projects, now: t1810, timeZone: taipei)
        #expect(s2.currentOrNext?.task.id == "brief")
        #expect(s2.currentOrNext?.isOngoing == true)

        // At 18:30 -> brief ended, dinner becomes currentOrNext
        let t1830 = today.date(minute: 18 * 60 + 30, in: taipei)
        let s3 = WidgetNextData.build(tasks: tasks, projectsById: projects, now: t1830, timeZone: taipei)
        #expect(s3.currentOrNext?.task.id == "dinner")
        #expect(s3.after.map(\.task.id) == ["gym"])

        // Timeline boundary dates from 17:30 include start/end of brief, dinner, gym + midnight
        let boundaries = WidgetNextData.timelineDates(tasks: tasks, from: t1730, timeZone: taipei)
        #expect(boundaries.contains(today.date(minute: 1080, in: taipei)))
        #expect(boundaries.contains(today.date(minute: 1110, in: taipei)))
        #expect(boundaries.contains(today.date(minute: 1140, in: taipei)))
        #expect(boundaries.contains(today.date(minute: 1170, in: taipei)))
        #expect(boundaries.contains(today.date(minute: 1230, in: taipei)))
        #expect(boundaries.contains(today.date(minute: 1260, in: taipei)))
        #expect(boundaries.last == today.adding(days: 1).date(minute: 0, in: taipei))
    }

    @Test func nextTimelineMidnightRespectsDSTWallClock() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let springForward = day("2026-03-08")
        let noonLA = springForward.date(minute: 12 * 60, in: la)
        let dates = WidgetNextData.timelineDates(tasks: [], from: noonLA, timeZone: la)
        #expect(dates.count == 2)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = la
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: dates[1])
        #expect(comps.year == 2026 && comps.month == 3 && comps.day == 9 && comps.hour == 0 && comps.minute == 0)
    }

    @Test func calendarDataBuildsTwoWeeksAcrossMonthBoundaryAndAdaptiveLanes() {
        let nov29 = day("2026-11-29")
        let projects = ["ours": makeProject("ours", name: "我們的行程", color: "#E8C14E")]
        let tasks = [
            makeTask("trip", title: "跨月旅行", projectId: "ours", schedule: .allDay(day("2026-11-29"), through: day("2026-12-08"))),
            makeTask("done", title: "已完成", projectId: "ours", status: 2, schedule: .allDay(nov29)),
            makeTask("active", title: "進行中", projectId: "ours", status: 0, schedule: .allDay(nov29)),
        ]
        let calData = WidgetCalendarData.build(tasks: tasks, projectsById: projects, today: nov29)
        // Two-week layout starts Nov 29 (Sunday) and ends Dec 12 (Saturday)
        #expect(calData.twoWeekLayout.weeks.count == 2)
        #expect(calData.twoWeekLayout.weeks[0].days.first == day("2026-11-29"))
        #expect(calData.twoWeekLayout.weeks[1].days.last == day("2026-12-12"))
        // Lane 0 has 跨月旅行, Lane 1 has active (active prioritized over completed), completed overflows
        #expect(calData.twoWeekLayout.weeks[0].bars.map(\.task.id) == ["trip", "active"])
        #expect(calData.twoWeekLayout.weeks[0].overflow[0] == 1)

        // August 2026 has 6 weeks -> monthMaxLanes drops to 2
        let aug = WidgetCalendarData.build(tasks: [], projectsById: projects, today: day("2026-08-15"))
        #expect(aug.monthLayout.weeks.count == 6)
        #expect(aug.month == day("2026-08-01"))
    }

    @Test func calendarDataExcludesCompletedTasksWhenHidden() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daydo-widget-cal-hide-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let nov15 = day("2026-11-15")
        let now = nov15.date(minute: 12 * 60, in: taipei)
        let clock = Clock.fixed(now, timeZone: taipei)

        do {
            let store = try DayDoStorage.openForApp(in: dir, clock: clock)
            try await store.bootstrap()
            // Nov 11: only a completed task -> dot disappears when hidden.
            let doneOnly = try await store.api.createTask(CreateTaskInput(
                title: "已完成事件",
                start: "2026-11-11",
                allDay: true
            ))
            _ = try await store.api.completeTask(id: doneOnly.id)
            // Nov 15: 2 active + 2 completed -> with maxLanes=2 in twoWeekLayout,
            // completed tasks cause +2 overflow when shown and 0 overflow when hidden.
            _ = try await store.api.createTask(CreateTaskInput(title: "未完成 A", start: "2026-11-15", allDay: true))
            _ = try await store.api.createTask(CreateTaskInput(title: "未完成 B", start: "2026-11-15", allDay: true))
            let done1 = try await store.api.createTask(CreateTaskInput(title: "已完成 C", start: "2026-11-15", allDay: true))
            _ = try await store.api.completeTask(id: done1.id)
            let done2 = try await store.api.createTask(CreateTaskInput(title: "已完成 D", start: "2026-11-15", allDay: true))
            _ = try await store.api.completeTask(id: done2.id)
        }

        let readAPI = try DayDoStorage.openReadOnly(in: dir, clock: clock)

        let shown = try #require(
            try await WidgetCalendarData.loadTimeline(from: readAPI, now: now, timeZone: taipei, includeCompleted: true).first?.data
        )
        #expect(shown.daysWithEvents.contains(day("2026-11-11")))
        #expect(shown.twoWeekLayout.weeks[0].overflow[0] == 2)
        #expect(shown.monthLayout.weeks[1].bars.contains(where: { $0.task.title == "已完成事件" }))
        #expect(shown.monthLayout.weeks[2].overflow[0] == 1)

        let hidden = try #require(
            try await WidgetCalendarData.loadTimeline(from: readAPI, now: now, timeZone: taipei, includeCompleted: false).first?.data
        )
        #expect(!hidden.daysWithEvents.contains(day("2026-11-11")))
        #expect(hidden.daysWithEvents.contains(day("2026-11-15")))
        #expect(hidden.twoWeekLayout.weeks[0].overflow[0] == nil)
        #expect(hidden.twoWeekLayout.weeks[0].bars.map(\.task.title).sorted() == ["未完成 A", "未完成 B"])
        #expect(!hidden.monthLayout.weeks[1].bars.contains(where: { $0.task.title == "已完成事件" }))
        #expect(hidden.monthLayout.weeks[2].overflow[0] == nil)
        #expect(hidden.monthLayout.weeks[2].bars.allSatisfy { !$0.task.isCompleted })
    }
}
}
