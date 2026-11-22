import Foundation
import Testing
@testable import DayDoCore

@Suite struct CalendarProjectionTests {
    private func makeTask(
        _ id: String,
        projectId: String = "p1",
        schedule: Schedule?,
        completed: Bool = false
    ) -> TodoTask {
        TodoTask(
            id: id,
            projectId: projectId,
            title: id,
            content: "",
            priority: .none,
            status: completed ? 2 : 0,
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
            sortKey: id,
            completedAt: completed ? 1000 : nil,
            createdAt: 0,
            updatedAt: 0,
            deletedAt: nil,
            attachments: [],
            commentCount: 0,
            sourceRaw: nil,
            importNote: nil
        )
    }

    // MARK: - LocalDay.startOfWeek

    @Test func startOfWeekForEachWeekday() {
        // 2026-11-15 is Sunday (weekday 0) through 2026-11-21 Saturday (weekday 6).
        let sunday = day("2026-11-15")
        #expect(sunday.weekday == 0)
        for offset in 0..<7 {
            let d = sunday.adding(days: offset)
            #expect(d.weekday == offset)
            #expect(d.startOfWeek == sunday)
            #expect(d.startOfWeek == d.adding(days: -d.weekday))
        }
        // Crossing month and year boundaries backwards to Sunday.
        // 2026-01-01 is Thursday (weekday 4) -> Sunday 2025-12-28.
        #expect(day("2026-01-01").startOfWeek == day("2025-12-28"))
        // 2026-03-01 is Sunday -> stays 2026-03-01.
        #expect(day("2026-03-01").startOfWeek == day("2026-03-01"))
        // 2026-03-02 is Monday -> 2026-03-01.
        #expect(day("2026-03-02").startOfWeek == day("2026-03-01"))
    }

    // MARK: - LanePacker

    @Test func lanePackerReproducesMonthLayoutDomainTestsFixture() {
        // Exact fixture from DomainTests.barsSplitAcrossWeeksAndOverflow.
        let trip = makeTask("trip", schedule: .allDay(day("2026-11-13"), through: day("2026-11-16")))
        var tasks = [trip]
        for i in 0..<4 {
            tasks.append(makeTask("t\(i)", schedule: .timed(day("2026-11-15"), start: 600 + i * 60, end: 630 + i * 60)))
        }
        let layout = MonthLayout(month: day("2026-11-01"), tasks: tasks, maxLanes: 3)

        // Week 2 (2026-11-08...2026-11-14): only trip on cols 5...6.
        let w2Packed = LanePacker.pack([5...6], maxLanes: 3)
        #expect(w2Packed.lanes == [0])
        #expect(w2Packed.overflow.isEmpty)
        #expect(layout.weeks[1].bars.map { ($0.task.id, $0.startColumn, $0.endColumn, $0.lane, $0.continues) }
            .elementsEqual([("trip", 5, 6, 0, false)], by: ==))

