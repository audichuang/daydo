import Foundation
import GRDB
import Testing
@testable import DayDoCore

private func isUnset<T>(_ patch: Patch<T>) -> Bool {
    if case .unset = patch { return true }
    return false
}

private func isClear<T>(_ patch: Patch<T>) -> Bool {
    if case .clear = patch { return true }
    return false
}

@Suite struct DateDraftTests {
    @Test func unchangedDraftProducesEmptyUpdateInput() async throws {
        let api = try await makeAPI()
        let inbox = try await api.listProjects(includeArchived: false)[0]
        let task = try await api.createTask(CreateTaskInput(
            projectId: inbox.id,
            title: "Original",
            start: "2026-11-15T09:00:00-0500",
            due: "2026-11-15T10:00:00-0500",
            timeZone: "America/New_York",
            reminder: "TRIGGER:-PT15M",
            repeat: "RRULE:FREQ=DAILY"
        ))

        let draft = DateDraft(task: task)
        let input = draft.updateInput(for: task)
        #expect(isUnset(input.schedule))
        #expect(input.reminders == nil)
        #expect(isUnset(input.repeat))
    }

    @Test func changingOnlyRemindersLeavesScheduleUnsetAndPreservesTimeZone() async throws {
        // Task stored in New York timezone, edited on a device running in Taipei timezone.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-tests-\(UUID().uuidString)")
        let db = try AppDatabase.inMemory()
        let nyApi = LocalDayDoAPI(
            database: db,
            clock: .fixed(noon, timeZone: TimeZone(identifier: "America/New_York")!),
            attachmentsDirectory: dir
        )
        try await nyApi.bootstrap()
        let inbox = try await nyApi.listProjects(includeArchived: false)[0]
        let created = try await nyApi.createTask(CreateTaskInput(
            projectId: inbox.id,
            title: "Flight",
            start: "2026-11-15T09:00:00-0500",
            due: "2026-11-15T10:00:00-0500",
            timeZone: "America/New_York",
            reminder: "TRIGGER:-PT15M"
        ))

        let taipeiApi = LocalDayDoAPI(
            database: db,
            clock: .fixed(noon, timeZone: taipei),
            attachmentsDirectory: dir
        )
        let loaded = try await taipeiApi.getTask(id: created.id)
        var draft = DateDraft(task: loaded)
        draft.reminders = ["TRIGGER:-PT30M"]

        let input = draft.updateInput(for: loaded)
        #expect(isUnset(input.schedule))
        #expect(input.reminders == ["TRIGGER:-PT30M"])
        #expect(isUnset(input.repeat))

        _ = try await taipeiApi.updateTask(input)
        let storedTimeZone = try await db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT timeZone FROM task WHERE id = ?", arguments: [created.id])
        }
        #expect(storedTimeZone == "America/New_York")
    }

    @Test func changingTimeSetsSchedule() async throws {
        let api = try await makeAPI()
        let inbox = try await api.listProjects(includeArchived: false)[0]
        let task = try await api.createTask(CreateTaskInput(
            projectId: inbox.id,
            title: "Timed",
            start: "2026-11-15T09:00:00+0800",
            due: "2026-11-15T10:00:00+0800",
            timeZone: "Asia/Taipei"
        ))

        var draft = DateDraft(task: task)
        draft.start = 14 * 60
        draft.end = 15 * 60

        let input = draft.updateInput(for: task)
        guard case .set(let schedule) = input.schedule else {
            Issue.record("Expected schedule to be .set, got \(input.schedule)")
            return
        }
        #expect(schedule.startMinute == 14 * 60)
        #expect(schedule.endOffsetMinutes == 15 * 60)
        #expect(input.reminders == nil)
        #expect(isUnset(input.repeat))
    }

    @Test func clearingDateProducesClearAndIgnoresRemindersOrRepeat() async throws {
        let api = try await makeAPI()
        let inbox = try await api.listProjects(includeArchived: false)[0]
        let task = try await api.createTask(CreateTaskInput(
            projectId: inbox.id,
            title: "Scheduled",
            start: "2026-11-15T09:00:00+0800",
            due: "2026-11-15T10:00:00+0800",
            timeZone: "Asia/Taipei",
            reminder: "TRIGGER:-PT15M",
            repeat: "RRULE:FREQ=DAILY"
        ))

        var draft = DateDraft(task: task)
        draft.day = nil
        draft.reminders = ["TRIGGER:-PT5M"]
        draft.repeatRule = nil

        let input = draft.updateInput(for: task)
        #expect(isClear(input.schedule))
        #expect(input.reminders == nil)
        #expect(isUnset(input.repeat))
    }

    @Test func updatingWithLocalizedOrSameDayMovedSchedulePreservesStoredZoneAndColumns() async throws {
        // Task stored in New York timezone, updated on a device running in Taipei timezone.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-tests-\(UUID().uuidString)")
        let db = try AppDatabase.inMemory()
        let nyApi = LocalDayDoAPI(
            database: db,
            clock: .fixed(noon, timeZone: TimeZone(identifier: "America/New_York")!),
            attachmentsDirectory: dir
        )
        try await nyApi.bootstrap()
        let inbox = try await nyApi.listProjects(includeArchived: false)[0]
        let created = try await nyApi.createTask(CreateTaskInput(
            projectId: inbox.id,
            title: "Flight",
            start: "2026-11-15T09:00:00-0500",
            due: "2026-11-15T10:00:00-0500",
            timeZone: "America/New_York"
        ))

        let changeCountBefore = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change WHERE entity = 'task' AND entityId = ?", arguments: [created.id])
        }

        let taipeiApi = LocalDayDoAPI(
            database: db,
            clock: .fixed(noon, timeZone: taipei),
            attachmentsDirectory: dir
        )
        let loaded = try await taipeiApi.getTask(id: created.id)
        let localized = try #require(loaded.schedule)
        #expect(localized.timeZone == taipei.identifier)

        var sameScheduleInput = UpdateTaskInput(taskId: created.id)
        sameScheduleInput.schedule = .set(localized)
        _ = try await taipeiApi.updateTask(sameScheduleInput)

        var sameDayMoveInput = UpdateTaskInput(taskId: created.id)
        sameDayMoveInput.schedule = .set(localized.moved(to: localized.startDay))
        _ = try await taipeiApi.updateTask(sameDayMoveInput)

        let stored: (startDay: String?, startMinute: Int?, endDay: String?, endMinute: Int?, timeZone: String?)? = try await db.writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT startDay, startMinute, endDay, endMinute, timeZone FROM task WHERE id = ?",
                arguments: [created.id]
            ) else { return nil }
            return (
                row["startDay"] as String?,
                row["startMinute"] as Int?,
                row["endDay"] as String?,
                row["endMinute"] as Int?,
                row["timeZone"] as String?
            )
        }
        let cols = try #require(stored)
        #expect(cols.startDay == "2026-11-15")
        #expect(cols.startMinute == 9 * 60)
        #expect(cols.endDay == "2026-11-15")
        #expect(cols.endMinute == 10 * 60)
        #expect(cols.timeZone == "America/New_York")

        let changeCountAfter = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change WHERE entity = 'task' AND entityId = ?", arguments: [created.id])
        }
        #expect(changeCountAfter == changeCountBefore)
    }

    @Test func stampTimeZoneIfFloatingOnlyStampsWhenNil() {
        var draft = DateDraft()
        draft.stampTimeZoneIfFloating("Asia/Taipei")
        #expect(draft.timeZone == "Asia/Taipei")

        draft.stampTimeZoneIfFloating("America/New_York")
        #expect(draft.timeZone == "Asia/Taipei")
    }
}
