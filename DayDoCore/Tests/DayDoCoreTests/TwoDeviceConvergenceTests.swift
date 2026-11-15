import Foundation
import GRDB
import Testing
@testable import DayDoCore

private let convergenceBaseURL = ProcessInfo.processInfo.environment["DAYDO_SYNC_BASE_URL"]
private let convergenceGoogleIdToken = ProcessInfo.processInfo.environment["DAYDO_SYNC_GOOGLE_ID_TOKEN"]
private let convergenceEnabled = convergenceBaseURL != nil && convergenceGoogleIdToken != nil

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentMs: EpochMillis

    init(startMs: EpochMillis) {
        self.currentMs = startMs
    }

    func now() -> Date {
        lock.withLock { Date(epochMillis: currentMs) }
    }

    @discardableResult
    func advance(by deltaMs: EpochMillis = 100) -> EpochMillis {
        lock.withLock {
            currentMs += deltaMs
            return currentMs
        }
    }

    func set(_ ms: EpochMillis) {
        lock.withLock { currentMs = ms }
    }

    var clock: Clock {
        Clock(now: { self.now() }, timeZone: { taipei })
    }
}

private struct DatabaseSnapshot: Equatable {
    struct SyncedAttachment: Equatable, Hashable {
        let id: String
        let taskId: String
        let fileName: String
        let size: Int64
        let mimeType: String
        let createdAt: EpochMillis
        let updatedAt: EpochMillis
        let deletedAt: EpochMillis?
    }

    struct PurgedKey: Equatable, Hashable {
        let entity: String
        let id: String
    }

    let members: [MemberRecord]
    let folders: [FolderRecord]
    let projects: [ProjectRecord]
    let projectMembers: [ProjectMemberRecord]
    let projectInvites: [ProjectInviteRecord]
    let tasks: [TaskRecord]
    let checklistItems: [ChecklistItemRecord]
    let tags: [TagRecord]
    let attachments: [SyncedAttachment]
    let comments: [CommentRecord]
    let purgedKeys: Set<PurgedKey>
}

