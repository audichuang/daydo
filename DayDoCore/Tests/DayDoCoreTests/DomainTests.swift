import Foundation
import Testing
@testable import DayDoCore

let taipei = TimeZone(identifier: "Asia/Taipei")!
func day(_ s: String) -> LocalDay { LocalDay(s)! }

@Suite struct SortKeyTests {
    @Test func betweenIsOrdered() {
        var keys: [String] = [SortKey.after(nil)]
        for _ in 0..<50 { keys.append(SortKey.after(keys.last)) }
        for _ in 0..<50 { keys.insert(SortKey.before(keys.first), at: 0) }
        #expect(keys == keys.sorted())
        var a = "a", b = "b"
        for _ in 0..<40 {
            let m = SortKey.between(a, b)
            #expect(a < m && m < b)
            b = m
        }
        a = "a5"; b = "b"
        let m = SortKey.between(a, b)
        #expect(a < m && m < b)
    }
}

@Suite struct ScheduleTests {
    @Test func parsesTickTickStyleISO() throws {
        let s = try #require(try Schedule.fromAPI(start: "2026-11-15T18:00:00+0800", due: "2026-11-15T18:30:00+0800", allDay: nil, timeZone: "Asia/Taipei"))
        #expect(s.startDay == day("2026-11-15"))
        #expect(s.startMinute == 1080)
        #expect(s.durationMinutes == 30)
        #expect(s.apiStart == "2026-11-15T18:00:00+08:00")
        #expect(s.apiDue == "2026-11-15T18:30:00+08:00")
    }

    @Test func convertsOffsetIntoZone() throws {
        let s = try #require(try Schedule.fromAPI(start: "2026-11-15T10:00:00Z", due: nil, allDay: nil, timeZone: "Asia/Taipei"))
        #expect(s.startMinute == 18 * 60)
        #expect(s.endDay == nil)
    }

    @Test func wallClockWithoutOffsetIsFloating() throws {
        let s = try #require(try Schedule.fromAPI(start: "2026-11-15T09:30", due: nil, allDay: nil, timeZone: nil))
        #expect(s.timeZone == nil)
        #expect(s.startMinute == 570)
    }

    @Test func allDayMultiDay() throws {
        let s = try #require(try Schedule.fromAPI(start: "2026-11-13", due: "2026-11-16", allDay: nil, timeZone: nil))
        #expect(s.isAllDay)
        #expect(s.dayPosition(on: day("2026-11-15"))! == (3, 4))
        #expect(s.occurs(on: day("2026-11-16")))
        #expect(!s.occurs(on: day("2026-11-17")))
        #expect(DateText.taskLine(s, today: day("2026-11-15")) == "全天・第 3/4 天")
        #expect(DateText.taskLine(s, today: day("2026-11-10")) == "11 月 13 日 起・4 天")
        #expect(DateText.taskLine(s, on: day("2026-11-13"), today: day("2026-11-10")) == "全天・第 1/4 天")
    }

    @Test func crossMidnightBlock() {
        let s = Schedule.timed(day("2026-11-15"), start: 1410, end: 30)
        #expect(s.endDay == day("2026-11-16"))
        #expect(s.crossesMidnight)
        #expect(s.durationMinutes == 60)
        #expect(DateText.range(s) == "23:30 – 隔日 00:30")
        #expect(s.lastDay == day("2026-11-16"))
        // Ending exactly at midnight stays on the first day.
        let m = Schedule.timed(day("2026-11-15"), start: 1380, end: 0)
        #expect(m.lastDay == day("2026-11-15"))
    }

