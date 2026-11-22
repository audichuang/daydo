import Foundation
import GRDB
import Testing
@testable import DayDoCore

@Suite struct HLCTests {
    @Test func formatAndParseRoundTrip() {
        let hlc = HLC(ms: 1_794_715_200_000, counter: 7, deviceId: "01932A1B-0000-7000-8000-000000000001")
        #expect(hlc.description == "1794715200000:0007:01932a1b-0000-7000-8000-000000000001")
        #expect(hlc.description.count == 13 + 1 + 4 + 1 + 36)

        let parsed = HLC(hlc.description)
        #expect(parsed == hlc)

        #expect(HLC("123:0000:abc") == nil) // ms too short
        #expect(HLC("0000000000123:00:abc") == nil) // counter too short
        #expect(HLC("0000000000123:0000:") == nil) // empty deviceId
        #expect(HLC("not-an-hlc") == nil)
    }

    @Test func monotonicSameMsAndBackwardClock() {
        let dev = "01932a1b-0000-7000-8000-000000000001"
        let h0 = HLC.next(now: 1000, last: nil, deviceId: dev)
        #expect(h0 == HLC(ms: 1000, counter: 0, deviceId: dev))

        // Same ms increments counter.
        let h1 = HLC.next(now: 1000, last: h0, deviceId: dev)
        #expect(h1 == HLC(ms: 1000, counter: 1, deviceId: dev))

        // Backward wall clock keeps last.ms and increments counter.
        let h2 = HLC.next(now: 900, last: h1, deviceId: dev)
        #expect(h2 == HLC(ms: 1000, counter: 2, deviceId: dev))

        // Advancing wall clock resets counter to 0.
        let h3 = HLC.next(now: 1001, last: h2, deviceId: dev)
        #expect(h3 == HLC(ms: 1001, counter: 0, deviceId: dev))

        #expect(h0 < h1 && h1 < h2 && h2 < h3)
    }

    @Test func counterOverflowBumpsMsAndResetsCounter() {
        let dev = "dev-a"
        let atMax = HLC(ms: 5000, counter: 9999, deviceId: dev)
        let overflowed = HLC.next(now: 5000, last: atMax, deviceId: dev)
        #expect(overflowed == HLC(ms: 5001, counter: 0, deviceId: dev))
        #expect(atMax < overflowed)
        #expect(atMax.description < overflowed.description)
    }

    @Test func receiveFutureRemoteAdvancesLocalClock() {
        let localDev = "dev-a"
        let remoteDev = "dev-z"
        let local = HLC(ms: 1000, counter: 2, deviceId: localDev)

        // Future remote advances past remote.
        let futureRemote = HLC(ms: 2000, counter: 5, deviceId: remoteDev)
        let afterFuture = HLC.receive(remote: futureRemote, now: 1000, last: local, deviceId: localDev)
        #expect(afterFuture == HLC(ms: 2000, counter: 6, deviceId: localDev))
        #expect(afterFuture > futureRemote)
        #expect(afterFuture > local)

        // Overflow on remote counter == 9999 bumps ms.
        let maxRemote = HLC(ms: 2000, counter: 9999, deviceId: remoteDev)
        let afterMax = HLC.receive(remote: maxRemote, now: 1000, last: local, deviceId: localDev)
        #expect(afterMax == HLC(ms: 2001, counter: 0, deviceId: localDev))
        #expect(afterMax > maxRemote)

        // Same ms & counter with higher remote deviceId still advances.
        let tieRemote = HLC(ms: 1000, counter: 2, deviceId: remoteDev)
        let afterTie = HLC.receive(remote: tieRemote, now: 1000, last: local, deviceId: localDev)
        #expect(afterTie == HLC(ms: 1000, counter: 3, deviceId: localDev))
        #expect(afterTie > tieRemote)

        // Older remote leaves local untouched when wall clock <= local.ms.
        let olderRemote = HLC(ms: 900, counter: 50, deviceId: remoteDev)
        let afterOlder = HLC.receive(remote: olderRemote, now: 1000, last: local, deviceId: localDev)
        #expect(afterOlder == local)
    }

