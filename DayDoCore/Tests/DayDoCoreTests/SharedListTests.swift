import Foundation
import GRDB
import Testing
@testable import DayDoCore

private let sharedBaseURL = ProcessInfo.processInfo.environment["DAYDO_SYNC_BASE_URL"]
private let sharedTokenA = ProcessInfo.processInfo.environment["DAYDO_SYNC_SHARED_USER_A_GOOGLE_ID_TOKEN"]
private let sharedTokenB = ProcessInfo.processInfo.environment["DAYDO_SYNC_SHARED_USER_B_GOOGLE_ID_TOKEN"]

@Suite struct SharedListTests {
    @Test(
        .enabled(
            if: sharedBaseURL != nil && sharedTokenA != nil && sharedTokenB != nil,
            "Requires DAYDO_SYNC_BASE_URL, DAYDO_SYNC_SHARED_USER_A_GOOGLE_ID_TOKEN, and DAYDO_SYNC_SHARED_USER_B_GOOGLE_ID_TOKEN"
        )
    )
    func sharedListEndToEndLifecycle() async throws {
        let baseURL = try #require(sharedBaseURL.flatMap(URL.init(string:)))
        let tokenA = try #require(sharedTokenA)
        let tokenB = try #require(sharedTokenB)

        let transport = HTTPSyncTransport(baseURL: baseURL)

        let baseMs = Date().epochMillis
        let clockA = MutableClock(startMs: baseMs)
        let clockB = MutableClock(startMs: baseMs + 100)

        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-shared-a-\(UUID().uuidString)")
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-shared-b-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let dbA = try AppDatabase.inMemory()
        let apiA = LocalDayDoAPI(database: dbA, clock: clockA.clock, attachmentsDirectory: dirA)
        let tokensA = InMemorySyncTokenStore()
        let syncA = SyncEngine(database: dbA, transport: transport, tokenStore: tokensA, clock: clockA.clock)

        let dbB = try AppDatabase.inMemory()
        let apiB = LocalDayDoAPI(database: dbB, clock: clockB.clock, attachmentsDirectory: dirB)
        let tokensB = InMemorySyncTokenStore()
        let syncB = SyncEngine(database: dbB, transport: transport, tokenStore: tokensB, clock: clockB.clock)

        // 1. A signs in, creates a list with tasks & a checklist, syncs, and creates an editor invite.
        _ = try await syncA.signIn(with: .google(idToken: tokenA))
        clockA.set(Date().epochMillis)
        let sharedList = try await apiA.createProject(CreateProjectInput(name: "家庭採買", color: "#4CAF50"))
        #expect(sharedList.myRole == "owner")
        let milkTask = try await apiA.createTask(CreateTaskInput(
            projectId: sharedList.id,
            title: "買牛奶",
            subtasks: ["全脂鮮奶", "無糖豆漿"]
        ))
        let breadTask = try await apiA.createTask(CreateTaskInput(
            projectId: sharedList.id,
            title: "買麵包"
        ))
        _ = try await syncA.syncNow()

        let invite = try await syncA.createInvite(projectId: sharedList.id, role: "editor")
        #expect(SyncEngine.parseInviteCode(from: invite.url) == invite.code)

        // 2. B signs in on own phone, inspects & accepts the invite -> backfill pulls shared list, tasks, checklist, and A.
        _ = try await syncB.signIn(with: .google(idToken: tokenB))
        let info = try await syncB.inviteInfo(code: invite.code)
        #expect(info.projectName == "家庭採買")
        #expect(info.role == "editor")

        let accepted = try await syncB.acceptInvite(code: invite.code)
        #expect(accepted.projectId == sharedList.id)
        #expect(accepted.role == "editor")

        let bListAfterAccept = try #require(
            try await apiB.listProjects(includeArchived: false).first { $0.id == sharedList.id }
        )
        #expect(bListAfterAccept.myRole == "editor")
        #expect(bListAfterAccept.name == "家庭採買")

