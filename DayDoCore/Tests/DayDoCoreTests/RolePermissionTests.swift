import Foundation
import GRDB
import Testing
@testable import DayDoCore

private struct RoleFixture {
    let db: AppDatabase
    let api: LocalDayDoAPI
    let meId: String
    let ownerId: String = "owner-other"
    let thirdMemberId: String = "member-third"
    let ownerListId: String
    let editorListId: String
    let viewerListId: String
    let editorTaskId: String = "task-editor"
    let editorDeletedTaskId: String = "task-editor-deleted"
    let editorChecklistId: String = "chk-editor"
    let editorAttachmentId: String = "att-editor"
    let editorInviteId: String = "inv-editor"
    let viewerTaskId: String = "task-viewer"
    let viewerDeletedTaskId: String = "task-viewer-deleted"
    let viewerChecklistId: String = "chk-viewer"
    let viewerAttachmentId: String = "att-viewer"
    let viewerInviteId: String = "inv-viewer"
}

private func expectForbidden(_ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected DayDoError.forbidden, succeeded instead")
    } catch let error as DayDoError {
        if case .forbidden = error {
            return
        }
        Issue.record("Expected DayDoError.forbidden, got \(error)")
    } catch {
        Issue.record("Expected DayDoError.forbidden, got \(error)")
    }
}

private func makeTaskUpdate(_ taskId: String, _ configure: (inout UpdateTaskInput) -> Void) -> UpdateTaskInput {
    var u = UpdateTaskInput(taskId: taskId)
    configure(&u)
    return u
}

private func makeProjectUpdate(_ projectId: String, _ configure: (inout UpdateProjectInput) -> Void) -> UpdateProjectInput {
    var u = UpdateProjectInput(projectId: projectId)
    configure(&u)
    return u
}

