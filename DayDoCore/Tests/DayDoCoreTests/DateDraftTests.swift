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
}