    @Test func rejectsEndBeforeStart() {
        #expect(throws: ScheduleError.endBeforeStart) {
            _ = try Schedule.fromAPI(start: "2026-11-15T18:00", due: "2026-11-15T17:00", allDay: nil, timeZone: nil)
        }
    }

    @Test func taskLines() {
        let today = day("2026-11-15")
        #expect(DateText.taskLine(.timed(today, start: 1080, end: 1110), today: today) == "18:00 – 18:30")
        #expect(DateText.taskLine(.timed(today.adding(days: 1), start: 600, end: 660), today: today) == "明天 10:00 – 11:00")
        #expect(DateText.taskLine(.timed(today.adding(days: -1), start: 1020, end: nil), today: today) == "昨天 17:00")
        #expect(DateText.taskLine(.allDay(today), today: today) == "")
        #expect(DateText.taskLine(.allDay(today), on: today, today: today) == "全天")
    }

    @Test func countdownLabels() {
        let today = day("2026-11-18")
        // Future start
        #expect(DateText.countdownLabel(.allDay(today.adding(days: 1)), today: today) == "明天")
        #expect(DateText.countdownLabel(.timed(today.adding(days: 1), start: 540, end: 600), today: today) == "明天")
        #expect(DateText.countdownLabel(.allDay(today.adding(days: 5)), today: today) == "還有 5 天")
        #expect(DateText.countdownLabel(.allDay(today.adding(days: 5), through: today.adding(days: 8)), today: today) == "還有 5 天")

        // Today single-day (all-day & timed)
        #expect(DateText.countdownLabel(.allDay(today), today: today) == "今天")
        #expect(DateText.countdownLabel(.timed(today, start: 60, end: 120), today: today) == "今天")
        #expect(DateText.countdownLabel(.timed(today, start: 1380, end: nil), today: today) == "今天")

        // Cross-midnight timed block (23:00–01:00 next day): not an all-day multi-day trip
        let crossMidnight = Schedule.timed(today, start: 23 * 60, end: 1 * 60)
        #expect(DateText.countdownLabel(crossMidnight, today: today.adding(days: -1)) == "明天")
        #expect(DateText.countdownLabel(crossMidnight, today: today) == "今天")
        #expect(DateText.countdownLabel(crossMidnight, today: today.adding(days: 1)) == "今天")
        #expect(DateText.countdownLabel(crossMidnight, today: today.adding(days: 2)) == nil)

        // Multi-day ongoing (5-day trip: Nov 16 .. Nov 20)
        let trip = Schedule.allDay(day("2026-11-16"), through: day("2026-11-20"))
        #expect(DateText.countdownLabel(trip, today: day("2026-11-16")) == "還剩 5 天")
        #expect(DateText.countdownLabel(trip, today: day("2026-11-18")) == "還剩 3 天")
        #expect(DateText.countdownLabel(trip, today: day("2026-11-19")) == "還剩 2 天")
        #expect(DateText.countdownLabel(trip, today: day("2026-11-20")) == "最後一天")

        // Past
        #expect(DateText.countdownLabel(.allDay(today.adding(days: -1)), today: today) == nil)
        #expect(DateText.countdownLabel(trip, today: day("2026-11-21")) == nil)

        // Task wrapper checks countdown, completion, deletedAt, schedule, and repeating current schedule
        func makeTask(status: Int = 0, schedule: Schedule? = .allDay(today.adding(days: 3)), countdown: Bool = true, deletedAt: EpochMillis? = nil, repeatRule: String? = "RRULE:FREQ=WEEKLY") -> TodoTask {
            TodoTask(
                id: "t1", projectId: "p1", title: "Test", content: "", priority: .none, status: status,
                schedule: schedule, start: nil, due: nil, allDay: schedule?.isAllDay ?? false, timeZone: nil,
                reminders: [], repeat: repeatRule, tags: [], items: [], assigneeId: nil,
                sortKey: "a0", completedAt: status == 2 ? 1000 : nil, createdAt: 1000, updatedAt: 1000,
                deletedAt: deletedAt, attachments: [], commentCount: 0, sourceRaw: nil, importNote: nil,
                countdown: countdown
            )
        }
        #expect(DateText.countdownLabel(for: makeTask(), today: today) == "還有 3 天")
        #expect(DateText.countdownLabel(for: makeTask(countdown: false), today: today) == nil)
        #expect(DateText.countdownLabel(for: makeTask(status: 2), today: today) == nil)
        #expect(DateText.countdownLabel(for: makeTask(deletedAt: 2000), today: today) == nil)
        #expect(DateText.countdownLabel(for: makeTask(schedule: nil), today: today) == nil)
    }
}

@Suite struct ReminderAndRecurrenceTests {
    @Test func triggers() {
        #expect(Reminder(trigger: "TRIGGER:-PT15M")?.offsetSeconds == -900)
        #expect(Reminder(trigger: "TRIGGER:PT0S")?.offsetSeconds == 0)
        #expect(Reminder(trigger: "TRIGGER:-P1D")?.offsetSeconds == -86400)
        #expect(Reminder(trigger: "TRIGGER:P0DT9H0M0S")?.offsetSeconds == 32400)
        #expect(Reminder(trigger: "nonsense") == nil)
        #expect(Reminder(offsetSeconds: -900).trigger == "TRIGGER:-PT15M")
        #expect(Reminder(offsetSeconds: -900).label(allDay: false) == "提前 15 分鐘")
        #expect(Reminder(offsetSeconds: -3600).label(allDay: false) == "提前 1 小時")
        #expect(Reminder(offsetSeconds: 0).label(allDay: false) == "準時")
        #expect(Reminder(offsetSeconds: 32400).label(allDay: true) == "當天 09:00")
    }