@Suite struct TwoDeviceConvergenceTests {
    @Test(.enabled(if: convergenceEnabled))
    func twoDeviceConvergence() async throws {
        let baseURLString = try #require(convergenceBaseURL)
        let baseURL = try #require(URL(string: baseURLString))
        let idToken = try #require(convergenceGoogleIdToken)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daydo-convergence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbA = try AppDatabase.open(at: tempDir.appendingPathComponent("device-a.sqlite"))
        let dbB = try AppDatabase.open(at: tempDir.appendingPathComponent("device-b.sqlite"))

        let deviceIdA = try await dbA.writer.write { db in try HLC.ensureDeviceId(in: db) }
        let deviceIdB = try await dbB.writer.write { db in try HLC.ensureDeviceId(in: db) }
        #expect(deviceIdA != deviceIdB)

        let transport = HTTPSyncTransport(baseURL: baseURL)
        let tokensA = InMemorySyncTokenStore()
        let tokensB = InMemorySyncTokenStore()

        let loginA = try await loginWithGoogle(transport: transport, idToken: idToken, deviceId: deviceIdA, tokenStore: tokensA)
        let loginB = try await loginWithGoogle(transport: transport, idToken: idToken, deviceId: deviceIdB, tokenStore: tokensB)
        #expect(loginA.user.id == loginB.user.id)
        #expect(loginA.isNewAccount)
        #expect(!loginB.isNewAccount)

        let clockA = MutableClock(startMs: Date().epochMillis)
        let clockB = MutableClock(startMs: Date().epochMillis)

        let apiA = LocalDayDoAPI(
            database: dbA,
            clock: clockA.clock,
            attachmentsDirectory: tempDir.appendingPathComponent("att-a")
        )
        let apiB = LocalDayDoAPI(
            database: dbB,
            clock: clockB.clock,
            attachmentsDirectory: tempDir.appendingPathComponent("att-b")
        )

        let syncA = SyncEngine(database: dbA, transport: transport, tokenStore: tokensA, clock: clockA.clock)
        let syncB = SyncEngine(database: dbB, transport: transport, tokenStore: tokensB, clock: clockB.clock)

        // 1. Device A bootstraps & syncs; Device B pulls initial account data without bootstrapping.
        try await apiA.bootstrap()
        _ = try await syncA.syncNow()
        _ = try await syncB.syncNow()

        let inboxA = try #require(try await apiA.listProjects(includeArchived: false).first(where: \.isInbox))
        let shoppingB = try #require(try await apiB.listProjects(includeArchived: false).first(where: { $0.name == "購物" }))

        // 2. Interleaved creates on both devices.
        let step2Base = try await maxClockFloor(dbA, dbB, clockA, clockB)
        clockA.set(step2Base + 100)
        let workFolder = try await apiA.createFolder(name: "工作區")
        let travelProject = try await apiA.createProject(CreateProjectInput(name: "旅遊計畫", color: "#4AA8E8", folderId: workFolder.id))
        let t1 = try await apiA.createTask(CreateTaskInput(
            projectId: travelProject.id,
            title: "訂機票",
            content: "初始內容",
            subtasks: ["比價", "刷卡"],
            tags: ["#旅行"]
        ))

        clockB.set(step2Base + 200)
        let groceryProject = try await apiB.createProject(CreateProjectInput(name: "家庭採買", color: "#E98A5B"))
        let t2 = try await apiB.createTask(CreateTaskInput(
            projectId: inboxA.id,
            title: "買牛奶",
            start: "2026-11-20T09:00:00+08:00",
            due: "2026-11-20T10:00:00+08:00",
            timeZone: "Asia/Taipei",
            reminder: "TRIGGER:-PT15M",
            tags: ["#日常"]
        ))

        try await syncUntilQuiet(syncA, syncB)

        // 3. Concurrent edits of the same task fields on both devices (test both winner-first and loser-first).
        let step3Base = try await maxClockFloor(dbA, dbB, clockA, clockB)
        clockA.set(step3Base + 100)
        var editT1A = UpdateTaskInput(taskId: t1.id)
        editT1A.title = "A 較早標題"
        editT1A.priority = .high
        _ = try await apiA.updateTask(editT1A)

        clockB.set(step3Base + 200)
        var editT2B = UpdateTaskInput(taskId: t2.id)
        editT2B.title = "B 較早牛奶"
        _ = try await apiB.updateTask(editT2B)

        clockB.set(step3Base + 300)
        var editT1B = UpdateTaskInput(taskId: t1.id)
        editT1B.title = "B 較晚標題"
        editT1B.content = "B 補充內容"
        _ = try await apiB.updateTask(editT1B)

        clockA.set(step3Base + 400)
        var editT2A = UpdateTaskInput(taskId: t2.id)
        editT2A.title = "A 較晚牛奶"
        _ = try await apiA.updateTask(editT2A)

        // Sync B first so B's t1.title ("B 較晚標題") is already on server when A pushes older ("A 較早標題").
        _ = try await syncB.syncNow()
        _ = try await syncA.syncNow()
        _ = try await syncB.syncNow()

        #expect(try await apiA.getTask(id: t1.id).title == "B 較晚標題")
        #expect(try await apiA.getTask(id: t1.id).priority == .high)
        #expect(try await apiA.getTask(id: t1.id).content == "B 補充內容")
        #expect(try await apiB.getTask(id: t2.id).title == "A 較晚牛奶")

        // 4. Schedule edit vs timezone edit on the same task (clocks["schedule"] group).
        let step4Create = try await maxClockFloor(dbA, dbB, clockA, clockB)
        clockA.set(step4Create + 100)
        let t3 = try await apiA.createTask(CreateTaskInput(
            projectId: travelProject.id,
            title: "跨時區會議",
            start: "2026-11-21T10:00:00+08:00",
            due: "2026-11-21T11:00:00+08:00",
            timeZone: "Asia/Taipei"
        ))
        try await syncUntilQuiet(syncA, syncB)

        let step4Edit = try await maxClockFloor(dbA, dbB, clockA, clockB)
        clockA.set(step4Edit + 100)
        var editSchedA = UpdateTaskInput(taskId: t3.id)
        editSchedA.start = .set("2026-11-22T14:00:00+08:00")
        editSchedA.due = .set("2026-11-22T15:30:00+08:00")
        _ = try await apiA.updateTask(editSchedA)

        clockB.set(step4Edit + 200)
        var editTzB = UpdateTaskInput(taskId: t3.id)
        editTzB.timeZone = "America/New_York"
        _ = try await apiB.updateTask(editTzB)

        // Sync A first, then B (B's newer schedule group wins intact).
        _ = try await syncA.syncNow()
        _ = try await syncB.syncNow()
        _ = try await syncA.syncNow()

        let t3RecA = try await dbA.writer.read { db in try TaskRecord.fetchOne(db, key: t3.id)! }
        let t3RecB = try await dbB.writer.read { db in try TaskRecord.fetchOne(db, key: t3.id)! }
        #expect(t3RecA.startDay == "2026-11-21")
        #expect(t3RecA.timeZone == "America/New_York")
        #expect(t3RecA == t3RecB)

        // 5. Soft delete vs edit.
        let step5Create = try await maxClockFloor(dbA, dbB, clockA, clockB)
        clockA.set(step5Create + 100)
        let t4 = try await apiA.createTask(CreateTaskInput(projectId: inboxA.id, title: "草稿任務"))
        try await syncUntilQuiet(syncA, syncB)

        let step5Edit = try await maxClockFloor(dbA, dbB, clockA, clockB)
        clockA.set(step5Edit + 100)
        try await apiA.deleteTask(id: t4.id)

        clockB.set(step5Edit + 200)
        var editT4B = UpdateTaskInput(taskId: t4.id)
        editT4B.title = "已刪除但標題最新"
        _ = try await apiB.updateTask(editT4B)

        try await syncUntilQuiet(syncA, syncB)

        let t4A = try await apiA.getTask(id: t4.id)
        let t4B = try await apiB.getTask(id: t4.id)
        #expect(t4A.deletedAt != nil)
        #expect(t4A.title == "已刪除但標題最新")
        #expect(t4A == t4B)

        // 6. purgeTask vs offline edit.
        let step6Create = try await maxClockFloor(dbA, dbB, clockA, clockB)
        clockA.set(step6Create + 100)
        let t5 = try await apiA.createTask(CreateTaskInput(projectId: inboxA.id, title: "即將永久刪除", subtasks: ["子項目"]))
        try await syncUntilQuiet(syncA, syncB)

        let step6Edit = try await maxClockFloor(dbA, dbB, clockA, clockB)
        clockA.set(step6Edit + 100)
        var editT5A = UpdateTaskInput(taskId: t5.id)
        editT5A.title = "離線修改但已被清掉"
        _ = try await apiA.updateTask(editT5A)

        clockB.set(step6Edit + 200)
        try await apiB.purgeTask(id: t5.id)

        _ = try await syncB.syncNow()
        _ = try await syncA.syncNow()

        // 7. Offline edits: move task, checklist toggle, tag update, attachment upload, soft delete project.
        let step7Base = try await maxClockFloor(dbA, dbB, clockA, clockB)
        clockA.set(step7Base + 100)
        _ = try await apiA.moveTask(id: t1.id, toProjectId: groceryProject.id)
        _ = try await apiA.updateTag(name: "旅行", label: "旅行", color: "#4AA8E8")
        _ = try await apiA.uploadAttachment(
            taskId: t1.id,
            fileName: "ticket.txt",
            data: Data("flight-123".utf8),
            mimeType: "text/plain",
            originalPath: "/tmp/ticket.txt"
        )

        clockB.set(step7Base + 200)
        _ = try await apiB.updateChecklistItem(id: t1.items[0].id, title: "比價（完成）", done: true)
        try await apiB.deleteProject(id: shoppingB.id)

        // Sync both until quiet.
        try await syncUntilQuiet(syncA, syncB)
        let quietA = try await syncA.syncNow()
        let quietB = try await syncB.syncNow()
        #expect(quietA.pushedCount == 0 && quietA.pulledCount == 0)
        #expect(quietB.pushedCount == 0 && quietB.pulledCount == 0)

        // Verify zero unacked changes and zero staged rows on both devices.
        for db in [dbA, dbB] {
            let (unacked, staged) = try await db.writer.read { db in
                (
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change WHERE ackedAt IS NULL") ?? -1,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging") ?? -1
                )
            }
            #expect(unacked == 0)
            #expect(staged == 0)
        }

