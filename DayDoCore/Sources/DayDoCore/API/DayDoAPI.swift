import Foundation

/// The command/query surface of DayDo. Every UI read and write goes through
/// this protocol; method names follow the ticktick-mcp tool names
/// (`list_projects`, `create_task`, `complete_task`, …) so the same contract
/// serves the app, the phase-2 Worker REST API (`spec/openapi.yaml`) and MCP.
public protocol DayDoAPI: Sendable {
    // Members
    func listMembers() async throws -> [Member]
    func updateMe(name: String, color: String?) async throws -> Member

    // Folders
    func listFolders() async throws -> [Folder]
    func createFolder(name: String) async throws -> Folder
    func updateFolder(id: String, name: String) async throws -> Folder
    func deleteFolder(id: String) async throws

    // Projects (清單)
    func listProjects(includeArchived: Bool) async throws -> [Project]
    func getProject(id: String) async throws -> Project
    func getProjectData(id: String) async throws -> ProjectData
    func createProject(_ input: CreateProjectInput) async throws -> Project
    func updateProject(_ input: UpdateProjectInput) async throws -> Project
    func moveProject(id: String, beforeProjectId: String?) async throws -> Project
    func duplicateProject(id: String) async throws -> Project
    func transferProjectOwner(projectId: String, toMemberId: String) async throws -> Project
    func deleteProject(id: String) async throws

    // Project members & invites (清單成員與共享邀請)
    func listProjectMembers(projectId: String) async throws -> [ProjectMemberInfo]
    func updateMemberRole(projectId: String, memberId: String, role: String) async throws
    func removeMember(projectId: String, memberId: String) async throws
    func listInvites(projectId: String) async throws -> [ProjectInvite]
    func inviteMember(projectId: String, email: String, role: String) async throws -> ProjectInvite
    func cancelInvite(id: String) async throws
    func updateInviteRole(id: String, role: String) async throws -> ProjectInvite

    // Tasks
    func listTasks(_ query: TaskQuery) async throws -> [TodoTask]
    func listSections(_ scope: TaskScope, limit: Int?) async throws -> [TaskSection]
    func searchTasks(text: String, activeOnly: Bool) async throws -> [TodoTask]
    func getTask(id: String) async throws -> TodoTask
    func createTask(_ input: CreateTaskInput) async throws -> TodoTask
    func updateTask(_ input: UpdateTaskInput) async throws -> TodoTask
    func completeTask(id: String, ifUpdatedAt: EpochMillis?) async throws -> TodoTask
    func uncompleteTask(id: String) async throws -> TodoTask
    func deleteTask(id: String) async throws
    func restoreTask(id: String) async throws -> TodoTask
    func purgeTask(id: String) async throws
    func moveTask(id: String, toProjectId: String) async throws -> TodoTask
    func getCompletedTasks(projectId: String?, limit: Int) async throws -> [TodoTask]
    /// 「全部延到今天」: moves the specified overdue tasks to today keeping their times.
    func postponeOverdue(taskIds: [String]) async throws -> Int
    func smartCounts() async throws -> SmartCounts

    // Checklist (子任務)
    func addChecklistItem(taskId: String, title: String) async throws -> ChecklistItem
    func updateChecklistItem(id: String, title: String?, done: Bool?) async throws -> ChecklistItem
    func deleteChecklistItem(id: String) async throws

    // Tags
    func listTags() async throws -> [Tag]
    func createTag(label: String, color: String?) async throws -> Tag
    func updateTag(name: String, label: String?, color: String?) async throws -> Tag
    func deleteTag(name: String) async throws

    // Attachments
    func uploadAttachment(taskId: String, fileName: String, data: Data, mimeType: String, originalPath: String?) async throws -> Attachment
    func deleteAttachment(id: String) async throws
    func attachmentURL(_ attachment: Attachment) -> URL?

    // Reminders
    func upcomingReminders(limit: Int) async throws -> [ScheduledReminder]
}

// Convenience overloads with distinct signatures, so a conforming type that
// forgets a requirement fails to compile instead of recursing forever.
public extension DayDoAPI {
    func listSections(_ scope: TaskScope) async throws -> [TaskSection] {
        try await listSections(scope, limit: nil)
    }

    func completeTask(id: String) async throws -> TodoTask {
        try await completeTask(id: id, ifUpdatedAt: nil)
    }
}