        let bTasksAfterAccept = try await apiB.listTasks(TaskQuery(projectId: sharedList.id))
        #expect(Set(bTasksAfterAccept.map(\.id)) == Set([milkTask.id, breadTask.id]))
        let bMilk = try #require(bTasksAfterAccept.first { $0.id == milkTask.id })
        #expect(bMilk.items.map(\.title) == ["全脂鮮奶", "無糖豆漿"])

        let meA = try #require(try await apiA.listMembers().first { $0.isMe })
        let bMembers = try await apiB.listMembers()
        let aOnB = try #require(bMembers.first { $0.id == meA.id })
        #expect(aOnB.isMe == false)
        #expect(aOnB.name == meA.name)
        let bProjMembers = try await apiB.listProjectMembers(projectId: sharedList.id)
        #expect(bProjMembers.first { $0.memberId == meA.id }?.role == "owner")
        #expect(bProjMembers.first { $0.isMe }?.role == "editor")

        // 3. B edits a task title and adds a task; A sees both.
        clockB.set(try await maxFloor(dbA, dbB, clockA, clockB) + 100)
        var editBread = UpdateTaskInput(taskId: breadTask.id)
        editBread.title = "買全麥麵包"
        _ = try await apiB.updateTask(editBread)
        let eggTask = try await apiB.createTask(CreateTaskInput(projectId: sharedList.id, title: "買雞蛋"))

        try await syncUntilQuiet(syncA, syncB)
        let aTasks = try await apiA.listTasks(TaskQuery(projectId: sharedList.id))
        #expect(aTasks.first { $0.id == breadTask.id }?.title == "買全麥麵包")
        #expect(aTasks.first { $0.id == eggTask.id }?.title == "買雞蛋")

        // Verify both DBs match what server exposes for each user while actively sharing.
        let snapA1 = try await snapshot(of: dbA)
        let srvA1 = try await fetchServerSnapshot(transport: transport, accessToken: try #require(tokensA.accessToken))
        #expect(snapA1 == srvA1)
        let snapB1 = try await snapshot(of: dbB)
        let srvB1 = try await fetchServerSnapshot(transport: transport, accessToken: try #require(tokensB.accessToken))
        #expect(snapB1 == srvB1)

        // 4. A changes B to viewer and updates the egg task; B edits offline then syncs -> rejected & reverted to A's value.
        let bOnA = try #require(try await apiA.listMembers().first { !$0.isMe })
        let userBId = try #require(bOnA.userId)
        try await syncA.changeMemberRole(projectId: sharedList.id, userId: userBId, role: "viewer")
        clockA.set(try await maxFloor(dbA, dbB, clockA, clockB) + 100)
        var editEggA = UpdateTaskInput(taskId: eggTask.id)
        editEggA.title = "買土雞蛋"
        _ = try await apiA.updateTask(editEggA)
        _ = try await syncA.syncNow()

        clockB.set(try await maxFloor(dbA, dbB, clockA, clockB) + 5_000)
        var editEggB = UpdateTaskInput(taskId: eggTask.id)
        editEggB.title = "B 離線偷改"
        _ = try await apiB.updateTask(editEggB)

        let viewerSyncSummary = try await syncB.syncNow()
        #expect(viewerSyncSummary.rejectedCount == 1)

        let bEggReverted = try #require(
            try await apiB.listTasks(TaskQuery(projectId: sharedList.id)).first { $0.id == eggTask.id }
        )
        #expect(bEggReverted.title == "買土雞蛋")
        let bListAsViewer = try #require(
            try await apiB.listProjects(includeArchived: false).first { $0.id == sharedList.id }
        )
        #expect(bListAsViewer.myRole == "viewer")

        // 5. A removes B -> B's local copy of the list is gone.
        try await syncA.removeMember(projectId: sharedList.id, userId: userBId)
        _ = try await syncB.syncNow()

        #expect(try await apiB.listProjects(includeArchived: false).contains { $0.id == sharedList.id } == false)
        let bStateAfterRemoved = try await dbB.writer.read { db in
            (
                projectCount: try ProjectRecord.filter(Column("id") == sharedList.id).fetchCount(db),
                taskCount: try TaskRecord.filter(Column("projectId") == sharedList.id).fetchCount(db),
                pmCount: try ProjectMemberRecord.filter(Column("projectId") == sharedList.id).fetchCount(db),
                membershipCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projectMembership WHERE projectId = ?", arguments: [sharedList.id]) ?? -1,
                purgedCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM purgedId") ?? -1
            )
        }
        #expect(bStateAfterRemoved.projectCount == 0)
        #expect(bStateAfterRemoved.taskCount == 0)
        #expect(bStateAfterRemoved.pmCount == 0)
        #expect(bStateAfterRemoved.membershipCount == 0)
        #expect(bStateAfterRemoved.purgedCount == 0)