        // Compare both local DBs and server rows across all synced fields.
        let snapA = try await snapshot(of: dbA)
        let snapB = try await snapshot(of: dbB)
        #expect(snapA == snapB)

        let serverSnap = try await fetchServerSnapshot(transport: transport, accessToken: try #require(tokensA.accessToken))
        #expect(snapA == serverSnap)
    }
}

private func loginWithGoogle(
    transport: HTTPSyncTransport,
    idToken: String,
    deviceId: String,
    tokenStore: InMemorySyncTokenStore
) async throws -> AuthLoginResponse {
    let body = try Outbox.encoder.encode(AuthGoogleRequest(idToken: idToken, deviceId: deviceId))
    let res = try await transport.send(
        method: "POST",
        path: "/auth/google",
        headers: ["Content-Type": "application/json"],
        body: body
    )
    #expect(res.status == 200)
    let decoded = try JSONDecoder().decode(AuthLoginResponse.self, from: res.body)
    tokenStore.refreshToken = decoded.refreshToken
    tokenStore.accessToken = decoded.accessToken
    return decoded
}

private func syncUntilQuiet(_ syncA: SyncEngine, _ syncB: SyncEngine, maxRounds: Int = 8) async throws {
    for _ in 0..<maxRounds {
        let a = try await syncA.syncNow()
        let b = try await syncB.syncNow()
        if a.pushedCount == 0 && a.pulledCount == 0 && b.pushedCount == 0 && b.pulledCount == 0 {
            return
        }
    }
    Issue.record("Did not reach quiet convergence within \(maxRounds) rounds")
}