    @Test func stringOrderingMatchesCausalOrdering() {
        let a = HLC(ms: 999, counter: 9999, deviceId: "zzz")
        let b = HLC(ms: 1000, counter: 0, deviceId: "aaa")
        let c = HLC(ms: 1000, counter: 1, deviceId: "aaa")
        let d = HLC(ms: 1000, counter: 1, deviceId: "bbb")
        let ordered = [a, b, c, d]
        #expect(ordered == ordered.sorted())
        #expect(ordered.map(\.description) == ordered.map(\.description).sorted())
    }

    @Test func metaStatePersistsInSameTransaction() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            let first = try HLC.tick(in: db, now: 1000)
            let second = try HLC.tick(in: db, now: 1000)
            #expect(first.counter == 0)
            #expect(second.counter == 1)
            #expect(first.deviceId == second.deviceId)
            #expect(try HLC.loadLast(in: db) == second)
        }
    }
}

@Suite struct MigrationV2Tests {
    @Test func migratesV1ChangesBackfillingOpIdAndMonotonicHLC() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        // Build a v1-only database.
        try AppDatabase.migrator.migrate(queue, upTo: "v1")

        // Insert v1 change rows with repeated and decreasing `at` timestamps.
        let timestamps: [EpochMillis] = [1000, 1000, 900, 1000, 1005, 1005, 800]
        try queue.write { db in
            for (i, at) in timestamps.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO change (entity, entityId, op, fields, row, at)
                    VALUES ('task', ?, 'upsert', '["id"]', '{"id":"t"}', ?)
                    """,
                    arguments: ["task-\(i)", at]
                )
            }
        }

        // Migrate to v2 via AppDatabase.
        let appDB = try AppDatabase(queue)

        try appDB.writer.read { db in
            let rows = try ChangeRecord.order(Column("seq")).fetchAll(db)
            #expect(rows.count == timestamps.count)

            let opIds = rows.compactMap(\.opId)
            #expect(opIds.count == timestamps.count)
            #expect(Set(opIds).count == timestamps.count)
            for opId in opIds {
                #expect(opId == opId.lowercased())
                #expect(UUID(uuidString: opId) != nil)
            }

            let hlcs = rows.compactMap(\.hlc)
            #expect(hlcs.count == timestamps.count)
            for pair in zip(hlcs, hlcs.dropFirst()) {
                #expect(pair.0 < pair.1)
            }
            #expect(hlcs == hlcs.sorted())
            #expect(rows.allSatisfy { $0.ackedAt == nil && $0.result == nil })

            let deviceId = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'deviceId'")
            #expect(deviceId != nil)
            #expect(deviceId == deviceId?.lowercased())

            let lastMetaHLC = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'hlc'")
            #expect(lastMetaHLC == hlcs.last)
        }
    }

    @Test func migratesEmptyV1DatabaseCreatingDeviceId() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        let appDB = try AppDatabase(queue)
        try appDB.writer.read { db in
            let deviceId = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'deviceId'")
            #expect(deviceId != nil)
            #expect(deviceId == deviceId?.lowercased())
        }
    }

    @Test func migratesV3DatabaseCreatingPurgedIdTable() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3")
        let hadTableBefore = try queue.read { db in
            try db.tableExists("purgedId")
        }
        #expect(!hadTableBefore)

        let appDB = try AppDatabase(queue)
        try appDB.writer.write { db in
            #expect(try db.tableExists("purgedId"))
            let columns = try db.columns(in: "purgedId").map(\.name)
            #expect(columns == ["entity", "id", "purgedAt"])
            try PurgedId.record(entity: "task", id: "abc", purgedAt: 1000, in: db)
            try PurgedId.record(entity: "task", id: "abc", purgedAt: 2000, in: db)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM purgedId")
            #expect(count == 1)
            let changeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change")
            #expect(changeCount == 0)
        }
    }

    @Test func migratesV3DatabaseBackfillingPurgedIdAndAvoidingReusedCloneId() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue, upTo: "v3")

        let now = noon.epochMillis
        let purgeAt: EpochMillis = now - 5_000
        let me = MemberRecord(
            id: ID.make(), name: "我", initial: "我", color: "#9BB8FF", isMe: true,
            createdAt: now, updatedAt: now
        )
        let inbox = ProjectRecord(
            id: ID.make(), name: "收件匣", color: nil, icon: "inbox", folderId: nil,
            viewMode: "list", kind: "TASK", isInbox: true, ownerId: me.id, sortKey: "a0",
            showInSmart: "all", notifyMode: "all", archivedAt: nil,
            createdAt: now, updatedAt: now
        )
        let masterId = ID.make()
        let purgedCloneId = ID.v5(name: "\(masterId)|2026-11-15|540")

        try await queue.write { db in
            try me.insert(db)
            try inbox.insert(db)
            try db.execute(
                sql: """
                    INSERT INTO task (id, projectId, title, content, priority, status, startDay, startMinute, endDay, endMinute, timeZone, reminders, repeatRule, tags, assigneeId, sortKey, completedAt, sourceRaw, importNote, createdAt, updatedAt, deletedAt)
                    VALUES (?, ?, '吃藥', '', 0, 0, '2026-11-15', 540, NULL, NULL, 'Asia/Taipei', '[]', 'RRULE:FREQ=DAILY', '[]', NULL, 'a0', NULL, NULL, NULL, ?, ?, NULL)
                    """,
                arguments: [masterId, inbox.id, now, now]
            )
            var deleteChange = ChangeRecord(
                seq: nil, entity: "task", entityId: purgedCloneId,
                op: "delete", fields: [], row: "{}", at: purgeAt,
                opId: ID.make(), hlc: HLC(ms: purgeAt, counter: 0, deviceId: "dev-v3").description,
                ackedAt: purgeAt + 100, result: "applied"
            )
            try deleteChange.insert(db)
        }
        let changeCountBefore = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change") ?? 0
        }

        let appDB = try AppDatabase(queue)

        let (containsPurgedId, purgedAt, changeCountAfter) = try await appDB.writer.read { db in
            let contains = try PurgedId.contains(entity: "task", id: purgedCloneId, in: db)
            let at = try EpochMillis.fetchOne(
                db,
                sql: "SELECT purgedAt FROM purgedId WHERE entity = 'task' AND id = ?",
                arguments: [purgedCloneId]
            )
            let changes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change") ?? 0
            return (contains, at, changes)
        }
        #expect(containsPurgedId)
        #expect(purgedAt == purgeAt)
        #expect(changeCountAfter == changeCountBefore)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-tests-\(UUID().uuidString)")
        let api = LocalDayDoAPI(database: appDB, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
        let done = try await api.completeTask(id: masterId)
        #expect(done.id != purgedCloneId)
        #expect(done.status == 2)
    }
}

@Suite struct SyncFoundationOutboxTests {
    @Test func everyOutboxWriteHasOpIdAndIncreasingHLCAndPendingFiltersAcked() async throws {
        let api = try await makeAPI()
        let task = try await api.createTask(CreateTaskInput(title: "Sync task"))
        try await api.deleteTask(id: task.id)
        try await api.purgeTask(id: task.id)

        let changes = try await api.pendingChanges()
        #expect(!changes.isEmpty)
        for c in changes {
            #expect(c.opId != nil)
            #expect(c.opId == c.opId?.lowercased())
            #expect(c.hlc != nil)
            #expect(HLC(c.hlc!) != nil)
            #expect(c.ackedAt == nil)
            #expect(c.result == nil)
        }
        let hlcs = changes.compactMap(\.hlc)
        for pair in zip(hlcs, hlcs.dropFirst()) {
            #expect(pair.0 < pair.1)
        }
        #expect(changes.last?.op == "delete")
        #expect(changes.last?.entity == "task")
        #expect(changes.last?.entityId == task.id)

        // Marking the first change acked hides it from pendingChanges(limit:).
        let ackedSeq = try #require(changes.first?.seq)
        try await api.database.writer.write { db in
            try db.execute(
                sql: "UPDATE change SET ackedAt = ?, result = 'applied' WHERE seq = ?",
                arguments: [noon.epochMillis, ackedSeq]
            )
        }
        let remaining = try await api.pendingChanges()
        #expect(remaining.count == changes.count - 1)
        #expect(!remaining.contains { $0.seq == ackedSeq })
        #expect(remaining.map(\.seq) == remaining.compactMap(\.seq).sorted())
    }

    @Test func doubleCompleteOfRecurringOccurrenceYieldsSingleDeterministicClone() async throws {
        let api = try await makeAPI()
        let t = try await api.createTask(CreateTaskInput(
            title: "吃藥",
            start: "2026-11-15T09:00:00+0800",
            timeZone: "Asia/Taipei",
            repeat: "RRULE:FREQ=DAILY",
            subtasks: ["維他命"]
        ))
        let expectedCloneId = ID.v5(name: "\(t.id)|2026-11-15|540")
        let expectedItemCopyId = ID.v5(name: "\(expectedCloneId)|\(t.items[0].id)")

        let done1 = try await api.completeTask(id: t.id)
        #expect(done1.id == expectedCloneId)
        #expect(done1.id == done1.id.lowercased())
        #expect(done1.items.map(\.id) == [expectedItemCopyId])

        // Simulate a second offline device completing the same occurrence by
        // resetting the recurring task's schedule and status back to 2026-11-15.
        try await api.database.writer.write { db in
            try db.execute(
                sql: "UPDATE task SET status = 0, startDay = '2026-11-15', startMinute = 540 WHERE id = ?",
                arguments: [t.id]
            )
        }
        let done2 = try await api.completeTask(id: t.id)
        #expect(done2.id == expectedCloneId)

        let (taskCount, itemCount) = try await api.database.writer.read { db in
            let tc = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE id = ?", arguments: [expectedCloneId]) ?? 0
            let ic = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM checklistItem WHERE id = ?", arguments: [expectedItemCopyId]) ?? 0
            return (tc, ic)
        }
        #expect(taskCount == 1)
        #expect(itemCount == 1)

        // All-day recurring task uses empty string after the second '|'.
        let allDay = try await api.createTask(CreateTaskInput(
            title: "全天重複",
            start: "2026-11-15",
            repeat: "RRULE:FREQ=DAILY"
        ))
        let expectedAllDayCloneId = ID.v5(name: "\(allDay.id)|2026-11-15|")
        let allDayDone = try await api.completeTask(id: allDay.id)
        #expect(allDayDone.id == expectedAllDayCloneId)
    }

    @Test func completingAfterPurgingCloneUsesFreshIdAndNeverRewritesPurgedId() async throws {
        let api = try await makeAPI()
        let t = try await api.createTask(CreateTaskInput(
            title: "吃藥",
            start: "2026-11-15T09:00:00+0800",
            timeZone: "Asia/Taipei",
            repeat: "RRULE:FREQ=DAILY",
            subtasks: ["維他命"]
        ))
        let expectedDeterministicId = ID.v5(name: "\(t.id)|2026-11-15|540")

        let done1 = try await api.completeTask(id: t.id)
        #expect(done1.id == expectedDeterministicId)

        try await api.purgeTask(id: done1.id)
        let seqAfterPurge = try #require(try await api.pendingChanges(limit: 500).last?.seq)

        let purgedAt = try await api.database.writer.read { db in
            try EpochMillis.fetchOne(db, sql: "SELECT purgedAt FROM purgedId WHERE entity = 'task' AND id = ?", arguments: [done1.id])
        }
        #expect(purgedAt == noon.epochMillis)

        // Move master back to the same slot and complete again.
        var moveBack = UpdateTaskInput(taskId: t.id)
        moveBack.start = .set("2026-11-15T09:00:00+0800")
        moveBack.timeZone = "Asia/Taipei"
        _ = try await api.updateTask(moveBack)

        let done2 = try await api.completeTask(id: t.id)
        #expect(done2.id != done1.id)
        #expect(done2.id == done2.id.lowercased())
        #expect(UUID(uuidString: done2.id) != nil)
        #expect(done2.status == 2)
        #expect(done2.items.map(\.id) == [ID.v5(name: "\(done2.id)|\(t.items[0].id)")])

        let allChanges = try await api.pendingChanges(limit: 500)
        #expect(!allChanges.contains { $0.entity == "purgedId" })
        let changesAfterPurge = allChanges.filter { ($0.seq ?? 0) > seqAfterPurge }
        #expect(!changesAfterPurge.contains { $0.entityId == done1.id })
        #expect(changesAfterPurge.contains { $0.entity == "task" && $0.entityId == done2.id && $0.op == "upsert" })
    }

    @Test func completingAfterUncompletingAndEditingClonePreservesCloneEdits() async throws {
        let api = try await makeAPI()
        let t = try await api.createTask(CreateTaskInput(
            title: "吃藥",
            start: "2026-11-15T09:00:00+0800",
            timeZone: "Asia/Taipei",
            repeat: "RRULE:FREQ=DAILY",
            subtasks: ["維他命"]
        ))
        let done1 = try await api.completeTask(id: t.id)

        _ = try await api.uncompleteTask(id: done1.id)
        var editClone = UpdateTaskInput(taskId: done1.id)
        editClone.title = "吃維他命（已改）"
        _ = try await api.updateTask(editClone)

        // Move master back to the same slot and complete again.
        var moveBack = UpdateTaskInput(taskId: t.id)
        moveBack.start = .set("2026-11-15T09:00:00+0800")
        moveBack.timeZone = "Asia/Taipei"
        _ = try await api.updateTask(moveBack)

        let done2 = try await api.completeTask(id: t.id)
        #expect(done2.id == done1.id)
        #expect(done2.title == "吃維他命（已改）")
        #expect(done2.status == 2)
        #expect(done2.completedAt != nil)

        let cloneCount = try await api.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE id != ? AND deletedAt IS NULL", arguments: [t.id]) ?? 0
        }
        #expect(cloneCount == 1)
    }

    @Test func recordingServerTombstoneAvoidsPurgedDeterministicCloneIdWithoutOutbox() async throws {
        let api = try await makeAPI()
        let t = try await api.createTask(CreateTaskInput(
            title: "伺服端已清掉的重複實例",
            start: "2026-11-15T09:00:00+0800",
            timeZone: "Asia/Taipei",
            repeat: "RRULE:FREQ=DAILY"
        ))
        let deterministicId = ID.v5(name: "\(t.id)|2026-11-15|540")
        let changeCountBefore = try await api.pendingChanges(limit: 500).count

        try await api.database.writer.write { db in
            try PurgedId.record(entity: "task", id: deterministicId, purgedAt: noon.epochMillis, in: db)
        }
        let changeCountAfter = try await api.pendingChanges(limit: 500).count
        #expect(changeCountAfter == changeCountBefore)

        let done = try await api.completeTask(id: t.id)
        #expect(done.id != deterministicId)
        #expect(done.status == 2)
    }

    @Test func completingRecurringTaskWithFutureUpdatedAtUsesWallClockForHLCAndChangeAt() async throws {
        let api = try await makeAPI()
        let wallNow = noon.epochMillis
        let t = try await api.createTask(CreateTaskInput(
            title: "未來時間戳重複任務",
            start: "2026-11-15",
            repeat: "RRULE:FREQ=DAILY"
        ))

        let futureUpdatedAt = wallNow + 30 * 86_400_000
        try await api.database.writer.write { db in
            try db.execute(
                sql: "UPDATE task SET updatedAt = ? WHERE id = ?",
                arguments: [futureUpdatedAt, t.id]
            )
        }
        let seqBefore = (try await api.pendingChanges(limit: 500).last?.seq) ?? 0

        _ = try await api.completeTask(id: t.id)

        let newChanges = try await api.pendingChanges(limit: 500).filter { ($0.seq ?? 0) > seqBefore }
        let parentChange = try #require(newChanges.first { $0.entity == "task" && $0.entityId == t.id })
        let parentHLC = try #require(parentChange.hlc.flatMap(HLC.init))
        #expect(parentChange.at == wallNow)
        #expect(parentHLC.ms == wallNow)
        for change in newChanges {
            #expect(change.at == wallNow)
            let hlc = try #require(change.hlc.flatMap(HLC.init))
            #expect(hlc.ms == wallNow)
        }

        let updatedTask = try await api.getTask(id: t.id)
        #expect(updatedTask.updatedAt == futureUpdatedAt + 1)

        let lastMetaHLC = try await api.database.writer.read { db in
            try HLC.loadLast(in: db)
        }
        #expect(lastMetaHLC?.ms == wallNow)
    }

    @Test func generateSyncOpsFixture() async throws {
        let api = try await makeAPI()

        // 1. Bootstrap creates member, inbox/default lists, and projectMember rows.
        // (makeAPI already calls bootstrap())

        // 2. Create project and invite a collaborator.
        let project = try await api.createProject(CreateProjectInput(name: "旅行計畫", color: "#4AA8E8"))
        _ = try await api.inviteMember(projectId: project.id, email: "family@example.com", role: "editor")

        // 3. Create task with schedule, timezone, reminders, repeat, subtasks, and tag.
        let recurring = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "每週讀書會",
            content: "帶筆記本",
            priority: .medium,
            start: "2026-11-15T19:00:00+0800",
            due: "2026-11-15T20:30:00+0800",
            timeZone: "Asia/Taipei",
            reminder: "TRIGGER:-PT15M",
            repeat: "RRULE:FREQ=WEEKLY",
            subtasks: ["準備章節摘要"],
            tags: ["讀書"],
            countdown: true
        ))

        // 4. Add a tag explicitly.
        _ = try await api.createTag(label: "重要", color: "#E98A5B")

        // 5. Create another task, then update fields to nil (clear repeatRule and schedule).
        let toClear = try await api.createTask(CreateTaskInput(
            projectId: project.id,
            title: "待定行程",
            start: "2026-11-16T10:00:00+0800",
            timeZone: "Asia/Taipei",
            repeat: "RRULE:FREQ=DAILY"
        ))
        var clearRepeat = UpdateTaskInput(taskId: toClear.id)
        clearRepeat.repeat = .clear
        _ = try await api.updateTask(clearRepeat)

        var clearSchedule = UpdateTaskInput(taskId: toClear.id)
        clearSchedule.start = .clear
        _ = try await api.updateTask(clearSchedule)

        // 6. Complete the recurring task.
        _ = try await api.completeTask(id: recurring.id)

        // 7. Soft delete and purge a task.
        try await api.deleteTask(id: toClear.id)
        try await api.purgeTask(id: toClear.id)

        let changes = try await api.pendingChanges(limit: 500)
        let decoder = JSONDecoder()
        let ops = try changes.map { c -> FixtureOp in
            let row = try decoder.decode(JSONValue.self, from: Data(c.row.utf8))
            return FixtureOp(
                opId: try #require(c.opId),
                hlc: try #require(c.hlc),
                entity: c.entity,
                entityId: c.entityId,
                op: c.op,
                fields: c.fields,
                row: row
            )
        }

        // Verify representative coverage in the generated ops.
        let entities = Set(ops.map(\.entity))
        #expect(entities.contains("member"))
        #expect(entities.contains("project"))
        #expect(entities.contains("projectMember"))
        #expect(entities.contains("projectInvite"))
        #expect(entities.contains("task"))
        #expect(entities.contains("checklistItem"))
        #expect(entities.contains("tag"))

        // Verify cleared-to-nil semantics: field present in `fields`, absent from `row`.
        let clearedRepeatOp = try #require(ops.first { $0.entity == "task" && $0.entityId == toClear.id && $0.fields.contains("repeatRule") && $0.op == "upsert" && !$0.fields.contains("id") })
        if case let .object(rowObj) = clearedRepeatOp.row {
            #expect(rowObj["repeatRule"] == nil)
        } else {
            Issue.record("Expected row to be a JSON object")
        }

        // Verify purgeTask delete op.
        let deleteOp = try #require(ops.last)
        #expect(deleteOp.op == "delete")
        #expect(deleteOp.fields.isEmpty)
        #expect(deleteOp.row == .object([:]))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(FixtureFile(ops: ops))
        data.append(contentsOf: "\n".utf8)

        if ProcessInfo.processInfo.environment["DAYDO_WRITE_FIXTURE"] == "1" {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let fixtureURL = repoRoot.appendingPathComponent("spec/fixtures/sync-ops.json")
            try FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fixtureURL, options: .atomic)
        }
    }
}

@Suite struct SyncApplierSchemaGuardTests {
    /// Guards against adding a column to a synced table in a migration without
    /// adding a matching `SyncApplier.FieldSpec` (missing fields are silently
    /// dropped when applying pulled rows).
    @Test func syncApplierSpecsMatchDatabaseColumns() throws {
        // Columns intentionally omitted from `SyncApplier.specs` because they are
        // device-local bookkeeping (excluded from outbox `CodingKeys` and preserved
        // manually in `SyncApplier.saveMergedDict`).
        let intentionallyUnsyncedColumns: [String: Set<String>] = [
            "attachment": [
                // Local-only attachment blob upload state; never synced over the wire.
                "fileUploadedAt",
                "fileUploadFailed",
            ],
        ]

        let appDB = try AppDatabase.inMemory()
        let specFieldsByEntity = SyncApplier.specFieldNamesByEntity
        #expect(!specFieldsByEntity.isEmpty)
        #expect(
            Set(intentionallyUnsyncedColumns.keys).isSubset(of: Set(specFieldsByEntity.keys)),
            "Allow-list references unknown synced entity"
        )

        // Mirrors `ENTITY_NAMES` in `server/src/sync/entities.ts`.
        let expectedEntities: Set<String> = [
            "member",
            "folder",
            "project",
            "projectMember",
            "projectInvite",
            "task",
            "checklistItem",
            "tag",
            "attachment",
            "comment",
        ]
        let actualEntities = Set(specFieldsByEntity.keys)
        let missingEntities = expectedEntities.subtracting(actualEntities).sorted()
        let extraEntities = actualEntities.subtracting(expectedEntities).sorted()
        #expect(
            actualEntities == expectedEntities,
            "SyncApplier.specs entity mismatch: missing=\(missingEntities), extra=\(extraEntities)"
        )

        try appDB.writer.read { db in
            for (entity, specFieldList) in specFieldsByEntity.sorted(by: { $0.key < $1.key }) {
                let specFields = Set(specFieldList)
                #expect(specFields.count == specFieldList.count, "Duplicate FieldSpec entries for \(entity)")

                let tableColumns = Set(try db.columns(in: entity).map(\.name))
                let allowedUnsynced = intentionallyUnsyncedColumns[entity] ?? []

                #expect(
                    allowedUnsynced.isSubset(of: tableColumns),
                    "Stale allow-listed unsynced columns for \(entity): \(allowedUnsynced.subtracting(tableColumns).sorted())"
                )
                #expect(
                    specFields.isDisjoint(with: allowedUnsynced),
                    "Columns listed in both SyncApplier.specs and unsynced allow-list for \(entity): \(specFields.intersection(allowedUnsynced).sorted())"
                )

                let expectedSpecFields = tableColumns.subtracting(allowedUnsynced)
                let missingFromSpec = expectedSpecFields.subtracting(specFields).sorted()
                let extraInSpec = specFields.subtracting(expectedSpecFields).sorted()
                #expect(
                    specFields == expectedSpecFields,
                    "SyncApplier.specs mismatch for \(entity): missing=\(missingFromSpec), extra=\(extraInSpec)"
                )
            }
        }
    }
}

private struct FixtureFile: Encodable {
    let ops: [FixtureOp]
}

private struct FixtureOp: Encodable {
    let opId: String
    let hlc: String
    let entity: String
    let entityId: String
    let op: String
    let fields: [String]
    let row: JSONValue
}

private enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}
