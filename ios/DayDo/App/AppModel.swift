import Foundation
import Observation
import SwiftUI
import DayDoCore

/// App-wide state. Views read cached lookups (projects, tags, counts) from
/// here and send every write through `api` (the same `DayDoAPI` contract the
/// sync server and MCP will use).
@MainActor
@Observable
final class AppModel {
    let api: LocalDayDoAPI

    // Lookups shared by many screens
    var projects: [Project] = []
    var folders: [Folder] = []
    var tags: [Tag] = []
    var members: [Member] = []
    var counts = SmartCounts(today: 0, tomorrow: 0, next7Days: 0, inbox: 0, assignedToMe: 0, completed: 0, trash: 0)

    /// Bumped after every write; screens reload with `.task(id: revision)`.
    private(set) var revision = 0
    /// False until the database is bootstrapped (local user + inbox exist).
    var ready = false
    var errorMessage: String?

    // Navigation
    var tab: MainTab = .tasks
    var scope: TaskScope = .smart(.today)
    var drawerOpen = false
    var detailTaskId: String?
    /// Task opened from a notification while another detail sheet was open;
    /// shown after that sheet is dismissed so unsaved edits are not replaced.
    var pendingDetailTaskId: String?

    /// Opens a task's detail without replacing a detail sheet that is already open.
    func openDetailFromNotification(_ id: String) {
        if let current = detailTaskId, current != id {
            pendingDetailTaskId = id
        } else {
            detailTaskId = id
        }
    }
    var composing: ComposeRequest?
    var editingProjectId: String?

    // Preferences
    var accentHex: String { didSet { UserDefaults.standard.set(accentHex, forKey: "accent") } }
    var compact: Bool { didSet { UserDefaults.standard.set(compact, forKey: "compact") } }
    var textScale: Double { didSet { UserDefaults.standard.set(textScale, forKey: "textScale") } }
    var openFolders: Set<String> { didSet { UserDefaults.standard.set(Array(openFolders), forKey: "openFolders") } }

    /// Task ids currently executing `completeTask` to ignore double-taps.
    private(set) var completingIds: Set<String> = []

    let reminders = ReminderScheduler()
    let notificationDelegate = NotificationDelegate()

    init(api: LocalDayDoAPI) {
        self.api = api
        let d = UserDefaults.standard
        accentHex = d.string(forKey: "accent") ?? "#FF8A1E"
        compact = d.bool(forKey: "compact")
        textScale = d.object(forKey: "textScale") as? Double ?? 1
        openFolders = Set(d.stringArray(forKey: "openFolders") ?? [])
        notificationDelegate.model = self
    }

    var accent: AccentTheme { AccentTheme(hex: accentHex) }
    var me: Member? { members.first(where: \.isMe) }
    var today: LocalDay { api.clock.today }

    func project(_ id: String?) -> Project? { projects.first { $0.id == id } }
    var inbox: Project? { projects.first(where: \.isInbox) }

    func refreshLookups() async {
        do {
            async let p = api.listProjects(includeArchived: false)
            async let f = api.listFolders()
            async let t = api.listTags()
            async let m = api.listMembers()
            async let c = api.smartCounts()
            (projects, folders, tags, members, counts) = try await (p, f, t, m, c)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a write, then refreshes lookups, bumps the revision and
    /// reschedules local notifications.
    @discardableResult
    func perform<T>(_ work: @escaping @Sendable (LocalDayDoAPI) async throws -> T) async -> T? {
        do {
            let result = try await work(api)
            await didWrite()
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Convenience for partial task updates from views.
    func updateTask(_ id: String, _ edit: (inout UpdateTaskInput) -> Void) {
        var u = UpdateTaskInput(taskId: id)
        edit(&u)
        let input = u
        Task { await perform { try await $0.updateTask(input) } }
    }

    /// Completes or uncompletes a task while preventing double-tap re-entry.
    func toggleComplete(_ task: TodoTask) {
        let id = task.id
        if task.isCompleted {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await perform { try await $0.uncompleteTask(id: id) } }
            return
        }
        guard completingIds.insert(id).inserted else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let ifUpdatedAt = task.updatedAt
        Task {
            defer { completingIds.remove(id) }
            await perform { try await $0.completeTask(id: id, ifUpdatedAt: ifUpdatedAt) }
        }
    }

    func didWrite() async {
        await refreshLookups()
        revision += 1
        // Never block the UI on the notification permission prompt.
        let scheduler = reminders, api = api
        Task.detached { await scheduler.reschedule(api: api) }
    }

    func scopeTitle(_ scope: TaskScope) -> String {
        switch scope {
        case .smart(let v):
            switch v {
            case .today: "今天"
            case .tomorrow: "明天"
            case .next7: "未來 7 天"
            case .inbox: "收件匣"
            case .assigned: "指派給我"
            case .completed: "已完成"
            case .trash: "垃圾桶"
            }
        case .project(let id): project(id)?.name ?? "清單"
        case .tag(let name): "# " + (tags.first { $0.name == name }?.label ?? name)
        }
    }
}

enum MainTab: Hashable { case tasks, calendar, search, settings }

/// Opening the composer with defaults (e.g. the day selected in the calendar).
struct ComposeRequest: Identifiable {
    let id = UUID()
    var projectId: String?
    var day: LocalDay?
    /// Start minute when created from a time slot in the week/day grid.
    var minute: Int?
    var tag: String?
}