private func snapshot(of database: AppDatabase) async throws -> DatabaseSnapshot {
    try await database.writer.read { db in
        let members = try MemberRecord.order(Column("id")).fetchAll(db)
        let folders = try FolderRecord.order(Column("id")).fetchAll(db)
        let projects = try ProjectRecord.order(Column("id")).fetchAll(db)
        let projectMembers = try ProjectMemberRecord.order(Column("projectId"), Column("memberId")).fetchAll(db)
        let projectInvites = try ProjectInviteRecord.order(Column("id")).fetchAll(db)
        let tasks = try TaskRecord.order(Column("id")).fetchAll(db)
        let checklistItems = try ChecklistItemRecord.order(Column("id")).fetchAll(db)
        let tags = try TagRecord.order(Column("name")).fetchAll(db)
        let attachments = try AttachmentRecord.order(Column("id")).fetchAll(db).map {
            DatabaseSnapshot.SyncedAttachment(
                id: $0.id,
                taskId: $0.taskId,
                fileName: $0.fileName,
                size: $0.size,
                mimeType: $0.mimeType,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                deletedAt: $0.deletedAt
            )
        }
        let comments = try CommentRecord.order(Column("id")).fetchAll(db)
        let purgedRows = try Row.fetchAll(db, sql: "SELECT entity, id FROM purgedId")
        let purgedKeys = Set(purgedRows.map {
            DatabaseSnapshot.PurgedKey(entity: $0["entity"], id: $0["id"])
        })
        return DatabaseSnapshot(
            members: members,
            folders: folders,
            projects: projects,
            projectMembers: projectMembers,
            projectInvites: projectInvites,
            tasks: tasks,
            checklistItems: checklistItems,
            tags: tags,
            attachments: attachments,
            comments: comments,
            purgedKeys: purgedKeys
        )
    }
}

private func fetchServerSnapshot(transport: HTTPSyncTransport, accessToken: String) async throws -> DatabaseSnapshot {
    let memDB = try AppDatabase.inMemory()
    let encoder = Outbox.encoder
    let decoder = JSONDecoder()

    var cursors: [String: Int64] = [:]
    var latestRows: [String: (entity: String, entityId: String, row: [String: SyncJSONValue])] = [:]

    while true {
        let reqData = try encoder.encode(SyncPullRequest(cursors: cursors, limit: 1000))
        let res = try await transport.send(
            method: "POST",
            path: "/sync/pull",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
            ],
            body: reqData
        )
        #expect(res.status == 200)
        let pulled = try decoder.decode(SyncPullResponse.self, from: res.body)
        for slice in pulled.scopes {
            cursors[slice.scope] = max(cursors[slice.scope] ?? 0, slice.cursor)
            for item in slice.rows {
                if item.gone == true { continue }
                guard let row = item.row,
                      let eid = SyncApplier.entityId(for: item.entity, row: row) else { continue }
                latestRows["\(item.entity):\(eid)"] = (item.entity, eid, row)
            }
        }
        if !pulled.scopes.contains(where: { $0.hasMore }) {
            break
        }
    }

    // Apply all server rows into a fresh in-memory DB in parent-first order to produce the exact same Snapshot shape.
    let order = ["member", "folder", "project", "projectMember", "projectInvite", "task", "checklistItem", "tag", "attachment", "comment"]
    let sorted = latestRows.values.sorted {
        (order.firstIndex(of: $0.entity) ?? 99) < (order.firstIndex(of: $1.entity) ?? 99)
    }
    try await memDB.writer.write { db in
        for entry in sorted {
            _ = try SyncApplier.applyRow(entity: entry.entity, entityId: entry.entityId, row: entry.row, clocks: [:], in: db)
        }
    }
    return try await snapshot(of: memDB)
}

private func maxClockFloor(
    _ dbA: AppDatabase,
    _ dbB: AppDatabase,
    _ clockA: MutableClock,
    _ clockB: MutableClock
) async throws -> Int64 {
    let lastA = try await dbA.writer.read { db in try HLC.loadLast(in: db)?.ms ?? 0 }
    let lastB = try await dbB.writer.read { db in try HLC.loadLast(in: db)?.ms ?? 0 }
    return max(Date().epochMillis, max(lastA, lastB), max(clockA.now().epochMillis, clockB.now().epochMillis))
}
