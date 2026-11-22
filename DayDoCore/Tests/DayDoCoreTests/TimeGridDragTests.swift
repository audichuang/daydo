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

        // 3-hour block moved to 23:45 preserves full duration (ends next day 02:45, no truncation)
        let long = Schedule.timed(d0, start: 600, end: 780, timeZone: "Asia/Taipei")
        let movedLong = TimeGridDrag.moveSchedule(long, sourceColumnDay: d0, targetColumnDay: d0, minuteDelta: 900)
        #expect(movedLong == .init(startDay: d0, startMinute: 1425, endOffsetMinutes: 1605))

        // 18:00–23:00 moved to 22:00 keeps 300m duration (22:00–next day 03:00)
        let evening = Schedule.timed(d0, start: 1080, end: 1380, timeZone: "Asia/Taipei")
        let movedEvening = TimeGridDrag.moveSchedule(evening, sourceColumnDay: d0, targetColumnDay: d0, minuteDelta: 240)
        #expect(movedEvening == .init(startDay: d0, startMinute: 1320, endOffsetMinutes: 1620))

        // 20:00–next day 03:00 dragged down 30m -> 20:30–next day 03:30
        let overnightLong = Schedule.timed(d0, start: 1200, end: 180, timeZone: "Asia/Taipei")
        let movedOvernightLong = TimeGridDrag.moveSchedule(overnightLong, sourceColumnDay: d0, targetColumnDay: d0, minuteDelta: 30)
        #expect(movedOvernightLong == .init(startDay: d0, startMinute: 1230, endOffsetMinutes: 1650))
    }

    @Test func moveZeroDeltaAndPureHorizontalPreserveUnclampedMinute() {
        let d0 = day("2026-11-18")
        let d1 = day("2026-11-19")

        // 23:50–next day 00:30 zero-delta drop leaves schedule identical and produces .unset update
        let lateBlock = Schedule.timed(d0, start: 1430, end: 30, timeZone: "Asia/Taipei")
        let zeroBlock = TimeGridDrag.moveSchedule(lateBlock, sourceColumnDay: d0, targetColumnDay: d0, minuteDelta: 0)!
        #expect(zeroBlock == .init(startDay: d0, startMinute: 1430, endOffsetMinutes: 1470))
        let blockTask = timedTask("late-block", lateBlock)
        let blockInput = zeroBlock.applied(to: blockTask).updateInput(for: blockTask)
        if case .unset = blockInput.schedule {} else {
            Issue.record("Expected zero-delta 23:50–00:30 drop to leave schedule .unset")
        }

        // 23:50 point-in-time zero-delta drop leaves schedule identical
        let latePoint = Schedule.timed(d0, start: 1430, end: nil, timeZone: "Asia/Taipei")
        let zeroPoint = TimeGridDrag.moveSchedule(latePoint, sourceColumnDay: d0, targetColumnDay: d0, minuteDelta: 0)!
        #expect(zeroPoint == .init(startDay: d0, startMinute: 1430, endOffsetMinutes: 1430))
        let pointTask = timedTask("late-point", latePoint)
        let pointInput = zeroPoint.applied(to: pointTask).updateInput(for: pointTask)
        if case .unset = pointInput.schedule {} else {
            Issue.record("Expected zero-delta 23:50 point drop to leave schedule .unset")
        }

        // 23:50 pure horizontal move to next day keeps 23:50
        let horizPoint = TimeGridDrag.moveSchedule(latePoint, sourceColumnDay: d0, targetColumnDay: d1, minuteDelta: 0)!
        #expect(horizPoint == .init(startDay: d1, startMinute: 1430, endOffsetMinutes: 1430))

        let horizBlock = TimeGridDrag.moveSchedule(lateBlock, sourceColumnDay: d0, targetColumnDay: d1, minuteDelta: 0)!
        #expect(horizBlock == .init(startDay: d1, startMinute: 1430, endOffsetMinutes: 1470))
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

        // Drag Day 2 segment up -15m -> Nov 18 22:45 – Nov 19 00:45
        let fromDay2Up15 = TimeGridDrag.moveSchedule(s, sourceColumnDay: d1, targetColumnDay: d1, minuteDelta: -15)
        #expect(fromDay2Up15 == .init(startDay: d0, startMinute: 1365, endOffsetMinutes: 1485))

        // Drag Day 2 segment up -120m -> Nov 18 21:00 – Nov 18 23:00
        let fromDay2Up120 = TimeGridDrag.moveSchedule(s, sourceColumnDay: d1, targetColumnDay: d1, minuteDelta: -120)
        #expect(fromDay2Up120 == .init(startDay: d0, startMinute: 1260, endOffsetMinutes: 1380))

        // Drag Day 2 segment all the way to previous day 00:00 (clamped there)
        let fromDay2UpEarly = TimeGridDrag.moveSchedule(s, sourceColumnDay: d1, targetColumnDay: d1, minuteDelta: -1500)
        #expect(fromDay2UpEarly == .init(startDay: d0, startMinute: 0, endOffsetMinutes: 120))

        // No movement from Day 2 produces unchanged DateDraft -> unset schedule in UpdateTaskInput
        let unchanged = TimeGridDrag.moveSchedule(s, sourceColumnDay: d1, targetColumnDay: d1, minuteDelta: 0)!
        let task = timedTask("cross", s)
        let input = unchanged.applied(to: task).updateInput(for: task)
        if case .unset = input.schedule {} else {
            Issue.record("Expected unchanged Day 2 move to leave schedule .unset")
        }
    }

    @Test func moveMultiDayTimedTaskFromAnyDaySegment() {
        let d0 = day("2026-11-18")
        let d1 = day("2026-11-19")
        let d2 = day("2026-11-20")
        let d3 = day("2026-11-21")
        // 11/18 09:00 – 11/20 10:00 (2940 minutes)
        let s = Schedule(startDay: d0, startMinute: 540, endDay: d2, endMinute: 600, timeZone: "Asia/Taipei")
        #expect(s.durationMinutes == 2940)

        for sourceDay in [d0, d1, d2] {
            let plus15 = TimeGridDrag.moveSchedule(s, sourceColumnDay: sourceDay, targetColumnDay: sourceDay, minuteDelta: 15)!
            #expect(plus15 == .init(startDay: d0, startMinute: 555, endOffsetMinutes: 3495))
            #expect(plus15.endOffsetMinutes - plus15.startMinute == 2940)

            let minus15 = TimeGridDrag.moveSchedule(s, sourceColumnDay: sourceDay, targetColumnDay: sourceDay, minuteDelta: -15)!
            #expect(minus15 == .init(startDay: d0, startMinute: 525, endOffsetMinutes: 3465))
            #expect(minus15.endOffsetMinutes - minus15.startMinute == 2940)
        }

        // Day 3 segment dragged to 11/21 +15m -> starts 11/19 09:15 (555), ends +2940m (3495)
        let crossDay3 = TimeGridDrag.moveSchedule(s, sourceColumnDay: d2, targetColumnDay: d3, minuteDelta: 15)!
        #expect(crossDay3 == .init(startDay: d1, startMinute: 555, endOffsetMinutes: 3495))
        #expect(crossDay3.endOffsetMinutes - crossDay3.startMinute == 2940)
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

    @Test func editorMoveCharacterization() {
        let step = 5
        let maxEnd = 1560
        let cases: [(label: String, start: Int, end: Int, delta: Double, expectedStart: Int, expectedEnd: Int)] = [
            ("normal downward move keeps length", 600, 660, 30, 630, 690),
            ("normal upward move keeps length", 600, 660, -30, 570, 630),
            ("positive delta below half-step snaps to 0", 600, 660, 2.4, 600, 660),
            ("positive delta at half-step snaps to +5", 600, 660, 2.5, 605, 665),
            ("negative delta above -half-step snaps to 0", 600, 660, -2.4, 600, 660),
            ("negative delta at -half-step snaps to -5", 600, 660, -2.5, 595, 655),
            ("arbitrary delta snaps to nearest multiple of 5", 600, 660, 12.6, 615, 675),
            ("huge upward move stops start at 0", 600, 660, -2000, 0, 60),
            ("huge downward move stops start at 1435 keeping length within maxEnd", 600, 660, 2000, 1435, 1495),
            ("huge downward move stops start at 1435 and caps end at 1560", 600, 780, 2000, 1435, 1560),
            ("evening move caps end at 1560 before start reaches 1435", 1320, 1500, 90, 1410, 1560),
        ]
        for c in cases {
            let actual = TimeGridDrag.move(start: c.start, end: c.end, deltaMinutes: c.delta, step: step, maxEnd: maxEnd)
            #expect(actual == .init(startMinute: c.expectedStart, endMinute: c.expectedEnd), "\(c.label)")
        }

        // Custom step and maxEnd are respected.
        #expect(
            TimeGridDrag.move(start: 600, end: 690, deltaMinutes: 2000, step: 15, maxEnd: 1440)
                == .init(startMinute: 1425, endMinute: 1440)
        )
    }

    @Test func editorResizeStartCharacterization() {
        let step = 5
        let maxEnd = 1560
        let cases: [(label: String, start: Int, end: Int, delta: Double, expectedStart: Int)] = [
            ("normal upward resize", 600, 660, -30, 570),
            ("normal downward resize", 600, 660, 20, 620),
            ("positive delta below half-step snaps to 0", 600, 660, 2.4, 600),
            ("positive delta at half-step snaps to +5", 600, 660, 2.5, 605),
            ("negative delta above -half-step snaps to 0", 600, 660, -2.4, 600),
            ("negative delta at -half-step snaps to -5", 600, 660, -2.5, 595),
            ("huge upward resize stops at 0", 600, 660, -2000, 0),
            ("huge downward resize stops at end - 5", 600, 660, 2000, 655),
            ("overnight block resizeStart stops at end - 5", 1380, 1500, 500, 1495),
        ]
        for c in cases {
            let actual = TimeGridDrag.resizeStart(start: c.start, end: c.end, deltaMinutes: c.delta, step: step, maxEnd: maxEnd)
            #expect(actual == c.expectedStart, "\(c.label)")
        }

        #expect(TimeGridDrag.resizeStart(start: 600, end: 660, deltaMinutes: 200, step: 15, maxEnd: 1440) == 645)
    }

    @Test func editorResizeEndCharacterization() {
        let step = 5
        let maxEnd = 1560
        let cases: [(label: String, start: Int, end: Int, delta: Double, expectedEnd: Int)] = [
            ("normal extend", 600, 660, 30, 690),
            ("normal shrink", 600, 660, -20, 640),
            ("positive delta below half-step snaps to 0", 600, 660, 2.4, 660),
            ("positive delta at half-step snaps to +5", 600, 660, 2.5, 665),
            ("negative delta above -half-step snaps to 0", 600, 660, -2.4, 660),
            ("negative delta at -half-step snaps to -5", 600, 660, -2.5, 655),
            ("huge upward resize floors at start + 5", 600, 660, -2000, 605),
            ("huge downward resize caps at 1560", 600, 660, 2000, 1560),
            ("duration chip from aligned start", 600, 600, 30, 630),
            ("duration chip from non-5-minute start preserves exact duration", 603, 603, 30, 633),
            ("duration chip near midnight stays within 1560", 1435, 1435, 120, 1555),
            ("duration chip beyond maxEnd caps at 1560", 1450, 1450, 120, 1560),
        ]
        for c in cases {
            let actual = TimeGridDrag.resizeEnd(start: c.start, end: c.end, deltaMinutes: c.delta, step: step, maxEnd: maxEnd)
            #expect(actual == c.expectedEnd, "\(c.label)")
        }

        #expect(TimeGridDrag.resizeEnd(start: 600, end: 660, deltaMinutes: -200, step: 15, maxEnd: 1440) == 615)
        #expect(TimeGridDrag.resizeEnd(start: 600, end: 660, deltaMinutes: 2000, step: 15, maxEnd: 1440) == 1440)
    }
}
