import Foundation
import GRDB
import Testing
@testable import DayDoCore

private struct CapturedRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

private enum FakeTransportAction: Sendable {
    case respond(SyncHTTPResponse)
    case throwError(Error)
}

private actor FakeSyncTransport: SyncTransport {
    typealias Handler = @Sendable (CapturedRequest, Int) async throws -> SyncHTTPResponse

    private var requests: [CapturedRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) async throws -> SyncHTTPResponse {
        let req = CapturedRequest(method: method, path: path, headers: headers, body: body)
        let index = requests.count
        requests.append(req)
        return try await handler(req, index)
    }

    func capturedRequests() -> [CapturedRequest] {
        requests
    }
}

private func jsonResponse(_ status: Int, _ object: Any) throws -> SyncHTTPResponse {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return SyncHTTPResponse(status: status, body: data)
}

private func decodeJSONObject(_ data: Data?) throws -> [String: Any] {
    guard let data else { return [:] }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func makeSyncSetup(
    now: Date = noon,
    baseBackoff: TimeInterval = 1.0,
    maxBackoff: TimeInterval = 300.0,
    pullLimit: Int = 500,
    handler: @escaping FakeSyncTransport.Handler
) async throws -> (LocalDayDoAPI, AppDatabase, InMemorySyncTokenStore, FakeSyncTransport, SyncEngine) {
    let db = try AppDatabase.inMemory()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
    let api = LocalDayDoAPI(database: db, clock: .fixed(now, timeZone: taipei), attachmentsDirectory: dir)
    try await api.bootstrap()
    let tokens = InMemorySyncTokenStore(accessToken: "access-1", refreshToken: "refresh-1")
    let transport = FakeSyncTransport(handler: handler)
    let engine = SyncEngine(
        database: db,
        transport: transport,
        tokenStore: tokens,
        clock: .fixed(now, timeZone: taipei),
        pushBatchSize: 50,
        pullLimit: pullLimit,
        baseBackoffSeconds: baseBackoff,
        maxBackoffSeconds: maxBackoff
    )
    return (api, db, tokens, transport, engine)
}

private func ackAllChanges(in db: AppDatabase, at ms: EpochMillis = noon.epochMillis) async throws {
    try await db.writer.write { db in
        try db.execute(sql: "UPDATE change SET ackedAt = ?, result = 'applied' WHERE ackedAt IS NULL", arguments: [ms])
    }
}

private func rowDict<R: Encodable>(_ record: R) throws -> [String: Any] {
    let data = try Outbox.encoder.encode(record)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Suite struct SyncEngineTests {
    @Test func remoteApplyWritesNoOutbox() async throws {
        let projectId = ID.make()
        let taskId = ID.make()
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 1000, counter: 0, deviceId: "other-dev").description

        let (api, db, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
            }
            return try jsonResponse(200, [
                "scopes": [[
                    "scope": "u:user-1",
                    "rows": [
                        [
                            "entity": "project",
                            "row": [
                                "id": projectId,
                                "name": "遠端清單",
                                "viewMode": "list",
                                "kind": "TASK",
                                "isInbox": false,
                                "ownerId": "m-remote",
                                "sortKey": "z0",
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
                                "projectId": projectId,
                                "title": "遠端任務",
                                "content": "",
                                "priority": 3,
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
                    ],
                    "cursor": 2,
                    "hasMore": false,
                ]],
                "memberships": [],
                "members": [],
            ])
        }
        try await ackAllChanges(in: db)
        let changeCountBefore = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change") ?? 0
        }

        let summary = try await engine.syncNow()
        #expect(summary.pulledCount == 2)
        #expect(summary.didChangeLocalData)

        let fetched = try await api.getTask(id: taskId)
        #expect(fetched.title == "遠端任務")
        #expect(fetched.priority == .medium)

        let changeCountAfter = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change") ?? 0
        }
        #expect(changeCountAfter == changeCountBefore)
    }

    @Test func keepsNewerLocalUnackedField() async throws {
        let (api, db, _, _, engine) = try await makeSyncSetup { _, _ in
            try jsonResponse(200, [:])
        }
        let task = try await api.createTask(CreateTaskInput(title: "初始", content: "初始內容"))
        try await ackAllChanges(in: db)

        // Make a newer unacked local edit ONLY to title at now + 5000.
        let laterClock = Clock.fixed(Date(epochMillis: noon.epochMillis + 5000), timeZone: taipei)
        let apiLater = LocalDayDoAPI(database: db, clock: laterClock, attachmentsDirectory: api.attachmentsDirectory)
        var edit = UpdateTaskInput(taskId: task.id)
        edit.title = "本機較新標題"
        _ = try await apiLater.updateTask(edit)

        // Simulate pull delivering an older title clock and a newer content clock (without pushing first).
        let olderHLC = HLC(ms: noon.epochMillis + 1000, counter: 0, deviceId: "other").description
        let newerContentHLC = HLC(ms: noon.epochMillis + 9000, counter: 0, deviceId: "other").description

        let pullTransport = FakeSyncTransport { req, _ in
            if req.path == "/sync/push" {
                let body = try decodeJSONObject(req.body)
                let ops = (body["ops"] as? [[String: Any]]) ?? []
                // Return applied for pushed ops? No, test pull-apply directly before acking:
                // Actually return 401 or let's test SyncApplier + pull directly!
                return try jsonResponse(200, ["results": ops.map { ["opId": $0["opId"]!, "status": "applied", "row": NSNull(), "clocks": [:]] }, "serverTime": newerContentHLC])
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }
        _ = pullTransport

        // Test SyncEngine pull-only / unacked preservation directly via SyncApplier inside a write txn,
        // AND via a push result returning older clock for title & newer clock for content.
        let engine2 = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    // Simulate another unacked write arriving or server returning a row where
                    // an unacked op on another field stays newer.
                    // Better: in pull, if we only call pull or if a local write happened concurrently:
                    var rec = try await db.writer.read { db in try TaskRecord.fetchOne(db, key: task.id)! }
                    rec.title = "伺服器舊標題"
                    rec.content = "伺服器新內容"
                    var row = try rowDict(rec)
                    row["title"] = "伺服器舊標題"
                    row["content"] = "伺服器新內容"
                    let body = try decodeJSONObject(req.body)
                    let ops = (body["ops"] as? [[String: Any]]) ?? []
                    // Simulate an unacked op inserted just before push response is applied,
                    // OR verify SyncApplier directly with unacked op intact.
                    return try jsonResponse(200, [
                        "results": ops.map { [
                            "opId": $0["opId"]!,
                            "status": "applied",
                            "row": row,
                            "clocks": ["title": olderHLC, "content": newerContentHLC],
                        ] },
                        "serverTime": newerContentHLC,
                    ])
                }
                return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: laterClock
        )
        _ = engine

        // Verify pull-time unacked preservation while the local op is STILL unacked.
        try await db.writer.write { db in
            var serverRec = try TaskRecord.fetchOne(db, key: task.id)!
            serverRec.title = "伺服器舊標題"
            serverRec.content = "伺服器新內容"
            let serverDict = try JSONDecoder().decode([String: SyncJSONValue].self, from: Outbox.encoder.encode(serverRec))
            _ = try SyncApplier.applyRow(
                entity: "task",
                entityId: task.id,
                row: serverDict,
                clocks: ["title": olderHLC, "content": newerContentHLC],
                in: db
            )
        }

        let afterPull = try await api.getTask(id: task.id)
        #expect(afterPull.title == "本機較新標題")
        #expect(afterPull.content == "伺服器新內容")
        _ = engine2
    }

    @Test func takesServerFieldWhenLocalOlder() async throws {
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in
            try jsonResponse(200, [:])
        }
        let task = try await api.createTask(CreateTaskInput(title: "本機舊標題", content: "本機舊內容"))
        // Unacked local op has HLC at noon.epochMillis.
        let newerServerHLC = HLC(ms: noon.epochMillis + 10_000, counter: 0, deviceId: "other").description

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    let body = try decodeJSONObject(req.body)
                    let ops = (body["ops"] as? [[String: Any]]) ?? []
                    return try jsonResponse(200, [
                        "results": ops.map { op -> [String: Any] in
                            var res: [String: Any] = [
                                "opId": op["opId"]!,
                                "status": "applied",
                                "clocks": [:],
                            ]
                            if (op["entity"] as? String) == "task" {
                                var row = (op["row"] as? [String: Any]) ?? [:]
                                row["title"] = "伺服器勝出標題"
                                row["content"] = "伺服器勝出內容"
                                res["row"] = row
                                res["clocks"] = [
                                    "title": newerServerHLC,
                                    "content": newerServerHLC,
                                ]
                            }
                            return res
                        },
                        "serverTime": newerServerHLC,
                    ])
                }
                return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )

        _ = try await engine.syncNow()
        let updated = try await api.getTask(id: task.id)
        #expect(updated.title == "伺服器勝出標題")
        #expect(updated.content == "伺服器勝出內容")
    }

    @Test func scheduleGroupDecidedTogether() async throws {
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in try jsonResponse(200, [:]) }
        let task = try await api.createTask(CreateTaskInput(
            title: "排程測試",
            start: "2026-11-15T09:00:00+0800",
            due: "2026-11-15T10:00:00+0800",
            timeZone: "Asia/Taipei"
        ))
        try await ackAllChanges(in: db)

        // Case 1: Local unacked op edits ONLY startDay/startMinute at t+5000 (newer than server clocks["schedule"]).
        // Server row changed timeZone to "America/New_York" and cleared endDay/endMinute at t+1000.
        // Local schedule must be kept as ONE whole group (including local endDay, endMinute, timeZone).
        let laterClock = Clock.fixed(Date(epochMillis: noon.epochMillis + 5000), timeZone: taipei)
        let apiLater = LocalDayDoAPI(database: db, clock: laterClock, attachmentsDirectory: api.attachmentsDirectory)
        var editStart = UpdateTaskInput(taskId: task.id)
        editStart.start = .set("2026-11-16T11:00:00+0800")
        editStart.due = .set("2026-11-16T12:00:00+0800")
        _ = try await apiLater.updateTask(editStart)

        let olderServerHLC = HLC(ms: noon.epochMillis + 1000, counter: 0, deviceId: "other").description
        try await db.writer.write { db in
            var rec = try TaskRecord.fetchOne(db, key: task.id)!
            rec.startDay = "2026-11-20"
            rec.startMinute = nil
            rec.endDay = nil
            rec.endMinute = nil
            rec.timeZone = "America/New_York"
            let serverDict = try JSONDecoder().decode([String: SyncJSONValue].self, from: Outbox.encoder.encode(rec))
            _ = try SyncApplier.applyRow(
                entity: "task",
                entityId: task.id,
                row: serverDict,
                clocks: ["schedule": olderServerHLC],
                in: db
            )
        }

        let afterKeepLocal = try await db.writer.read { db in try TaskRecord.fetchOne(db, key: task.id)! }
        #expect(afterKeepLocal.startDay == "2026-11-16")
        #expect(afterKeepLocal.startMinute == 11 * 60)
        #expect(afterKeepLocal.endDay == "2026-11-16")
        #expect(afterKeepLocal.endMinute == 12 * 60)
        #expect(afterKeepLocal.timeZone == "Asia/Taipei")

        // Case 2: Now server has newer clocks["schedule"] (t+9000) with all-day schedule (startDay="2026-11-25", absent minutes/end/tz).
        // Local unacked op at t+5000 loses, so ALL 5 schedule fields take server values (including absent -> nil).
        let newerServerHLC = HLC(ms: noon.epochMillis + 9000, counter: 0, deviceId: "other").description
        try await db.writer.write { db in
            var rec = try TaskRecord.fetchOne(db, key: task.id)!
            rec.startDay = "2026-11-25"
            rec.startMinute = nil
            rec.endDay = nil
            rec.endMinute = nil
            rec.timeZone = nil
            let serverDict = try JSONDecoder().decode([String: SyncJSONValue].self, from: Outbox.encoder.encode(rec))
            _ = try SyncApplier.applyRow(
                entity: "task",
                entityId: task.id,
                row: serverDict,
                clocks: ["schedule": newerServerHLC],
                in: db
            )
        }

        let afterTakeServer = try await db.writer.read { db in try TaskRecord.fetchOne(db, key: task.id)! }
        #expect(afterTakeServer.startDay == "2026-11-25")
        #expect(afterTakeServer.startMinute == nil)
        #expect(afterTakeServer.endDay == nil)
        #expect(afterTakeServer.endMinute == nil)
        #expect(afterTakeServer.timeZone == nil)
    }

    @Test func absentFieldBecomesNullExceptLocalOnlyFields() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 5000, counter: 0, deviceId: "other").description
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in try jsonResponse(200, [:]) }

        let project = try await api.createProject(CreateProjectInput(name: "有圖示", color: "#4AA8E8", icon: "star"))
        let task = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "有重複和備註",
            start: "2026-11-15",
            repeat: "RRULE:FREQ=DAILY"
        ))
        let att = try await api.uploadAttachment(
            taskId: task.id,
            fileName: "doc.txt",
            data: Data("hello".utf8),
            mimeType: "text/plain",
            originalPath: "/Users/test/doc.txt"
        )
        let me = try await api.listMembers().first!
        #expect(me.isMe == true)
        #expect(att.localPath != nil)
        #expect(att.originalPath == "/Users/test/doc.txt")
        try await ackAllChanges(in: db)

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
                }
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:user-1",
                        "rows": [
                            [
                                "entity": "member",
                                "row": [
                                    "id": me.id,
                                    "name": "新名字",
                                    "initial": "新",
                                    "color": "#9BB8FF",
                                    "isMe": false, // server value must NOT overwrite local isMe
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs + 100,
                                ],
                                "clocks": ["name": serverHLC, "initial": serverHLC],
                                "serverSeq": 1,
                            ],
                            [
                                "entity": "project",
                                "row": [
                                    "id": project.id,
                                    "name": "無圖示",
                                    // color & icon omitted -> should become nil
                                    "viewMode": "list",
                                    "kind": "TASK",
                                    "isInbox": false,
                                    "ownerId": me.id,
                                    "sortKey": "a1",
                                    "showInSmart": "all",
                                    "notifyMode": "all",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs + 100,
                                ],
                                "clocks": ["name": serverHLC, "color": serverHLC, "icon": serverHLC],
                                "serverSeq": 2,
                            ],
                            [
                                "entity": "task",
                                "row": [
                                    "id": task.id,
                                    "projectId": project.id,
                                    "title": "無重複",
                                    "content": "",
                                    "priority": 0,
                                    "status": 0,
                                    "startDay": "2026-11-15",
                                    "reminders": [],
                                    "tags": [],
                                    // repeatRule omitted -> should become nil
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs + 100,
                                ],
                                "clocks": ["title": serverHLC, "repeatRule": serverHLC],
                                "serverSeq": 3,
                            ],
                            [
                                "entity": "attachment",
                                "row": [
                                    "id": att.id,
                                    "taskId": task.id,
                                    "fileName": "renamed.txt",
                                    "size": 5,
                                    "mimeType": "text/plain",
                                    // localPath & originalPath omitted -> must keep local!
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs + 100,
                                ],
                                "clocks": ["fileName": serverHLC],
                                "serverSeq": 4,
                            ],
                        ],
                        "cursor": 4,
                        "hasMore": false,
                    ]],
                    "memberships": [],
                    "members": [],
                ])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )

        _ = try await engine.syncNow()

        let updatedMe = try await api.listMembers().first { $0.id == me.id }!
        #expect(updatedMe.name == "新名字")
        #expect(updatedMe.isMe == true)

        let updatedProject = try await api.getProject(id: project.id)
        #expect(updatedProject.color == nil)
        #expect(updatedProject.icon == nil)

        let updatedTask = try await api.getTask(id: task.id)
        #expect(updatedTask.repeat == nil)

        let updatedAtt = try #require(updatedTask.attachments.first)
        #expect(updatedAtt.fileName == "renamed.txt")
        #expect(updatedAtt.localPath == att.localPath)
        #expect(updatedAtt.originalPath == att.originalPath)
    }

    @Test func tombstoneHardDeletesAndRecordsPurgedId() async throws {
        let nowMs = noon.epochMillis
        let purgeMs = nowMs + 2000
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in try jsonResponse(200, [:]) }
        let task = try await api.createTask(CreateTaskInput(title: "要被清掉", subtasks: ["子項目"]))
        let childId = task.items[0].id
        try await ackAllChanges(in: db)

        let changeCountBefore = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change") ?? 0
        }

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    return try jsonResponse(200, ["results": [], "serverTime": HLC(ms: purgeMs, counter: 0, deviceId: "server").description])
                }
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:user-1",
                        "rows": [[
                            "entity": "task",
                            "row": [
                                "id": task.id,
                                "projectId": task.projectId,
                                "title": "要被清掉",
                                "content": "",
                                "priority": 0,
                                "status": 0,
                                "reminders": [],
                                "tags": [],
                                "sortKey": "a0",
                                "createdAt": nowMs,
                                "updatedAt": nowMs,
                                "purgedAt": purgeMs,
                            ],
                            "clocks": [:],
                            "serverSeq": 1,
                        ]],
                        "cursor": 1,
                        "hasMore": false,
                    ]],
                    "memberships": [],
                    "members": [],
                ])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )

        _ = try await engine.syncNow()

        let (taskRow, childRow, purgedAt, changeCountAfter) = try await db.writer.read { db in
            let t = try TaskRecord.fetchOne(db, key: task.id)
            let c = try ChecklistItemRecord.fetchOne(db, key: childId)
            let p = try EpochMillis.fetchOne(db, sql: "SELECT purgedAt FROM purgedId WHERE entity = 'task' AND id = ?", arguments: [task.id])
            let ch = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change") ?? 0
            return (t, c, p, ch)
        }
        #expect(taskRow == nil)
        #expect(childRow == nil)
        #expect(purgedAt == purgeMs)
        #expect(changeCountAfter == changeCountBefore)
    }

    @Test func goneHardDeletesDropsOpsNoPurgedId() async throws {
        let nowMs = noon.epochMillis
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in try jsonResponse(200, [:]) }
        let task = try await api.createTask(CreateTaskInput(title: "離開的任務", subtasks: ["子任務"]))
        let childId = task.items[0].id
        try await ackAllChanges(in: db)

        // Add an unacked edit on the task and child, then simulate a pull-only gone:true
        // (and separately verify push rejected with gone:true).
        var edit = UpdateTaskInput(taskId: task.id)
        edit.title = "離線編輯"
        _ = try await api.updateTask(edit)
        _ = try await api.updateChecklistItem(id: childId, title: "子任務編輯", done: true)

        // Test 1: push rejected with gone:true
        let enginePushGone = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    let body = try decodeJSONObject(req.body)
                    let ops = (body["ops"] as? [[String: Any]]) ?? []
                    return try jsonResponse(200, [
                        "results": ops.map { op -> [String: Any] in
                            if (op["entity"] as? String) == "task" {
                                return [
                                    "opId": op["opId"]!,
                                    "status": "rejected",
                                    "reason": "Forbidden",
                                    "row": NSNull(),
                                    "clocks": [:],
                                    "gone": true,
                                ]
                            }
                            return ["opId": op["opId"]!, "status": "applied", "row": NSNull(), "clocks": [:]]
                        },
                        "serverTime": HLC(ms: nowMs + 100, counter: 0, deviceId: "server").description,
                    ])
                }
                return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )
        _ = try await enginePushGone.syncNow()

        let (t1, c1, purged1, unacked1) = try await db.writer.read { db in
            (
                try TaskRecord.fetchOne(db, key: task.id),
                try ChecklistItemRecord.fetchOne(db, key: childId),
                try PurgedId.contains(entity: "task", id: task.id, in: db),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change WHERE entityId IN (?, ?) AND ackedAt IS NULL", arguments: [task.id, childId]) ?? 0
            )
        }
        #expect(t1 == nil)
        #expect(c1 == nil)
        #expect(!purged1)
        #expect(unacked1 == 0)

        // Test 2: pull gone:true on another task (with unacked ops left behind before pull).
        let task2 = try await api.createTask(CreateTaskInput(title: "任務2", subtasks: ["子2"]))
        let child2Id = task2.items[0].id
        try await ackAllChanges(in: db)

        // Direct pull with unacked local edit still in outbox (by returning empty push or invoking pull via 0-push / direct):
        var edit2 = UpdateTaskInput(taskId: task2.id)
        edit2.title = "未送出編輯"
        _ = try await api.updateTask(edit2)

        // Simulate pull delivering gone:true for task2.
        try await db.writer.write { db in
            _ = try SyncApplier.applyGone(entity: "task", entityId: task2.id, in: db)
        }
        let (t2, c2, purged2, unacked2) = try await db.writer.read { db in
            (
                try TaskRecord.fetchOne(db, key: task2.id),
                try ChecklistItemRecord.fetchOne(db, key: child2Id),
                try PurgedId.contains(entity: "task", id: task2.id, in: db),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change WHERE entityId IN (?, ?) AND ackedAt IS NULL", arguments: [task2.id, child2Id]) ?? 0
            )
        }
        #expect(t2 == nil)
        #expect(c2 == nil)
        #expect(!purged2)
        #expect(unacked2 == 0)
    }

    @Test func childBeforeParentAcrossPagesIsStagedThenApplied() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 1000, counter: 0, deviceId: "other").description
        let projectId = ID.make()
        let taskId = ID.make()
        let childId = ID.make()

        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in try jsonResponse(200, [:]) }
        try await ackAllChanges(in: db)

        actor PageState {
            var pullCalls = 0
            func nextPull() -> Int {
                pullCalls += 1
                return pullCalls
            }
        }
        let state = PageState()

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
                }
                let call = await state.nextPull()
                let body = try decodeJSONObject(req.body)
                let cursors = (body["cursors"] as? [String: Int]) ?? [:]
                if call == 1 {
                    // Sync 1 Page 1 (hasMore: true): child arrives before parent!
                    #expect(cursors.isEmpty)
                    return try jsonResponse(200, [
                        "scopes": [[
                            "scope": "u:user-1",
                            "rows": [[
                                "entity": "checklistItem",
                                "row": [
                                    "id": childId,
                                    "taskId": taskId,
                                    "title": "先到的子項目",
                                    "status": 0,
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["title": serverHLC],
                                "serverSeq": 1,
                            ]],
                            "cursor": 1,
                            "hasMore": true,
                        ]],
                        "memberships": [],
                        "members": [],
                    ])
                } else if call == 2 {
                    // Sync 1 Page 2 (hasMore: false): parent task arrives, project still missing!
                    #expect(cursors["u:user-1"] == 1)
                    return try jsonResponse(200, [
                        "scopes": [[
                            "scope": "u:user-1",
                            "rows": [[
                                "entity": "task",
                                "row": [
                                    "id": taskId,
                                    "projectId": projectId,
                                    "title": "跨頁到的任務",
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
                            ]],
                            "cursor": 2,
                            "hasMore": false,
                        ]],
                        "memberships": [],
                        "members": [],
                    ])
                } else {
                    // Sync 2 Page 1: grandparent project arrives -> unblocks BOTH task and checklistItem!
                    #expect(cursors["u:user-1"] == 2)
                    return try jsonResponse(200, [
                        "scopes": [[
                            "scope": "u:user-1",
                            "rows": [[
                                "entity": "project",
                                "row": [
                                    "id": projectId,
                                    "name": "跨次拉取的清單",
                                    "viewMode": "list",
                                    "kind": "TASK",
                                    "isInbox": false,
                                    "ownerId": "m-1",
                                    "sortKey": "z0",
                                    "showInSmart": "all",
                                    "notifyMode": "all",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["name": serverHLC],
                                "serverSeq": 3,
                            ]],
                            "cursor": 3,
                            "hasMore": false,
                        ]],
                        "memberships": [],
                        "members": [],
                    ])
                }
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )

        // After Sync 1 (2 pages): both checklistItem and task are staged because project is still missing.
        _ = try await engine.syncNow()
        let (stagedAfterSync1, taskAfterSync1, childAfterSync1) = try await db.writer.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging") ?? 0,
                try TaskRecord.fetchOne(db, key: taskId),
                try ChecklistItemRecord.fetchOne(db, key: childId)
            )
        }
        #expect(stagedAfterSync1 == 2)
        #expect(taskAfterSync1 == nil)
        #expect(childAfterSync1 == nil)

        // After Sync 2: project arrives -> task and checklistItem are unblocked and applied, staging is empty.
        let summary2 = try await engine.syncNow()
        #expect(summary2.didChangeLocalData)
        let stagedAfterSync2 = try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging") ?? 0
        }
        #expect(stagedAfterSync2 == 0)

        let fetchedTask = try await api.getTask(id: taskId)
        #expect(fetchedTask.title == "跨頁到的任務")
        #expect(fetchedTask.items.map(\.title) == ["先到的子項目"])
    }

    @Test func pushBatchesOf50InSeqOrderAndAcksAppliedAndRejected() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 1000, counter: 0, deviceId: "server").description
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in try jsonResponse(200, [:]) }

        // Bootstrap created 9 ops (1 member + 4 projects + 4 projectMembers). Create 111 tasks -> 120 total ops (50 + 50 + 20).
        for i in 0..<111 {
            _ = try await api.createTask(CreateTaskInput(title: "Batch task \(i)"))
        }

        let expectedSeqs = try await db.writer.read { db in
            try ChangeRecord.filter(Column("ackedAt") == nil).order(Column("seq")).fetchAll(db).compactMap(\.seq)
        }
        #expect(expectedSeqs.count == 120)

        actor Recorder {
            var batchSizes: [Int] = []
            var pushedOpIds: [String] = []
            func record(opIds: [String]) {
                batchSizes.append(opIds.count)
                pushedOpIds.append(contentsOf: opIds)
            }
        }
        let recorder = Recorder()

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    let body = try decodeJSONObject(req.body)
                    let ops = (body["ops"] as? [[String: Any]]) ?? []
                    let opIds = ops.compactMap { $0["opId"] as? String }
                    await recorder.record(opIds: opIds)
                    let results: [[String: Any]] = ops.map { op in
                        let entity = op["entity"] as? String
                        let status = entity == "projectMember" ? "rejected" : "applied"
                        return [
                            "opId": op["opId"]!,
                            "status": status,
                            "row": NSNull(),
                            "clocks": [:],
                        ]
                    }
                    return try jsonResponse(200, ["results": results, "serverTime": serverTime])
                }
                return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )

        let summary = try await engine.syncNow()
        #expect(summary.pushedCount == 120)
        #expect(summary.appliedCount == 116)
        #expect(summary.rejectedCount == 4)

        let batchSizes = await recorder.batchSizes
        let pushedOpIds = await recorder.pushedOpIds
        #expect(batchSizes == [50, 50, 20])

        let allChanges = try await db.writer.read { db in
            try ChangeRecord.order(Column("seq")).fetchAll(db)
        }
        #expect(pushedOpIds == allChanges.compactMap(\.opId))
        #expect(allChanges.allSatisfy { $0.ackedAt == nowMs })
        for c in allChanges {
            if c.entity == "projectMember" {
                #expect(c.result == "rejected")
            } else {
                #expect(c.result == "applied")
            }
        }
    }

    @Test func rejectedRowOverwritesLocal() async throws {
        let nowMs = noon.epochMillis
        let serverClock = HLC(ms: nowMs - 5000, counter: 0, deviceId: "other").description
        let serverTime = HLC(ms: nowMs + 100, counter: 0, deviceId: "server").description
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in try jsonResponse(200, [:]) }
        let task = try await api.createTask(CreateTaskInput(title: "伺服器原標題"))
        try await ackAllChanges(in: db)

        // Local viewer offline edit (newer HLC than server clock, but rejected by server).
        let laterClock = Clock.fixed(Date(epochMillis: nowMs + 5000), timeZone: taipei)
        let apiLater = LocalDayDoAPI(database: db, clock: laterClock, attachmentsDirectory: api.attachmentsDirectory)
        var edit = UpdateTaskInput(taskId: task.id)
        edit.title = "被拒絕的本機編輯"
        _ = try await apiLater.updateTask(edit)

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    let body = try decodeJSONObject(req.body)
                    let ops = (body["ops"] as? [[String: Any]]) ?? []
                    let op = ops[0]
                    return try jsonResponse(200, [
                        "results": [[
                            "opId": op["opId"]!,
                            "status": "rejected",
                            "reason": "Forbidden",
                            "row": [
                                "id": task.id,
                                "projectId": task.projectId,
                                "title": "伺服器原標題",
                                "content": "",
                                "priority": 0,
                                "status": 0,
                                "reminders": [],
                                "tags": [],
                                "sortKey": task.sortKey,
                                "createdAt": nowMs,
                                "updatedAt": nowMs,
                            ],
                            "clocks": ["title": serverClock],
                        ]],
                        "serverTime": serverTime,
                    ])
                }
                return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: laterClock
        )

        let summary = try await engine.syncNow()
        #expect(summary.rejectedCount == 1)
        #expect(summary.didChangeLocalData)

        let fetched = try await api.getTask(id: task.id)
        #expect(fetched.title == "伺服器原標題")
    }

    @Test func serverTimeAdvancesLocalHLC() async throws {
        let nowMs = noon.epochMillis
        let futureServerTime = HLC(ms: nowMs + 60_000, counter: 7, deviceId: "server").description
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in try jsonResponse(200, [:]) }
        _ = try await api.createTask(CreateTaskInput(title: "時鐘推進"))

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    let body = try decodeJSONObject(req.body)
                    let ops = (body["ops"] as? [[String: Any]]) ?? []
                    return try jsonResponse(200, [
                        "results": ops.map { ["opId": $0["opId"]!, "status": "applied", "row": NSNull(), "clocks": [:]] },
                        "serverTime": futureServerTime,
                    ])
                }
                return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )

        _ = try await engine.syncNow()

        let metaHLC = try await db.writer.read { db in
            try HLC.loadLast(in: db)
        }
        let serverHLC = try #require(HLC(futureServerTime))
        let loaded = try #require(metaHLC)
        #expect(loaded > serverHLC)
        #expect(loaded.ms == nowMs + 60_000)
        #expect(loaded.counter == 8)

        // Subsequent local write with old wall clock still produces an HLC > serverTime.
        _ = try await api.createTask(CreateTaskInput(title: "下一筆"))
        let latestChange = try await db.writer.read { db in
            try ChangeRecord.order(Column("seq").desc).fetchOne(db)
        }
        let latestHLC = try #require(latestChange?.hlc.flatMap(HLC.init))
        #expect(latestHLC > serverHLC)
    }

    @Test func unauthorizedRefreshesOnceThenRetries() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()
        let tokens = InMemorySyncTokenStore(accessToken: "expired-access", refreshToken: "refresh-old")

        actor AuthCheck {
            var refreshCount = 0
            var pushAttempts = 0
            var rotatedBeforeRetry = false
            func incRefresh() { refreshCount += 1 }
            func incPush() -> Int {
                pushAttempts += 1
                return pushAttempts
            }
            func markRotated(_ ok: Bool) { rotatedBeforeRetry = ok }
        }
        let state = AuthCheck()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/sync/push" {
                let attempt = await state.incPush()
                if attempt == 1 {
                    #expect(req.headers["Authorization"] == "Bearer expired-access")
                    return try jsonResponse(401, ["error": "Unauthorized"])
                }
                #expect(req.headers["Authorization"] == "Bearer fresh-access")
                // Crucial invariant: rotated refreshToken MUST be persisted before using fresh-access.
                await state.markRotated(tokens.refreshToken == "refresh-rotated")
                let body = try decodeJSONObject(req.body)
                let ops = (body["ops"] as? [[String: Any]]) ?? []
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]!, "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            if req.path == "/auth/refresh" {
                await state.incRefresh()
                let body = try decodeJSONObject(req.body)
                #expect(body["refreshToken"] as? String == "refresh-old")
                return try jsonResponse(200, [
                    "accessToken": "fresh-access",
                    "refreshToken": "refresh-rotated",
                    "hasData": true,
                    "meMemberId": NSNull(),
                    "inboxProjectId": NSNull(),
                ])
            }
            #expect(req.headers["Authorization"] == "Bearer fresh-access")
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        let engine = SyncEngine(
            database: db,
            transport: transport,
            tokenStore: tokens,
            clock: .fixed(noon, timeZone: taipei)
        )

        let summary = try await engine.syncNow()
        #expect(summary.pushedCount == 9)
        #expect(await state.refreshCount == 1)
        #expect(await state.pushAttempts == 2)
        #expect(await state.rotatedBeforeRetry)
        #expect(tokens.accessToken == "fresh-access")
        #expect(tokens.refreshToken == "refresh-rotated")
    }

    @Test func refreshFailureSignsOut() async throws {
        let (_, db, tokens, transport, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                return try jsonResponse(401, ["error": "Unauthorized"])
            }
            if req.path == "/auth/refresh" {
                return try jsonResponse(401, ["error": "Invalid or expired refresh token"])
            }
            return try jsonResponse(200, [:])
        }

        await #expect(throws: SyncError.signedOut) {
            _ = try await engine.syncNow()
        }
        let unacked = try await db.writer.read { db in
            try ChangeRecord.filter(Column("ackedAt") == nil).fetchCount(db)
        }
        #expect(unacked == 9)
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
        let reqs = await transport.capturedRequests()
        #expect(reqs.map(\.path) == ["/sync/push", "/auth/refresh"])
    }

    @Test func retryableErrorLeavesOpsUnacked() async throws {
        actor Mode {
            var next: FakeTransportAction
            init(_ initial: FakeTransportAction) { self.next = initial }
            func set(_ action: FakeTransportAction) { next = action }
            func get() -> FakeTransportAction { next }
        }
        let mode = Mode(.respond(try jsonResponse(429, ["error": "rate limit"])))
        let (_, db, _, _, engine) = try await makeSyncSetup(baseBackoff: 2.0, maxBackoff: 10.0) { req, _ in
            if req.path == "/sync/push" {
                switch await mode.get() {
                case let .respond(response):
                    return response
                case let .throwError(err):
                    throw err
                }
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        // Failure 1 (429): 2s
        do {
            _ = try await engine.syncNow()
            Issue.record("Expected retryable error")
        } catch let SyncError.retryable(retryAfter, status, _) {
            #expect(status == 429)
            #expect(retryAfter == 2.0)
        }

        // Failure 2 (503): 4s
        await mode.set(.respond(try jsonResponse(503, ["error": "unavailable"])))
        do {
            _ = try await engine.syncNow()
            Issue.record("Expected retryable error")
        } catch let SyncError.retryable(retryAfter, status, _) {
            #expect(status == 503)
            #expect(retryAfter == 4.0)
        }

        // Failure 3 (network): 8s
        await mode.set(.throwError(URLError(.timedOut)))
        do {
            _ = try await engine.syncNow()
            Issue.record("Expected retryable error")
        } catch let SyncError.retryable(retryAfter, status, _) {
            #expect(status == nil)
            #expect(retryAfter == 8.0)
        }

        // Failure 4 (429): capped at maxBackoff (10s)
        await mode.set(.respond(try jsonResponse(429, ["error": "rate limit"])))
        do {
            _ = try await engine.syncNow()
            Issue.record("Expected retryable error")
        } catch let SyncError.retryable(retryAfter, _, _) {
            #expect(retryAfter == 10.0)
        }

        let unacked = try await db.writer.read { db in
            try ChangeRecord.filter(Column("ackedAt") == nil).fetchCount(db)
        }
        #expect(unacked == 9)
    }

    @Test func concurrentSyncNowCallsShareOneCycle() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs, counter: 0, deviceId: "server").description

        actor Gate {
            private var pushEnteredContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var hasEntered = false
            private var isReleased = false
            var pushCount = 0
            var pullCount = 0

            func enterPushAndWait() async {
                pushCount += 1
                hasEntered = true
                pushEnteredContinuation?.resume()
                pushEnteredContinuation = nil
                if !isReleased {
                    await withCheckedContinuation { cont in
                        releaseContinuation = cont
                    }
                }
            }

            func recordPull() {
                pullCount += 1
            }

            func waitForPushEntry() async {
                if hasEntered { return }
                await withCheckedContinuation { cont in
                    pushEnteredContinuation = cont
                }
            }

            func release() {
                isReleased = true
                releaseContinuation?.resume()
                releaseContinuation = nil
            }
        }
        let gate = Gate()

        let (_, _, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                await gate.enterPushAndWait()
                let body = try decodeJSONObject(req.body)
                let ops = (body["ops"] as? [[String: Any]]) ?? []
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]!, "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            await gate.recordPull()
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        let t1 = Task { try await engine.syncNow() }
        await gate.waitForPushEntry()

        let t2 = Task { try await engine.syncNow() }
        let t3 = Task { try await engine.syncNow() }
        let t4 = Task { try await engine.syncNow() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.release()

        let results = try await [t1.value, t2.value, t3.value, t4.value]
        for r in results {
            #expect(r.pushedCount == 9)
        }
        #expect(await gate.pushCount == 1)
        #expect(await gate.pullCount == 2)
    }

    @Test func changeStreamEmitsOnlyWhenLocalDataChanges() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs, counter: 0, deviceId: "server").description
        let (_, db, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                let body = try decodeJSONObject(req.body)
                let ops = (body["ops"] as? [[String: Any]]) ?? []
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]!, "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }
        try await ackAllChanges(in: db)

        let stream = await engine.changeNotifications()
        _ = stream

        // Empty sync emits nothing.
        let empty = try await engine.syncNow()
        #expect(!empty.didChangeLocalData)

        // Now apply a remote task via SyncEngine.
        let taskId = ID.make()
        let projectId = try await db.writer.read { db in
            try ProjectRecord.fetchOne(db)!.id
        }
        let remoteEngine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    return try jsonResponse(200, ["results": [], "serverTime": serverTime])
                }
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:user-1",
                        "rows": [[
                            "entity": "task",
                            "row": [
                                "id": taskId,
                                "projectId": projectId,
                                "title": "通知測試",
                                "content": "",
                                "priority": 0,
                                "status": 0,
                                "reminders": [],
                                "tags": [],
                                "sortKey": "a0",
                                "createdAt": nowMs,
                                "updatedAt": nowMs,
                            ],
                            "clocks": ["title": serverTime],
                            "serverSeq": 1,
                        ]],
                        "cursor": 1,
                        "hasMore": false,
                    ]],
                    "memberships": [],
                    "members": [],
                ])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )
        let remoteStream = await remoteEngine.changeNotifications()
        var remoteIter = remoteStream.makeAsyncIterator()

        let changed = try await remoteEngine.syncNow()
        #expect(changed.didChangeLocalData)
        let event = await remoteIter.next()
        #expect(event == changed)
    }

    private func nextEmittedSummary(from stream: AsyncStream<SyncSummary>) async -> SyncSummary? {
        await withTaskGroup(of: SyncSummary?.self) { group in
            group.addTask {
                var iter = stream.makeAsyncIterator()
                return await iter.next()
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test func pullPartialPageFailureEmitsChangeBeforeThrowing() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs, counter: 0, deviceId: "server").description
        let taskId = ID.make()

        let (_, db, _, _, _) = try await makeSyncSetup { _, _ in
            try jsonResponse(200, ["results": [], "serverTime": serverTime])
        }
        try await ackAllChanges(in: db)
        let projectId = try await db.writer.read { db in
            try ProjectRecord.fetchOne(db)!.id
        }

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/sync/push" {
                return try jsonResponse(200, ["results": [], "serverTime": serverTime])
            }
            let body = try decodeJSONObject(req.body)
            let cursors = (body["cursors"] as? [String: Any]) ?? [:]
            let cursor = (cursors["u:user-1"] as? NSNumber)?.int64Value ?? 0
            if cursor == 0 {
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:user-1",
                        "rows": [[
                            "entity": "task",
                            "row": [
                                "id": taskId,
                                "projectId": projectId,
                                "title": "第一頁任務",
                                "content": "",
                                "priority": 0,
                                "status": 0,
                                "reminders": [],
                                "tags": [],
                                "sortKey": "a0",
                                "createdAt": nowMs,
                                "updatedAt": nowMs,
                            ],
                            "clocks": ["title": serverTime],
                            "serverSeq": 1,
                        ]],
                        "cursor": 1,
                        "hasMore": true,
                    ]],
                    "memberships": [],
                    "members": [],
                ])
            }
            return SyncHTTPResponse(status: 500, body: Data("pull page 2 error".utf8))
        }

        let engine = SyncEngine(
            database: db,
            transport: transport,
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )
        let stream = await engine.changeNotifications()

        var thrownError: SyncError?
        do {
            _ = try await engine.syncNow()
            Issue.record("Expected syncNow() to throw on pull page 2 500")
        } catch let error as SyncError {
            thrownError = error
        }

        guard case .retryable(_, let statusCode, _) = thrownError else {
            Issue.record("Expected retryable error, got \(String(describing: thrownError))")
            return
        }
        #expect(statusCode == 500)

        let taskRowsInDB = try await db.writer.read { db in
            try TaskRecord.filter(Column("id") == taskId).fetchCount(db)
        }
        #expect(taskRowsInDB == 1)

        let emitted = await nextEmittedSummary(from: stream)
        #expect(emitted == SyncSummary(
            pushedCount: 0,
            appliedCount: 0,
            rejectedCount: 0,
            pulledCount: 1,
            didChangeLocalData: true
        ))
    }

    @Test func pushChangeThenPullFailureEmitsChangeBeforeThrowing() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 5000, counter: 0, deviceId: "server").description
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in
            try jsonResponse(200, ["results": [], "serverTime": serverTime])
        }
        try await ackAllChanges(in: db)

        let created = try await api.createTask(CreateTaskInput(title: "本機標題"))
        let createdId = created.id
        let projectId = created.projectId
        let sortKey = created.sortKey
        let createdAt = created.createdAt

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/sync/push" {
                let body = try decodeJSONObject(req.body)
                let ops = (body["ops"] as? [[String: Any]]) ?? []
                let serverRow: [String: Any] = [
                    "id": createdId,
                    "projectId": projectId,
                    "title": "伺服器覆蓋標題",
                    "content": "",
                    "priority": 0,
                    "status": 0,
                    "reminders": [],
                    "tags": [],
                    "sortKey": sortKey,
                    "createdAt": createdAt,
                    "updatedAt": nowMs + 5000,
                ]
                return try jsonResponse(200, [
                    "results": ops.map {
                        [
                            "opId": $0["opId"]!,
                            "status": "rejected",
                            "row": serverRow,
                            "clocks": ["title": serverTime],
                        ] as [String: Any]
                    },
                    "serverTime": serverTime,
                ])
            }
            return SyncHTTPResponse(status: 500, body: Data("pull failed".utf8))
        }

        let engine = SyncEngine(
            database: db,
            transport: transport,
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )
        let stream = await engine.changeNotifications()

        var thrownError: SyncError?
        do {
            _ = try await engine.syncNow()
            Issue.record("Expected syncNow() to throw on pull 500")
        } catch let error as SyncError {
            thrownError = error
        }

        guard case .retryable(_, let statusCode, _) = thrownError else {
            Issue.record("Expected retryable error, got \(String(describing: thrownError))")
            return
        }
        #expect(statusCode == 500)

        let storedTitle = try await db.writer.read { db in
            try TaskRecord.fetchOne(db, key: created.id)?.title
        }
        #expect(storedTitle == "伺服器覆蓋標題")

        let emitted = await nextEmittedSummary(from: stream)
        #expect(emitted == SyncSummary(
            pushedCount: 1,
            appliedCount: 0,
            rejectedCount: 1,
            pulledCount: 0,
            didChangeLocalData: true
        ))
    }

    @Test func pushBatch1ChangeThenBatch2FailureEmitsChangeBeforeThrowing() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 5000, counter: 0, deviceId: "server").description
        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in
            try jsonResponse(200, ["results": [], "serverTime": serverTime])
        }
        try await ackAllChanges(in: db)

        let task1 = try await api.createTask(CreateTaskInput(title: "任務一"))
        _ = try await api.createTask(CreateTaskInput(title: "任務二"))
        let task1Id = task1.id
        let projectId = task1.projectId
        let sortKey1 = task1.sortKey
        let createdAt1 = task1.createdAt

        let transport = FakeSyncTransport { req, index in
            if index == 0 {
                let body = try decodeJSONObject(req.body)
                let ops = (body["ops"] as? [[String: Any]]) ?? []
                let serverRow1: [String: Any] = [
                    "id": task1Id,
                    "projectId": projectId,
                    "title": "批次一覆蓋",
                    "content": "",
                    "priority": 0,
                    "status": 0,
                    "reminders": [],
                    "tags": [],
                    "sortKey": sortKey1,
                    "createdAt": createdAt1,
                    "updatedAt": nowMs + 5000,
                ]
                return try jsonResponse(200, [
                    "results": ops.map {
                        [
                            "opId": $0["opId"]!,
                            "status": "rejected",
                            "row": serverRow1,
                            "clocks": ["title": serverTime],
                        ] as [String: Any]
                    },
                    "serverTime": serverTime,
                ])
            }
            return SyncHTTPResponse(status: 500, body: Data("push batch 2 failed".utf8))
        }

        let engine = SyncEngine(
            database: db,
            transport: transport,
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei),
            pushBatchSize: 1
        )
        let stream = await engine.changeNotifications()

        var thrownError: SyncError?
        do {
            _ = try await engine.syncNow()
            Issue.record("Expected syncNow() to throw on push batch 2 500")
        } catch let error as SyncError {
            thrownError = error
        }

        guard case .retryable(_, let statusCode, _) = thrownError else {
            Issue.record("Expected retryable error, got \(String(describing: thrownError))")
            return
        }
        #expect(statusCode == 500)

        let storedTitle = try await db.writer.read { db in
            try TaskRecord.fetchOne(db, key: task1.id)?.title
        }
        #expect(storedTitle == "批次一覆蓋")

        let emitted = await nextEmittedSummary(from: stream)
        #expect(emitted == SyncSummary(
            pushedCount: 1,
            appliedCount: 0,
            rejectedCount: 1,
            pulledCount: 0,
            didChangeLocalData: true
        ))
    }

    @Test func writeDuringInFlightCycleIsPushedBeforeJoinedCallReturns() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs, counter: 0, deviceId: "server").description

        actor PullGate {
            private var pullEnteredContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var hasEnteredPull = false
            private var isReleased = false
            var pushOpEntityIds: [[String]] = []
            var pullCount = 0
            var events: [String] = []

            func recordPush(entityIds: [String]) {
                pushOpEntityIds.append(entityIds)
                events.append("push-\(pushOpEntityIds.count)")
            }

            func enterPullAndWaitOnFirst() async {
                pullCount += 1
                events.append("pull-\(pullCount)")
                if pullCount == 1 {
                    hasEnteredPull = true
                    pullEnteredContinuation?.resume()
                    pullEnteredContinuation = nil
                    if !isReleased {
                        await withCheckedContinuation { cont in
                            releaseContinuation = cont
                        }
                    }
                }
            }

            func waitForFirstPullEntry() async {
                if hasEnteredPull { return }
                await withCheckedContinuation { cont in
                    pullEnteredContinuation = cont
                }
            }

            func releasePull() {
                isReleased = true
                releaseContinuation?.resume()
                releaseContinuation = nil
            }

            func recordEvent(_ event: String) {
                events.append(event)
            }
        }
        let gate = PullGate()

        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in
            try jsonResponse(200, [:])
        }
        try await ackAllChanges(in: db)
        let initialTask = try await api.createTask(CreateTaskInput(title: "週期前任務"))

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    let body = try decodeJSONObject(req.body)
                    let ops = (body["ops"] as? [[String: Any]]) ?? []
                    let entityIds = ops.compactMap { $0["entityId"] as? String }
                    await gate.recordPush(entityIds: entityIds)
                    return try jsonResponse(200, [
                        "results": ops.map { ["opId": $0["opId"]!, "status": "applied", "row": NSNull(), "clocks": [:]] },
                        "serverTime": serverTime,
                    ])
                }
                await gate.enterPullAndWaitOnFirst()
                return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )

        let cycleA = Task { try await engine.syncNow() }
        await gate.waitForFirstPullEntry()

        let newTask = try await api.createTask(CreateTaskInput(title: "進行中新寫入"))
        let joined = Task {
            let summary = try await engine.syncNow()
            await gate.recordEvent("joined-returned")
            return summary
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await !gate.events.contains("joined-returned"))
        #expect(await gate.pushOpEntityIds.count == 1)

        await gate.releasePull()

        let summaryA = try await cycleA.value
        let joinedSummary = try await joined.value

        let pushBatches = await gate.pushOpEntityIds
        try #require(pushBatches.count == 2)
        #expect(pushBatches[0] == [initialTask.id])
        #expect(pushBatches[1] == [newTask.id])
        #expect(await gate.pullCount == 2)

        let events = await gate.events
        let push2Index = events.firstIndex(of: "push-2")
        let joinedIndex = events.firstIndex(of: "joined-returned")
        #expect(push2Index != nil)
        #expect(joinedIndex != nil)
        if let push2Index, let joinedIndex {
            #expect(push2Index < joinedIndex)
        }

        #expect(summaryA.pushedCount == 2)
        #expect(joinedSummary.pushedCount == 2)

        let unackedCount = try await db.writer.read { db in
            try ChangeRecord.filter(Column("ackedAt") == nil).fetchCount(db)
        }
        #expect(unackedCount == 0)
    }

    @Test func manyJoinsCoalesceIntoOneExtraCycle() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs, counter: 0, deviceId: "server").description

        actor PullGate {
            private var pullEnteredContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var hasEnteredPull = false
            private var isReleased = false
            var pushOpEntityIds: [[String]] = []
            var pullCount = 0

            func recordPush(entityIds: [String]) {
                pushOpEntityIds.append(entityIds)
            }

            func enterPullAndWaitOnFirst() async {
                pullCount += 1
                if pullCount == 1 {
                    hasEnteredPull = true
                    pullEnteredContinuation?.resume()
                    pullEnteredContinuation = nil
                    if !isReleased {
                        await withCheckedContinuation { cont in
                            releaseContinuation = cont
                        }
                    }
                }
            }

            func waitForFirstPullEntry() async {
                if hasEnteredPull { return }
                await withCheckedContinuation { cont in
                    pullEnteredContinuation = cont
                }
            }

            func releasePull() {
                isReleased = true
                releaseContinuation?.resume()
                releaseContinuation = nil
            }
        }
        let gate = PullGate()

        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in
            try jsonResponse(200, [:])
        }
        try await ackAllChanges(in: db)
        let initialTask = try await api.createTask(CreateTaskInput(title: "初始任務"))

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    let body = try decodeJSONObject(req.body)
                    let ops = (body["ops"] as? [[String: Any]]) ?? []
                    await gate.recordPush(entityIds: ops.compactMap { $0["entityId"] as? String })
                    return try jsonResponse(200, [
                        "results": ops.map { ["opId": $0["opId"]!, "status": "applied", "row": NSNull(), "clocks": [:]] },
                        "serverTime": serverTime,
                    ])
                }
                await gate.enterPullAndWaitOnFirst()
                return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )

        let cycleA = Task { try await engine.syncNow() }
        await gate.waitForFirstPullEntry()

        let w1 = try await api.createTask(CreateTaskInput(title: "寫入一"))
        let w2 = try await api.createTask(CreateTaskInput(title: "寫入二"))

        let joiners = (0..<8).map { _ in
            Task { try await engine.syncNow() }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.releasePull()

        let primarySummary = try await cycleA.value
        var joinerSummaries: [SyncSummary] = []
        for joiner in joiners {
            try await joinerSummaries.append(joiner.value)
        }

        let pushBatches = await gate.pushOpEntityIds
        try #require(pushBatches.count == 2)
        #expect(pushBatches[0] == [initialTask.id])
        #expect(pushBatches[1] == [w1.id, w2.id])
        #expect(await gate.pullCount == 2)
        #expect(primarySummary.pushedCount == 3)
        for s in joinerSummaries {
            #expect(s.pushedCount == 3)
        }
    }

    @Test func inFlightFailureDoesNotRerunAndPropagatesToJoinedCallers() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs, counter: 0, deviceId: "server").description

        actor PullGate {
            private var pullEnteredContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var hasEnteredPull = false
            private var isReleased = false
            var pushCount = 0
            var pullCount = 0
            var failFirstPull = true

            func recordPush() {
                pushCount += 1
            }

            func enterPull() async -> Bool {
                pullCount += 1
                if pullCount == 1 {
                    hasEnteredPull = true
                    pullEnteredContinuation?.resume()
                    pullEnteredContinuation = nil
                    if !isReleased {
                        await withCheckedContinuation { cont in
                            releaseContinuation = cont
                        }
                    }
                    return failFirstPull
                }
                return false
            }

            func waitForFirstPullEntry() async {
                if hasEnteredPull { return }
                await withCheckedContinuation { cont in
                    pullEnteredContinuation = cont
                }
            }

            func releasePull() {
                isReleased = true
                releaseContinuation?.resume()
                releaseContinuation = nil
            }
        }
        let gate = PullGate()

        let (api, db, _, _, _) = try await makeSyncSetup { _, _ in
            try jsonResponse(200, [:])
        }
        try await ackAllChanges(in: db)
        _ = try await api.createTask(CreateTaskInput(title: "失敗前任務"))

        let engine = SyncEngine(
            database: db,
            transport: FakeSyncTransport { req, _ in
                if req.path == "/sync/push" {
                    await gate.recordPush()
                    let body = try decodeJSONObject(req.body)
                    let ops = (body["ops"] as? [[String: Any]]) ?? []
                    return try jsonResponse(200, [
                        "results": ops.map { ["opId": $0["opId"]!, "status": "applied", "row": NSNull(), "clocks": [:]] },
                        "serverTime": serverTime,
                    ])
                }
                if await gate.enterPull() {
                    return SyncHTTPResponse(status: 500, body: Data("pull boom".utf8))
                }
                return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
            },
            tokenStore: InMemorySyncTokenStore(accessToken: "a", refreshToken: "r"),
            clock: .fixed(noon, timeZone: taipei)
        )

        let cycleA = Task { try await engine.syncNow() }
        await gate.waitForFirstPullEntry()

        _ = try await api.createTask(CreateTaskInput(title: "失敗期間寫入"))
        let joined = Task { try await engine.syncNow() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.releasePull()

        for task in [cycleA, joined] {
            var caught: SyncError?
            do {
                _ = try await task.value
                Issue.record("Expected syncNow() to throw on pull 500")
            } catch let error as SyncError {
                caught = error
            }
            guard case .retryable(_, let statusCode, _) = caught else {
                Issue.record("Expected retryable error, got \(String(describing: caught))")
                return
            }
            #expect(statusCode == 500)
        }

        #expect(await gate.pushCount == 1)
        #expect(await gate.pullCount == 1)

        let unackedBeforeRetry = try await db.writer.read { db in
            try ChangeRecord.filter(Column("ackedAt") == nil).fetchCount(db)
        }
        #expect(unackedBeforeRetry == 1)

        // Subsequent syncNow() starts fresh and pushes the pending op.
        let recovery = try await engine.syncNow()
        #expect(recovery.pushedCount == 1)
        #expect(await gate.pushCount == 2)
        #expect(await gate.pullCount == 2)
    }

    @Test func firstLoginEmptyNoServerDataBootstraps() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        let tokens = InMemorySyncTokenStore()

        let pushed = PushOpRecorder()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                let body = try decodeJSONObject(req.body)
                #expect(body["idToken"] as? String == "google-id-token")
                #expect((body["deviceId"] as? String)?.isEmpty == false)
                return try jsonResponse(200, [
                    "accessToken": "acc-new",
                    "refreshToken": "ref-new",
                    "user": ["id": "user-1"],
                    "isNewAccount": true,
                    "hasData": false,
                    "meMemberId": NSNull(),
                    "inboxProjectId": NSNull(),
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                await pushed.append(ops)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens, clock: .fixed(noon, timeZone: taipei))
        #expect(try await !engine.isSignedIn)

        let summary = try await engine.signIn(with: .google(idToken: "google-id-token"))
        #expect(summary.pushedCount == 9)
        #expect(try await engine.isSignedIn)
        #expect(try await engine.signedInUserId == "user-1")
        #expect(tokens.accessToken == "acc-new")
        #expect(tokens.refreshToken == "ref-new")

        let members = try await api.listMembers()
        let projects = try await api.listProjects(includeArchived: false)
        #expect(members.filter(\.isMe).count == 1)
        #expect(projects.filter(\.isInbox).count == 1)
        #expect(projects.map(\.name) == ["收件匣", "工作", "個人", "購物"])
        #expect(await pushed.ops.count == 9)

        let unacked = try await db.writer.read { db in
            try ChangeRecord.filter(Column("ackedAt") == nil).fetchCount(db)
        }
        #expect(unacked == 0)
    }

    @Test func firstLoginEmptyWithServerDataPullsWithoutBootstrap() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "other-dev").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        let tokens = InMemorySyncTokenStore()

        let serverMeId = ID.make()
        let otherMemberId = ID.make()
        let serverInboxId = ID.make()
        let serverWorkId = ID.make()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/apple" {
                let body = try decodeJSONObject(req.body)
                #expect(body["identityToken"] as? String == "apple-id-token")
                #expect(body["nonce"] as? String == "apple-nonce")
                #expect((body["deviceId"] as? String)?.isEmpty == false)
                return try jsonResponse(200, [
                    "accessToken": "acc-apple",
                    "refreshToken": "ref-apple",
                    "user": ["id": "user-existing"],
                    "isNewAccount": false,
                    "hasData": true,
                    "meMemberId": serverMeId,
                    "inboxProjectId": serverInboxId,
                ])
            }
            if req.path == "/sync/push" {
                Issue.record("Should not push when local is empty and server hasData=true")
                return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
            }
            return try jsonResponse(200, [
                "scopes": [[
                    "scope": "u:user-existing",
                    "rows": [
                        [
                            "entity": "member",
                            "row": [
                                "id": serverMeId,
                                "name": "我",
                                "initial": "我",
                                "color": "#9BB8FF",
                                "isMe": true,
                                "createdAt": nowMs,
                                "updatedAt": nowMs,
                            ],
                            "clocks": ["name": serverHLC],
                            "serverSeq": 1,
                        ],
                        [
                            "entity": "project",
                            "row": [
                                "id": serverInboxId,
                                "name": "收件匣",
                                "icon": "inbox",
                                "viewMode": "list",
                                "kind": "TASK",
                                "isInbox": true,
                                "ownerId": serverMeId,
                                "sortKey": "a0",
                                "showInSmart": "all",
                                "notifyMode": "all",
                                "createdAt": nowMs,
                                "updatedAt": nowMs,
                            ],
                            "clocks": ["name": serverHLC],
                            "serverSeq": 2,
                        ],
                        [
                            "entity": "project",
                            "row": [
                                "id": serverWorkId,
                                "name": "工作",
                                "color": "#4AA8E8",
                                "viewMode": "list",
                                "kind": "TASK",
                                "isInbox": false,
                                "ownerId": serverMeId,
                                "sortKey": "a1",
                                "showInSmart": "all",
                                "notifyMode": "all",
                                "createdAt": nowMs,
                                "updatedAt": nowMs,
                            ],
                            "clocks": ["name": serverHLC],
                            "serverSeq": 3,
                        ],
                    ],
                    "cursor": 3,
                    "hasMore": false,
                ]],
                "memberships": [],
                "members": [[
                    "id": otherMemberId,
                    "name": "家人",
                    "initial": "家",
                    "color": "#FFB89B",
                    "isMe": false,
                    "createdAt": nowMs,
                    "updatedAt": nowMs,
                ]],
            ])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens, clock: .fixed(noon, timeZone: taipei))
        let summary = try await engine.signIn(with: .apple(identityToken: "apple-id-token", nonce: "apple-nonce"))
        #expect(summary.pushedCount == 0)
        #expect(summary.pulledCount == 3)
        #expect(try await engine.isSignedIn)
        #expect(try await engine.signedInUserId == "user-existing")

        let members = try await api.listMembers()
        let meMembers = members.filter(\.isMe)
        #expect(meMembers.count == 1)
        #expect(meMembers.first?.id == serverMeId)
        #expect(members.first(where: { $0.id == otherMemberId })?.isMe == false)

        let projects = try await api.listProjects(includeArchived: false)
        #expect(projects.map(\.id) == [serverInboxId, serverWorkId])
        let paths = await transport.capturedRequests().map(\.path)
        #expect(paths == ["/auth/apple", "/sync/pull"])
    }

    @Test func firstLoginLocalDataNoServerDataUploadsAll() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 100, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()
        let localMeBefore = try #require(try await api.listMembers().first(where: \.isMe))
        let localInboxBefore = try #require(try await api.listProjects(includeArchived: false).first(where: \.isInbox))
        let localTask = try await api.createTask(CreateTaskInput(projectId: localInboxBefore.id, title: "登入前任務"))

        let pushed = PushOpRecorder()
        let tokens = InMemorySyncTokenStore()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                return try jsonResponse(200, [
                    "accessToken": "acc-1",
                    "refreshToken": "ref-1",
                    "user": ["id": "user-new"],
                    "isNewAccount": true,
                    "hasData": false,
                    "meMemberId": NSNull(),
                    "inboxProjectId": NSNull(),
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                await pushed.append(ops)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens, clock: .fixed(noon, timeZone: taipei))
        let summary = try await engine.signIn(with: .google(idToken: "g-tok"))
        #expect(summary.pushedCount == 10)
        #expect(try await engine.isSignedIn)

        let localMeAfter = try #require(try await api.listMembers().first(where: \.isMe))
        let localInboxAfter = try #require(try await api.listProjects(includeArchived: false).first(where: \.isInbox))
        #expect(localMeAfter.id == localMeBefore.id)
        #expect(localInboxAfter.id == localInboxBefore.id)
        let entityIds = await pushed.ops.compactMap { $0["entityId"]?.stringValue }
        #expect(entityIds.contains(localMeBefore.id))
        #expect(entityIds.contains(localInboxBefore.id))
        #expect(entityIds.contains(localTask.id))
    }

    @Test func firstLoginRemapsMeAndInboxInRowsAndOutbox() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 1000, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()

        let localMe = try #require(try await api.listMembers().first(where: \.isMe))
        let localInbox = try #require(try await api.listProjects(includeArchived: false).first(where: \.isInbox))

        // Task in local inbox assigned to me, created before sign-in.
        let localTask = try await api.createTask(CreateTaskInput(
            projectId: localInbox.id,
            title: "收件匣待辦",
            assigneeId: localMe.id
        ))
        // Unacked edit to the inbox after creation.
        var inboxEdit = UpdateProjectInput(projectId: localInbox.id)
        inboxEdit.name = "我的收件匣"
        _ = try await api.updateProject(inboxEdit)
        // Add a comment and a projectInvite referencing me/inbox to verify every FK column is remapped.
        let commentId = ID.make()
        let inviteId = ID.make()
        try await db.writer.write { db in
            let comment = CommentRecord(id: commentId, taskId: localTask.id, authorId: localMe.id, body: "備註", createdAt: nowMs, updatedAt: nowMs)
            try Outbox.save(comment, entity: "comment", id: commentId, in: db, now: nowMs)
            let invite = ProjectInviteRecord(id: inviteId, projectId: localInbox.id, email: "a@example.test", role: "viewer", status: "pending", createdAt: nowMs, updatedAt: nowMs)
            try Outbox.save(invite, entity: "projectInvite", id: inviteId, in: db, now: nowMs)
        }

        let serverMeId = ID.make()
        let serverInboxId = ID.make()

        let pushed = PushOpRecorder()
        let tokens = InMemorySyncTokenStore()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                return try jsonResponse(200, [
                    "accessToken": "acc-remap",
                    "refreshToken": "ref-remap",
                    "user": ["id": "user-remap"],
                    "isNewAccount": false,
                    "hasData": true,
                    "meMemberId": serverMeId,
                    "inboxProjectId": serverInboxId,
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                await pushed.append(ops)
                return try jsonResponse(200, [
                    "results": ops.map { op -> [String: Any] in
                        let entity = op["entity"]?.stringValue
                        let status = (entity == "projectMember" || entity == "projectInvite") ? "rejected" : "applied"
                        return ["opId": op["opId"]?.stringValue ?? "", "status": status, "row": NSNull(), "clocks": [:]]
                    },
                    "serverTime": serverTime,
                ])
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens, clock: .fixed(noon, timeZone: taipei))
        _ = try await engine.signIn(with: .google(idToken: "g-tok"))

        // Verify SQLite table rows were remapped.
        let (meRow, inboxRow, pmRow, taskRow, commentRow, inviteRow) = try await db.writer.read { db in
            (
                try MemberRecord.fetchOne(db, key: serverMeId),
                try ProjectRecord.fetchOne(db, key: serverInboxId),
                try ProjectMemberRecord.fetchOne(db, key: ["projectId": serverInboxId, "memberId": serverMeId]),
                try TaskRecord.fetchOne(db, key: localTask.id),
                try CommentRecord.fetchOne(db, key: commentId),
                try ProjectInviteRecord.fetchOne(db, key: inviteId)
            )
        }
        #expect(meRow?.isMe == true)
        #expect(inboxRow?.ownerId == serverMeId)
        #expect(inboxRow?.name == "我的收件匣")
        #expect(pmRow?.role == "owner")
        #expect(taskRow?.projectId == serverInboxId)
        #expect(taskRow?.assigneeId == serverMeId)
        #expect(commentRow?.authorId == serverMeId)
        #expect(inviteRow?.projectId == serverInboxId)

        // Verify old local IDs are completely gone from tables.
        let oldCounts = try await db.writer.read { db in
            (
                try MemberRecord.filter(Column("id") == localMe.id).fetchCount(db),
                try ProjectRecord.filter(Column("id") == localInbox.id).fetchCount(db)
            )
        }
        #expect(oldCounts.0 == 0 && oldCounts.1 == 0)

        // Verify pushed ops:
        // - no member create op (and no ops referencing old IDs)
        // - no inbox create op, YES remapped inbox edit op
        // - remapped projectMember composite key "<serverInboxId>:<serverMeId>"
        // - remapped task, comment, projectInvite
        let ops = await pushed.ops
        #expect(!ops.contains { $0["entity"]?.stringValue == "member" })
        let projectOps = ops.filter { $0["entity"]?.stringValue == "project" }
        #expect(projectOps.count == 1)
        #expect(projectOps[0]["entityId"]?.stringValue == serverInboxId)
        let projectFields = projectOps[0]["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(!projectFields.contains("id"))
        let projectRow = projectOps[0]["row"]?.objectValue
        #expect(projectRow?["id"]?.stringValue == serverInboxId)
        #expect(projectRow?["ownerId"]?.stringValue == serverMeId)
        #expect(projectRow?["name"]?.stringValue == "我的收件匣")

        let pmOp = try #require(ops.first { $0["entity"]?.stringValue == "projectMember" })
        #expect(pmOp["entityId"]?.stringValue == "\(serverInboxId):\(serverMeId)")
        let pmRowDict = pmOp["row"]?.objectValue
        #expect(pmRowDict?["projectId"]?.stringValue == serverInboxId)
        #expect(pmRowDict?["memberId"]?.stringValue == serverMeId)

        let taskOp = try #require(ops.first { $0["entity"]?.stringValue == "task" })
        let taskRowDict = taskOp["row"]?.objectValue
        #expect(taskRowDict?["projectId"]?.stringValue == serverInboxId)
        #expect(taskRowDict?["assigneeId"]?.stringValue == serverMeId)

        let commentOp = try #require(ops.first { $0["entity"]?.stringValue == "comment" })
        #expect(commentOp["row"]?.objectValue?["authorId"]?.stringValue == serverMeId)

        // Local projectInvite ops stay local (never pushed), their outbox payload was remapped, and they are marked local-only.
        #expect(!ops.contains { $0["entity"]?.stringValue == "projectInvite" })
        let localInviteChange = try await db.writer.read { db in
            try ChangeRecord
                .filter(Column("entity") == "projectInvite" && Column("entityId") == inviteId)
                .fetchOne(db)
        }
        let remappedChange = try #require(localInviteChange)
        #expect(remappedChange.ackedAt == nowMs)
        #expect(remappedChange.result == "local-only")
        let remappedChangeRow = try JSONDecoder().decode([String: SyncJSONValue].self, from: Data(remappedChange.row.utf8))
        #expect(remappedChangeRow["projectId"]?.stringValue == serverInboxId)
    }

    @Test func firstLoginNullMeMemberIdSkipsMemberRemap() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 100, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()

        let localMe = try #require(try await api.listMembers().first(where: \.isMe))
        let localInbox = try #require(try await api.listProjects(includeArchived: false).first(where: \.isInbox))
        _ = try await api.createTask(CreateTaskInput(projectId: localInbox.id, title: "無 meMemberId 任務", assigneeId: localMe.id))
        let serverInboxId = ID.make()

        let pushed = PushOpRecorder()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                return try jsonResponse(200, [
                    "accessToken": "acc-1",
                    "refreshToken": "ref-1",
                    "user": ["id": "user-null-me"],
                    "isNewAccount": false,
                    "hasData": true,
                    "meMemberId": NSNull(),
                    "inboxProjectId": serverInboxId,
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                await pushed.append(ops)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: InMemorySyncTokenStore(), clock: .fixed(noon, timeZone: taipei))
        _ = try await engine.signIn(with: .google(idToken: "g-tok"))

        let meAfter = try #require(try await api.listMembers().first(where: \.isMe))
        #expect(meAfter.id == localMe.id)
        let inboxAfter = try #require(try await api.listProjects(includeArchived: false).first(where: \.isInbox))
        #expect(inboxAfter.id == serverInboxId)

        // Member create op is NOT deleted when meMemberId is null; inbox create op IS deleted.
        let ops = await pushed.ops
        #expect(ops.contains { $0["entity"]?.stringValue == "member" && $0["entityId"]?.stringValue == localMe.id })
        #expect(!ops.contains { $0["entity"]?.stringValue == "project" })
        let pmOp = try #require(ops.first { $0["entity"]?.stringValue == "projectMember" })
        #expect(pmOp["entityId"]?.stringValue == "\(serverInboxId):\(localMe.id)")
    }

    @Test func firstLoginDropsUntouchedDefaultListsAndTheirOps() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "other-dev").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()

        let localProjectsBefore = try await api.listProjects(includeArchived: false)
        let localDefaultIds = Set(localProjectsBefore.filter { !$0.isInbox }.map(\.id))
        #expect(localDefaultIds.count == 3)

        let serverMeId = ID.make()
        let serverInboxId = ID.make()
        let serverWorkId = ID.make()

        let pushed = PushOpRecorder()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                return try jsonResponse(200, [
                    "accessToken": "acc-1",
                    "refreshToken": "ref-1",
                    "user": ["id": "user-1"],
                    "isNewAccount": false,
                    "hasData": true,
                    "meMemberId": serverMeId,
                    "inboxProjectId": serverInboxId,
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                await pushed.append(ops)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "rejected", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverHLC,
                ])
            }
            return try jsonResponse(200, [
                "scopes": [[
                    "scope": "u:user-1",
                    "rows": [
                        [
                            "entity": "member",
                            "row": ["id": serverMeId, "name": "我", "initial": "我", "color": "#9BB8FF", "isMe": true, "createdAt": nowMs, "updatedAt": nowMs],
                            "clocks": ["name": serverHLC],
                            "serverSeq": 1,
                        ],
                        [
                            "entity": "project",
                            "row": ["id": serverInboxId, "name": "收件匣", "icon": "inbox", "viewMode": "list", "kind": "TASK", "isInbox": true, "ownerId": serverMeId, "sortKey": "a0", "showInSmart": "all", "notifyMode": "all", "createdAt": nowMs, "updatedAt": nowMs],
                            "clocks": ["name": serverHLC],
                            "serverSeq": 2,
                        ],
                        [
                            "entity": "project",
                            "row": ["id": serverWorkId, "name": "工作", "color": "#4AA8E8", "viewMode": "list", "kind": "TASK", "isInbox": false, "ownerId": serverMeId, "sortKey": "a1", "showInSmart": "all", "notifyMode": "all", "createdAt": nowMs, "updatedAt": nowMs],
                            "clocks": ["name": serverHLC],
                            "serverSeq": 3,
                        ],
                    ],
                    "cursor": 3,
                    "hasMore": false,
                ]],
                "memberships": [],
                "members": [],
            ])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: InMemorySyncTokenStore(), clock: .fixed(noon, timeZone: taipei))
        _ = try await engine.signIn(with: .google(idToken: "g-tok"))

        // None of the local untouched default lists or their projectMember ops were pushed.
        let ops = await pushed.ops
        for localId in localDefaultIds {
            #expect(!ops.contains { $0["entityId"]?.stringValue == localId })
            #expect(!ops.contains { $0["entityId"]?.stringValue?.hasPrefix("\(localId):") == true })
        }

        let remainingProjects = try await api.listProjects(includeArchived: false)
        #expect(remainingProjects.map(\.id) == [serverInboxId, serverWorkId])

        let (orphanedPMs, unacked) = try await db.writer.read { db in
            (
                try ProjectMemberRecord.filter(localDefaultIds.contains(Column("projectId"))).fetchCount(db),
                try ChangeRecord.filter(Column("ackedAt") == nil).fetchCount(db)
            )
        }
        #expect(orphanedPMs == 0)
        #expect(unacked == 0)
    }

    @Test func firstLoginKeepsDefaultListWithTasksOrEdits() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 100, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()

        let projects = try await api.listProjects(includeArchived: false)
        let work = try #require(projects.first(where: { $0.name == "工作" }))
        let personal = try #require(projects.first(where: { $0.name == "個人" }))
        let shopping = try #require(projects.first(where: { $0.name == "購物" }))

        // 1. "工作" has an active task.
        _ = try await api.createTask(CreateTaskInput(projectId: work.id, title: "工作任務"))

        // 2. "個人" had a task created and then purged (no row in `task`, only history in `change`).
        let purgedTask = try await api.createTask(CreateTaskInput(projectId: personal.id, title: "已清除的個人任務"))
        try await api.purgeTask(id: purgedTask.id)

        // 3. "購物" was edited (name/color changed or reordered after creation).
        var editShopping = UpdateProjectInput(projectId: shopping.id)
        editShopping.color = .set("#00AA88")
        _ = try await api.updateProject(editShopping)

        let serverMeId = ID.make()
        let serverInboxId = ID.make()

        let pushed = PushOpRecorder()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                return try jsonResponse(200, [
                    "accessToken": "acc-1",
                    "refreshToken": "ref-1",
                    "user": ["id": "user-1"],
                    "isNewAccount": false,
                    "hasData": true,
                    "meMemberId": serverMeId,
                    "inboxProjectId": serverInboxId,
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                await pushed.append(ops)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: InMemorySyncTokenStore(), clock: .fixed(noon, timeZone: taipei))
        _ = try await engine.signIn(with: .google(idToken: "g-tok"))

        let remainingIds = Set(try await api.listProjects(includeArchived: false).map(\.id))
        #expect(remainingIds == [serverInboxId, work.id, personal.id, shopping.id])

        let ops = await pushed.ops
        for keptId in [work.id, personal.id, shopping.id] {
            let projectCreate = try #require(ops.first { $0["entity"]?.stringValue == "project" && $0["entityId"]?.stringValue == keptId })
            #expect(projectCreate["row"]?.objectValue?["ownerId"]?.stringValue == serverMeId)
            let pmOp = try #require(ops.first { $0["entity"]?.stringValue == "projectMember" && $0["entityId"]?.stringValue == "\(keptId):\(serverMeId)" })
            #expect(pmOp["row"]?.objectValue?["memberId"]?.stringValue == serverMeId)
        }
    }

    @Test func firstLoginKeepsUserCreatedListMatchingDefaultNameAndColor() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 5000, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let clock = MutableClock(startMs: nowMs)
        let api = LocalDayDoAPI(database: db, clock: clock.clock, attachmentsDirectory: dir)
        try await api.bootstrap()

        let bootstrapDefaults = try await api.listProjects(includeArchived: false).filter { !$0.isInbox }
        #expect(bootstrapDefaults.count == 3)

        clock.advance(by: 1000)
        let userWork = try await api.createProject(CreateProjectInput(name: "工作", color: "#4AA8E8"))

        let serverMeId = ID.make()
        let serverInboxId = ID.make()
        let pushed = PushOpRecorder()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                return try jsonResponse(200, [
                    "accessToken": "acc-1",
                    "refreshToken": "ref-1",
                    "user": ["id": "user-1"],
                    "isNewAccount": false,
                    "hasData": true,
                    "meMemberId": serverMeId,
                    "inboxProjectId": serverInboxId,
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                await pushed.append(ops)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: InMemorySyncTokenStore(), clock: clock.clock)
        _ = try await engine.signIn(with: .google(idToken: "g-tok"))

        let remainingIds = Set(try await api.listProjects(includeArchived: false).map(\.id))
        #expect(remainingIds == [serverInboxId, userWork.id])

        let ops = await pushed.ops
        for dropped in bootstrapDefaults {
            #expect(!ops.contains { $0["entityId"]?.stringValue == dropped.id })
        }
        let projectCreate = try #require(ops.first { $0["entity"]?.stringValue == "project" && $0["entityId"]?.stringValue == userWork.id })
        #expect(projectCreate["row"]?.objectValue?["ownerId"]?.stringValue == serverMeId)
        let pmOp = try #require(ops.first { $0["entity"]?.stringValue == "projectMember" && $0["entityId"]?.stringValue == "\(userWork.id):\(serverMeId)" })
        #expect(pmOp["row"]?.objectValue?["memberId"]?.stringValue == serverMeId)
    }

    @Test func firstLoginReconcileEmitsChangeEvenWhenFirstSyncFails() async throws {
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()

        let serverMeId = ID.make()
        let serverInboxId = ID.make()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                return try jsonResponse(200, [
                    "accessToken": "acc-1",
                    "refreshToken": "ref-1",
                    "user": ["id": "user-1"],
                    "isNewAccount": false,
                    "hasData": true,
                    "meMemberId": serverMeId,
                    "inboxProjectId": serverInboxId,
                ])
            }
            return SyncHTTPResponse(status: 500, body: Data("first sync failed".utf8))
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: InMemorySyncTokenStore(), clock: .fixed(noon, timeZone: taipei))
        let stream = await engine.changeNotifications()

        var thrownError: SyncError?
        do {
            _ = try await engine.signIn(with: .google(idToken: "g-tok"))
            Issue.record("Expected signIn() to throw when first syncNow() fails with 500")
        } catch let error as SyncError {
            thrownError = error
        }

        guard case .retryable(_, let statusCode, _) = thrownError else {
            Issue.record("Expected retryable error, got \(String(describing: thrownError))")
            return
        }
        #expect(statusCode == 500)
        #expect(try await engine.isSignedIn)
        #expect(try await engine.signedInUserId == "user-1")

        let remainingProjects = try await api.listProjects(includeArchived: false)
        #expect(remainingProjects.map(\.id) == [serverInboxId])

        let emitted = await nextEmittedSummary(from: stream)
        #expect(emitted == SyncSummary(didChangeLocalData: true))
    }

    @Test func signOutWipesLocalDataAndTokens() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 100, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        let tokens = InMemorySyncTokenStore()

        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                return try jsonResponse(200, [
                    "accessToken": "acc-1",
                    "refreshToken": "ref-1",
                    "user": ["id": "user-A"],
                    "isNewAccount": true,
                    "hasData": false,
                    "meMemberId": NSNull(),
                    "inboxProjectId": NSNull(),
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            return try jsonResponse(200, [
                "scopes": [["scope": "u:user-A", "rows": [], "cursor": 7, "hasMore": false]],
                "memberships": [],
                "members": [],
            ])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens, clock: .fixed(noon, timeZone: taipei))
        _ = try await engine.signIn(with: .google(idToken: "g-tok"))

        // Populate remaining synced tables (folder, task, checklistItem, tag, attachment, comment, invite, purgedId, syncStaging).
        let folder = try await api.createFolder(name: "資料夾")
        let project = try await api.createProject(CreateProjectInput(name: "測試清單", folderId: folder.id))
        let task = try await api.createTask(CreateTaskInput(projectId: project.id, title: "測試任務", subtasks: ["子項目"], tags: ["#標籤"]))
        _ = try await api.uploadAttachment(taskId: task.id, fileName: "a.txt", data: Data("hi".utf8), mimeType: "text/plain", originalPath: nil)
        _ = try await api.inviteMember(projectId: project.id, email: "x@example.test", role: "editor")
        let me = try #require(try await api.listMembers().first(where: \.isMe))
        try await db.writer.write { db in
            let c = CommentRecord(id: ID.make(), taskId: task.id, authorId: me.id, body: "hi", createdAt: nowMs, updatedAt: nowMs)
            try c.insert(db)
            try PurgedId.record(entity: "task", id: ID.make(), purgedAt: nowMs, in: db)
            try SyncApplier.stageRow(entity: "task", entityId: ID.make(), row: [:], clocks: [:], serverSeq: 1, now: nowMs, in: db)
        }

        let (deviceIdBefore, hlcBefore) = try await db.writer.read { db in
            (
                try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [HLC.deviceIdMetaKey]),
                try HLC.loadLast(in: db)
            )
        }
        #expect(deviceIdBefore != nil)
        #expect(hlcBefore != nil)
        #expect(try await engine.isSignedIn)

        try await engine.signOut()

        #expect(try await !engine.isSignedIn)
        #expect(try await engine.signedInUserId == nil)
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)

        try await db.writer.read { db in
            for table in [
                "member", "folder", "project", "projectMember", "projectInvite",
                "task", "checklistItem", "tag", "attachment", "comment",
                "change", "purgedId", "syncStaging", "projectMembership", "memberUser",
            ] {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? -1
                #expect(count == 0, "Expected \(table) to be empty after signOut")
            }
            let cursors = try SyncEngine.loadPullCursors(in: db)
            #expect(cursors.isEmpty)
            let userIdMeta = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [SyncEngine.signedInUserIdMetaKey])
            #expect(userIdMeta == nil)
            let deviceIdAfter = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [HLC.deviceIdMetaKey])
            let hlcAfter = try HLC.loadLast(in: db)
            #expect(deviceIdAfter == deviceIdBefore)
            #expect(hlcAfter == hlcBefore)
        }
    }

    @Test func membershipAppearsTriggersBackfillOnce() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "srv").description
        let sharedId = ID.make()
        let ownerId = ID.make()
        let taskId = ID.make()

        let pullBodies = PullBodyRecorder()
        let (_, db, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
            }
            let bodyObj = try decodeBodyObject(req.body)
            await pullBodies.append(bodyObj)
            let backfillIds = bodyObj["backfill"]?.arrayValue?.compactMap(\.stringValue)
            if backfillIds == [sharedId] {
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:owner-a",
                        "rows": [
                            [
                                "entity": "project",
                                "row": [
                                    "id": sharedId,
                                    "name": "共享清單",
                                    "viewMode": "list",
                                    "kind": "TASK",
                                    "isInbox": false,
                                    "ownerId": ownerId,
                                    "sortKey": "z0",
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
                                    "projectId": sharedId,
                                    "title": "回補任務",
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
                        ],
                        "cursor": 2,
                        "hasMore": false,
                    ]],
                    "memberships": [
                        ["projectId": sharedId, "scope": "u:owner-a", "role": "editor"],
                    ],
                    "members": [],
                ])
            }
            return try jsonResponse(200, [
                "scopes": [],
                "memberships": [
                    ["projectId": sharedId, "scope": "u:owner-a", "role": "editor"],
                ],
                "members": [],
            ])
        }
        try await ackAllChanges(in: db)

        // First pull discovers the new shared membership.
        _ = try await engine.syncNow()
        // Second sync triggers backfill once, then third sync runs normal pull without backfill.
        _ = try await engine.syncNow()
        _ = try await engine.syncNow()

        let pulls = await pullBodies.bodies
        let backfillPulls = pulls.filter { $0["backfill"] != nil }
        #expect(backfillPulls.count == 1)
        #expect(backfillPulls[0]["backfill"]?.arrayValue?.compactMap(\.stringValue) == [sharedId])
        #expect(pulls.last?["backfill"] == nil)

        let task = try await db.writer.read { db in try TaskRecord.fetchOne(db, key: taskId) }
        #expect(task?.title == "回補任務")
    }

    @Test func newMembershipLearnedFromNormalPullIsBackfilledInSameCycle() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "srv").description
        let sharedId = ID.make()
        let ownerId = ID.make()
        let taskId = ID.make()

        let pullBodies = PullBodyRecorder()
        let (_, db, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
            }
            let bodyObj = try decodeBodyObject(req.body)
            await pullBodies.append(bodyObj)
            let backfillIds = bodyObj["backfill"]?.arrayValue?.compactMap(\.stringValue)
            if backfillIds == [sharedId] {
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:owner-a",
                        "rows": [
                            [
                                "entity": "project",
                                "row": [
                                    "id": sharedId,
                                    "name": "既有共享清單",
                                    "viewMode": "list",
                                    "kind": "TASK",
                                    "isInbox": false,
                                    "ownerId": ownerId,
                                    "sortKey": "z0",
                                    "showInSmart": "all",
                                    "notifyMode": "all",
                                    "createdAt": nowMs - 10_000,
                                    "updatedAt": nowMs - 10_000,
                                ],
                                "clocks": ["name": serverHLC],
                                "serverSeq": 1,
                            ],
                            [
                                "entity": "task",
                                "row": [
                                    "id": taskId,
                                    "projectId": sharedId,
                                    "title": "舊清單任務",
                                    "content": "",
                                    "priority": 0,
                                    "status": 0,
                                    "reminders": [],
                                    "tags": [],
                                    "sortKey": "a0",
                                    "createdAt": nowMs - 10_000,
                                    "updatedAt": nowMs - 10_000,
                                ],
                                "clocks": ["title": serverHLC],
                                "serverSeq": 2,
                            ],
                        ],
                        "cursor": 2,
                        "hasMore": false,
                    ]],
                    "memberships": [
                        ["projectId": sharedId, "scope": "u:owner-a", "role": "editor"],
                    ],
                    "members": [],
                ])
            }
            return try jsonResponse(200, [
                "scopes": [[
                    "scope": "u:owner-a",
                    "rows": [],
                    "cursor": 10,
                    "hasMore": false,
                ]],
                "memberships": [
                    ["projectId": sharedId, "scope": "u:owner-a", "role": "editor"],
                ],
                "members": [],
            ])
        }
        try await ackAllChanges(in: db)
        try await db.writer.write { db in
            try SyncEngine.savePullCursors(["u:owner-a": 10], in: db)
        }

        // Single syncNow() on B2 (already has cursors): normal pull reveals new membership,
        // and the same syncNow() must immediately issue backfill and apply the old list rows.
        let summary = try await engine.syncNow()

        let pulls = await pullBodies.bodies
        try #require(pulls.count == 2)
        #expect(pulls[0]["backfill"] == nil)
        #expect(pulls[0]["cursors"]?.objectValue?["u:owner-a"] == .int(10))
        #expect(pulls[1]["backfill"]?.arrayValue?.compactMap(\.stringValue) == [sharedId])

        let (project, task, needsBackfill) = try await db.writer.read { db in
            (
                try ProjectRecord.fetchOne(db, key: sharedId),
                try TaskRecord.fetchOne(db, key: taskId),
                try Bool.fetchOne(
                    db,
                    sql: "SELECT needsBackfill FROM projectMembership WHERE projectId = ?",
                    arguments: [sharedId]
                )
            )
        }
        #expect(project?.name == "既有共享清單")
        #expect(task?.title == "舊清單任務")
        #expect(needsBackfill == false)
        #expect(summary.didChangeLocalData)
    }

    @Test func membershipDisappearsDeletesSharedListLocally() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "srv").description
        let sharedId = ID.make()
        let ownerId = ID.make()
        let taskId = ID.make()
        let checkId = ID.make()

        let dbSlot = DBBox()
        let (api, db, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "applied"] },
                    "serverTime": serverHLC,
                ])
            }
            // Simulate a concurrent offline edit created while pull HTTP is in flight (unacked at pull apply).
            if let db = await dbSlot.get() {
                try await db.writer.write { db in
                    if var edited = try TaskRecord.fetchOne(db, key: taskId) {
                        edited.title = "編輯到一半"
                        edited.updatedAt = nowMs + 200
                        try Outbox.save(edited, entity: "task", id: taskId, in: db, now: nowMs + 200)
                    }
                }
            }
            return try jsonResponse(200, [
                "scopes": [],
                "memberships": [],
                "members": [],
            ])
        }
        await dbSlot.set(db)
        try await ackAllChanges(in: db)

        let me = try #require(try await api.listMembers().first { $0.isMe })
        let inbox = try #require(try await api.listProjects(includeArchived: false).first { $0.isInbox })
        try await db.writer.write { db in
            try MemberRecord(id: ownerId, name: "Owner", initial: "O", color: "#112233", isMe: false, createdAt: nowMs, updatedAt: nowMs).insert(db)
            let p = ProjectRecord(id: sharedId, name: "共享", viewMode: "list", kind: "TASK", isInbox: false, ownerId: ownerId, sortKey: "z1", showInSmart: "all", notifyMode: "all", createdAt: nowMs, updatedAt: nowMs)
            try p.insert(db)
            try ProjectMemberRecord(projectId: sharedId, memberId: ownerId, role: "owner", createdAt: nowMs, updatedAt: nowMs).insert(db)
            try ProjectMemberRecord(projectId: sharedId, memberId: me.id, role: "editor", createdAt: nowMs, updatedAt: nowMs).insert(db)
            let t = TaskRecord(id: taskId, projectId: sharedId, title: "子任務之父", content: "", priority: 0, status: 0, reminders: [], tags: [], sortKey: "a0", createdAt: nowMs, updatedAt: nowMs)
            try t.insert(db)
            let c = ChecklistItemRecord(id: checkId, taskId: taskId, title: "步驟", status: 0, sortKey: "a0", createdAt: nowMs, updatedAt: nowMs)
            try c.insert(db)
            try db.execute(
                sql: "INSERT INTO projectMembership (projectId, scope, role, needsBackfill) VALUES (?, ?, ?, 0)",
                arguments: [sharedId, "u:owner-a", "editor"]
            )
        }

        _ = try await engine.syncNow()

        let counts = try await db.writer.read { db in
            (
                projectExists: try ProjectRecord.fetchOne(db, key: sharedId) != nil,
                taskExists: try TaskRecord.fetchOne(db, key: taskId) != nil,
                checkExists: try ChecklistItemRecord.fetchOne(db, key: checkId) != nil,
                pmCount: try ProjectMemberRecord.filter(Column("projectId") == sharedId).fetchCount(db),
                membershipCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projectMembership WHERE projectId = ?", arguments: [sharedId]) ?? -1,
                unackedProject: try ChangeRecord.filter(Column("entityId") == sharedId && Column("ackedAt") == nil).fetchCount(db),
                unackedTask: try ChangeRecord.filter(Column("entityId") == taskId && Column("ackedAt") == nil).fetchCount(db),
                unackedCheck: try ChangeRecord.filter(Column("entityId") == checkId && Column("ackedAt") == nil).fetchCount(db),
                purgedCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM purgedId") ?? -1,
                inboxExists: try ProjectRecord.fetchOne(db, key: inbox.id) != nil
            )
        }
        #expect(!counts.projectExists)
        #expect(!counts.taskExists)
        #expect(!counts.checkExists)
        #expect(counts.pmCount == 0)
        #expect(counts.membershipCount == 0)
        #expect(counts.unackedProject == 0)
        #expect(counts.unackedTask == 0)
        #expect(counts.unackedCheck == 0)
        #expect(counts.purgedCount == 0)
        #expect(counts.inboxExists)
    }

    @Test func ownListNeverDeletedOnMissingMembership() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "srv").description

        let (api, db, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
            }
            return try jsonResponse(200, [
                "scopes": [],
                "memberships": [],
                "members": [],
            ])
        }

        let ownList = try await api.createProject(CreateProjectInput(name: "自己的清單"))
        let ownTask = try await api.createTask(CreateTaskInput(projectId: ownList.id, title: "自己任務"))
        try await ackAllChanges(in: db)
        try await db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO projectMembership (projectId, scope, role, needsBackfill) VALUES (?, ?, ?, 0)",
                arguments: [ownList.id, "u:me", "owner"]
            )
        }

        _ = try await engine.syncNow()

        let remainingProject = try await db.writer.read { db in try ProjectRecord.fetchOne(db, key: ownList.id) }
        let remainingTask = try await db.writer.read { db in try TaskRecord.fetchOne(db, key: ownTask.id) }
        #expect(remainingProject?.name == "自己的清單")
        #expect(remainingTask?.title == "自己任務")
    }

    @Test func membersRowsApplied() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "srv").description
        let otherMemberId = ID.make()

        let (api, db, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
            }
            return try jsonResponse(200, [
                "scopes": [],
                "memberships": [],
                "members": [[
                    "id": otherMemberId,
                    "name": "家人 B",
                    "initial": "B",
                    "color": "#44AA66",
                    "isMe": true,
                    "userId": "user-b",
                    "createdAt": nowMs,
                    "updatedAt": nowMs,
                ]],
            ])
        }
        try await ackAllChanges(in: db)

        _ = try await engine.syncNow()

        let members = try await api.listMembers()
        let meCount = members.filter(\.isMe).count
        let appliedOther = try #require(members.first { $0.id == otherMemberId })
        #expect(meCount == 1)
        #expect(appliedOther.name == "家人 B")
        #expect(appliedOther.isMe == false)
        #expect(appliedOther.userId == "user-b")
    }

    @Test func nonCreatorFolderIdKeptLocal() async throws {
        let nowMs = noon.epochMillis
        let olderHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "srv").description
        let newerHLC = HLC(ms: nowMs + 500, counter: 0, deviceId: "srv").description
        let sharedId = ID.make()
        let ownerId = ID.make()

        let (api, db, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                return try jsonResponse(200, ["results": [], "serverTime": newerHLC])
            }
            return try jsonResponse(200, [
                "scopes": [[
                    "scope": "u:owner-a",
                    "rows": [[
                        "entity": "project",
                        "row": [
                            "id": sharedId,
                            "name": "改名後共享",
                            "viewMode": "list",
                            "kind": "TASK",
                            "isInbox": false,
                            "ownerId": ownerId,
                            "sortKey": "z0",
                            "showInSmart": "all",
                            "notifyMode": "all",
                            "createdAt": nowMs,
                            "updatedAt": nowMs + 500,
                        ],
                        "clocks": ["name": newerHLC, "folderId": newerHLC],
                        "serverSeq": 1,
                    ]],
                    "cursor": 1,
                    "hasMore": false,
                ]],
                "memberships": [["projectId": sharedId, "scope": "u:owner-a", "role": "editor"]],
                "members": [],
            ])
        }

        let localFolder = try await api.createFolder(name: "我的資料夾")
        try await db.writer.write { db in
            try MemberRecord(id: ownerId, name: "Owner", initial: "O", color: "#112233", isMe: false, createdAt: nowMs, updatedAt: nowMs).insert(db)
            try ProjectRecord(
                id: sharedId,
                name: "原本共享",
                folderId: localFolder.id,
                viewMode: "list",
                kind: "TASK",
                isInbox: false,
                ownerId: ownerId,
                sortKey: "z0",
                showInSmart: "all",
                notifyMode: "all",
                createdAt: nowMs,
                updatedAt: nowMs
            ).insert(db)
        }
        _ = olderHLC
        try await ackAllChanges(in: db)

        _ = try await engine.syncNow()

        let updated = try #require(try await api.listProjects(includeArchived: false).first { $0.id == sharedId })
        #expect(updated.name == "改名後共享")
        #expect(updated.folderId == localFolder.id)
    }

    @Test func myRoleExposed() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "srv").description
        let editorProjectId = ID.make()
        let viewerProjectId = ID.make()
        let ownerId = ID.make()

        let (api, db, _, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/sync/push" {
                return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
            }
            return try jsonResponse(200, [
                "scopes": [[
                    "scope": "u:owner-a",
                    "rows": [
                        [
                            "entity": "project",
                            "row": [
                                "id": editorProjectId,
                                "name": "可編輯清單",
                                "viewMode": "list",
                                "kind": "TASK",
                                "isInbox": false,
                                "ownerId": ownerId,
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
                            "entity": "project",
                            "row": [
                                "id": viewerProjectId,
                                "name": "唯讀清單",
                                "viewMode": "list",
                                "kind": "TASK",
                                "isInbox": false,
                                "ownerId": ownerId,
                                "sortKey": "z2",
                                "showInSmart": "all",
                                "notifyMode": "all",
                                "createdAt": nowMs,
                                "updatedAt": nowMs,
                            ],
                            "clocks": ["name": serverHLC],
                            "serverSeq": 2,
                        ],
                    ],
                    "cursor": 2,
                    "hasMore": false,
                ]],
                "memberships": [
                    ["projectId": editorProjectId, "scope": "u:owner-a", "role": "editor"],
                    ["projectId": viewerProjectId, "scope": "u:owner-a", "role": "viewer"],
                ],
                "members": [["id": ownerId, "name": "Owner", "initial": "O", "color": "#112233", "isMe": false, "createdAt": nowMs, "updatedAt": nowMs]],
            ])
        }

        let localOnly = try await api.createProject(CreateProjectInput(name: "本地清單"))
        #expect(localOnly.myRole == "owner")
        try await ackAllChanges(in: db)

        _ = try await engine.syncNow()

        let projects = try await api.listProjects(includeArchived: false)
        #expect(projects.first { $0.id == localOnly.id }?.myRole == "owner")
        #expect(projects.first { $0.id == editorProjectId }?.myRole == "editor")
        #expect(projects.first { $0.id == viewerProjectId }?.myRole == "viewer")
    }

    @Test func acceptInviteSyncsWithBackfill() async throws {
        let nowMs = noon.epochMillis
        let serverHLC = HLC(ms: nowMs + 100, counter: 0, deviceId: "srv").description
        let sharedId = ID.make()
        let ownerId = ID.make()
        let taskId = ID.make()

        let pullBodies = PullBodyRecorder()
        let (api, db, _, transport, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/invites/INV-CODE/accept" && req.method == "POST" {
                return try jsonResponse(200, [
                    "projectId": sharedId,
                    "scope": "u:owner-a",
                    "role": "editor",
                ])
            }
            if req.path == "/sync/push" {
                return try jsonResponse(200, ["results": [], "serverTime": serverHLC])
            }
            if req.path == "/sync/pull" {
                let bodyObj = try decodeBodyObject(req.body)
                await pullBodies.append(bodyObj)
                if bodyObj["backfill"]?.arrayValue?.compactMap(\.stringValue) == [sharedId] {
                    return try jsonResponse(200, [
                        "scopes": [[
                            "scope": "u:owner-a",
                            "rows": [
                                [
                                    "entity": "project",
                                    "row": [
                                        "id": sharedId,
                                        "name": "受邀清單",
                                        "viewMode": "list",
                                        "kind": "TASK",
                                        "isInbox": false,
                                        "ownerId": ownerId,
                                        "sortKey": "z0",
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
                                        "projectId": sharedId,
                                        "title": "受邀任務",
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
                            ],
                            "cursor": 2,
                            "hasMore": false,
                        ]],
                        "memberships": [["projectId": sharedId, "scope": "u:owner-a", "role": "editor"]],
                        "members": [["id": ownerId, "name": "Owner", "initial": "O", "color": "#112233", "isMe": false, "createdAt": nowMs, "updatedAt": nowMs]],
                    ])
                }
                return try jsonResponse(200, [
                    "scopes": [],
                    "memberships": [["projectId": sharedId, "scope": "u:owner-a", "role": "editor"]],
                    "members": [],
                ])
            }
            return try jsonResponse(404, ["error": "Unexpected path"])
        }
        try await ackAllChanges(in: db)

        let sharing = RemoteListSharing(syncEngine: engine)
        let accepted = try await sharing.acceptInvite(code: "INV-CODE")
        #expect(accepted.projectId == sharedId)
        #expect(accepted.role == "editor")

        let captured = await transport.capturedRequests()
        #expect(captured.contains { $0.path == "/invites/INV-CODE/accept" && $0.method == "POST" })

        let pulls = await pullBodies.bodies
        let backfillPulls = pulls.filter { $0["backfill"] != nil }
        #expect(backfillPulls.count == 1)
        #expect(backfillPulls[0]["backfill"]?.arrayValue?.compactMap(\.stringValue) == [sharedId])

        let projects = try await api.listProjects(includeArchived: false)
        let syncedProject = try #require(projects.first { $0.id == sharedId })
        #expect(syncedProject.name == "受邀清單")
        #expect(syncedProject.myRole == "editor")
        let tasks = try await api.listTasks(TaskQuery(projectId: sharedId))
        #expect(tasks.map(\.title) == ["受邀任務"])
    }

    @Test func inviteUrlParsing() {
        #expect(SyncEngine.parseInviteCode(from: "daydo://invite/abc_123-XYZ") == "abc_123-XYZ")
        #expect(SyncEngine.parseInviteCode(from: "  daydo://invite/code99/\n") == "code99")
        #expect(SyncEngine.parseInviteCode(from: URL(string: "daydo://invite/token1")!) == "token1")
        #expect(SyncEngine.parseInviteCode(from: "https://daydo.app/invite/abc") == nil)
        #expect(SyncEngine.parseInviteCode(from: "daydo://project/abc") == nil)
        #expect(SyncEngine.parseInviteCode(from: "daydo://invite/") == nil)
        #expect(SyncEngine.parseInviteCode(from: "daydo://invite/a/b") == nil)
        #expect(SyncEngine.parseInviteCode(from: "daydo://invite/abc?x=1") == nil)
        #expect(SyncEngine.parseInviteCode(from: "") == nil)
    }

    @Test func sharingErrorsMapped() async throws {
        let nowMs = noon.epochMillis
        let (_, db, tokens, _, engine) = try await makeSyncSetup { req, _ in
            if req.path == "/auth/refresh" {
                return try jsonResponse(200, [
                    "accessToken": "access-refreshed",
                    "refreshToken": "refresh-2",
                ])
            }
            if req.path == "/invites" && req.method == "POST" {
                if req.headers["Authorization"] == "Bearer access-1" {
                    return try jsonResponse(401, ["error": "expired"])
                }
                return try jsonResponse(200, [
                    "code": "c1",
                    "url": "daydo://invite/c1",
                    "expiresAt": nowMs + 3600_000,
                ])
            }
            if req.path == "/invites/forbidden-code" && req.method == "DELETE" {
                return try jsonResponse(403, ["error": "Only the owner can revoke"])
            }
            if req.path == "/invites/missing-code" && req.method == "GET" {
                return try jsonResponse(404, ["error": "Invite not found"])
            }
            if req.path == "/projects/p1/members/u2" && req.method == "PUT" {
                return try jsonResponse(409, ["error": "Conflict updating role"])
            }
            if req.path == "/projects/p1/members/user-self" && req.method == "DELETE" {
                return try jsonResponse(400, ["error": "Cannot remove owner"])
            }
            return try jsonResponse(500, ["error": "unexpected"])
        }
        try await db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?)",
                arguments: [SyncEngine.signedInUserIdMetaKey, "user-self"]
            )
        }

        let sharing = RemoteListSharing(syncEngine: engine)
        let targetMember = ProjectMemberInfo(
            memberId: "m2",
            name: "User 2",
            initial: "U",
            color: "#4AA8E8",
            isMe: false,
            role: "editor",
            userId: "u2"
        )

        // 401 -> refresh -> retry succeeds.
        let created = try await sharing.createInvite(projectId: "p1", role: "editor")
        #expect(created.code == "c1")
        #expect(created.url == "daydo://invite/c1")
        #expect(tokens.accessToken == "access-refreshed")

        await #expect(throws: SharingError.forbidden("Only the owner can revoke")) {
            try await sharing.revokeInvite(code: "forbidden-code")
        }
        await #expect(throws: SharingError.notFound("Invite not found")) {
            _ = try await sharing.inviteInfo(code: "missing-code")
        }
        await #expect(throws: SharingError.conflict("Conflict updating role")) {
            try await sharing.changeMemberRole(projectId: "p1", member: targetMember, role: "viewer")
        }
        await #expect(throws: SharingError.badRequest("Cannot remove owner")) {
            try await sharing.leaveList(projectId: "p1")
        }
    }

    @Test func signInMarksLocalProjectInviteOpsLocalOnly() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 100, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()

        let list = try await api.createProject(CreateProjectInput(name: "共享清單"))
        let invite = try await api.inviteMember(projectId: list.id, email: "family@example.test", role: "editor")
        _ = try await api.updateInviteRole(id: invite.id, role: "viewer")

        let pushed = PushOpRecorder()
        let tokens = InMemorySyncTokenStore()
        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                return try jsonResponse(200, [
                    "accessToken": "acc-invite",
                    "refreshToken": "ref-invite",
                    "user": ["id": "user-invite"],
                    "isNewAccount": true,
                    "hasData": false,
                    "meMemberId": NSNull(),
                    "inboxProjectId": NSNull(),
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                await pushed.append(ops)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            return try jsonResponse(200, ["scopes": [], "memberships": [], "members": []])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens, clock: .fixed(noon, timeZone: taipei))
        _ = try await engine.signIn(with: .google(idToken: "g-tok"))

        let ops = await pushed.ops
        #expect(!ops.contains { $0["entity"]?.stringValue == "projectInvite" })

        let (inviteChanges, pendingCount, keptInvite) = try await db.writer.read { db in
            (
                try ChangeRecord
                    .filter(Column("entity") == "projectInvite" && Column("entityId") == invite.id)
                    .order(Column("seq"))
                    .fetchAll(db),
                try ChangeRecord.filter(Column("ackedAt") == nil).fetchCount(db),
                try ProjectInviteRecord.fetchOne(db, key: invite.id)
            )
        }
        #expect(inviteChanges.count == 2)
        #expect(inviteChanges.allSatisfy { $0.ackedAt == nowMs && $0.result == "local-only" })
        #expect(pendingCount == 0)
        #expect(keptInvite?.email == "family@example.test")
        #expect(keptInvite?.role == "viewer")
    }

    @Test func avatarUrlPersistedFromLoginAndPullMembersAndClearedOnSignOut() async throws {
        let nowMs = noon.epochMillis
        let serverTime = HLC(ms: nowMs + 100, counter: 0, deviceId: "server").description
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-avatar-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()
        let project = try await api.createProject(CreateProjectInput(name: "共享清單"))

        actor AvatarState {
            var memberAvatar: String? = "https://lh3.googleusercontent.com/a/other-1"
            var meAvatar: String? = "https://lh3.googleusercontent.com/a/me-1"
            func setMemberAvatar(_ v: String?) { memberAvatar = v }
            func setMeAvatar(_ v: String?) { meAvatar = v }
        }
        let state = AvatarState()
        let tokens = InMemorySyncTokenStore()
        let transport = FakeSyncTransport { req, _ in
            if req.path == "/auth/google" {
                let meAvatar = await state.meAvatar
                return try jsonResponse(200, [
                    "accessToken": "acc-1",
                    "refreshToken": "ref-1",
                    "user": ["id": "user-me"],
                    "isNewAccount": true,
                    "hasData": false,
                    "meMemberId": NSNull(),
                    "inboxProjectId": NSNull(),
                    "avatarUrl": meAvatar as Any,
                ])
            }
            if req.path == "/sync/push" {
                let ops = try decodePushOps(req.body)
                return try jsonResponse(200, [
                    "results": ops.map { ["opId": $0["opId"]?.stringValue ?? "", "status": "applied", "row": NSNull(), "clocks": [:]] },
                    "serverTime": serverTime,
                ])
            }
            if req.path == "/sync/pull" {
                let memberAvatar = await state.memberAvatar
                return try jsonResponse(200, [
                    "scopes": [
                        [
                            "scope": "u:user-me",
                            "rows": [
                                [
                                    "entity": "projectMember",
                                    "row": [
                                        "projectId": project.id,
                                        "memberId": "m-other",
                                        "role": "editor",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs + 50,
                                    ],
                                    "clocks": ["role": serverTime, "updatedAt": serverTime],
                                    "serverSeq": 1,
                                ],
                            ],
                            "cursor": 1,
                            "hasMore": false,
                        ],
                    ],
                    "memberships": [
                        ["projectId": project.id, "scope": "u:user-me", "role": "owner"],
                    ],
                    "members": [
                        [
                            "id": "m-other",
                            "userId": "user-other",
                            "name": "小安",
                            "initial": "小",
                            "color": "#008B8B",
                            "avatarUrl": memberAvatar as Any,
                            "isMe": false,
                            "createdAt": nowMs,
                            "updatedAt": nowMs,
                        ],
                    ],
                ])
            }
            return try jsonResponse(200, [:])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens, clock: .fixed(noon, timeZone: taipei))
        _ = try await engine.signIn(with: .google(idToken: "g-tok"))

        let members1 = try await api.listMembers()
        let me1 = members1.first { $0.isMe }
        let other1 = members1.first { $0.id == "m-other" }
        #expect(me1?.avatarUrl == "https://lh3.googleusercontent.com/a/me-1")
        #expect(other1?.avatarUrl == "https://lh3.googleusercontent.com/a/other-1")
        #expect(other1?.userId == "user-other")

        let projMembers1 = try await api.listProjectMembers(projectId: project.id)
        #expect(projMembers1.first { $0.memberId == "m-other" }?.avatarUrl == "https://lh3.googleusercontent.com/a/other-1")

        // setMeAvatarUrlIfMissing does NOT overwrite an existing server URL.
        try await engine.setMeAvatarUrlIfMissing("https://lh3.googleusercontent.com/a/fallback")
        #expect(try await api.listMembers().first { $0.isMe }?.avatarUrl == "https://lh3.googleusercontent.com/a/me-1")

        // Updating only co-member's avatarUrl in pull marks didChangeLocalData and preserves userId when omitted.
        await state.setMemberAvatar("https://lh3.googleusercontent.com/a/other-2")
        let summary2 = try await engine.syncNow()
        #expect(summary2.didChangeLocalData)
        let other2 = try await api.listMembers().first { $0.id == "m-other" }
        #expect(other2?.avatarUrl == "https://lh3.googleusercontent.com/a/other-2")
        #expect(other2?.userId == "user-other")

        // Sign out clears my avatarUrl and memberUser table.
        try await engine.signOut()
        #expect(try await api.listMembers().isEmpty)

        // When server login returns nil avatarUrl, setMeAvatarUrlIfMissing populates it.
        await state.setMeAvatar(nil)
        _ = try await engine.signIn(with: .google(idToken: "g-tok-2"))
        #expect(try await api.listMembers().first { $0.isMe }?.avatarUrl == nil)
        try await engine.setMeAvatarUrlIfMissing("https://lh3.googleusercontent.com/a/fallback")
        #expect(try await api.listMembers().first { $0.isMe }?.avatarUrl == "https://lh3.googleusercontent.com/a/fallback")
    }

    @Test func migratesV6MemberUserAddingAvatarUrl() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO memberUser (memberId, userId) VALUES ('m1', 'u1')")
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT memberId, userId, avatarUrl FROM memberUser WHERE memberId = 'm1'")
            #expect(row?["userId"] == "u1")
            let url: String? = row?["avatarUrl"]
            #expect(url == nil)
        }
    }

    @Test func updateMeAvatarSendsAuthorizedPutRefreshesOn401AndPersists() async throws {
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-sync-put-avatar-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        try await api.bootstrap()

        actor CallLog {
            var calls: [(method: String, path: String, auth: String?, avatarUrl: String?)] = []
            func append(method: String, path: String, auth: String?, avatarUrl: String?) {
                calls.append((method, path, auth, avatarUrl))
            }
        }
        let log = CallLog()
        let tokens = InMemorySyncTokenStore(accessToken: "expired-access", refreshToken: "refresh-1")
        let targetUrl = "https://lh3.googleusercontent.com/a/me=s256-c"

        let transport = FakeSyncTransport { req, _ in
            let auth = req.headers["Authorization"]
            let bodyObj = try? decodeBodyObject(req.body)
            await log.append(
                method: req.method,
                path: req.path,
                auth: auth,
                avatarUrl: bodyObj?["avatarUrl"]?.stringValue
            )

            if req.method == "PUT" && req.path == "/me/avatar" {
                if auth == "Bearer expired-access" {
                    return try jsonResponse(401, ["error": "Unauthorized"])
                }
                let sentUrl = bodyObj?["avatarUrl"]?.stringValue ?? ""
                if sentUrl.hasPrefix("http://") {
                    return try jsonResponse(400, ["error": "Invalid avatarUrl"])
                }
                return try jsonResponse(200, ["avatarUrl": sentUrl])
            }
            if req.method == "POST" && req.path == "/auth/refresh" {
                return try jsonResponse(200, [
                    "accessToken": "fresh-access",
                    "refreshToken": "refresh-2",
                    "hasData": true,
                    "meMemberId": NSNull(),
                    "inboxProjectId": NSNull(),
                    "avatarUrl": NSNull(),
                ])
            }
            return try jsonResponse(404, ["error": "Not found"])
        }

        let engine = SyncEngine(database: db, transport: transport, tokenStore: tokens, clock: .fixed(noon, timeZone: taipei))
        let stream = await engine.changeNotifications()
        #expect(try await engine.meAvatarUrl == nil)

        let returned = try await engine.updateMeAvatar(targetUrl)
        #expect(returned == targetUrl)
        #expect(try await engine.meAvatarUrl == targetUrl)
        #expect(try await api.listMembers().first { $0.isMe }?.avatarUrl == targetUrl)
        #expect(tokens.accessToken == "fresh-access")
        #expect(tokens.refreshToken == "refresh-2")

        let emitted = await nextEmittedSummary(from: stream)
        #expect(emitted == SyncSummary(didChangeLocalData: true))

        let calls = await log.calls
        try #require(calls.count == 3)
        #expect(calls[0].method == "PUT")
        #expect(calls[0].path == "/me/avatar")
        #expect(calls[0].auth == "Bearer expired-access")
        #expect(calls[0].avatarUrl == targetUrl)
        #expect(calls[1].method == "POST")
        #expect(calls[1].path == "/auth/refresh")
        #expect(calls[2].method == "PUT")
        #expect(calls[2].path == "/me/avatar")
        #expect(calls[2].auth == "Bearer fresh-access")
        #expect(calls[2].avatarUrl == targetUrl)

        do {
            _ = try await engine.updateMeAvatar("http://insecure.example.com/a.png")
            Issue.record("Expected HTTP 400 to throw SyncError.protocolError")
        } catch let SyncError.protocolError(msg) {
            #expect(msg.contains("400"))
        }
        #expect(try await engine.meAvatarUrl == targetUrl)
    }
}

private actor PullBodyRecorder {
    var bodies: [[String: SyncJSONValue]] = []
    func append(_ obj: [String: SyncJSONValue]) {
        bodies.append(obj)
    }
}

private actor DBBox {
    var db: AppDatabase?
    func set(_ db: AppDatabase) { self.db = db }
    func get() -> AppDatabase? { db }
}

private func decodeBodyObject(_ data: Data?) throws -> [String: SyncJSONValue] {
    guard let data else { return [:] }
    return try JSONDecoder().decode([String: SyncJSONValue].self, from: data)
}

private actor PushOpRecorder {
    var ops: [[String: SyncJSONValue]] = []
    func append(_ items: [[String: SyncJSONValue]]) {
        ops.append(contentsOf: items)
    }
}

private func decodePushOps(_ data: Data?) throws -> [[String: SyncJSONValue]] {
    guard let data else { return [] }
    let root = try JSONDecoder().decode([String: SyncJSONValue].self, from: data)
    return root["ops"]?.arrayValue?.compactMap(\.objectValue) ?? []
}

private extension SyncJSONValue {
    var arrayValue: [SyncJSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var objectValue: [String: SyncJSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }
}
