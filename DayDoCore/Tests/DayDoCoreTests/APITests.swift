import Foundation
import GRDB
import Testing
@testable import DayDoCore

/// 2026-11-15 12:00 in Taipei (a Sunday, matching the design mock data).
let noon = LocalDay("2026-11-15")!.date(minute: 720, in: taipei)

func makeAPI(now: Date = noon) async throws -> LocalDayDoAPI {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-tests-\(UUID().uuidString)")
    let api = LocalDayDoAPI(database: try .inMemory(), clock: .fixed(now, timeZone: taipei), attachmentsDirectory: dir)
    try await api.bootstrap()
    return api
}

@Suite struct APITests {
    @Test func bootstrapCreatesInboxAndListsOnce() async throws {
        let api = try await makeAPI()
        try await api.bootstrap()
        let projects = try await api.listProjects(includeArchived: false)
        #expect(projects.first?.isInbox == true)
        #expect(projects.map(\.name) == ["收件匣", "工作", "個人", "購物"])
        #expect(try await api.listMembers().count == 1)
    }

    @Test func createTaskWithTickTickFields() async throws {
        let api = try await makeAPI()
        let work = try await api.listProjects(includeArchived: false)[1]
        let t = try await api.createTask(CreateTaskInput(
            projectId: work.id, title: "準備週一產品會議簡報", content: "重點放在 Q4", priority: .high,
            start: "2026-11-15T18:00:00+0800", due: "2026-11-15T18:30:00+0800", timeZone: "Asia/Taipei",
            reminder: "TRIGGER:-PT15M", subtasks: ["整理上週數據", "更新路線圖頁面"], tags: ["#會議", "Q4"]))
        #expect(t.priority == .high)
        #expect(t.schedule?.startMinute == 1080)
        #expect(t.reminders == ["TRIGGER:-PT15M"])
        #expect(t.items.map(\.title) == ["整理上週數據", "更新路線圖頁面"])
        #expect(t.tags == ["會議", "q4"])
        #expect(try await api.listTags().map(\.label) == ["會議", "Q4"])
        let defaultInbox = try await api.createTask(CreateTaskInput(title: "隨手記"))
        #expect(defaultInbox.projectId == (try await api.listProjects(includeArchived: false)[0].id))
    }

