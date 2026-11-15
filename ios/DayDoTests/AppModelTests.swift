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
    ) async throws -> (AppModel, LocalDayDoAPI) {
        let db = try AppDatabase.inMemory()
        let attachmentsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let api = LocalDayDoAPI(database: db, attachmentsDirectory: attachmentsDir)
        if !syncEnabled {
            try await api.bootstrap()
        }
        let model = AppModel(
            api: api,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: syncEnabled,
            transport: transport
        )
        if syncEnabled {
            try await model.signIn(with: .apple(identityToken: "t", nonce: "n"))
        } else {
            await model.reloadData()
        }
        return (model, api)
    }

    func testSelectedTaskRemotelySoftDeletedThenDeleteDoesNotPurge() async throws {
        let transport = RemoteSoftDeleteTransport()
        let (model, api) = try await makeModel(syncEnabled: true, transport: transport)
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

        let pending = try await api.pendingChanges(limit: 1000)
        XCTAssertFalse(
            pending.contains { $0.entity == "task" && $0.entityId == task.id && $0.op == "delete" },
            "Permanent delete op must not be queued outside Trash"
        )

        let trashSections = try await api.listSections(.smart(.trash))
        let trashIds = trashSections.flatMap(\.tasks).map(\.id)
        XCTAssertTrue(trashIds.contains(task.id), "Remotely soft-deleted task must remain restorable in 垃圾桶")
    }

    func testPurgeTaskOnlyAllowedInTrashWhenSoftDeleted() async throws {
        let (model, api) = try await makeModel()
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
}
