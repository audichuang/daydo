import XCTest
import DayDoCore
@testable import DayDo

final class KanbanDropTests: XCTestCase {
    private let today = LocalDay(year: 2026, month: 11, day: 24)

    private func makeTask(
        id: String = "t1",
        schedule: Schedule? = nil,
        status: Int = 0
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
            reminders: [],
            repeat: nil,
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

    func testDropOntoNoDateClearsScheduleOrNoOpsWhenAlreadyUndated() {
        let scheduled = makeTask(schedule: .allDay(today))
        XCTAssertEqual(
            KanbanDrop.action(for: scheduled, from: .today, to: .noDate, today: today),
            .clearSchedule
        )

        let undated = makeTask(schedule: nil)
        XCTAssertNil(KanbanDrop.action(for: undated, from: .today, to: .noDate, today: today))
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
}