private func makeRoleFixture() async throws -> RoleFixture {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daydo-role-tests-\(UUID().uuidString)")
    let db = try AppDatabase.inMemory()
    let api = LocalDayDoAPI(database: db, clock: .fixed(noon, timeZone: taipei), attachmentsDirectory: dir)
    try await api.bootstrap()

    let me = try #require(try await api.listMembers().first { $0.isMe })
    let ownerProject = try await api.createProject(CreateProjectInput(name: "Owner List", viewMode: "list", kind: "TASK"))
    let editorListId = "proj-editor"
    let viewerListId = "proj-viewer"
    let nowMs = EpochMillis(noon.timeIntervalSince1970 * 1000)

    try await db.writer.write { db in
        try MemberRecord(
            id: "owner-other", name: "Owner", initial: "O", color: "#112233",
            isMe: false, createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try MemberRecord(
            id: "member-third", name: "Third", initial: "T", color: "#445566",
            isMe: false, createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try ProjectMemberRecord(
            projectId: ownerProject.id, memberId: "member-third", role: "editor",
            createdAt: nowMs, updatedAt: nowMs
        ).insert(db)

        // Editor shared list owned by owner-other
        try ProjectRecord(
            id: editorListId, name: "Editor List", viewMode: "list", kind: "TASK",
            isInbox: false, ownerId: "owner-other", sortKey: "y1",
            showInSmart: "all", notifyMode: "all", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try ProjectMemberRecord(
            projectId: editorListId, memberId: "owner-other", role: "owner",
            createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try ProjectMemberRecord(
            projectId: editorListId, memberId: me.id, role: "editor",
            createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try ProjectMemberRecord(
            projectId: editorListId, memberId: "member-third", role: "viewer",
            createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try ProjectInviteRecord(
            id: "inv-editor", projectId: editorListId, email: "inv-editor@example.com",
            role: "viewer", status: "pending", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try TaskRecord(
            id: "task-editor", projectId: editorListId, title: "Editor Task", content: "",
            priority: 0, status: 0, startDay: "2026-11-10", reminders: [], tags: [],
            sortKey: "a0", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try TaskRecord(
            id: "task-editor-deleted", projectId: editorListId, title: "Editor Deleted", content: "",
            priority: 0, status: 0, reminders: [], tags: [], sortKey: "a1",
            createdAt: nowMs, updatedAt: nowMs, deletedAt: nowMs
        ).insert(db)
        try ChecklistItemRecord(
            id: "chk-editor", taskId: "task-editor", title: "Step E", status: 0,
            sortKey: "a0", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try AttachmentRecord(
            id: "att-editor", taskId: "task-editor", fileName: "e.txt", size: 4,
            mimeType: "text/plain", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try db.execute(
            sql: "INSERT INTO projectMembership (projectId, scope, role, needsBackfill) VALUES (?, ?, ?, 0)",
            arguments: [editorListId, "u:owner-other", "editor"]
        )

        // Viewer shared list owned by owner-other
        try ProjectRecord(
            id: viewerListId, name: "Viewer List", viewMode: "list", kind: "TASK",
            isInbox: false, ownerId: "owner-other", sortKey: "y2",
            showInSmart: "all", notifyMode: "all", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try ProjectMemberRecord(
            projectId: viewerListId, memberId: "owner-other", role: "owner",
            createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try ProjectMemberRecord(
            projectId: viewerListId, memberId: me.id, role: "viewer",
            createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try ProjectMemberRecord(
            projectId: viewerListId, memberId: "member-third", role: "editor",
            createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try ProjectInviteRecord(
            id: "inv-viewer", projectId: viewerListId, email: "inv-viewer@example.com",
            role: "editor", status: "pending", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try TaskRecord(
            id: "task-viewer", projectId: viewerListId, title: "Viewer Task", content: "",
            priority: 0, status: 0, startDay: "2026-11-10", reminders: [], tags: [],
            sortKey: "a0", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try TaskRecord(
            id: "task-viewer-deleted", projectId: viewerListId, title: "Viewer Deleted", content: "",
            priority: 0, status: 0, reminders: [], tags: [], sortKey: "a1",
            createdAt: nowMs, updatedAt: nowMs, deletedAt: nowMs
        ).insert(db)
        try ChecklistItemRecord(
            id: "chk-viewer", taskId: "task-viewer", title: "Step V", status: 0,
            sortKey: "a0", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try AttachmentRecord(
            id: "att-viewer", taskId: "task-viewer", fileName: "v.txt", size: 4,
            mimeType: "text/plain", createdAt: nowMs, updatedAt: nowMs
        ).insert(db)
        try db.execute(
            sql: "INSERT INTO projectMembership (projectId, scope, role, needsBackfill) VALUES (?, ?, ?, 0)",
            arguments: [viewerListId, "u:owner-other", "viewer"]
        )
    }

    return RoleFixture(
        db: db,
        api: api,
        meId: me.id,
        ownerListId: ownerProject.id,
        editorListId: editorListId,
        viewerListId: viewerListId
    )
}

@Suite struct RolePermissionTests {
    @Test func projectRoleHelpersReflectResolvedRole() async throws {
        let f = try await makeRoleFixture()
        let projects = try await f.api.listProjects(includeArchived: false)
        let owner = try #require(projects.first { $0.id == f.ownerListId })
        let editor = try #require(projects.first { $0.id == f.editorListId })
        let viewer = try #require(projects.first { $0.id == f.viewerListId })

        #expect(owner.isOwner && !owner.isViewer && owner.canEditTasks)
        #expect(!editor.isOwner && !editor.isViewer && editor.canEditTasks)
        #expect(!viewer.isOwner && viewer.isViewer && !viewer.canEditTasks)
    }

    @Test func viewerCannotWriteTasksChildrenOrProject() async throws {
        let f = try await makeRoleFixture()

        await expectForbidden {
            _ = try await f.api.createTask(CreateTaskInput(projectId: f.viewerListId, title: "Blocked"))
        }
        await expectForbidden {
            _ = try await f.api.updateTask(makeTaskUpdate(f.viewerTaskId) { $0.title = "Renamed" })
        }
        await expectForbidden {
            _ = try await f.api.completeTask(id: f.viewerTaskId, ifUpdatedAt: nil)
        }
        await expectForbidden {
            _ = try await f.api.uncompleteTask(id: f.viewerTaskId)
        }
        await expectForbidden {
            try await f.api.deleteTask(id: f.viewerTaskId)
        }
        await expectForbidden {
            _ = try await f.api.restoreTask(id: f.viewerDeletedTaskId)
        }
        await expectForbidden {
            try await f.api.purgeTask(id: f.viewerDeletedTaskId)
        }
        await expectForbidden {
            _ = try await f.api.moveTask(id: f.viewerTaskId, toProjectId: f.ownerListId)
        }
        await expectForbidden {
            _ = try await f.api.addChecklistItem(taskId: f.viewerTaskId, title: "New Step")
        }
        await expectForbidden {
            _ = try await f.api.updateChecklistItem(id: f.viewerChecklistId, title: "Edited", done: true)
        }
        await expectForbidden {
            try await f.api.deleteChecklistItem(id: f.viewerChecklistId)
        }
        await expectForbidden {
            _ = try await f.api.uploadAttachment(
                taskId: f.viewerTaskId,
                fileName: "note.txt",
                data: Data("hi".utf8),
                mimeType: "text/plain",
                originalPath: nil
            )
        }
        await expectForbidden {
            try await f.api.deleteAttachment(id: f.viewerAttachmentId)
        }
        await expectForbidden {
            _ = try await f.api.updateProject(makeProjectUpdate(f.viewerListId) { $0.name = "Renamed" })
        }
        await expectForbidden {
            _ = try await f.api.moveProject(id: f.viewerListId, beforeProjectId: nil)
        }
        await expectForbidden {
            try await f.api.deleteProject(id: f.viewerListId)
        }
        await expectForbidden {
            _ = try await f.api.transferProjectOwner(projectId: f.viewerListId, toMemberId: f.thirdMemberId)
        }
        await expectForbidden {
            try await f.api.updateMemberRole(projectId: f.viewerListId, memberId: f.thirdMemberId, role: "viewer")
        }
        await expectForbidden {
            try await f.api.removeMember(projectId: f.viewerListId, memberId: f.thirdMemberId)
        }
        await expectForbidden {
            _ = try await f.api.inviteMember(projectId: f.viewerListId, email: "new@example.com", role: "viewer")
        }
        await expectForbidden {
            _ = try await f.api.updateInviteRole(id: f.viewerInviteId, role: "viewer")
        }
        await expectForbidden {
            try await f.api.cancelInvite(id: f.viewerInviteId)
        }
    }

    @Test func editorCanWriteTasksAndDisplayFieldsButCannotManageOwnershipMembersOrArchive() async throws {
        let f = try await makeRoleFixture()

        let created = try await f.api.createTask(CreateTaskInput(projectId: f.editorListId, title: "Allowed"))
        let updated = try await f.api.updateTask(makeTaskUpdate(created.id) { $0.title = "Updated" })
        #expect(updated.title == "Updated")
        _ = try await f.api.completeTask(id: created.id, ifUpdatedAt: nil)
        _ = try await f.api.uncompleteTask(id: created.id)
        let item = try await f.api.addChecklistItem(taskId: f.editorTaskId, title: "Editor Step")
        _ = try await f.api.updateChecklistItem(id: item.id, title: "Done Step", done: true)
        try await f.api.deleteChecklistItem(id: item.id)
        let att = try await f.api.uploadAttachment(
            taskId: f.editorTaskId,
            fileName: "doc.txt",
            data: Data("ok".utf8),
            mimeType: "text/plain",
            originalPath: nil
        )
        try await f.api.deleteAttachment(id: att.id)
        _ = try await f.api.updateProject(makeProjectUpdate(f.editorListId) {
            $0.name = "Editor Renamed"
            $0.color = .set("#123456")
        })
        _ = try await f.api.moveProject(id: f.editorListId, beforeProjectId: nil)
        try await f.api.deleteTask(id: created.id)
        _ = try await f.api.restoreTask(id: created.id)
        try await f.api.deleteTask(id: created.id)
        try await f.api.purgeTask(id: created.id)

        // Editor cannot perform owner-only operations
        await expectForbidden {
            _ = try await f.api.updateProject(makeProjectUpdate(f.editorListId) { $0.archived = true })
        }
        await expectForbidden {
            try await f.api.deleteProject(id: f.editorListId)
        }
        await expectForbidden {
            _ = try await f.api.transferProjectOwner(projectId: f.editorListId, toMemberId: f.thirdMemberId)
        }
        await expectForbidden {
            try await f.api.updateMemberRole(projectId: f.editorListId, memberId: f.thirdMemberId, role: "editor")
        }
        await expectForbidden {
            try await f.api.removeMember(projectId: f.editorListId, memberId: f.thirdMemberId)
        }
        await expectForbidden {
            _ = try await f.api.inviteMember(projectId: f.editorListId, email: "other@example.com", role: "viewer")
        }
        await expectForbidden {
            _ = try await f.api.updateInviteRole(id: f.editorInviteId, role: "editor")
        }
        await expectForbidden {
            try await f.api.cancelInvite(id: f.editorInviteId)
        }

        // Self-leave remains allowed
        try await f.api.removeMember(projectId: f.editorListId, memberId: f.meId)
    }

    @Test func ownerCanPerformOwnerOnlyOperations() async throws {
        let f = try await makeRoleFixture()
        let invite = try await f.api.inviteMember(projectId: f.ownerListId, email: "guest@example.com", role: "viewer")
        _ = try await f.api.updateInviteRole(id: invite.id, role: "editor")
        try await f.api.cancelInvite(id: invite.id)
        try await f.api.updateMemberRole(projectId: f.ownerListId, memberId: f.thirdMemberId, role: "viewer")
        _ = try await f.api.updateProject(makeProjectUpdate(f.ownerListId) { $0.archived = true })
        _ = try await f.api.updateProject(makeProjectUpdate(f.ownerListId) { $0.archived = false })
        try await f.api.removeMember(projectId: f.ownerListId, memberId: f.thirdMemberId)
        try await f.api.deleteProject(id: f.ownerListId)
    }

    @Test func moveRequiresWritePermissionOnBothSourceAndDestination() async throws {
        let f = try await makeRoleFixture()

        await expectForbidden {
            _ = try await f.api.moveTask(id: f.editorTaskId, toProjectId: f.viewerListId)
        }
        await expectForbidden {
            _ = try await f.api.updateTask(makeTaskUpdate(f.editorTaskId) { $0.projectId = f.viewerListId })
        }
        await expectForbidden {
            _ = try await f.api.moveTask(id: f.viewerTaskId, toProjectId: f.editorListId)
        }
        await expectForbidden {
            _ = try await f.api.updateTask(makeTaskUpdate(f.viewerTaskId) { $0.projectId = f.editorListId })
        }

        let moved = try await f.api.moveTask(id: f.editorTaskId, toProjectId: f.ownerListId)
        #expect(moved.projectId == f.ownerListId)
    }

    @Test func restoreTaskWhenOriginalListIsDeletedChecksPermissionBeforeFallingBackToInbox() async throws {
        let f = try await makeRoleFixture()
        let inbox = try #require(try await f.api.listProjects(includeArchived: false).first { $0.isInbox })
        let nowMs = EpochMillis(noon.timeIntervalSince1970 * 1000)

        try await f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE project SET deletedAt = ? WHERE id IN (?, ?)",
                arguments: [nowMs, f.editorListId, f.viewerListId]
            )
        }

        await expectForbidden {
            _ = try await f.api.restoreTask(id: f.viewerDeletedTaskId)
        }

        let restored = try await f.api.restoreTask(id: f.editorDeletedTaskId)
        #expect(restored.projectId == inbox.id)
    }

    @Test func postponeOverdueSkipsViewerTasksWithoutFailing() async throws {
        let f = try await makeRoleFixture()

        let skippedOnly = try await f.api.postponeOverdue(taskIds: [f.viewerTaskId])
        #expect(skippedOnly == 0)

        let viewerBefore = try await f.api.getTask(id: f.viewerTaskId)
        #expect(viewerBefore.schedule?.startDay == LocalDay("2026-11-10"))

        let count = try await f.api.postponeOverdue(taskIds: [f.editorTaskId, f.viewerTaskId])
        #expect(count == 1)

        let editorAfter = try await f.api.getTask(id: f.editorTaskId)
        let viewerAfter = try await f.api.getTask(id: f.viewerTaskId)
        #expect(editorAfter.schedule?.startDay == LocalDay("2026-11-15"))
        #expect(viewerAfter.schedule?.startDay == LocalDay("2026-11-10"))
    }

    @Test func deleteTagSkipsViewerTasksWithoutWritingOutbox() async throws {
        let f = try await makeRoleFixture()
        let nowMs = EpochMillis(noon.timeIntervalSince1970 * 1000)

        _ = try await f.api.createTag(label: "work", color: nil)
        _ = try await f.api.updateTask(makeTaskUpdate(f.editorTaskId) { $0.tags = ["work"] })
        try await f.db.writer.write { db in
            var viewerTask = try #require(try TaskRecord.fetchOne(db, key: f.viewerTaskId))
            viewerTask.tags = ["work"]
            viewerTask.updatedAt = nowMs
            try viewerTask.update(db)
        }

        let pendingBefore = try await f.api.pendingChanges(limit: 1000)
        let viewerOpsBefore = pendingBefore.filter { $0.entity == "task" && $0.entityId == f.viewerTaskId }.count

        try await f.api.deleteTag(name: "work")

        let tagsAfter = try await f.api.listTags()
        #expect(!tagsAfter.contains { $0.name == "work" })

        let editorAfter = try await f.api.getTask(id: f.editorTaskId)
        let viewerAfter = try await f.api.getTask(id: f.viewerTaskId)
        #expect(editorAfter.tags.isEmpty)
        #expect(viewerAfter.tags == ["work"])

        let pendingAfter = try await f.api.pendingChanges(limit: 1000)
        let viewerOpsAfter = pendingAfter.filter { $0.entity == "task" && $0.entityId == f.viewerTaskId }.count
        #expect(viewerOpsAfter == viewerOpsBefore)
    }

    @Test func syncApplierCanApplyRemoteUpdateToTaskInViewerList() async throws {
        let f = try await makeRoleFixture()
        let nowMs = EpochMillis(noon.timeIntervalSince1970 * 1000) + 5_000
        try await f.db.writer.write { db in
            var remoteRec = try #require(try TaskRecord.fetchOne(db, key: f.viewerTaskId))
            remoteRec.title = "Remote Updated"
            remoteRec.updatedAt = nowMs
            let remoteRow = try JSONDecoder().decode([String: SyncJSONValue].self, from: Outbox.encoder.encode(remoteRec))
            _ = try SyncApplier.applyRow(entity: "task", entityId: f.viewerTaskId, row: remoteRow, clocks: [:], in: db)
        }

        let task = try await f.api.getTask(id: f.viewerTaskId)
        #expect(task.title == "Remote Updated")
    }
}
