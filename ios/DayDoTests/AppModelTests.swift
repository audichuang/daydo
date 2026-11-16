import XCTest
@testable import DayDo
import DayDoCore

private actor RemoteSoftDeleteTransport: SyncTransport {
    private var pullCount = 0
    private var taskToSoftDelete: TodoTask?

    func scheduleRemoteSoftDelete(_ task: TodoTask) {
        taskToSoftDelete = task
    }

    func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
        let nowMs = EpochMillis(Date().timeIntervalSince1970 * 1000)
        let serverHLC = HLC(ms: nowMs, counter: 0, deviceId: "srv").description

        if method == "POST" && path == "/auth/apple" {
            return try jsonResponse(200, [
                "accessToken": "test-access",
                "refreshToken": "test-refresh",
                "user": ["id": "test-user"],
                "isNewAccount": true,
                "hasData": false,
                "meMemberId": NSNull(),
                "inboxProjectId": NSNull(),
            ])
        }

        if method == "POST" && path == "/sync/push" {
            var results: [[String: Any]] = []
            if let body,
               let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let ops = payload["ops"] as? [[String: Any]] {
                for op in ops {
                    if let opId = op["opId"] as? String {
                        results.append(["opId": opId, "status": "applied"])
                    }
                }
            }
            return try jsonResponse(200, ["results": results, "serverTime": serverHLC])
        }

        if method == "POST" && path == "/sync/pull" {
            pullCount += 1
            if let task = taskToSoftDelete {
                taskToSoftDelete = nil
                let deletedMs = task.updatedAt + 60_000
                let futureHLC = HLC(ms: deletedMs, counter: 0, deviceId: "other-iphone").description
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:test-user",
                        "rows": [[
                            "entity": "task",
                            "row": [
                                "id": task.id,
                                "projectId": task.projectId,
                                "title": task.title,
                                "content": task.content,
                                "priority": task.priority.rawValue,
                                "status": task.status,
                                "reminders": [],
                                "tags": [],
                                "sortKey": task.sortKey,
                                "createdAt": task.createdAt,
                                "updatedAt": deletedMs,
                                "deletedAt": deletedMs,
                            ],
                            "clocks": ["deletedAt": futureHLC],
                            "serverSeq": pullCount,
                        ]],
                        "cursor": pullCount,
                        "hasMore": false,
                    ]],
                    "members": [],
                ])
            }
            return try jsonResponse(200, ["scopes": [], "members": []])
        }

        return try jsonResponse(404, ["error": "Not found"])
    }

    private func jsonResponse(_ status: Int, _ object: Any) throws -> SyncHTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: object)
        return SyncHTTPResponse(status: status, body: data)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel(
        syncEnabled: Bool = false,
        transport: (any SyncTransport)? = nil
    ) async throws -> (AppModel, DeviceStore) {
        let store = try DeviceStore.inMemory()
        if !syncEnabled {
            try await store.bootstrap()
        }
        let model = AppModel(
            store: store,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: syncEnabled,
            transport: transport
        )
        if syncEnabled {
            try await model.signIn(with: .apple(identityToken: "t", nonce: "n"))
        } else {
            await model.reloadData()
        }
        return (model, store)
    }

    func testSelectedTaskRemotelySoftDeletedThenDeleteDoesNotPurge() async throws {
        let transport = RemoteSoftDeleteTransport()
        let (model, store) = try await makeModel(syncEnabled: true, transport: transport)
        let api = store.api
        let project = try await api.createProject(CreateProjectInput(name: "家庭採買"))
        let task = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "買鮮奶",
            start: model.today.description,
            allDay: true
        ))
        try await model.syncEngine.syncNow()
        await model.reloadData()

        model.scope = .smart(.today)
        model.selectedTaskId = task.id

        // Another account's iPhone soft-deletes the shared task and syncs.
        await transport.scheduleRemoteSoftDelete(task)
        try await model.syncEngine.syncNow()
        await model.reloadData()

        // Pressing Delete in 今天 while selectedTaskId still points to the task must NOT purge.
        model.deleteSelectedTask(id: task.id)
        for _ in 0..<40 where model.selectedTaskId != nil {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertNil(model.selectedTaskId, "Stale selection on a remotely soft-deleted task should clear")
        let fetched = try await api.getTask(id: task.id)
        XCTAssertNotNil(fetched.deletedAt, "Task must remain soft-deleted, not purged")

        let hasPendingPurge = try await store.hasPendingChange(entity: "task", entityId: task.id, op: "delete")
        XCTAssertFalse(
            hasPendingPurge,
            "Permanent delete op must not be queued outside Trash"
        )

        let trashSections = try await api.listSections(.smart(.trash))
        let trashIds = trashSections.flatMap(\.tasks).map(\.id)
        XCTAssertTrue(trashIds.contains(task.id), "Remotely soft-deleted task must remain restorable in 垃圾桶")
    }

    func testPurgeTaskOnlyAllowedInTrashWhenSoftDeleted() async throws {
        let (model, store) = try await makeModel()
        let api = store.api
        let project = try await api.createProject(CreateProjectInput(name: "家庭採買"))
        let active = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "未刪除任務",
            start: model.today.description,
            allDay: true
        ))
        let trashed = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "已刪除任務",
            start: model.today.description,
            allDay: true
        ))
        try await api.deleteTask(id: trashed.id)
        await model.reloadData()

        // Calling purgeTask outside Trash must be a no-op even if deletedAt != nil.
        model.scope = .smart(.today)
        await model.purgeTask(id: trashed.id)
        let stillInTrash = try await api.getTask(id: trashed.id)
        XCTAssertNotNil(stillInTrash.deletedAt)

        // Calling purgeTask in Trash on a non-deleted task must be a no-op.
        model.scope = .smart(.trash)
        await model.purgeTask(id: active.id)
        let stillActive = try await api.getTask(id: active.id)
        XCTAssertNil(stillActive.deletedAt)

        // Calling purgeTask in Trash on a soft-deleted task permanently purges it.
        await model.purgeTask(id: trashed.id)
        do {
            _ = try await api.getTask(id: trashed.id)
            XCTFail("Expected purged task to throw notFound")
        } catch DayDoError.notFound {
            // expected
        }
    }

    func testCommandNBlockedInTrashAndCompletedScopes() async throws {
        let (model, _) = try await makeModel()
        model.tab = .tasks

        model.scope = .smart(.trash)
        XCTAssertFalse(model.canComposeForCurrentScope)
        model.openComposerForCurrentScope()
        XCTAssertNil(model.composing)

        model.scope = .smart(.completed)
        XCTAssertFalse(model.canComposeForCurrentScope)
        model.openComposerForCurrentScope()
        XCTAssertNil(model.composing)

        model.scope = .smart(.today)
        XCTAssertTrue(model.canComposeForCurrentScope)
        model.openComposerForCurrentScope()
        XCTAssertNotNil(model.composing)
    }

    func testInlineDetailSelectionShortcutsGuard() async throws {
        let (model, _) = try await makeModel()
        XCTAssertFalse(model.inlineDetailAllowsSelectionShortcuts)

        model.selectedTaskId = "task-1"
        XCTAssertTrue(model.inlineDetailAllowsSelectionShortcuts)

        model.inlineDetailSubpageTaskId = "task-1"
        XCTAssertFalse(model.inlineDetailAllowsSelectionShortcuts)

        // Selecting a different task clears stale subpage/focus guards.
        model.selectedTaskId = "task-2"
        XCTAssertNil(model.inlineDetailSubpageTaskId)
        XCTAssertTrue(model.inlineDetailAllowsSelectionShortcuts)

        model.inlineDetailFocusedTaskId = "task-2"
        XCTAssertFalse(model.inlineDetailAllowsSelectionShortcuts)
    }

    func testOpenTaskRouting() async throws {
        let (model, _) = try await makeModel()

        // Regular width in Tasks tab selects inline without bumping focus by default.
        model.tab = .tasks
        model.openTask("task-1", inlineAvailable: true)
        XCTAssertEqual(model.selectedTaskId, "task-1")
        XCTAssertNil(model.detailTaskId)
        XCTAssertEqual(model.detailFocusTrigger, 0)

        // Tapping the same task again without focusIfAlreadyInline does not bump focus.
        model.openTask("task-1", inlineAvailable: true)
        XCTAssertEqual(model.detailFocusTrigger, 0)

        // Keyboard Return on the already-selected inline task bumps detailFocusTrigger.
        model.openTask("task-1", inlineAvailable: true, focusIfAlreadyInline: true)
        XCTAssertEqual(model.detailFocusTrigger, 1)

        // Regular width outside Tasks tab opens the sheet instead of inline selection.
        model.tab = .calendar
        model.openTask("task-2", inlineAvailable: true)
        XCTAssertEqual(model.detailTaskId, "task-2")
        XCTAssertEqual(model.selectedTaskId, "task-1")

        // Compact width in Tasks tab opens the sheet (even with focusIfAlreadyInline).
        model.detailTaskId = nil
        model.tab = .tasks
        model.openTask("task-3", inlineAvailable: false, focusIfAlreadyInline: true)
        XCTAssertEqual(model.detailTaskId, "task-3")
        XCTAssertEqual(model.detailFocusTrigger, 1)

        // Notification open queues behind active sheet and opens as a sheet on flush.
        model.openDetailFromNotification("task-4")
        XCTAssertEqual(model.pendingDetailTaskId, "task-4")
        XCTAssertEqual(model.detailTaskId, "task-3")
        model.detailTaskId = nil
        model.flushPendingPresentations()
        XCTAssertNil(model.pendingDetailTaskId)
        XCTAssertEqual(model.detailTaskId, "task-4")
    }

    func testWidgetDeepLinkRoutingAndQueuingBeforeLaunchReady() async throws {
        let store = try DeviceStore.inMemory()
        try await store.bootstrap()
        let model = AppModel(
            store: store,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: false
        )

        // Deep link arriving before launch() completes is queued and flushed on ready+signedIn.
        let targetDay = LocalDay(year: 2026, month: 11, day: 20)
        model.handleWidgetDeepLink(.calendar(targetDay))
        XCTAssertEqual(model.pendingWidgetDeepLink, .calendar(targetDay))
        XCTAssertEqual(model.tab, .tasks)

        await model.launch()
        XCTAssertNil(model.pendingWidgetDeepLink)
        XCTAssertEqual(model.tab, .calendar)
        XCTAssertEqual(model.calendarNavigationDay, targetDay)
        XCTAssertEqual(model.calendarNavigationTrigger, 1)

        model.handleWidgetDeepLink(.today)
        XCTAssertEqual(model.tab, .tasks)
        XCTAssertEqual(model.scope, .smart(.today))

        model.handleWidgetDeepLink(.task("widget-task-1"))
        XCTAssertEqual(model.detailTaskId, "widget-task-1")
    }
}