        // 6. A re-invites, B accepts, then A permanently deletes the list -> gone on B.
        let reinvite = try await syncA.createInvite(projectId: sharedList.id, role: "editor")
        _ = try await syncB.acceptInvite(code: reinvite.code)
        #expect(try await apiB.listProjects(includeArchived: false).contains { $0.id == sharedList.id })

        clockA.set(try await maxFloor(dbA, dbB, clockA, clockB) + 100)
        let purgeNow = clockA.now().epochMillis
        try await dbA.writer.write { db in
            _ = try ProjectRecord.deleteOne(db, key: sharedList.id)
            let hlc = try HLC.tick(in: db, now: purgeNow)
            var del = ChangeRecord(
                seq: nil,
                entity: "project",
                entityId: sharedList.id,
                op: "delete",
                fields: [],
                row: "{}",
                at: purgeNow,
                opId: ID.make(),
                hlc: hlc.description,
                ackedAt: nil,
                result: nil
            )
            try del.insert(db)
            try PurgedId.record(entity: "project", id: sharedList.id, purgedAt: purgeNow, in: db)
        }

        _ = try await syncA.syncNow()
        _ = try await syncB.syncNow()
        try await syncUntilQuiet(syncA, syncB)

        #expect(try await apiA.listProjects(includeArchived: false).contains { $0.id == sharedList.id } == false)
        #expect(try await apiB.listProjects(includeArchived: false).contains { $0.id == sharedList.id } == false)

        // Both DBs match what the server can see for each user across all list/task/child tables.
        let snapAEnd = try await snapshot(of: dbA)
        let srvAEnd = try await fetchServerSnapshot(transport: transport, accessToken: try #require(tokensA.accessToken))
        #expect(snapAEnd.folders == srvAEnd.folders)
        #expect(snapAEnd.projects == srvAEnd.projects)
        #expect(snapAEnd.projectMembers == srvAEnd.projectMembers)
        #expect(snapAEnd.tasks == srvAEnd.tasks)
        #expect(snapAEnd.checklistItems == srvAEnd.checklistItems)
        #expect(snapAEnd.tags == srvAEnd.tags)
        #expect(snapAEnd.attachments == srvAEnd.attachments)
        #expect(snapAEnd.comments == srvAEnd.comments)

        let snapBEnd = try await snapshot(of: dbB)
        let srvBEnd = try await fetchServerSnapshot(transport: transport, accessToken: try #require(tokensB.accessToken))
        #expect(snapBEnd.folders == srvBEnd.folders)
        #expect(snapBEnd.projects == srvBEnd.projects)
        #expect(snapBEnd.projectMembers == srvBEnd.projectMembers)
        #expect(snapBEnd.tasks == srvBEnd.tasks)
        #expect(snapBEnd.checklistItems == srvBEnd.checklistItems)
        #expect(snapBEnd.tags == srvBEnd.tags)
        #expect(snapBEnd.attachments == srvBEnd.attachments)
        #expect(snapBEnd.comments == srvBEnd.comments)
        #expect(snapBEnd.purgedKeys == srvBEnd.purgedKeys)
    }
}

private func maxFloor(
    _ dbA: AppDatabase,
    _ dbB: AppDatabase,
    _ clockA: MutableClock,
    _ clockB: MutableClock
) async throws -> Int64 {
    let lastA = try await dbA.writer.read { db in try HLC.loadLast(in: db)?.ms ?? 0 }
    let lastB = try await dbB.writer.read { db in try HLC.loadLast(in: db)?.ms ?? 0 }
    return max(Date().epochMillis, max(lastA, lastB), max(clockA.now().epochMillis, clockB.now().epochMillis))
}