    @Test func dstSpringForwardPreservesWallClock() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let springForward = day("2026-03-08")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = la

        let nineAM = springForward.date(minute: 9 * 60, in: la)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: nineAM)
        #expect(comps.year == 2026 && comps.month == 3 && comps.day == 8 && comps.hour == 9 && comps.minute == 0)

        let allDaySched = Schedule(startDay: springForward, timeZone: "America/Los_Angeles")
        let fire = Reminder(offsetSeconds: 9 * 3600).fireDate(for: allDaySched)
        let fireComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        #expect(fireComps.year == 2026 && fireComps.month == 3 && fireComps.day == 8 && fireComps.hour == 9 && fireComps.minute == 0)
    }

    @Test func nextOccurrences() {
        let sun = day("2026-11-15")
        #expect(sun.weekday == 0)
        #expect(Recurrence(rrule: "RRULE:FREQ=DAILY")!.next(after: sun) == day("2026-11-16"))
        let weekdays = Recurrence(rrule: "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")!
        #expect(weekdays.next(after: day("2026-11-13")) == day("2026-11-16")) // Fri → Mon
        #expect(weekdays.label(anchor: sun) == "平日")
        #expect(Recurrence(rrule: "RRULE:FREQ=MONTHLY;BYMONTHDAY=31")!.next(after: day("2027-01-31")) == day("2027-03-31"))
        #expect(Recurrence(rrule: "RRULE:FREQ=YEARLY")!.next(after: day("2028-02-29")) == day("2032-02-29"))
        #expect(Recurrence(frequency: .weekly, byWeekday: [0]).label(anchor: sun) == "每週日")
    }
}

@Suite struct LayoutTests {
    func task(_ id: String, _ s: Schedule) -> TodoTask {
        TodoTask(id: id, projectId: "p", title: id, content: "", priority: .none, status: 0, schedule: s, start: nil, due: nil, allDay: s.isAllDay,
                 timeZone: nil, reminders: [], repeat: nil, tags: [], items: [], assigneeId: nil, sortKey: id, completedAt: nil,
                 createdAt: 0, updatedAt: 0, deletedAt: nil, attachments: [], commentCount: 0, sourceRaw: nil, importNote: nil)
    }

    @Test func monthGridIsSundayFirst() {
        let g = MonthLayout.gridDays(for: day("2026-11-01"))
        #expect(g.first == day("2026-11-01"))
        #expect(g.count == 35)
        #expect(g.last == day("2026-12-05"))
    }

    @Test func barsSplitAcrossWeeksAndOverflow() {
        let trip = task("trip", .allDay(day("2026-11-13"), through: day("2026-11-16")))
        var tasks = [trip]
        for i in 0..<4 { tasks.append(task("t\(i)", .timed(day("2026-11-15"), start: 600 + i * 60, end: 630 + i * 60))) }
        let layout = MonthLayout(month: day("2026-11-01"), tasks: tasks)
        let w2 = layout.weeks[1], w3 = layout.weeks[2]
        #expect(w2.bars.first { $0.task.id == "trip" }.map { ($0.startColumn, $0.endColumn, $0.continues) }! == (5, 6, false))
        let cont = w3.bars.first { $0.task.id == "trip" }!
        #expect(cont.continues && cont.startColumn == 0 && cont.endColumn == 1 && cont.lane == 0)
        #expect(w3.bars.filter { $0.startColumn == 0 }.count == 3)
        #expect(w3.overflow[0] == 2)
    }

    @Test func todaySections() {
        let today = day("2026-11-15")
        let tasks = [
            task("over", .timed(today.adding(days: -1), start: 1020, end: nil)),
            task("late", .timed(today, start: 1080, end: 1110)),
            task("allday", .allDay(today)),
            task("tmr", .allDay(today.adding(days: 1))),
        ]
        let s = TaskGrouping.sections(for: .smart(.today), tasks: tasks, completed: [], today: today)
        #expect(s.map(\.id) == ["overdue", "today", "tomorrow"])
        #expect(s[1].tasks.map(\.id) == ["allday", "late"])
    }

