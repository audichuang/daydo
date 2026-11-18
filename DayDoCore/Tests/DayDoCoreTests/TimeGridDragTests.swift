import Foundation
import Testing
@testable import DayDoCore

@Suite struct TimeGridDragTests {
    private func day(_ s: String) -> LocalDay { LocalDay(s)! }

    private func timedTask(_ id: String, _ schedule: Schedule) -> TodoTask {
        TodoTask(
            id: id,
            projectId: "p1",
            title: id,
            content: "",
            priority: .none,
            status: 0,
            schedule: schedule,
            start: nil,
            due: nil,
            allDay: schedule.isAllDay,
            timeZone: schedule.timeZone,
            reminders: [],
            repeat: nil,
            tags: [],
            items: [],
            assigneeId: nil,
            sortKey: id,
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

    @Test func snapRoundsToNearest15Minutes() {
        #expect(TimeGridDrag.snap(0) == 0)
        #expect(TimeGridDrag.snap(7.4) == 0)
        #expect(TimeGridDrag.snap(7.5) == 15)
        #expect(TimeGridDrag.snap(22.4) == 15)
        #expect(TimeGridDrag.snap(22.5) == 30)
        #expect(TimeGridDrag.snap(-8.0) == -15)
    }

    @Test func columnIndexClampsToVisibleColumns() {
        #expect(TimeGridDrag.columnIndex(x: 10, gutter: 40, columnWidth: 50, columnCount: 7) == 0)
        #expect(TimeGridDrag.columnIndex(x: 40, gutter: 40, columnWidth: 50, columnCount: 7) == 0)
        #expect(TimeGridDrag.columnIndex(x: 89.9, gutter: 40, columnWidth: 50, columnCount: 7) == 0)
        #expect(TimeGridDrag.columnIndex(x: 90, gutter: 40, columnWidth: 50, columnCount: 7) == 1)
        #expect(TimeGridDrag.columnIndex(x: 500, gutter: 40, columnWidth: 50, columnCount: 7) == 6)
        #expect(TimeGridDrag.columnIndex(x: 100, gutter: 40, columnWidth: 50, columnCount: 1) == 0)
    }

    @Test func createRangeSupportsDownwardUpwardAndClamping() {
        let hourH = 60.0
        // No movement -> 15 min minimum
        #expect(TimeGridDrag.createRange(anchorY: 600, currentY: 600, hourHeight: hourH) == .init(startMinute: 600, endMinute: 615))
        // Downward drag
        #expect(TimeGridDrag.createRange(anchorY: 600, currentY: 690, hourHeight: hourH) == .init(startMinute: 600, endMinute: 690))
        // Upward drag
        #expect(TimeGridDrag.createRange(anchorY: 600, currentY: 510, hourHeight: hourH) == .init(startMinute: 510, endMinute: 600))
        // Clamped to 00:00 and 24:00
        #expect(TimeGridDrag.createRange(anchorY: 30, currentY: -40, hourHeight: hourH) == .init(startMinute: 0, endMinute: 30))
        #expect(TimeGridDrag.createRange(anchorY: 1410, currentY: 1500, hourHeight: hourH) == .init(startMinute: 1410, endMinute: 1440))
        #expect(TimeGridDrag.createRange(anchorY: 1440, currentY: 1440, hourHeight: hourH) == .init(startMinute: 1425, endMinute: 1440))
    }

    @Test func moveSchedulePreservesDurationAndClampsStartAndMaxEnd() {
        let d0 = day("2026-11-18")
        let d1 = day("2026-11-19")
        let s = Schedule.timed(d0, start: 600, end: 690, timeZone: "Asia/Taipei")

        // Move to next day +30m
        let moved = TimeGridDrag.moveSchedule(s, sourceColumnDay: d0, targetColumnDay: d1, minuteDelta: 30)
        #expect(moved == .init(startDay: d1, startMinute: 630, endOffsetMinutes: 720))

        // Clamp start at 00:00
        let early = TimeGridDrag.moveSchedule(s, sourceColumnDay: d0, targetColumnDay: d0, minuteDelta: -700)
        #expect(early == .init(startDay: d0, startMinute: 0, endOffsetMinutes: 90))

        // Clamp start at 23:45 (end crosses midnight to 01:15)
        let late = TimeGridDrag.moveSchedule(s, sourceColumnDay: d0, targetColumnDay: d0, minuteDelta: 900)
        #expect(late == .init(startDay: d0, startMinute: 1425, endOffsetMinutes: 1515))

        // 3-hour block moved to 23:45 caps end at TimeBlockEditor.maxEnd (26:00)
        let long = Schedule.timed(d0, start: 600, end: 780, timeZone: "Asia/Taipei")
        let capped = TimeGridDrag.moveSchedule(long, sourceColumnDay: d0, targetColumnDay: d0, minuteDelta: 900)
        #expect(capped == .init(startDay: d0, startMinute: 1425, endOffsetMinutes: 1560))
    }

    @Test func moveCrossMidnightFromDay1AndDay2Segments() {
        let d0 = day("2026-11-18")
        let d1 = day("2026-11-19")
        let d2 = day("2026-11-20")
        // 23:00 on Nov 18 to 01:00 on Nov 19 (duration 120m)
        let s = Schedule.timed(d0, start: 1380, end: 60, timeZone: "Asia/Taipei")

        // Drag Day 1 segment back 60m -> 22:00 – 隔日 00:00 (keeps full 120m duration, not clipped 60m)
        let fromDay1 = TimeGridDrag.moveSchedule(s, sourceColumnDay: d0, targetColumnDay: d0, minuteDelta: -60)
        #expect(fromDay1 == .init(startDay: d0, startMinute: 1320, endOffsetMinutes: 1440))

        // Drag Day 2 segment horizontally to Nov 20 with 0 vertical delta -> Nov 19 23:00 – Nov 20 01:00
        let fromDay2Horiz = TimeGridDrag.moveSchedule(s, sourceColumnDay: d1, targetColumnDay: d2, minuteDelta: 0)
        #expect(fromDay2Horiz == .init(startDay: d1, startMinute: 1380, endOffsetMinutes: 1500))

        // Drag Day 2 segment down +30m -> Nov 18 23:30 – Nov 19 01:30
        let fromDay2Down30 = TimeGridDrag.moveSchedule(s, sourceColumnDay: d1, targetColumnDay: d1, minuteDelta: 30)
        #expect(fromDay2Down30 == .init(startDay: d0, startMinute: 1410, endOffsetMinutes: 1530))

        // Drag Day 2 segment down +120m -> Nov 19 01:00 – Nov 19 03:00
        let fromDay2Down120 = TimeGridDrag.moveSchedule(s, sourceColumnDay: d1, targetColumnDay: d1, minuteDelta: 120)
        #expect(fromDay2Down120 == .init(startDay: d1, startMinute: 60, endOffsetMinutes: 180))

        // No movement from Day 2 produces unchanged DateDraft -> unset schedule in UpdateTaskInput
        let unchanged = TimeGridDrag.moveSchedule(s, sourceColumnDay: d1, targetColumnDay: d1, minuteDelta: 0)!
        let task = timedTask("cross", s)
        let input = unchanged.applied(to: task).updateInput(for: task)
        if case .unset = input.schedule {} else {
            Issue.record("Expected unchanged Day 2 move to leave schedule .unset")
        }
    }

    @Test func movePointInTimeTaskPreservesZeroDuration() {
        let d0 = day("2026-11-18")
        let d1 = day("2026-11-19")
        let s = Schedule.timed(d0, start: 1020, end: nil, timeZone: "Asia/Taipei")
        let task = timedTask("point", s)

        let moved = TimeGridDrag.moveSchedule(s, sourceColumnDay: d0, targetColumnDay: d1, minuteDelta: 45)!
        #expect(moved == .init(startDay: d1, startMinute: 1065, endOffsetMinutes: 1065))

        let draft = moved.applied(to: task)
        #expect(draft.schedule == Schedule(startDay: d1, startMinute: 1065, timeZone: "Asia/Taipei"))
    }

    @Test func hitTestBlockFindsCorrectLaneAndColumn() {
        let d0 = day("2026-11-18")
        let d1 = day("2026-11-19")
        let a = timedTask("a", .timed(d0, start: 600, end: 720))
        let b = timedTask("b", .timed(d0, start: 630, end: 690))
        let c = timedTask("c", .timed(d1, start: 600, end: 660))

        let hitA = TimeGridDrag.hitTestBlock(x: 60, y: 615, days: [d0, d1], tasks: [a, b, c], gutter: 40, columnWidth: 100, hourHeight: 60)
        #expect(hitA?.block.task.id == "a")
        #expect(hitA?.day == d0)

        let hitB = TimeGridDrag.hitTestBlock(x: 115, y: 650, days: [d0, d1], tasks: [a, b, c], gutter: 40, columnWidth: 100, hourHeight: 60)
        #expect(hitB?.block.task.id == "b")

        let hitC = TimeGridDrag.hitTestBlock(x: 160, y: 630, days: [d0, d1], tasks: [a, b, c], gutter: 40, columnWidth: 100, hourHeight: 60)
        #expect(hitC?.block.task.id == "c")
        #expect(hitC?.columnIndex == 1)

        // Gutter or empty space returns nil
        #expect(TimeGridDrag.hitTestBlock(x: 20, y: 630, days: [d0, d1], tasks: [a, b, c], gutter: 40, columnWidth: 100, hourHeight: 60) == nil)
        #expect(TimeGridDrag.hitTestBlock(x: 160, y: 800, days: [d0, d1], tasks: [a, b, c], gutter: 40, columnWidth: 100, hourHeight: 60) == nil)
    }
}
