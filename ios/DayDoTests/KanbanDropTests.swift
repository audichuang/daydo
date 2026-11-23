import SwiftUI
import XCTest
import DayDoCore
@testable import DayDo

final class KanbanDropTests: XCTestCase {
    private let today = LocalDay(year: 2026, month: 11, day: 24)

    private func makeTask(
        id: String = "t1",
        schedule: Schedule? = nil,
        status: Int = 0,
        reminders: [String] = [],
        repeatRule: String? = nil
    ) -> TodoTask {
        TodoTask(
            id: id,
            projectId: "p1",
            title: "測試任務",
            content: "",
            priority: .none,
            status: status,
            schedule: schedule,
            start: nil,
            due: nil,
            allDay: schedule?.isAllDay ?? false,
            timeZone: schedule?.timeZone,
            reminders: reminders,
            repeat: repeatRule,
            tags: [],
            items: [],
            assigneeId: nil,
            sortKey: "a0",
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

    func testAcceptsDropsOnlyForSingleMeaningTargets() {
        XCTAssertTrue(KanbanDrop.acceptsDrops(sectionKind: .today))
        XCTAssertTrue(KanbanDrop.acceptsDrops(sectionKind: .tomorrow))
        XCTAssertTrue(KanbanDrop.acceptsDrops(sectionKind: .noDate))
        XCTAssertTrue(KanbanDrop.acceptsDrops(sectionKind: .completed))

        XCTAssertFalse(KanbanDrop.acceptsDrops(sectionKind: .overdue))
        XCTAssertFalse(KanbanDrop.acceptsDrops(sectionKind: .later))
        XCTAssertFalse(KanbanDrop.acceptsDrops(sectionKind: .trash))
        XCTAssertFalse(KanbanDrop.acceptsDrops(sectionKind: .day(today)))
        XCTAssertFalse(KanbanDrop.acceptsDrops(sectionKind: .other("custom")))
    }

    func testMoveTimedTaskPreservesTimeAndTimeZone() {
        let tomorrow = today.adding(days: 1)
        let timed = Schedule.timed(today, start: 1140, end: 1260, timeZone: "Asia/Taipei")
        let task = makeTask(schedule: timed)

        let action = KanbanDrop.action(for: task, from: .today, to: .tomorrow, today: today)
        XCTAssertEqual(action, .moveSchedule(.timed(tomorrow, start: 1140, end: 1260, timeZone: "Asia/Taipei")))
    }

    func testCrossMidnightTaskMovesFromTodayToTomorrowPreservingSpanAndTimes() {
        let tomorrow = today.adding(days: 1)
        let dayAfter = today.adding(days: 2)
        // 23:30 – 00:30 crossing midnight (start=1410, endOffset=1470).
        let overnight = Schedule.timed(today, start: 23 * 60 + 30, end: 24 * 60 + 30, timeZone: "Asia/Taipei")
        let task = makeTask(schedule: overnight)

        let action = KanbanDrop.action(for: task, from: .today, to: .tomorrow, today: today)
        guard case .moveSchedule(let moved) = action else {
            return XCTFail("Expected .moveSchedule, got \(String(describing: action))")
        }
        XCTAssertEqual(moved.startDay, tomorrow)
        XCTAssertEqual(moved.lastDay, dayAfter)
        XCTAssertEqual(moved.startMinute, 23 * 60 + 30)
        XCTAssertEqual(moved.endOffsetMinutes, 24 * 60 + 30)
        XCTAssertEqual(moved.timeZone, "Asia/Taipei")
    }

    func testMoveUndatedTaskToTodayAndTomorrowCreatesAllDaySchedule() {
        let task = makeTask(schedule: nil)
        let tomorrow = today.adding(days: 1)

        XCTAssertEqual(
            KanbanDrop.action(for: task, from: .noDate, to: .today, today: today),
            .moveSchedule(.allDay(today))
        )
        XCTAssertEqual(
            KanbanDrop.action(for: task, from: .noDate, to: .tomorrow, today: today),
            .moveSchedule(.allDay(tomorrow))
        )
    }

    func testDropOntoNoDateClearsScheduleOrRejectsRepeatAndReminders() {
        let plainScheduled = makeTask(schedule: .allDay(today))
        XCTAssertTrue(KanbanDrop.canClearSchedule(plainScheduled))
        XCTAssertTrue(KanbanDrop.acceptsDrops(sectionKind: .noDate, for: plainScheduled, from: .today))
        XCTAssertEqual(
            KanbanDrop.action(for: plainScheduled, from: .today, to: .noDate, today: today),
            .clearSchedule
        )

        let undated = makeTask(schedule: nil)
        XCTAssertFalse(KanbanDrop.canClearSchedule(undated))
        XCTAssertFalse(KanbanDrop.acceptsDrops(sectionKind: .noDate, for: undated, from: .today))
        XCTAssertNil(KanbanDrop.action(for: undated, from: .today, to: .noDate, today: today))

        let repeating = makeTask(schedule: .allDay(today), repeatRule: "RRULE:FREQ=WEEKLY")
        XCTAssertFalse(KanbanDrop.canClearSchedule(repeating))
        XCTAssertFalse(KanbanDrop.acceptsDrops(sectionKind: .noDate, for: repeating, from: .today))
        XCTAssertNil(KanbanDrop.action(for: repeating, from: .today, to: .noDate, today: today))

        let withReminder = makeTask(schedule: .allDay(today), reminders: ["TRIGGER:-PT15M"])
        XCTAssertFalse(KanbanDrop.canClearSchedule(withReminder))
        XCTAssertFalse(KanbanDrop.acceptsDrops(sectionKind: .noDate, for: withReminder, from: .today))
        XCTAssertNil(KanbanDrop.action(for: withReminder, from: .today, to: .noDate, today: today))
    }

    func testDropOntoCompletedCompletesActiveTaskAndIgnoresCompletedSource() {
        let active = makeTask(schedule: .allDay(today), status: 0)
        XCTAssertEqual(
            KanbanDrop.action(for: active, from: .today, to: .completed, today: today),
            .complete
        )

        let done = makeTask(schedule: .allDay(today), status: 2)
        XCTAssertNil(KanbanDrop.action(for: done, from: .completed, to: .today, today: today))
        XCTAssertNil(KanbanDrop.action(for: done, from: .completed, to: .tomorrow, today: today))
        XCTAssertNil(KanbanDrop.action(for: done, from: .completed, to: .noDate, today: today))
        XCTAssertNil(KanbanDrop.action(for: done, from: .completed, to: .completed, today: today))
    }

    func testSameColumnAndDisallowedTargetsReturnNil() {
        let task = makeTask(schedule: .allDay(today))
        XCTAssertNil(KanbanDrop.action(for: task, from: .today, to: .today, today: today))
        XCTAssertNil(KanbanDrop.action(for: task, from: .today, to: .overdue, today: today))
        XCTAssertNil(KanbanDrop.action(for: task, from: .today, to: .later, today: today))
        XCTAssertNil(KanbanDrop.action(for: task, from: .today, to: .day(today.adding(days: 2)), today: today))
    }

    func testKanbanColumnsAlwaysIncludeFixedFourInListOrder() {
        let empty = TaskGrouping.kanbanColumns(from: [])
        XCTAssertEqual(empty.map(\.kind), [.today, .tomorrow, .noDate, .completed])
        XCTAssertTrue(empty.allSatisfy { $0.tasks.isEmpty })

        let t1 = makeTask(id: "t1", schedule: .allDay(today.adding(days: -1)))
        let t2 = makeTask(id: "t2", schedule: .allDay(today.adding(days: 5)))
        let listSections = TaskGrouping.sections(for: .project("p1"), tasks: [t1, t2], completed: [], today: today)
        // List mode omits empty groups.
        XCTAssertEqual(listSections.map(\.kind), [.overdue, .later])

        let kanban = TaskGrouping.kanbanColumns(from: listSections)
        XCTAssertEqual(kanban.map(\.kind), [.overdue, .today, .tomorrow, .later, .noDate, .completed])
        XCTAssertEqual(kanban[0].tasks.map(\.id), ["t1"])
        XCTAssertEqual(kanban[3].tasks.map(\.id), ["t2"])
        XCTAssertTrue(kanban[1].tasks.isEmpty)
        XCTAssertTrue(kanban[2].tasks.isEmpty)
        XCTAssertTrue(kanban[4].tasks.isEmpty)
        XCTAssertTrue(kanban[5].tasks.isEmpty)
    }

    func testRegularSplitVisibilityPreservesSidebarAcrossKanbanToggle() {
        // Narrow window (<1100): sidebar manually opened in list (.all) stays open in kanban (.all).
        XCTAssertEqual(
            RegularSplitVisibility.translatedForKanbanToggle(current: .all, toKanban: true, wide: false),
            .all
        )
        // Narrow window: sidebar closed in list (.doubleColumn) stays closed in kanban (.detailOnly).
        XCTAssertEqual(
            RegularSplitVisibility.translatedForKanbanToggle(current: .doubleColumn, toKanban: true, wide: false),
            .detailOnly
        )
        // Narrow window: sidebar open in kanban (.all or .doubleColumn) stays open in list (.all).
        XCTAssertEqual(
            RegularSplitVisibility.translatedForKanbanToggle(current: .all, toKanban: false, wide: false),
            .all
        )
        XCTAssertEqual(
            RegularSplitVisibility.translatedForKanbanToggle(current: .doubleColumn, toKanban: false, wide: false),
            .all
        )
        // Narrow window: sidebar closed in kanban (.detailOnly) stays closed in list (.doubleColumn).
        XCTAssertEqual(
            RegularSplitVisibility.translatedForKanbanToggle(current: .detailOnly, toKanban: false, wide: false),
            .doubleColumn
        )
    }

    func testMacMonthMaxLanesAllowsZeroAndMonthLayoutCountsAllInOverflow() {
        XCTAssertEqual(CalendarMonthMetrics.macMonthMaxLanes(forCellHeight: 40), 0)
        XCTAssertEqual(CalendarMonthMetrics.macMonthMaxLanes(forCellHeight: 69), 0)
        XCTAssertEqual(CalendarMonthMetrics.macMonthMaxLanes(forCellHeight: 70), 1)

        let t1 = makeTask(id: "a", schedule: .allDay(today))
        let t2 = makeTask(id: "b", schedule: .allDay(today))
        let layout = MonthLayout(month: today, tasks: [t1, t2], maxLanes: 0)
        let weekWithToday = layout.weeks.first { $0.days.contains(today) }
        XCTAssertNotNil(weekWithToday)
        XCTAssertTrue(weekWithToday?.bars.isEmpty == true)
        if let col = weekWithToday?.days.firstIndex(of: today) {
            XCTAssertEqual(weekWithToday?.overflow[col], 2)
        } else {
            XCTFail("Expected today in month layout week")
        }
    }
}
