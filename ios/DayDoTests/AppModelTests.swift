import SwiftUI
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
        transport: (any SyncTransport)? = nil,
        clock: any Swift.Clock<Duration> = ContinuousClock(),
        reduceMotion: @escaping @MainActor () -> Bool = { false }
    ) async throws -> (AppModel, DeviceStore) {
        let store = try DeviceStore.inMemory()
        if !syncEnabled {
            try await store.bootstrap()
        }
        let model = AppModel(
            store: store,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: syncEnabled,
            transport: transport,
            clock: clock,
            reduceMotion: reduceMotion
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

    func testScenePhaseChangeBackgroundTaskAndExpirationLifecycle() async throws {
        let (model, _) = try await makeModel()
        var events: [String] = []
        var nextID = 1
        var handlers: [Int: DatabaseSuspensionCoordinator.ExpirationHandler] = [:]

        let coordinator = DatabaseSuspensionCoordinator(
            beginBackgroundTask: { _, handler in
                let raw = nextID
                nextID += 1
                handlers[raw] = handler
                events.append("begin:\(raw)")
                return UIBackgroundTaskIdentifier(rawValue: raw)
            },
            endBackgroundTask: { id in
                events.append("end:\(id.rawValue)")
            },
            suspend: { events.append("suspend") },
            resume: { events.append("resume") }
        )

        // Active -> inactive does nothing.
        DayDoApp.handleScenePhaseChange(from: .active, to: .inactive, model: model, coordinator: coordinator)
        XCTAssertEqual(events, [])

        // Entering background opens one background task without suspending immediately.
        DayDoApp.handleScenePhaseChange(from: .inactive, to: .background, model: model, coordinator: coordinator)
        XCTAssertEqual(events, ["begin:1"])

        // Repeated background entry does not open a second background task.
        DayDoApp.handleScenePhaseChange(from: .inactive, to: .background, model: model, coordinator: coordinator)
        XCTAssertEqual(events, ["begin:1"])

        // Leaving background before expiration ends the task without suspend/resume.
        DayDoApp.handleScenePhaseChange(from: .background, to: .inactive, model: model, coordinator: coordinator)
        XCTAssertEqual(events, ["begin:1", "end:1"])

        // Stale expiration callback after returning to foreground is a no-op.
        handlers[1]?()
        XCTAssertEqual(events, ["begin:1", "end:1"])

        // Entering background again opens a new task; expiration suspends then ends the task.
        DayDoApp.handleScenePhaseChange(from: .active, to: .background, model: model, coordinator: coordinator)
        XCTAssertEqual(events, ["begin:1", "end:1", "begin:2"])
        handlers[2]?()
        XCTAssertEqual(events, ["begin:1", "end:1", "begin:2", "suspend", "end:2"])

        // Leaving background after expiration resumes synchronously.
        DayDoApp.handleScenePhaseChange(from: .background, to: .active, model: model, coordinator: coordinator)
        XCTAssertEqual(events, ["begin:1", "end:1", "begin:2", "suspend", "end:2", "resume"])
    }

    func testScenePhaseChangeSuspendsOnExpirationAndResumesRealDatabaseBeforeForegroundReload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daydo-app-suspension-\(UUID().uuidString)", isDirectory: true)
        defer {
            DayDoStorage.resumeDatabaseAccess()
            try? FileManager.default.removeItem(at: dir)
        }

        let store = try DayDoStorage.openForApp(in: dir)
        let model = AppModel(
            store: store,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: false
        )
        await model.launch()
        XCTAssertTrue(model.ready)
        XCTAssertTrue(model.isSignedIn)

        var expirationHandler: DatabaseSuspensionCoordinator.ExpirationHandler?
        var endedIDs: [Int] = []
        let coordinator = DatabaseSuspensionCoordinator(
            beginBackgroundTask: { _, handler in
                expirationHandler = handler
                return UIBackgroundTaskIdentifier(rawValue: 42)
            },
            endBackgroundTask: { id in
                endedIDs.append(id.rawValue)
            }
        )

        // Entering background keeps writes working until expiration so pending saves can finish.
        DayDoApp.handleScenePhaseChange(from: .inactive, to: .background, model: model, coordinator: coordinator)
        let savedInBackground = try await store.api.createTask(CreateTaskInput(title: "Saved before expiration"))
        XCTAssertEqual(endedIDs, [])

        // System expiration suspends DB access and ends the background task.
        let handler = try XCTUnwrap(expirationHandler)
        handler()
        XCTAssertEqual(endedIDs, [42])

        do {
            _ = try await store.api.createTask(CreateTaskInput(title: "Should fail while suspended"))
            XCTFail("Expected write while suspended to throw")
        } catch {
            // expected
        }

        // Direct .background -> .active must resume synchronously before foreground reloadData() runs.
        let beforeRevision = model.revision
        DayDoApp.handleScenePhaseChange(from: .background, to: .active, model: model, coordinator: coordinator)
        for _ in 0..<40 where model.revision == beforeRevision {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(model.revision, beforeRevision)
        XCTAssertNil(model.errorMessage)

        let created = try await store.api.createTask(CreateTaskInput(title: "Allowed after foreground"))
        let tasks = try await store.api.listTasks(TaskQuery())
        XCTAssertEqual(Set(tasks.map(\.id)), [savedInBackground.id, created.id])
    }

    func testToggleCompleteAfterConcurrentTitleUpdateStillCompletes() async throws {
        let clock = TestClock()
        let (model, store) = try await makeModel(clock: clock)
        let api = store.api
        let task = try await api.createTask(CreateTaskInput(
            title: "原本標題",
            start: model.today.description,
            allDay: true
        ))
        await model.reloadData()

        model.toggleComplete(task)
        XCTAssertTrue(model.displaysCompleted(task))
        await clock.waitForSleeper()

        // Not written before the commit delay even after a concurrent title edit.
        await clock.advance(by: AppModel.completionCommitDelay - .milliseconds(1))
        var edit = UpdateTaskInput(taskId: task.id)
        edit.title = "已改標題"
        _ = try await api.updateTask(edit)
        let beforeCommit = try await api.getTask(id: task.id)
        XCTAssertFalse(beforeCommit.isCompleted, "Task must not be written before completionCommitDelay")
        XCTAssertTrue(model.displaysCompleted(beforeCommit))

        // Written at the commit delay, and optimistic state stays held during layoutSettle.
        await clock.advance(by: .milliseconds(1))
        await clock.waitForSleeper()
        let fetched = try await api.getTask(id: task.id)
        XCTAssertEqual(fetched.title, "已改標題")
        XCTAssertTrue(fetched.isCompleted, "Delayed toggleComplete must not be silently swallowed by an earlier save")
        XCTAssertNotNil(model.completingIds[task.id], "Optimistic state must remain held right after commit")

        await clock.advance(by: Motion.layoutSettle(false) - .milliseconds(1))
        XCTAssertNotNil(model.completingIds[task.id], "Optimistic state must remain held until layoutSettle elapses")
        XCTAssertTrue(model.displaysCompleted(task), "Unrefreshed snapshot still renders completed during hold")

        await clock.advance(by: .milliseconds(1))
        await model.waitForCompletions()
        XCTAssertTrue(model.completingIds.isEmpty, "Optimistic state must release after layoutSettle")
        XCTAssertFalse(model.displaysCompleted(task), "Unrefreshed snapshot stops appearing completed once hold releases")
    }

    func testToggleCompleteRepeatingTaskCompletesOnlyOnce() async throws {
        let clock = TestClock()
        let (model, store) = try await makeModel(clock: clock)
        let api = store.api
        let task = try await api.createTask(CreateTaskInput(
            title: "每日例行",
            start: model.today.description,
            allDay: true,
            repeat: "RRULE:FREQ=DAILY"
        ))
        await model.reloadData()

        // 1. Rapid double-tap is ignored while completingLocks holds the task.
        model.toggleComplete(task)
        model.toggleComplete(task)
        await clock.waitForSleeper()

        // 2. If another writer already completed this occurrence during the commit delay
        //    (advancing the repeating task's schedule), the delayed write must NOT complete
        //    the next occurrence a second time.
        _ = try await api.completeTask(id: task.id, ifUpdatedAt: task.updatedAt)

        await clock.advance(by: AppModel.completionCommitDelay)
        await model.waitForCompletions()

        let all = try await api.listTasks(TaskQuery(includeCompleted: true))
        let completedCopies = all.filter { $0.isCompleted && $0.title == "每日例行" }
        XCTAssertEqual(completedCopies.count, 1, "Repeating task must produce exactly one completed copy")

        let active = try await api.getTask(id: task.id)
        XCTAssertFalse(active.isCompleted)
        XCTAssertEqual(active.schedule?.startDay, model.today.adding(days: 1))
        XCTAssertTrue(model.completingIds.isEmpty)
    }

    func testToggleCompleteRepeatingTaskNextOccurrenceIsNotCompletingAndCanCompleteImmediately() async throws {
        let clock = TestClock()
        let (model, store) = try await makeModel(clock: clock)
        let api = store.api
        let task = try await api.createTask(CreateTaskInput(
            title: "每日打卡",
            start: model.today.description,
            allDay: true,
            repeat: "RRULE:FREQ=DAILY"
        ))
        await model.reloadData()

        model.toggleComplete(task)
        XCTAssertTrue(model.displaysCompleted(task))
        await clock.waitForSleeper()

        // Before the commit delay, nothing is written yet.
        await clock.advance(by: AppModel.completionCommitDelay - .milliseconds(1))
        let preWrite = try await api.getTask(id: task.id)
        XCTAssertEqual(preWrite.schedule?.startDay, model.today)

        // At the commit delay, completeTask writes and immediately unlocks the next occurrence
        // while keeping the clicked occurrence held for layoutSettle.
        await clock.advance(by: .milliseconds(1))
        await clock.waitForSleeper()

        let nextOccurrence = try await api.getTask(id: task.id)
        XCTAssertEqual(nextOccurrence.schedule?.startDay, model.today.adding(days: 1))
        XCTAssertTrue(model.displaysCompleted(task), "Clicked occurrence must remain displayed as completed during hold")
        XCTAssertFalse(model.displaysCompleted(nextOccurrence), "Next occurrence must not appear optimistically completed during the hold window")

        model.toggleComplete(nextOccurrence)
        XCTAssertTrue(model.displaysCompleted(nextOccurrence), "Next occurrence must be immediately completable without being swallowed")
        await clock.waitForSleeper(count: 2)

        await clock.advance(by: AppModel.completionCommitDelay)
        await clock.waitForSleeper(count: 2)

        let secondAdvanced = try await api.getTask(id: task.id)
        XCTAssertEqual(secondAdvanced.schedule?.startDay, model.today.adding(days: 2))

        await clock.advance(by: Motion.layoutSettle(false))
        await model.waitForCompletions()

        let all = try await api.listTasks(TaskQuery(includeCompleted: true))
        let completedCopies = all.filter { $0.isCompleted && $0.title == "每日打卡" }
        XCTAssertEqual(completedCopies.count, 2)
        let finalTask = try await api.getTask(id: task.id)
        XCTAssertEqual(finalTask.schedule?.startDay, model.today.adding(days: 2))
        XCTAssertTrue(model.completingIds.isEmpty)
    }

    func testDisplaysCompletedShowsClickedOccurrenceOnlyForRepeatingTask() async throws {
        let clock = TestClock()
        let (model, store) = try await makeModel(clock: clock)
        let api = store.api
        let clicked = try await api.createTask(CreateTaskInput(
            title: "週期測試",
            start: model.today.description,
            allDay: true,
            repeat: "RRULE:FREQ=DAILY"
        ))
        await model.reloadData()

        XCTAssertFalse(model.displaysCompleted(clicked))
        model.toggleComplete(clicked)
        XCTAssertTrue(model.displaysCompleted(clicked))

        await clock.waitForSleeper()
        await clock.advance(by: AppModel.completionCommitDelay)
        await clock.waitForSleeper()

        let nextOccurrence = try await api.getTask(id: clicked.id)
        XCTAssertEqual(nextOccurrence.schedule?.startDay, model.today.adding(days: 1))
        XCTAssertTrue(model.displaysCompleted(clicked), "Clicked occurrence stays completed during layoutSettle hold")
        XCTAssertFalse(model.displaysCompleted(nextOccurrence), "Repeating task's next occurrence must not show completed")

        await clock.advance(by: Motion.layoutSettle(false))
        await model.waitForCompletions()
        XCTAssertFalse(model.displaysCompleted(clicked))
        XCTAssertFalse(model.displaysCompleted(nextOccurrence))
    }

    func testToggleCompleteHoldUsesReducedLayoutSettleUnderReduceMotion() async throws {
        let clock = TestClock()
        let (model, store) = try await makeModel(clock: clock, reduceMotion: { true })
        let api = store.api
        let task = try await api.createTask(CreateTaskInput(
            title: "減少動態效果",
            start: model.today.description,
            allDay: true
        ))
        await model.reloadData()

        model.toggleComplete(task)
        await clock.waitForSleeper()
        await clock.advance(by: AppModel.completionCommitDelay)
        await clock.waitForSleeper()

        await clock.advance(by: Motion.layoutSettle(true) - .milliseconds(1))
        XCTAssertNotNil(model.completingIds[task.id])

        await clock.advance(by: .milliseconds(1))
        // The sleeper resumes off the main actor first; give the release a bounded number of hops.
        for _ in 0..<100 where !model.completingIds.isEmpty { await Task.yield() }
        XCTAssertTrue(model.completingIds.isEmpty, "Reduced-motion hold should release at Motion.layoutSettle(true)")
        if !model.completingIds.isEmpty {
            await clock.advance(by: Motion.layoutSettle(false))
        }
        await model.waitForCompletions()
    }

    func testAppearanceDefaultRoundTripAndLaunchArgOverride() async throws {
        let suiteName = "daydo.test.appearance.\(UUID().uuidString)"
        let sharedSuiteName = "daydo.test.appearance.shared.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedSuiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            shared.removePersistentDomain(forName: sharedSuiteName)
            AppearanceApplier.apply(.dark)
        }

        let store = try DeviceStore.inMemory()
        try await store.bootstrap()

        // 1. Default is dark when nothing is stored.
        let initial = AppModel(
            store: store,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: false,
            defaults: defaults,
            sharedDefaults: shared,
            arguments: []
        )
        XCTAssertEqual(initial.appearance, .dark)
        XCTAssertEqual(shared.string(forKey: AppAppearance.defaultsKey), "dark")

        // 2. Stored value round-trips to defaults, sharedDefaults, and a fresh AppModel.
        initial.appearance = .light
        XCTAssertEqual(defaults.string(forKey: AppAppearance.defaultsKey), "light")
        XCTAssertEqual(shared.string(forKey: AppAppearance.defaultsKey), "light")

        let reloaded = AppModel(
            store: store,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: false,
            defaults: defaults,
            sharedDefaults: shared,
            arguments: []
        )
        XCTAssertEqual(reloaded.appearance, .light)

        reloaded.appearance = .system
        let reloadedSystem = AppModel(
            store: store,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: false,
            defaults: defaults,
            sharedDefaults: shared,
            arguments: []
        )
        XCTAssertEqual(reloadedSystem.appearance, .system)

        // 3. Launch argument `-appearance` overrides the stored setting.
        let forcedDark = AppModel(
            store: store,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: false,
            defaults: defaults,
            sharedDefaults: shared,
            arguments: ["DayDo", "-appearance", "dark"]
        )
        XCTAssertEqual(forcedDark.appearance, .dark)

        let forcedLight = AppModel(
            store: store,
            tokenStore: InMemorySyncTokenStore(),
            syncEnabled: false,
            defaults: defaults,
            sharedDefaults: shared,
            arguments: ["DayDo", "-appearance", "light"]
        )
        XCTAssertEqual(forcedLight.appearance, .light)
    }

    func testPaletteDarkTokensMatchOriginalHexByteForByte() throws {
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)

        func rgbaHex(_ color: Color, traits: UITraitCollection) -> String {
            let resolved = UIColor(color).resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
            let ri = Int((r * 255).rounded())
            let gi = Int((g * 255).rounded())
            let bi = Int((b * 255).rounded())
            let ai = Int((a * 255).rounded())
            if ai == 255 {
                return String(format: "#%02X%02X%02X", ri, gi, bi)
            }
            return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
        }

        let darkExpected: [(String, Color, String, String)] = [
            ("background", Palette.background, "#0E0F10", "#F2F3F5"),
            ("card", Palette.card, "#18191B", "#FFFFFF"),
            ("raised", Palette.raised, "#1F2123", "#F4F5F7"),
            ("control", Palette.control, "#232527", "#ECEDEF"),
            ("chip", Palette.chip, "#2A2C2E", "#E7E9EB"),
            ("separator", Palette.separator, "#26282A", "#E3E5E7"),
            ("separatorSoft", Palette.separatorSoft, "#2A2C2E", "#E7E9EB"),
            ("text", Palette.text, "#F1F3F2", "#111314"),
            ("textBody", Palette.textBody, "#D3D8D6", "#2A2E2C"),
            ("textSecondary", Palette.textSecondary, "#9BA3A0", "#5F6764"),
            ("textTertiary", Palette.textTertiary, "#8A928F", "#6F7774"),
            ("textFaint", Palette.textFaint, "#6E7673", "#767E7B"),
            ("textMuted", Palette.textMuted, "#B7BEBB", "#4E5653"),
            ("textNav", Palette.textNav, "#C9CFCC", "#3A403E"),
            ("done", Palette.done, "#7A827F", "#7C8481"),
            ("overdue", Palette.overdue, "#FF7A70", "#D9383E"),
            ("conflict", Palette.conflict, "#F7B500", "#A87300"),
            ("danger", Palette.danger, "#FF7A70", "#D9383E"),
            ("handle", Palette.handle, "#3A3D40", "#C9CDCF"),
            ("priority.high", Palette.priority(.high), "#F2555A", "#E03E43"),
            ("priority.medium", Palette.priority(.medium), "#F7B500", "#C98F00"),
            ("priority.low", Palette.priority(.low), "#4E8BF7", "#3270DF"),
            ("priority.none", Palette.priority(.none), "#7C8582", "#8A928F"),
            ("textDay", Palette.textDay, "#E6E9E8", "#1D201F"),
            ("textDisabled", Palette.textDisabled, "#737B78", "#8C9491"),
            ("gridLabel", Palette.gridLabel, "#737B78", "#767E7B"),
            ("border", Palette.border, "#33363A", "#D5D8DC"),
            ("gridLine", Palette.gridLine, "#222426", "#E6E8EB"),
            ("gridColumnLine", Palette.gridColumnLine, "#1E2022", "#ECEEF0"),
            ("blockMuted", Palette.blockMuted, "#26292B", "#ECEDEF"),
            ("blockMutedBorder", Palette.blockMutedBorder, "#33373A", "#D5D8DC"),
            ("checkboxMuted", Palette.checkboxMuted, "#5B6461", "#9AA19E"),
            ("codeWell", Palette.codeWell, "#121314", "#FFFFFF"),
            ("segmentSelected", Palette.segmentSelected, "#3A3D40", "#FFFFFF"),
            ("segmentSelectedText", Palette.segmentSelectedText, "#FFFFFF", "#111314"),
        ]

        for (name, color, darkHex, lightHex) in darkExpected {
            XCTAssertEqual(rgbaHex(color, traits: darkTraits), darkHex, "Dark mismatch for \(name)")
            XCTAssertEqual(rgbaHex(color, traits: lightTraits), lightHex, "Light mismatch for \(name)")
        }

        // AccentTheme.text: dark mixes 10% toward white; light mixes 30% toward black.
        let orange = AccentTheme(hex: "#FF8A1E")
        XCTAssertEqual(rgbaHex(orange.text, traits: darkTraits), "#FF9635")
        XCTAssertEqual(rgbaHex(orange.text, traits: lightTraits), "#B36115")

        // Tag style in dark matches exact tag color + 16% alpha; light is darkened for contrast.
        let (tagBg, tagFg) = Palette.tagStyle("會議", color: "#B6C1FF")
        XCTAssertEqual(rgbaHex(tagFg, traits: darkTraits), "#B6C1FF")
        XCTAssertEqual(rgbaHex(tagBg, traits: darkTraits), "#B6C1FF29")
        XCTAssertNotEqual(rgbaHex(tagFg, traits: lightTraits), "#B6C1FF")

        // Glass & nav tokens keep exact dark RGBA.
        XCTAssertEqual(rgbaHex(Palette.glassTint, traits: darkTraits), "#282A2C8C")
        XCTAssertEqual(rgbaHex(Palette.navGlassTint, traits: darkTraits), "#24262899")
        XCTAssertEqual(rgbaHex(Palette.navSelection, traits: darkTraits), "#FFFFFF14")
        XCTAssertEqual(rgbaHex(Palette.fabShadow, traits: darkTraits), "#00000059")
        XCTAssertEqual(rgbaHex(Palette.fabShadow, traits: lightTraits), "#00000024")
    }

    func testTaskCheckboxCheckmarkResolvesToDarkInkForAllAccents() throws {
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)

        func hex(_ color: Color, traits: UITraitCollection) -> String {
            let resolved = UIColor(color).resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
            return String(
                format: "#%02X%02X%02X",
                Int((r * 255).rounded()),
                Int((g * 255).rounded()),
                Int((b * 255).rounded())
            )
        }

        for accentHex in Palette.accentOptions {
            let checkmark = TaskCheckbox.checkmarkColor(accent: AccentTheme(hex: accentHex))
            XCTAssertEqual(hex(checkmark, traits: darkTraits), "#0E0F10", "Dark checkmark mismatch for \(accentHex)")
            XCTAssertEqual(hex(checkmark, traits: lightTraits), "#0E0F10", "Light checkmark mismatch for \(accentHex)")
        }
    }

    func testAppearanceApplierUpdatesWindowsAndPresentedSheet() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let rootVC = UIViewController()
        let sheetVC = UIViewController()
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        defer {
            rootVC.dismiss(animated: false)
            window.isHidden = true
            AppearanceApplier.apply(.dark)
        }

        rootVC.present(sheetVC, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        AppearanceApplier.apply(.dark)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(window.traitCollection.userInterfaceStyle, .dark)
        XCTAssertEqual(rootVC.traitCollection.userInterfaceStyle, .dark)
        XCTAssertEqual(sheetVC.traitCollection.userInterfaceStyle, .dark)

        AppearanceApplier.apply(.light)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(window.traitCollection.userInterfaceStyle, .light)
        XCTAssertEqual(rootVC.traitCollection.userInterfaceStyle, .light)
        XCTAssertEqual(sheetVC.traitCollection.userInterfaceStyle, .light)

        AppearanceApplier.apply(.system)
        XCTAssertEqual(window.overrideUserInterfaceStyle, .unspecified)
    }

    private func sharedProject(id: String = "shared-1", memberIds: [String], archived: Bool = false) -> Project {
        Project(
            id: id,
            name: "共享清單",
            viewMode: "list",
            kind: "TASK",
            isInbox: false,
            ownerId: memberIds.first ?? "me",
            sortKey: "z1",
            showInSmart: "all",
            notifyMode: "all",
            archived: archived,
            memberIds: memberIds,
            activeCount: 0,
            createdAt: 0,
            updatedAt: 0
        )
    }

    func testAllMemberFilterPersistsAndFallsBackWhenMemberMissing() async throws {
        let suiteName = "daydo-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = try DeviceStore.inMemory()
        try await store.bootstrap()

        let m1 = AppModel(store: store, syncEnabled: false, defaults: defaults)
        let partner = Member(id: "partner-1", name: "小安", initial: "小", color: Member.avatarColors[0], isMe: false)
        await m1.reloadData()
        let me = try XCTUnwrap(m1.me)
        m1.members = [me, partner]
        m1.projects.append(sharedProject(memberIds: [me.id, partner.id]))
        m1.allMemberFilter = partner.id

        XCTAssertEqual(defaults.string(forKey: AppModel.allMemberFilterKey), partner.id)
        XCTAssertEqual(m1.effectiveAllMemberFilter, partner.id)

        // New AppModel reads the persisted filter from UserDefaults.
        let m2 = AppModel(store: store, syncEnabled: false, defaults: defaults)
        XCTAssertEqual(m2.allMemberFilter, partner.id)
        // Before members load (or when partner no longer exists), effective filter falls back to nil.
        XCTAssertNil(m2.effectiveAllMemberFilter)

        // A refresh that only sees `me` (e.g. before sync catches up) falls back
        // to 全部 without forgetting the stored choice.
        await m2.refreshLookups()
        XCTAssertNil(m2.effectiveAllMemberFilter)
        XCTAssertEqual(defaults.string(forKey: AppModel.allMemberFilterKey), partner.id)
    }

    func testAllMemberFilterFallsBackWhenPartnerLeavesAllSharedLists() async throws {
        let suiteName = "daydo-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = try DeviceStore.inMemory()
        try await store.bootstrap()
        let model = AppModel(store: store, syncEnabled: false, defaults: defaults)
        await model.reloadData()
        let me = try XCTUnwrap(model.me)
        let partner = Member(id: "partner-1", name: "小安", initial: "小", color: Member.avatarColors[0], isMe: false)
        model.members = [me, partner]
        let shared = sharedProject(memberIds: [me.id, partner.id])
        model.projects.append(shared)
        model.allMemberFilter = partner.id

        XCTAssertEqual(model.filterMembers.map(\.id), [me.id, partner.id])
        XCTAssertEqual(model.effectiveAllMemberFilter, partner.id)

        // Both leave / are removed from the shared list, though partner remains in cached members.
        model.projects.removeAll { $0.id == shared.id }
        XCTAssertEqual(model.filterMembers.map(\.id), [me.id])
        XCTAssertNil(model.effectiveAllMemberFilter)
        XCTAssertEqual(defaults.string(forKey: AppModel.allMemberFilterKey), partner.id)
    }

    func testCreatingTaskHiddenByAllMemberFilterResetsFilter() async throws {
        let suiteName = "daydo-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = try DeviceStore.inMemory()
        try await store.bootstrap()
        let model = AppModel(store: store, syncEnabled: false, defaults: defaults)
        await model.reloadData()
        let me = try XCTUnwrap(model.me)
        let partner = Member(id: "partner-1", name: "小安", initial: "小", color: Member.avatarColors[0], isMe: false)
        model.members = [me, partner]
        model.projects.append(sharedProject(memberIds: [me.id, partner.id]))
        model.scope = .smart(.all)

        // Inbox task belongs to me: 「我的」 still shows it, filter stays.
        model.allMemberFilter = me.id
        let mine = try await model.api.createTask(CreateTaskInput(title: "我的新任務"))
        await model.revealCreatedTaskInAll(mine)
        XCTAssertEqual(model.allMemberFilter, me.id)

        // Same task under 「小安的」 would vanish, so the filter goes back to 全部.
        model.allMemberFilter = partner.id
        await model.revealCreatedTaskInAll(mine)
        XCTAssertNil(model.allMemberFilter)
    }

    func testDuplicateProjectIgnoresReentryWhileInFlight() async throws {
        actor SlowAttachmentTransport: SyncTransport {
            private let projId = "slow-dup-proj-1"
            private let taskId = "slow-dup-task-1"
            private let attId = "slow-dup-att-1"
            private var downloadStartedCont: CheckedContinuation<Void, Never>?
            private var downloadStarted = false
            private var allowFinishCont: CheckedContinuation<Void, Never>?
            private var allowFinish = false
            private(set) var downloadCount = 0

            func waitForDownloadStart() async {
                if downloadStarted { return }
                await withCheckedContinuation { downloadStartedCont = $0 }
            }

            func allowDownloadFinish() {
                allowFinish = true
                allowFinishCont?.resume()
                allowFinishCont = nil
            }

            func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
                let nowMs = EpochMillis(Date().timeIntervalSince1970 * 1000)
                let serverHLC = HLC(ms: nowMs, counter: 0, deviceId: "srv").description

                if method == "POST" && path == "/auth/apple" {
                    return try jsonResponse(200, [
                        "accessToken": "acc",
                        "refreshToken": "ref",
                        "user": ["id": "u-dup"],
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
                    return try jsonResponse(200, [
                        "scopes": [[
                            "scope": "u:u-dup",
                            "rows": [
                                [
                                    "entity": "project",
                                    "row": [
                                        "id": projId,
                                        "name": "待複製清單",
                                        "viewMode": "list",
                                        "kind": "TASK",
                                        "isInbox": false,
                                        "ownerId": "m-1",
                                        "sortKey": "z1",
                                        "showInSmart": "all",
                                        "notifyMode": "all",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["name": serverHLC],
                                    "serverSeq": 1,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": taskId,
                                        "projectId": projId,
                                        "title": "含遠端附件",
                                        "content": "",
                                        "priority": 0,
                                        "status": 0,
                                        "reminders": [],
                                        "tags": [],
                                        "sortKey": "a0",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC],
                                    "serverSeq": 2,
                                ],
                                [
                                    "entity": "attachment",
                                    "row": [
                                        "id": attId,
                                        "taskId": taskId,
                                        "fileName": "doc.txt",
                                        "size": 4,
                                        "mimeType": "text/plain",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["fileName": serverHLC],
                                    "serverSeq": 3,
                                ],
                            ],
                            "cursor": 3,
                            "hasMore": false,
                        ]],
                        "members": [],
                    ])
                }
                if method == "GET" && path == "/attachments/\(attId)/content" {
                    downloadCount += 1
                    downloadStarted = true
                    downloadStartedCont?.resume()
                    downloadStartedCont = nil
                    if !allowFinish {
                        await withCheckedContinuation { allowFinishCont = $0 }
                    }
                    return SyncHTTPResponse(status: 200, body: Data("test".utf8))
                }
                return try jsonResponse(404, ["error": "Not found"])
            }

            private func jsonResponse(_ status: Int, _ object: Any) throws -> SyncHTTPResponse {
                SyncHTTPResponse(status: status, body: try JSONSerialization.data(withJSONObject: object))
            }
        }

        let suiteName = "daydo-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let transport = SlowAttachmentTransport()
        let (model, _) = try await makeModel(syncEnabled: true, transport: transport)
        model.scope = .project("slow-dup-proj-1")

        model.duplicateProject(id: "slow-dup-proj-1")
        XCTAssertTrue(model.isDuplicatingProject("slow-dup-proj-1"))
        await transport.waitForDownloadStart()

        // Second trigger while in-flight must be ignored.
        model.duplicateProject(id: "slow-dup-proj-1")
        await transport.allowDownloadFinish()
        await model.waitForProjectDuplications()

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isDuplicatingProject("slow-dup-proj-1"))
        let downloadCount = await transport.downloadCount
        XCTAssertEqual(downloadCount, 1)
        let copies = model.projects.filter { $0.name == "待複製清單 副本" }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(model.scope, .project(try XCTUnwrap(copies.first?.id)))
    }

    func testDuplicateProjectCancelledOnSignOutLeavesNoErrorOrLock() async throws {
        actor GateTransport: SyncTransport {
            private let projId = "cancel-dup-proj-1"
            private let taskId = "cancel-dup-task-1"
            private let attId = "cancel-dup-att-1"
            private var started = false
            private var startedCont: CheckedContinuation<Void, Never>?
            private var allowFinish = false
            private var finishCont: CheckedContinuation<Void, Never>?

            func waitForDownloadStart() async {
                if started { return }
                await withCheckedContinuation { startedCont = $0 }
            }

            func allowDownloadFinish() {
                allowFinish = true
                finishCont?.resume()
                finishCont = nil
            }

            func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
                let nowMs = EpochMillis(Date().timeIntervalSince1970 * 1000)
                let serverHLC = HLC(ms: nowMs, counter: 0, deviceId: "srv").description
                if method == "POST" && path == "/auth/apple" {
                    return try jsonResponse(200, [
                        "accessToken": "acc",
                        "refreshToken": "ref",
                        "user": ["id": "u-cancel"],
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
                    return try jsonResponse(200, [
                        "scopes": [[
                            "scope": "u:u-cancel",
                            "rows": [
                                [
                                    "entity": "project",
                                    "row": [
                                        "id": projId, "name": "待取消清單", "viewMode": "list", "kind": "TASK",
                                        "isInbox": false, "ownerId": "m-1", "sortKey": "z1",
                                        "showInSmart": "all", "notifyMode": "all", "createdAt": nowMs, "updatedAt": nowMs,
                                    ],
                                    "clocks": ["name": serverHLC], "serverSeq": 1,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": taskId, "projectId": projId, "title": "附件任務", "content": "",
                                        "priority": 0, "status": 0, "reminders": [], "tags": [], "sortKey": "a0",
                                        "createdAt": nowMs, "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC], "serverSeq": 2,
                                ],
                                [
                                    "entity": "attachment",
                                    "row": [
                                        "id": attId, "taskId": taskId, "fileName": "doc.txt", "size": 4,
                                        "mimeType": "text/plain", "createdAt": nowMs, "updatedAt": nowMs,
                                    ],
                                    "clocks": ["fileName": serverHLC], "serverSeq": 3,
                                ],
                            ],
                            "cursor": 3, "hasMore": false,
                        ]],
                        "members": [],
                    ])
                }
                if method == "GET" && path == "/attachments/\(attId)/content" {
                    started = true
                    startedCont?.resume()
                    startedCont = nil
                    if !allowFinish {
                        await withCheckedContinuation { finishCont = $0 }
                    }
                    return SyncHTTPResponse(status: 200, body: Data("test".utf8))
                }
                return try jsonResponse(404, ["error": "Not found"])
            }

            private func jsonResponse(_ status: Int, _ object: Any) throws -> SyncHTTPResponse {
                SyncHTTPResponse(status: status, body: try JSONSerialization.data(withJSONObject: object))
            }
        }

        let transport = GateTransport()
        let (model, _) = try await makeModel(syncEnabled: true, transport: transport)
        model.scope = .project("cancel-dup-proj-1")

        model.duplicateProject(id: "cancel-dup-proj-1")
        XCTAssertTrue(model.isDuplicatingProject("cancel-dup-proj-1"))
        await transport.waitForDownloadStart()

        await model.signOut()
        XCTAssertFalse(model.isDuplicatingProject("cancel-dup-proj-1"))
        XCTAssertNil(model.errorMessage)

        await transport.allowDownloadFinish()
        await model.waitForProjectDuplications()

        XCTAssertFalse(model.isDuplicatingProject("cancel-dup-proj-1"))
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.projects.isEmpty)
    }

    func testStaleDuplicateProjectCompletionDoesNotReleaseNewAccountLock() async throws {
        actor TwoRoundDownloadTransport: SyncTransport {
            private let projId = "shared-dup-proj-1"
            private let taskId = "shared-dup-task-1"
            private let attId = "shared-dup-att-1"
            private var callIndex = 0
            private var firstStarted = false
            private var firstStartedCont: CheckedContinuation<Void, Never>?
            private var allowFirst = false
            private var firstFinishCont: CheckedContinuation<Void, Never>?
            private var secondStarted = false
            private var secondStartedCont: CheckedContinuation<Void, Never>?
            private var allowSecond = false
            private var secondFinishCont: CheckedContinuation<Void, Never>?

            func waitForFirstStart() async {
                if firstStarted { return }
                await withCheckedContinuation { firstStartedCont = $0 }
            }

            func allowFirstFinish() {
                allowFirst = true
                firstFinishCont?.resume()
                firstFinishCont = nil
            }

            func waitForSecondStart() async {
                if secondStarted { return }
                await withCheckedContinuation { secondStartedCont = $0 }
            }

            func allowSecondFinish() {
                allowSecond = true
                secondFinishCont?.resume()
                secondFinishCont = nil
            }

            func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
                let nowMs = EpochMillis(Date().timeIntervalSince1970 * 1000)
                let serverHLC = HLC(ms: nowMs, counter: 0, deviceId: "srv").description
                if method == "POST" && path == "/auth/apple" {
                    return try jsonResponse(200, [
                        "accessToken": "acc",
                        "refreshToken": "ref",
                        "user": ["id": "u-shared-dup"],
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
                    return try jsonResponse(200, [
                        "scopes": [[
                            "scope": "u:u-shared-dup",
                            "rows": [
                                [
                                    "entity": "project",
                                    "row": [
                                        "id": projId, "name": "共用清單", "viewMode": "list", "kind": "TASK",
                                        "isInbox": false, "ownerId": "m-1", "sortKey": "z1",
                                        "showInSmart": "all", "notifyMode": "all", "createdAt": nowMs, "updatedAt": nowMs,
                                    ],
                                    "clocks": ["name": serverHLC], "serverSeq": 1,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": taskId, "projectId": projId, "title": "附件任務", "content": "",
                                        "priority": 0, "status": 0, "reminders": [], "tags": [], "sortKey": "a0",
                                        "createdAt": nowMs, "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC], "serverSeq": 2,
                                ],
                                [
                                    "entity": "attachment",
                                    "row": [
                                        "id": attId, "taskId": taskId, "fileName": "doc.txt", "size": 4,
                                        "mimeType": "text/plain", "createdAt": nowMs, "updatedAt": nowMs,
                                    ],
                                    "clocks": ["fileName": serverHLC], "serverSeq": 3,
                                ],
                            ],
                            "cursor": 3, "hasMore": false,
                        ]],
                        "members": [],
                    ])
                }
                if method == "GET" && path == "/attachments/\(attId)/content" {
                    callIndex += 1
                    if callIndex == 1 {
                        firstStarted = true
                        firstStartedCont?.resume()
                        firstStartedCont = nil
                        if !allowFirst {
                            await withCheckedContinuation { firstFinishCont = $0 }
                        }
                    } else {
                        secondStarted = true
                        secondStartedCont?.resume()
                        secondStartedCont = nil
                        if !allowSecond {
                            await withCheckedContinuation { secondFinishCont = $0 }
                        }
                    }
                    return SyncHTTPResponse(status: 200, body: Data("test".utf8))
                }
                return try jsonResponse(404, ["error": "Not found"])
            }

            private func jsonResponse(_ status: Int, _ object: Any) throws -> SyncHTTPResponse {
                SyncHTTPResponse(status: status, body: try JSONSerialization.data(withJSONObject: object))
            }
        }

        let transport = TwoRoundDownloadTransport()
        let (model, _) = try await makeModel(syncEnabled: true, transport: transport)
        model.scope = .project("shared-dup-proj-1")

        // Account A starts duplicating and blocks on download #1.
        model.duplicateProject(id: "shared-dup-proj-1")
        await transport.waitForFirstStart()

        // Sign out A, sign in B, and start duplicating the same list id on B.
        await model.signOut()
        try await model.signIn(with: .apple(identityToken: "tok-B", nonce: "n-B"))
        model.scope = .project("shared-dup-proj-1")
        model.duplicateProject(id: "shared-dup-proj-1")
        await transport.waitForSecondStart()
        XCTAssertTrue(model.isDuplicatingProject("shared-dup-proj-1"))

        // Release A's stale download while B is still running: B's lock must stay held and no stale copy/error appears.
        await transport.allowFirstFinish()
        await model.waitForRetiredProjectDuplications()
        XCTAssertTrue(model.isDuplicatingProject("shared-dup-proj-1"))
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.projects.filter { $0.name == "共用清單 副本" }.isEmpty)

        // Release B's download: exactly one copy is created and B's lock releases cleanly.
        await transport.allowSecondFinish()
        await model.waitForProjectDuplications()
        XCTAssertFalse(model.isDuplicatingProject("shared-dup-proj-1"))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.projects.filter { $0.name == "共用清單 副本" }.count, 1)
    }

    func testPrepareSignOutConfirmationWaitsForCancelledDuplicationAndBlocksDuplicateWhileConfirming() async throws {
        actor GateTransport: SyncTransport {
            private let projId = "confirm-dup-proj-1"
            private let taskId = "confirm-dup-task-1"
            private let attId = "confirm-dup-att-1"
            private var started = false
            private var startedCont: CheckedContinuation<Void, Never>?
            private var allowFinish = false
            private var finishCont: CheckedContinuation<Void, Never>?
            private(set) var downloadCount = 0

            func waitForDownloadStart() async {
                if started { return }
                await withCheckedContinuation { startedCont = $0 }
            }

            func allowDownloadFinish() {
                allowFinish = true
                finishCont?.resume()
                finishCont = nil
            }

            func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
                let nowMs = EpochMillis(Date().timeIntervalSince1970 * 1000)
                let serverHLC = HLC(ms: nowMs, counter: 0, deviceId: "srv").description
                if method == "POST" && path == "/auth/apple" {
                    return try jsonResponse(200, [
                        "accessToken": "acc",
                        "refreshToken": "ref",
                        "user": ["id": "u-confirm"],
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
                    return try jsonResponse(200, [
                        "scopes": [[
                            "scope": "u:u-confirm",
                            "rows": [
                                [
                                    "entity": "project",
                                    "row": [
                                        "id": projId, "name": "確認登出清單", "viewMode": "list", "kind": "TASK",
                                        "isInbox": false, "ownerId": "m-1", "sortKey": "z1",
                                        "showInSmart": "all", "notifyMode": "all", "createdAt": nowMs, "updatedAt": nowMs,
                                    ],
                                    "clocks": ["name": serverHLC], "serverSeq": 1,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": taskId, "projectId": projId, "title": "附件任務", "content": "",
                                        "priority": 0, "status": 0, "reminders": [], "tags": [], "sortKey": "a0",
                                        "createdAt": nowMs, "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC], "serverSeq": 2,
                                ],
                                [
                                    "entity": "attachment",
                                    "row": [
                                        "id": attId, "taskId": taskId, "fileName": "doc.txt", "size": 4,
                                        "mimeType": "text/plain", "createdAt": nowMs, "updatedAt": nowMs,
                                    ],
                                    "clocks": ["fileName": serverHLC], "serverSeq": 3,
                                ],
                            ],
                            "cursor": 3, "hasMore": false,
                        ]],
                        "members": [],
                    ])
                }
                if method == "GET" && path == "/attachments/\(attId)/content" {
                    downloadCount += 1
                    started = true
                    startedCont?.resume()
                    startedCont = nil
                    if !allowFinish {
                        await withCheckedContinuation { finishCont = $0 }
                    }
                    return SyncHTTPResponse(status: 200, body: Data("test".utf8))
                }
                return try jsonResponse(404, ["error": "Not found"])
            }

            private func jsonResponse(_ status: Int, _ object: Any) throws -> SyncHTTPResponse {
                SyncHTTPResponse(status: status, body: try JSONSerialization.data(withJSONObject: object))
            }
        }

        let transport = GateTransport()
        let (model, _) = try await makeModel(syncEnabled: true, transport: transport)
        model.scope = .project("confirm-dup-proj-1")

        // 1. Start duplication while attachment download is blocked, then tap Sign Out confirmation.
        model.duplicateProject(id: "confirm-dup-proj-1")
        await transport.waitForDownloadStart()

        var confirmFinished = false
        let confirmTask = Task {
            let count = await model.prepareSignOutConfirmation()
            confirmFinished = true
            return count
        }

        for _ in 0..<5 {
            await Task.yield()
        }
        // Must still be waiting for the cancelled duplication before reading unsyncedChangeCount.
        XCTAssertTrue(model.isConfirmingSignOut)
        XCTAssertFalse(confirmFinished)

        // Release download -> cancelled duplication finishes without writing -> confirmation returns 0.
        await transport.allowDownloadFinish()
        let unsyncedCount = await confirmTask.value
        XCTAssertTrue(confirmFinished)
        XCTAssertEqual(unsyncedCount, 0)
        XCTAssertTrue(model.projects.filter { $0.name == "確認登出清單 副本" }.isEmpty)

        // 2. While sign-out confirmation is open, duplicateProject must be blocked.
        model.duplicateProject(id: "confirm-dup-proj-1")
        XCTAssertFalse(model.isDuplicatingProject("confirm-dup-proj-1"))
        let downloadsWhileConfirming = await transport.downloadCount
        XCTAssertEqual(downloadsWhileConfirming, 1)

        // 3. Cancelling confirmation lifts the block so duplicating works again.
        model.cancelSignOutConfirmation()
        XCTAssertFalse(model.isConfirmingSignOut)
        model.duplicateProject(id: "confirm-dup-proj-1")
        await model.waitForProjectDuplications()
        let downloadsAfterCancel = await transport.downloadCount
        XCTAssertEqual(downloadsAfterCancel, 2)
        XCTAssertEqual(model.projects.filter { $0.name == "確認登出清單 副本" }.count, 1)
    }

    func testDeleteRestoreAndPurgeIncrementHapticTriggers() async throws {
        let (model, store) = try await makeModel()
        let api = store.api
        let project = try await api.createProject(CreateProjectInput(name: "測試清單"))
        let task = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "要刪除的任務",
            start: model.today.description,
            allDay: true
        ))
        await model.reloadData()
        model.selectedTaskId = task.id

        XCTAssertEqual(model.deleteHapticTrigger, 0)
        XCTAssertEqual(model.restoreHapticTrigger, 0)

        let deletedMissing = await model.deleteTask(id: "missing-task-id")
        XCTAssertFalse(deletedMissing)
        XCTAssertEqual(model.deleteHapticTrigger, 0)
        XCTAssertEqual(model.selectedTaskId, task.id)

        let deleted = await model.deleteTask(id: task.id)
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.deleteHapticTrigger, 1)
        XCTAssertNil(model.selectedTaskId)

        let restoredMissing = await model.restoreTask(id: "missing-task-id")
        XCTAssertFalse(restoredMissing)
        XCTAssertEqual(model.restoreHapticTrigger, 0)

        let restored = await model.restoreTask(id: task.id)
        XCTAssertTrue(restored)
        XCTAssertEqual(model.restoreHapticTrigger, 1)

        let deletedAgain = await model.deleteTask(id: task.id)
        XCTAssertTrue(deletedAgain)
        XCTAssertEqual(model.deleteHapticTrigger, 2)

        model.scope = .smart(.trash)
        await model.purgeTask(id: task.id)
        XCTAssertEqual(model.deleteHapticTrigger, 3)
    }

    func testPostponeOverdueIncrementsHapticTrigger() async throws {
        let (model, store) = try await makeModel()
        let api = store.api
        let project = try await api.createProject(CreateProjectInput(name: "延期測試"))
        let yesterday = model.today.adding(days: -1)
        let overdue = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "逾期任務",
            start: yesterday.description,
            allDay: true
        ))
        let future = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "未來任務",
            start: model.today.adding(days: 2).description,
            allDay: true
        ))
        await model.reloadData()

        XCTAssertEqual(model.postponeHapticTrigger, 0)

        let revBefore = model.revision
        model.postponeOverdue(tasks: [overdue])
        for _ in 0..<40 where model.revision == revBefore {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.postponeHapticTrigger, 1)

        // Postponing a non-overdue task yields count 0 and must not fire haptic.
        let revBeforeNoop = model.revision
        model.postponeOverdue(tasks: [future])
        for _ in 0..<40 where model.revision == revBeforeNoop {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.postponeHapticTrigger, 1)
    }

    func testMoveTaskToLaterDayIncrementsPostponeHaptic() async throws {
        let (model, store) = try await makeModel()
        let api = store.api
        let project = try await api.createProject(CreateProjectInput(name: "單筆延期"))
        let yesterday = model.today.adding(days: -1)
        let created = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "逾期任務",
            start: yesterday.description,
            allDay: true
        ))
        let task = try await api.getTask(id: created.id)
        let schedule = try XCTUnwrap(task.schedule)

        await model.moveTask(task, to: schedule.moved(to: model.today.adding(days: 1)))
        XCTAssertEqual(model.postponeHapticTrigger, 1)
        let moved = try await api.getTask(id: task.id)
        XCTAssertEqual(moved.schedule?.startDay, model.today.adding(days: 1))

        // Moving earlier is not a postpone.
        await model.moveTask(moved, to: schedule.moved(to: model.today))
        XCTAssertEqual(model.postponeHapticTrigger, 1)
    }

    func testMoveTaskSelectionAcrossDuplicateMultiDayRowsDoesNotLoop() async throws {
        let (model, _) = try await makeModel()
        let rows: [TaskRowSelection] = [
            TaskRowSelection(sectionId: "today", taskId: "A"),
            TaskRowSelection(sectionId: "today", taskId: "B"),
            TaskRowSelection(sectionId: "tomorrow", taskId: "A"),
            TaskRowSelection(sectionId: "tomorrow", taskId: "C"),
        ]
        model.visibleTaskRows = rows

        model.moveTaskSelection(delta: 1)
        XCTAssertEqual(model.selectedTaskRow, rows[0])
        XCTAssertEqual(model.selectedTaskId, "A")

        model.moveTaskSelection(delta: 1)
        XCTAssertEqual(model.selectedTaskRow, rows[1])
        XCTAssertEqual(model.selectedTaskId, "B")

        model.moveTaskSelection(delta: 1)
        XCTAssertEqual(model.selectedTaskRow, rows[2])
        XCTAssertEqual(model.selectedTaskId, "A")

        model.moveTaskSelection(delta: 1)
        XCTAssertEqual(model.selectedTaskRow, rows[3])
        XCTAssertEqual(model.selectedTaskId, "C")

        model.moveTaskSelection(delta: -1)
        XCTAssertEqual(model.selectedTaskRow, rows[2])
        XCTAssertEqual(model.selectedTaskId, "A")
    }

    func testQuickAddDefaultsForNext7AndAssignedLeaveComposerUnchanged() async throws {
        let (model, _) = try await makeModel()
        let me = try XCTUnwrap(model.me)

        // The composer keeps its original defaults; only the quick-add bar fills these in.
        let next7Req = model.composeRequest(for: .smart(.next7))
        XCTAssertNil(next7Req.day)
        XCTAssertNil(next7Req.assigneeId)

        let assignedReq = model.composeRequest(for: .smart(.assigned))
        XCTAssertNil(assignedReq.day)
        XCTAssertNil(assignedReq.assigneeId)

        let createdNext7 = await model.createQuickTask(title: "未來7天任務", in: .smart(.next7))
        let quickNext7 = try XCTUnwrap(createdNext7)
        XCTAssertEqual(quickNext7.schedule?.startDay, model.today)

        let createdAssigned = await model.createQuickTask(title: "指派給我任務", in: .smart(.assigned))
        let quickAssigned = try XCTUnwrap(createdAssigned)
        XCTAssertEqual(quickAssigned.assigneeId, me.id)
    }

    func testRootSheetEntryDismissesCalendarPopoverBeforePresenting() async throws {
        let (model, _) = try await makeModel()
        model.isSignedIn = true
        model.tab = .calendar
        model.isCalendarPopoverPresented = true

        var pendingDismissCompletion: (@MainActor () -> Void)?
        model.registerCalendarPopoverDismisser { completion in
            pendingDismissCompletion = completion
        }

        model.openComposerForCurrentScope()
        XCTAssertNil(model.composing, "Sheet state must wait for popover dismissal completion")
        XCTAssertNotNil(pendingDismissCompletion)

        model.isCalendarPopoverPresented = false
        pendingDismissCompletion?()
        XCTAssertNotNil(model.composing)
    }

    func testStaleLoadLinkedIdentitiesDoesNotOverwriteCompletedLink() async throws {
        actor GatedIdentitiesTransport: SyncTransport {
            private var releaseLoad: CheckedContinuation<Void, Never>?
            private var loadStartedContinuation: CheckedContinuation<Void, Never>?
            private var loadStarted = false

            func waitForLoadStart() async {
                if loadStarted { return }
                await withCheckedContinuation { cont in
                    loadStartedContinuation = cont
                }
            }

            func finishLoad() {
                releaseLoad?.resume()
                releaseLoad = nil
            }

            func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
                switch (method, path) {
                case ("GET", "/me/identities"):
                    loadStarted = true
                    loadStartedContinuation?.resume()
                    loadStartedContinuation = nil
                    await withCheckedContinuation { cont in
                        releaseLoad = cont
                    }
                    let data = try JSONSerialization.data(withJSONObject: [
                        ["provider": "apple", "email": "old@privaterelay.appleid.com", "createdAt": 1000],
                    ])
                    return SyncHTTPResponse(status: 200, body: data)
                case ("POST", "/auth/link"):
                    let data = try JSONSerialization.data(withJSONObject: [
                        ["provider": "apple", "email": "old@privaterelay.appleid.com", "createdAt": 1000],
                        ["provider": "google", "email": "new@gmail.com", "createdAt": 2000],
                    ])
                    return SyncHTTPResponse(status: 200, body: data)
                default:
                    return SyncHTTPResponse(status: 404, body: Data())
                }
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-identities-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try DayDoStorage.openForApp(in: dir)
        let transport = GatedIdentitiesTransport()
        let tokens = InMemorySyncTokenStore(accessToken: "acc", refreshToken: "ref")
        let suite = "daydo.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(
            store: store,
            tokenStore: tokens,
            syncEnabled: true,
            transport: transport,
            defaults: defaults,
            sharedDefaults: nil,
            arguments: []
        )
        model.isSignedIn = true

        // Start a slow GET /me/identities that will return stale [apple].
        let loadTask = Task { try await model.loadLinkedIdentities() }
        await transport.waitForLoadStart()

        // Meanwhile, linking Google succeeds and updates model.linkedIdentities to [apple, google].
        let linked = try await model.linkIdentity(with: .google(idToken: "g-tok"))
        XCTAssertEqual(linked.map(\.provider), [.apple, .google])
        XCTAssertEqual(model.linkedIdentities.map(\.provider), [.apple, .google])

        // Now release the earlier GET /me/identities response; it must be discarded.
        await transport.finishLoad()
        _ = try await loadTask.value
        XCTAssertEqual(model.linkedIdentities.map(\.provider), [.apple, .google])
        XCTAssertTrue(model.identitiesLoaded)
    }

    func testLinkUnconfirmedRefreshesIdentitiesAndThrowsUnconfirmedError() async throws {
        actor UnconfirmedLinkTransport: SyncTransport {
            func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
                switch (method, path) {
                case ("POST", "/auth/link"):
                    return SyncHTTPResponse(status: 500, body: Data("{\"error\":\"timeout\"}".utf8))
                case ("GET", "/me/identities"):
                    let data = try JSONSerialization.data(withJSONObject: [
                        ["provider": "apple", "email": "a@privaterelay.appleid.com", "createdAt": 1000],
                        ["provider": "google", "email": "other@gmail.com", "createdAt": 1500],
                    ])
                    return SyncHTTPResponse(status: 200, body: data)
                default:
                    return SyncHTTPResponse(status: 404, body: Data())
                }
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-identities-unconfirmed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try DayDoStorage.openForApp(in: dir)
        let tokens = InMemorySyncTokenStore(accessToken: "acc", refreshToken: "ref")
        let suite = "daydo.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(
            store: store,
            tokenStore: tokens,
            syncEnabled: true,
            transport: UnconfirmedLinkTransport(),
            defaults: defaults,
            sharedDefaults: nil,
            arguments: []
        )
        model.isSignedIn = true

        do {
            _ = try await model.linkIdentity(with: .google(idToken: "g-tok"))
            XCTFail("Expected AuthError.linkUnconfirmed")
        } catch let AuthError.linkUnconfirmed(refreshed) {
            XCTAssertEqual(refreshed.map(\.provider), [.apple, .google])
            XCTAssertEqual(AuthErrorMessage.text(for: AuthError.linkUnconfirmed(refreshed)), "無法確認是否已連結，請看上方清單")
        }
        XCTAssertEqual(model.linkedIdentities.map(\.provider), [.apple, .google])
        XCTAssertTrue(model.identitiesLoaded)
    }
}