        // Week 3 (2026-11-15...2026-11-21): sorted order is trip (0...1), then t0..t3 (0...0).
        let w3Packed = LanePacker.pack([0...1, 0...0, 0...0, 0...0, 0...0], maxLanes: 3)
        #expect(w3Packed.lanes == [0, 1, 2, nil, nil])
        #expect(w3Packed.overflow == [0: 2])
        #expect(layout.weeks[2].bars.map(\.task.id) == ["trip", "t0", "t1"])
        #expect(layout.weeks[2].bars.map(\.lane) == [0, 1, 2])
        #expect(layout.weeks[2].overflow == [0: 2])
    }

    @Test func lanePackerPreservesInputOrderAndUncappedLanes() {
        // Adjacent ranges share lane 0; touching endpoint overlaps into lane 1;
        // shorter range placed before longer overlapping range keeps input order (lane 0 vs lane 1).
        let packed = LanePacker.pack([0...0, 0...3, 1...2, 3...4, 0...0, 0...0])
        #expect(packed.lanes == [0, 1, 0, 0, 2, 3])
        #expect(packed.overflow.isEmpty)

        // maxLanes: 0 overflows all ranges across every covered column.
        let zeroCap = LanePacker.pack([0...2, 1...3], maxLanes: 0)
        #expect(zeroCap.lanes == [nil, nil])
        #expect(zeroCap.overflow == [0: 1, 1: 2, 2: 2, 3: 1])

        // Empty input produces empty result.
        let empty = LanePacker.pack([], maxLanes: 3)
        #expect(empty.lanes.isEmpty)
        #expect(empty.overflow.isEmpty)
    }

    // MARK: - dayDotColors

    @Test func dayDotColorsIncludesCompletedWithActiveFirstCapsAtThreeAndClipsToGrid() {
        let grid = MonthLayout.gridDays(for: day("2026-11-01")) // 2026-11-01...2026-12-05
        let colors = [
            "p1": "#FF0000",
            "p2": "#00FF00",
            "p3": "#0000FF",
            "p4": "#FFFF00",
        ]
        let tasks = [
            // Completed-only day still shows its dot when completed tasks are loaded.
            makeTask("done", projectId: "p1", schedule: .allDay(day("2026-11-10")), completed: true),
            // Completed task placed before active task on Nov 12: active colour must come first.
            makeTask("done12", projectId: "p4", schedule: .allDay(day("2026-11-12")), completed: true),
            makeTask("active12", projectId: "p2", schedule: .allDay(day("2026-11-12"))),
            // Completed task placed before 5 active tasks on Nov 15: active colours win all 3 slots.
            makeTask("done15", projectId: "p4", schedule: .allDay(day("2026-11-15")), completed: true),
            makeTask("a1", projectId: "p1", schedule: .allDay(day("2026-11-15"))),
            makeTask("a2", projectId: "p1", schedule: .timed(day("2026-11-15"), start: 600, end: 660)),
            makeTask("a3", projectId: "pMissing", schedule: .allDay(day("2026-11-15"))),
            makeTask("a4", projectId: "p2", schedule: .allDay(day("2026-11-15"))),
            makeTask("a5", projectId: "p3", schedule: .allDay(day("2026-11-15"))),
            // Two completed tasks before two active tasks on Nov 16: active colours first, completed fills 3rd slot.
            makeTask("done16a", projectId: "p4", schedule: .allDay(day("2026-11-16")), completed: true),
            makeTask("done16b", projectId: "p3", schedule: .allDay(day("2026-11-16")), completed: true),
            makeTask("active16a", projectId: "p1", schedule: .allDay(day("2026-11-16"))),
            makeTask("active16b", projectId: "p2", schedule: .allDay(day("2026-11-16"))),
            // Multi-day starting before grid (Oct 30 -> Nov 2) clipped to Nov 1..Nov 2.
            makeTask("beforeGrid", projectId: "p4", schedule: .allDay(day("2026-10-30"), through: day("2026-11-02"))),
            // Multi-day extending past grid (Dec 4 -> Dec 8) clipped to Dec 4..Dec 5.
            makeTask("afterGrid", projectId: "p2", schedule: .allDay(day("2026-12-04"), through: day("2026-12-08"))),
            // Completely outside grid and unscheduled tasks are ignored.
            makeTask("outside", projectId: "p1", schedule: .allDay(day("2026-12-20"))),
            makeTask("undated", projectId: "p1", schedule: nil),
        ]

        let dots = CalendarProjection.dayDotColors(tasks: tasks, gridDays: grid, projectColors: colors)

        #expect(dots[day("2026-11-10")] == ["#FF0000"])
        #expect(dots[day("2026-11-12")] == ["#00FF00", "#FFFF00"])
        #expect(dots[day("2026-11-15")] == ["#FF0000", "#5B6461", "#00FF00"])
        #expect(dots[day("2026-11-16")] == ["#FF0000", "#00FF00", "#FFFF00"])
        #expect(dots[day("2026-10-31")] == nil)
        #expect(dots[day("2026-11-01")] == ["#FFFF00"])
        #expect(dots[day("2026-11-02")] == ["#FFFF00"])
        #expect(dots[day("2026-11-03")] == nil)
        #expect(dots[day("2026-12-04")] == ["#00FF00"])
        #expect(dots[day("2026-12-05")] == ["#00FF00"])
        #expect(dots[day("2026-12-06")] == nil)
        #expect(dots[day("2026-12-20")] == nil)

        #expect(CalendarProjection.dayDotColors(tasks: tasks, gridDays: [], projectColors: colors).isEmpty)
    }

    // MARK: - busyDays

    @Test func busyDaysIncludesCompletedAndClipsToYear() {
        let tasks = [
            makeTask("doneOnly", schedule: .allDay(day("2026-05-10")), completed: true),
            makeTask("active", schedule: .timed(day("2026-06-01"), start: 540, end: 600)),
            // Crosses start-of-year boundary: 2025-12-30...2026-01-02 -> clips to Jan 1..Jan 2.
            makeTask("prevYearSpan", schedule: .allDay(day("2025-12-30"), through: day("2026-01-02"))),
            // Crosses end-of-year boundary: 2026-12-30...2027-01-02 -> clips to Dec 30..Dec 31.
            makeTask("nextYearSpan", schedule: .allDay(day("2026-12-30"), through: day("2027-01-02"))),
            // Completely in another year or unscheduled.
            makeTask("otherYear", schedule: .allDay(day("2025-07-04"))),
            makeTask("undated", schedule: nil),
        ]

        let busy = CalendarProjection.busyDays(tasks: tasks, year: 2026)

        let expected: Set<LocalDay> = [
            day("2026-01-01"), day("2026-01-02"),
            day("2026-05-10"),
            day("2026-06-01"),
            day("2026-12-30"), day("2026-12-31"),
        ]
        #expect(busy == expected)
    }

    // MARK: - timeGridData

    @Test func timeGridDataPacksAllDayInSpanOrderOverlaysPendingMoveAndBuildsBlocks() {
        let days = [day("2026-11-15"), day("2026-11-16"), day("2026-11-17")]
        // Longer spans take upper lanes regardless of input order; equal spans tie-break by earlier start day.
        let shortFirst = makeTask("short", schedule: .allDay(day("2026-11-15")))
        let lateSpan = makeTask("lateSpan", schedule: .allDay(day("2026-11-16"), through: day("2026-11-17")))
        let earlySpan = makeTask("earlySpan", schedule: .allDay(day("2026-11-15"), through: day("2026-11-16")))
        let longSecond = makeTask("long", schedule: .allDay(day("2026-11-14"), through: day("2026-11-18")))
        // Extra all-day tasks on col 0 to confirm there is no 3-lane cap.
        let extra1 = makeTask("e1", schedule: .allDay(day("2026-11-15")))
        let extra2 = makeTask("e2", schedule: .allDay(day("2026-11-15")))
        let timed = makeTask("timed", schedule: .timed(day("2026-11-15"), start: 540, end: 600))
        let outsideAllDay = makeTask("outside", schedule: .allDay(day("2026-11-20")))

        let baseTasks = [shortFirst, lateSpan, earlySpan, longSecond, extra1, extra2, timed, outsideAllDay]
        let baseData = CalendarProjection.timeGridData(tasks: baseTasks, days: days)

        #expect(baseData.displayedTasks == baseTasks)
        #expect(baseData.allDayItems.map { ($0.task.id, $0.firstColumn, $0.lastColumn, $0.lane) }
            .elementsEqual([
                ("long", 0, 2, 0),
                ("earlySpan", 0, 1, 1),
                ("lateSpan", 1, 2, 2),
                ("short", 0, 0, 2),
                ("e1", 0, 0, 3),
                ("e2", 0, 0, 4),
            ], by: ==))
        #expect(baseData.blocksByDay.count == 3)
        #expect(baseData.blocksByDay[0].map { ($0.task.id, $0.start, $0.end) }.elementsEqual([("timed", 540, 600)], by: ==))
        #expect(baseData.blocksByDay[1].isEmpty)
        #expect(baseData.blocksByDay[2].isEmpty)

        // Pending move shifts timed task from day 0 (09:00-10:00) to day 2 (14:00-15:00).
        let movedSchedule = Schedule.timed(day("2026-11-17"), start: 840, end: 900)
        let movedData = CalendarProjection.timeGridData(
            tasks: baseTasks,
            days: days,
            pendingMove: CalendarProjection.ScheduleOverride(taskId: "timed", schedule: movedSchedule)
        )
        #expect(movedData.displayedTasks.first { $0.id == "timed" }?.schedule == movedSchedule)
        #expect(movedData.blocksByDay[0].isEmpty)
        #expect(movedData.blocksByDay[2].map { ($0.task.id, $0.start, $0.end) }.elementsEqual([("timed", 840, 900)], by: ==))

        // Empty days returns empty all-day items and blocks.
        let emptyDays = CalendarProjection.timeGridData(tasks: baseTasks, days: [])
        #expect(emptyDays.allDayItems.isEmpty)
        #expect(emptyDays.blocksByDay.isEmpty)
    }

    // MARK: - Viewport (visibleDays, queryRange, shift)

    @Test func calModeRawValuesAndDayCountStayStable() {
        #expect(CalMode.allCases.map(\.rawValue) == ["list", "year", "month", "week", "threeDay", "day"])
        #expect(CalMode.list.dayCount == 1)
        #expect(CalMode.year.dayCount == 1)
        #expect(CalMode.month.dayCount == 1)
        #expect(CalMode.week.dayCount == 7)
        #expect(CalMode.threeDay.dayCount == 3)
        #expect(CalMode.day.dayCount == 1)
    }

    @Test func viewportVisibleDaysAndQueryRangeAcrossAllModes() {
        // 2026-11-18 is Wednesday (weekday 3); its week is 2026-11-15 (Sun) ... 2026-11-21 (Sat).
        let sel = day("2026-11-18")
        let shown = day("2026-11-01")
        let novGrid = MonthLayout.gridDays(for: shown)
        let novRange = novGrid.first!...novGrid.last!

        for collapsed in [false, true] {
            let listVP = CalendarProjection.Viewport(mode: .list, selected: sel, shownMonth: shown, collapsed: collapsed)
            #expect(listVP.visibleDays.isEmpty)
            #expect(listVP.queryRange() == novRange)
            #expect(listVP.queryRange(monthGridDays: novGrid) == novRange)
        }

        let monthVP = CalendarProjection.Viewport(mode: .month, selected: sel, shownMonth: shown)
        #expect(monthVP.visibleDays.isEmpty)
        #expect(monthVP.queryRange() == novRange)

        let yearVP = CalendarProjection.Viewport(mode: .year, selected: day("2025-03-05"), shownMonth: shown)
        #expect(yearVP.visibleDays.isEmpty)
        #expect(yearVP.queryRange() == day("2026-01-01")...day("2026-12-31"))

        let weekVP = CalendarProjection.Viewport(mode: .week, selected: sel, shownMonth: shown)
        #expect(weekVP.visibleDays == (0..<7).map { day("2026-11-15").adding(days: $0) })
        #expect(weekVP.queryRange() == day("2026-11-15")...day("2026-11-21"))

        let threeDayVP = CalendarProjection.Viewport(mode: .threeDay, selected: sel, shownMonth: shown)
        #expect(threeDayVP.visibleDays == [day("2026-11-18"), day("2026-11-19"), day("2026-11-20")])
        #expect(threeDayVP.queryRange() == day("2026-11-18")...day("2026-11-20"))

        let dayVP = CalendarProjection.Viewport(mode: .day, selected: sel, shownMonth: shown)
        #expect(dayVP.visibleDays == [sel])
        #expect(dayVP.queryRange() == sel...sel)
    }

    @Test func viewportShiftAcrossAllModes() {
        // List collapsed: shifts selected by ±7 days and updates shownMonth to selected.firstOfMonth.
        let listCollapsed = CalendarProjection.Viewport(
            mode: .list,
            selected: day("2026-11-28"),
            shownMonth: day("2026-11-01"),
            collapsed: true
        )
        let lcNext = listCollapsed.shifted(by: 1)
        #expect(lcNext.selected == day("2026-12-05"))
        #expect(lcNext.shownMonth == day("2026-12-01"))
        let lcPrev = listCollapsed.shifted(by: -1)
        #expect(lcPrev.selected == day("2026-11-21"))
        #expect(lcPrev.shownMonth == day("2026-11-01"))

        // List expanded: shifts shownMonth by ±1 month and sets selected = shownMonth.
        let listExpanded = CalendarProjection.Viewport(
            mode: .list,
            selected: day("2026-11-18"),
            shownMonth: day("2026-11-01"),
            collapsed: false
        )
        let leNext = listExpanded.shifted(by: 1)
        #expect(leNext.shownMonth == day("2026-12-01"))
        #expect(leNext.selected == day("2026-12-01"))
        let lePrev = listExpanded.shifted(by: -1)
        #expect(lePrev.shownMonth == day("2026-10-01"))
        #expect(lePrev.selected == day("2026-10-01"))

        // Month (even when collapsed == true): shifts shownMonth by ±1 month and sets selected = shownMonth.
        let monthVP = CalendarProjection.Viewport(
            mode: .month,
            selected: day("2026-11-18"),
            shownMonth: day("2026-11-01"),
            collapsed: true
        )
        let mNext = monthVP.shifted(by: 1)
        #expect(mNext.shownMonth == day("2026-12-01"))
        #expect(mNext.selected == day("2026-12-01"))
        let mPrev = monthVP.shifted(by: -1)
        #expect(mPrev.shownMonth == day("2026-10-01"))
        #expect(mPrev.selected == day("2026-10-01"))

        // Year: shifts shownMonth by ±12 months and leaves selected untouched.
        let yearVP = CalendarProjection.Viewport(
            mode: .year,
            selected: day("2026-11-18"),
            shownMonth: day("2026-11-01")
        )
        let yNext = yearVP.shifted(by: 1)
        #expect(yNext.shownMonth == day("2027-11-01"))
        #expect(yNext.selected == day("2026-11-18"))
        let yPrev = yearVP.shifted(by: -1)
        #expect(yPrev.shownMonth == day("2025-11-01"))
        #expect(yPrev.selected == day("2026-11-18"))

        // Week: shifts selected by ±7 days and updates shownMonth.
        let weekVP = CalendarProjection.Viewport(
            mode: .week,
            selected: day("2026-11-28"),
            shownMonth: day("2026-11-01")
        )
        let wNext = weekVP.shifted(by: 1)
        #expect(wNext.selected == day("2026-12-05"))
        #expect(wNext.shownMonth == day("2026-12-01"))
        let wPrev = weekVP.shifted(by: -1)
        #expect(wPrev.selected == day("2026-11-21"))
        #expect(wPrev.shownMonth == day("2026-11-01"))

        // ThreeDay: shifts selected by ±3 days and updates shownMonth.
        let threeDayVP = CalendarProjection.Viewport(
            mode: .threeDay,
            selected: day("2026-11-29"),
            shownMonth: day("2026-11-01")
        )
        let tdNext = threeDayVP.shifted(by: 1)
        #expect(tdNext.selected == day("2026-12-02"))
        #expect(tdNext.shownMonth == day("2026-12-01"))
        let tdPrev = threeDayVP.shifted(by: -1)
        #expect(tdPrev.selected == day("2026-11-26"))
        #expect(tdPrev.shownMonth == day("2026-11-01"))

        // Day: shifts selected by ±1 day and updates shownMonth.
        let dayVP = CalendarProjection.Viewport(
            mode: .day,
            selected: day("2026-12-01"),
            shownMonth: day("2026-12-01")
        )
        let dNext = dayVP.shifted(by: 1)
        #expect(dNext.selected == day("2026-12-02"))
        #expect(dNext.shownMonth == day("2026-12-01"))
        let dPrev = dayVP.shifted(by: -1)
        #expect(dPrev.selected == day("2026-11-30"))
        #expect(dPrev.shownMonth == day("2026-11-01"))
    }
}