    @Test func remindersNeedADate() async throws {
        let api = try await makeAPI()
        await #expect(throws: DayDoError.self) {
            _ = try await api.createTask(CreateTaskInput(title: "x", reminder: "TRIGGER:-PT15M"))
        }
        await #expect(throws: DayDoError.self) {
            _ = try await api.createTask(CreateTaskInput(title: "x", start: "2026-11-15", reminder: "bogus"))
        }
    }

    @Test func updatePatchSemantics() async throws {
        let api = try await makeAPI()
        let t = try await api.createTask(CreateTaskInput(title: "週會", start: "2026-11-16T10:00", due: "2026-11-16T11:00", reminders: ["TRIGGER:PT0S"], repeat: "RRULE:FREQ=WEEKLY"))
        var u = UpdateTaskInput(taskId: t.id)
        u.title = "週會（改）"
        let u1 = try await api.updateTask(u)
        #expect(u1.schedule == t.schedule)
        #expect(u1.repeat == "RRULE:FREQ=WEEKLY")
        // Clearing the date also clears reminders and repeat.
        var c = UpdateTaskInput(taskId: t.id)
        c.start = .clear
        let u2 = try await api.updateTask(c)
        #expect(u2.schedule == nil && u2.reminders.isEmpty && u2.repeat == nil)
        // JSON decoding distinguishes absent / null.
        let json = #"{"task_id":"\#(t.id)","start":"2026-11-20","repeat":null}"#
        let decoded = try DayDoJSON.decoder.decode(UpdateTaskInput.self, from: Data(json.utf8))
        #expect(decoded.start == .set("2026-11-20"))
        #expect(decoded.repeat == .clear)
        #expect(decoded.due == .unset)
        let u3 = try await api.updateTask(decoded)
        #expect(u3.schedule == .allDay(LocalDay("2026-11-20")!))
    }

    @Test func completingRepeatingTaskAdvances() async throws {
        let api = try await makeAPI()
        let t = try await api.createTask(CreateTaskInput(title: "繳帳單", start: "2026-11-15", repeat: "RRULE:FREQ=MONTHLY;BYMONTHDAY=15", subtasks: ["a"]))
        _ = try await api.updateChecklistItem(id: t.items[0].id, title: nil, done: true)
        let done = try await api.completeTask(id: t.id)
        #expect(done.isCompleted && done.id != t.id && done.repeat == nil)
        let next = try await api.getTask(id: t.id)
        #expect(!next.isCompleted)
        #expect(next.schedule?.startDay == LocalDay("2026-12-15"))
        #expect(next.items.allSatisfy { !$0.isDone })
    }

    @Test func todaySectionsAndCounts() async throws {
        let api = try await makeAPI()
        _ = try await api.createTask(CreateTaskInput(title: "逾期", start: "2026-11-14T17:00"))
        _ = try await api.createTask(CreateTaskInput(title: "今天", start: "2026-11-15T18:00", due: "2026-11-15T18:30"))
        let trip = try await api.createTask(CreateTaskInput(title: "花蓮", start: "2026-11-13", due: "2026-11-16"))
        _ = try await api.createTask(CreateTaskInput(title: "明天", start: "2026-11-16"))
        _ = try await api.createTask(CreateTaskInput(title: "無日期"))
        let doneT = try await api.createTask(CreateTaskInput(title: "完成的", start: "2026-11-15"))
        _ = try await api.completeTask(id: doneT.id)
        let sections = try await api.listSections(.smart(.today))
        #expect(sections.map(\.id) == ["overdue", "today", "tomorrow", "completed"])
        #expect(sections[1].tasks.map(\.title) == ["花蓮", "今天"])
        #expect(sections[2].tasks.map(\.title).contains("花蓮"))
        let counts = try await api.smartCounts()
        #expect(counts.today == 3)
        #expect(counts.inbox == 5)
        let overdueIds = sections.first(where: { $0.id == "overdue" })!.tasks.map(\.id)
        let moved = try await api.postponeOverdue(taskIds: overdueIds)
        #expect(moved == 1)
        #expect(try await api.listSections(.smart(.today)).first?.id == "today")
        let inRange = try await api.listTasks(TaskQuery(from: LocalDay("2026-11-16")!, to: LocalDay("2026-11-16")!))
        #expect(Set(inRange.map(\.id)).contains(trip.id))
    }

    @Test func postponeOverdueOnlyTouchesSpecifiedTasks() async throws {
        let api = try await makeAPI()
        let projects = try await api.listProjects(includeArchived: false)
        let work = projects[1]
        let personal = projects[2]
        let workOverdue = try await api.createTask(CreateTaskInput(projectId: work.id, title: "工作逾期", start: "2026-11-14T10:00"))
        let personalOverdue = try await api.createTask(CreateTaskInput(projectId: personal.id, title: "個人逾期", start: "2026-11-13T11:00"))

        let workSections = try await api.listSections(.project(work.id))
        let workOverdueIds = workSections.first(where: { $0.id == "overdue" })!.tasks.map(\.id)
        let moved = try await api.postponeOverdue(taskIds: workOverdueIds)
        #expect(moved == 1)
        #expect(try await api.getTask(id: workOverdue.id).schedule?.startDay == LocalDay("2026-11-15"))
        #expect(try await api.getTask(id: personalOverdue.id).schedule?.startDay == LocalDay("2026-11-13"))
    }

    @Test func completeTaskWithStaleUpdatedAtIsNoOp() async throws {
        let api = try await makeAPI()
        let t = try await api.createTask(CreateTaskInput(title: "每日站會", start: "2026-11-15", repeat: "RRULE:FREQ=DAILY"))
        let done = try await api.completeTask(id: t.id, ifUpdatedAt: t.updatedAt)
        #expect(done.isCompleted)
        #expect(try await api.getTask(id: t.id).schedule?.startDay == LocalDay("2026-11-16"))

        // Second tap arriving with the stale updatedAt token does not advance again.
        let second = try await api.completeTask(id: t.id, ifUpdatedAt: t.updatedAt)
        #expect(second.id == t.id)
        #expect(!second.isCompleted)
        #expect(try await api.getTask(id: t.id).schedule?.startDay == LocalDay("2026-11-16"))
    }

    @Test func completeRepeatingTaskCrossesMidnightZoneWithIfUpdatedAt() async throws {
        // Daily 15:30 Asia/Taipei: 2026-11-01 -> 11-01 00:30 PDT in LA; 2026-11-02 -> 11-01 23:30 PST in LA.
        // Both localize to 2026-11-01 in America/Los_Angeles, so only ifUpdatedAt blocks the stale resend.
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let now = ISO8601DateFormatter().date(from: "2026-11-01T20:00:00Z")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-test-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: try .inMemory(), clock: .fixed(now, timeZone: la), attachmentsDirectory: dir)
        try await api.bootstrap()

        let created = try await api.createTask(CreateTaskInput(
            title: "跨時區每日任務",
            start: "2026-11-01T15:30:00+08:00",
            timeZone: "Asia/Taipei",
            repeat: "RRULE:FREQ=DAILY"
        ))
        #expect(created.schedule?.startDay == LocalDay("2026-11-01"))
        #expect(created.schedule?.startMinute == 30)

        let done = try await api.completeTask(id: created.id, ifUpdatedAt: created.updatedAt)
        #expect(done.isCompleted)
        let afterFirst = try await api.getTask(id: created.id)
        #expect(afterFirst.schedule?.startDay == LocalDay("2026-11-01"))
        #expect(afterFirst.schedule?.startMinute == 23 * 60 + 30)
        #expect(afterFirst.updatedAt > created.updatedAt)

        // Resend with the original updatedAt token: must be a no-op with no second completed copy.
        let resent = try await api.completeTask(id: created.id, ifUpdatedAt: created.updatedAt)
        #expect(!resent.isCompleted)
        #expect(resent.schedule?.startDay == LocalDay("2026-11-01"))
        #expect(resent.schedule?.startMinute == 23 * 60 + 30)
        let completed = try await api.getCompletedTasks(projectId: nil, limit: 50)
        #expect(completed.count == 1)
    }

    @Test func listSectionsPagesCompletedAndTrash() async throws {
        let api = try await makeAPI()
        let work = try await api.listProjects(includeArchived: false)[1]
        for i in 1...4 {
            let t = try await api.createTask(CreateTaskInput(projectId: work.id, title: "done-\(i)"))
            _ = try await api.completeTask(id: t.id)
        }
        let page1 = try await api.listSections(.project(work.id), limit: 2)
        let completed1 = try #require(page1.first(where: { $0.id == "completed" }))
        #expect(completed1.tasks.count == 2)
        #expect(completed1.hasMore)

        let page2 = try await api.listSections(.project(work.id), limit: 4)
        let completed2 = try #require(page2.first(where: { $0.id == "completed" }))
        #expect(completed2.tasks.count == 4)
        #expect(!completed2.hasMore)
    }

    @Test func outboxRecordsFieldLevelChanges() async throws {
        let api = try await makeAPI()
        let t = try await api.createTask(CreateTaskInput(title: "a"))
        let before = try await api.pendingChanges().count
        var u = UpdateTaskInput(taskId: t.id)
        u.title = "b"
        _ = try await api.updateTask(u)
        let changes = try await api.pendingChanges()
        #expect(changes.count == before + 1)
        #expect(changes.last?.entity == "task")
        #expect(changes.last!.fields == ["title"])
        // A no-op write leaves no trace.
        _ = try await api.updateTask(UpdateTaskInput(taskId: t.id))
        let after = try await api.pendingChanges()
        // The clock is fixed, so updatedAt does not move either.
        #expect(after.count == changes.count)
    }

    @Test func trashRestoreSearchAndProjects() async throws {
        let api = try await makeAPI()
        let p = try await api.createProject(CreateProjectInput(name: "我們的行程", color: "#E8C14E"))
        let t = try await api.createTask(CreateTaskInput(projectId: p.id, title: "晚餐：巷口火鍋", content: "記得先訂位"))
        #expect(try await api.searchTasks(text: "訂位", activeOnly: true).map(\.id) == [t.id])
        try await api.deleteTask(id: t.id)
        #expect(try await api.searchTasks(text: "訂位", activeOnly: false).isEmpty)
        #expect(try await api.listSections(.smart(.trash)).first?.tasks.count == 1)
        _ = try await api.restoreTask(id: t.id)
        var up = UpdateProjectInput(projectId: p.id)
        up.archived = true
        _ = try await api.updateProject(up)
        #expect(try await api.listProjects(includeArchived: false).contains { $0.id == p.id } == false)
        let inbox = try await api.listProjects(includeArchived: false)[0]
        await #expect(throws: DayDoError.self) { try await api.deleteProject(id: inbox.id) }
    }

    @Test func moveProjectReordersWithinGroupAndRecordsOutbox() async throws {
        let api = try await makeAPI()
        let initial = try await api.listProjects(includeArchived: false)
        // Initial order: [收件匣(inbox), 工作, 個人, 購物]
        #expect(initial.map(\.name) == ["收件匣", "工作", "個人", "購物"])
        let work = initial[1], personal = initial[2], shop = initial[3]

        let beforeChanges = try await api.pendingChanges().count
        // Pin 購物 to the top of root lists (before 工作); inbox must stay first.
        _ = try await api.moveProject(id: shop.id, beforeProjectId: work.id)
        let afterPin = try await api.listProjects(includeArchived: false)
        #expect(afterPin.map(\.name) == ["收件匣", "購物", "工作", "個人"])

        let changes = try await api.pendingChanges()
        #expect(changes.count == beforeChanges + 1)
        #expect(changes.last?.entity == "project")
        #expect(changes.last?.entityId == shop.id)
        #expect(changes.last?.fields == ["sortKey"])

        // Move 購物 to the end (beforeProjectId: nil).
        _ = try await api.moveProject(id: shop.id, beforeProjectId: nil)
        #expect(try await api.listProjects(includeArchived: false).map(\.name) == ["收件匣", "工作", "個人", "購物"])

        // Move 個人 between 工作 and 購物? Actually move 個人 before 工作 -> [收件匣, 個人, 工作, 購物].
        _ = try await api.moveProject(id: personal.id, beforeProjectId: work.id)
        #expect(try await api.listProjects(includeArchived: false).map(\.name) == ["收件匣", "個人", "工作", "購物"])

        // Folder-scoped lists reorder independently within their folder.
        let folder = try await api.createFolder(name: "資料夾")
        let f1 = try await api.createProject(CreateProjectInput(name: "F1", folderId: folder.id))
        let f2 = try await api.createProject(CreateProjectInput(name: "F2", folderId: folder.id))
        _ = try await api.moveProject(id: f2.id, beforeProjectId: f1.id)
        let folderLists = try await api.listProjects(includeArchived: false).filter { $0.folderId == folder.id }
        #expect(folderLists.map(\.name) == ["F2", "F1"])

        // Inbox cannot be reordered, and cross-group move is rejected.
        await #expect(throws: DayDoError.self) { try await api.moveProject(id: initial[0].id, beforeProjectId: work.id) }
        await #expect(throws: DayDoError.self) { try await api.moveProject(id: f1.id, beforeProjectId: work.id) }
    }

    @Test func remindersAreScheduledInTheFuture() async throws {
        let api = try await makeAPI()
        _ = try await api.createTask(CreateTaskInput(title: "簡報", start: "2026-11-15T18:00", due: "2026-11-15T18:30", timeZone: "Asia/Taipei", reminders: ["TRIGGER:-PT15M", "TRIGGER:-P1D"]))
        let r = try await api.upcomingReminders(limit: 10)
        #expect(r.count == 1)
        #expect(r[0].fireDate == LocalDay("2026-11-15")!.date(minute: 1065, in: taipei))
    }

    @Test func dtoJSONIsSnakeCase() async throws {
        let api = try await makeAPI()
        let t = try await api.createTask(CreateTaskInput(title: "x", start: "2026-11-15T09:00", timeZone: "Asia/Taipei"))
        let json = String(data: try DayDoJSON.encoder.encode(t), encoding: .utf8)!
        #expect(json.contains("\"project_id\""))
        #expect(json.contains("\"start\" : \"2026-11-15T09:00:00+08:00\""))
        #expect(json.contains("\"all_day\" : false"))
        #expect(json.contains("\"timezone\" : \"Asia/Taipei\""))
        let input = try DayDoJSON.decoder.decode(CreateTaskInput.self, from: Data(#"{"title":"x","start":"2026-11-15T09:00","timezone":"Asia/Tokyo"}"#.utf8))
        #expect(input.timeZone == "Asia/Tokyo")
    }
}