@MainActor
final class EmailCodeFlowTests: XCTestCase {
    func testFailedCodeCannotBeResubmittedViaRepeatSubmitOrDeleteAndRetype() async {
        let flow = EmailCodeFlow()
        flow.email = "family@example.com"
        let sent = await flow.sendCode { _ in }
        XCTAssertTrue(sent)
        XCTAssertEqual(flow.step, .enterCode)

        flow.sanitizeCode("000000")
        XCTAssertTrue(flow.canSubmitCode)

        var attempts = 0
        let first = await flow.submitCode { _, _ in
            attempts += 1
            throw AuthError.invalidCode
        }
        XCTAssertFalse(first)
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(flow.errorText)
        XCTAssertTrue(flow.isCurrentCodeAttempted)
        XCTAssertFalse(flow.canSubmitCode)

        // Pressing Enter or tapping submit again must not resend the same code.
        let second = await flow.submitCode { _, _ in
            attempts += 1
        }
        XCTAssertFalse(second)
        XCTAssertEqual(attempts, 1)

        // Deleting one digit and typing it back must still block resubmission and report attempted state.
        flow.sanitizeCode("00000")
        XCTAssertFalse(flow.isCurrentCodeAttempted)
        XCTAssertFalse(flow.canSubmitCode)
        flow.sanitizeCode("000000")
        XCTAssertTrue(flow.isCurrentCodeAttempted)
        XCTAssertFalse(flow.canSubmitCode)
        let third = await flow.submitCode { _, _ in
            attempts += 1
        }
        XCTAssertFalse(third)
        XCTAssertEqual(attempts, 1)
    }