    @Test func calendarDayTasksClipsCrossMidnightAndPlacesCompletedLast() {
        let d0 = day("2026-11-15")
        let d1 = day("2026-11-16")
        var done = task("done", .allDay(d1))
        done.status = 2
        let tasks = [
            done,
            task("morning", .timed(d1, start: 480, end: 540)),
            task("overnight", .timed(d0, start: 1410, end: 30)),
            task("early", .timed(d0, start: 600, end: 630)),
            task("allday", .allDay(d1)),
        ]
        #expect(TaskGrouping.calendarDayTasks(tasks, on: d0).map(\.id) == ["early", "overnight"])
        // On d1: all-day first, then overnight continuation (00:00), then morning (08:00), then completed.
        #expect(TaskGrouping.calendarDayTasks(tasks, on: d1).map(\.id) == ["allday", "overnight", "morning", "done"])
        #expect(DayLayout.clippedRange(for: tasks[2].schedule!, on: d1)?.start == 0)
    }
}

@Suite struct DayLayoutTests {
    func task(_ id: String, _ s: Schedule) -> TodoTask { LayoutTests().task(id, s) }

    @Test func overlapsGoSideBySide() {
        let d = day("2026-11-15")
        let blocks = DayLayout.blocks(for: [
            task("a", .timed(d, start: 1080, end: 1110)),
            task("b", .timed(d, start: 1140, end: 1260)),
            task("c", .timed(d, start: 1170, end: 1230)),
            task("all", .allDay(d)),
        ], on: d)
        #expect(blocks.map(\.task.id) == ["a", "b", "c"])
        #expect(blocks[0].lanes == 1)
        #expect(blocks[1].lane == 0 && blocks[2].lane == 1 && blocks[2].lanes == 2)
    }

    @Test func crossMidnightIsClippedPerDay() {
        let d = day("2026-11-15")
        let t = task("late", .timed(d, start: 1410, end: 30))
        #expect(DayLayout.blocks(for: [t], on: d).map { [$0.start, $0.end] } == [[1410, 1440]])
        #expect(DayLayout.blocks(for: [t], on: d.adding(days: 1)).map { [$0.start, $0.end] } == [[0, 30]])
    }
}

@Suite struct MemberFilterTests {
    private func member(_ id: String, _ name: String, isMe: Bool = false) -> Member {
        Member(id: id, name: name, initial: String(name.prefix(1)), color: Member.avatarColors[0], isMe: isMe)
    }

    private func project(_ id: String, memberIds: [String], archived: Bool = false) -> Project {
        Project(
            id: id,
            name: id,
            viewMode: "list",
            kind: "TASK",
            isInbox: false,
            ownerId: memberIds.first ?? "me",
            sortKey: "a",
            showInSmart: "all",
            notifyMode: "all",
            archived: archived,
            memberIds: memberIds,
            activeCount: 0,
            createdAt: 0,
            updatedAt: 0
        )
    }

    @Test func meOnly() {
        let me = member("me", "我", isMe: true)
        let result = MemberFilter.filterableMembers(
            members: [me],
            projects: [project("inbox", memberIds: ["me"])]
        )
        #expect(result.map(\.id) == ["me"])
    }

    @Test func partnerInSharedLiveListIncludedWithMeFirst() {
        let me = member("me", "我", isMe: true)
        let partner = member("p1", "小安")
        let partner2 = member("p2", "阿明")
        let result = MemberFilter.filterableMembers(
            members: [partner, partner2, me],
            projects: [project("shared", memberIds: ["me", "p1", "p2"])]
        )
        #expect(result.map(\.id) == ["me", "p1", "p2"])
    }

    @Test func partnerOnlyInArchivedListExcluded() {
        let me = member("me", "我", isMe: true)
        let partner = member("p1", "小安")
        let result = MemberFilter.filterableMembers(
            members: [me, partner],
            projects: [
                project("inbox", memberIds: ["me"]),
                project("old-shared", memberIds: ["me", "p1"], archived: true),
            ]
        )
        #expect(result.map(\.id) == ["me"])
    }

    @Test func partnerInNoListExcluded() {
        let me = member("me", "我", isMe: true)
        let partner = member("p1", "小安")
        let result = MemberFilter.filterableMembers(
            members: [me, partner],
            projects: [project("inbox", memberIds: ["me"])]
        )
        #expect(result.map(\.id) == ["me"])
    }

    @Test func effectiveFilterRequiresMultipleFilterableMembersAndMembership() {
        let me = member("me", "我", isMe: true)
        let partner = member("p1", "小安")
        #expect(MemberFilter.effectiveFilter(me.id, among: [me]) == nil)
        #expect(MemberFilter.effectiveFilter(partner.id, among: [me]) == nil)
        #expect(MemberFilter.effectiveFilter(partner.id, among: [me, partner]) == partner.id)
        #expect(MemberFilter.effectiveFilter("unknown", among: [me, partner]) == nil)
        #expect(MemberFilter.effectiveFilter(nil, among: [me, partner]) == nil)
    }
}