    func testOfflineOrRetryableErrorAllowsManualRetryOfSameCode() async {
        let flow = EmailCodeFlow()
        flow.email = "family@example.com"
        _ = await flow.sendCode { _ in }

        flow.sanitizeCode("123456")
        XCTAssertTrue(flow.canSubmitCode)

        var attempts = 0
        let retryableResult = await flow.submitCode { _, _ in
            attempts += 1
            throw SyncError.retryable(retryAfter: 1, statusCode: nil, message: "offline")
        }
        XCTAssertFalse(retryableResult)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(flow.errorText, "網路連線失敗，請再試一次")
        XCTAssertFalse(flow.isCurrentCodeAttempted)
        XCTAssertTrue(flow.canSubmitCode)

        let urlErrorResult = await flow.submitCode { _, _ in
            attempts += 1
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertFalse(urlErrorResult)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(flow.errorText, "網路連線失敗，請再試一次")
        XCTAssertFalse(flow.isCurrentCodeAttempted)
        XCTAssertTrue(flow.canSubmitCode)

        // Once back online, manual retry with the same valid code succeeds.
        let recovered = await flow.submitCode { _, code in
            attempts += 1
            XCTAssertEqual(code, "123456")
        }
        XCTAssertTrue(recovered)
        XCTAssertEqual(attempts, 3)
    }

    func testNewCodeAfterFailureCanBeSubmitted() async {
        let flow = EmailCodeFlow()
        flow.email = "family@example.com"
        _ = await flow.sendCode { _ in }

        flow.sanitizeCode("000000")
        _ = await flow.submitCode { _, _ in
            throw AuthError.invalidCode
        }
        XCTAssertFalse(flow.canSubmitCode)

        // Replacing with a new 6-digit code re-enables submission.
        flow.sanitizeCode("123456")
        XCTAssertTrue(flow.canSubmitCode)

        var submittedCode: String?
        let ok = await flow.submitCode { _, code in
            submittedCode = code
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(submittedCode, "123456")
    }

    func testResendCodeClearsAttemptedCodes() async {
        let flow = EmailCodeFlow()
        flow.email = "family@example.com"
        _ = await flow.sendCode { _ in }

        flow.sanitizeCode("000000")
        _ = await flow.submitCode { _, _ in
            throw AuthError.invalidCode
        }
        XCTAssertFalse(flow.canSubmitCode)

        let resent = await flow.resendCode { _ in }
        XCTAssertTrue(resent)
        XCTAssertEqual(flow.code, "")
        XCTAssertTrue(flow.attemptedCodes.isEmpty)
        XCTAssertEqual(flow.infoText, "已重新寄送驗證碼。")

        flow.sanitizeCode("000000")
        XCTAssertTrue(flow.canSubmitCode)
    }

    func testResetToEmailPreservesEmailAndErrorAndClearsConsumedCode() async {
        let flow = EmailCodeFlow()
        flow.email = "family@example.com"
        _ = await flow.sendCode { _ in }

        flow.sanitizeCode("123456")
        _ = await flow.submitCode { _, _ in }

        flow.resetToEmail(error: "網路連線失敗，請再試一次。請重新寄送驗證碼")
        XCTAssertEqual(flow.step, .enterEmail)
        XCTAssertEqual(flow.email, "family@example.com")
        XCTAssertEqual(flow.code, "")
        XCTAssertTrue(flow.attemptedCodes.isEmpty)
        XCTAssertEqual(flow.errorText, "網路連線失敗，請再試一次。請重新寄送驗證碼")
    }
}
