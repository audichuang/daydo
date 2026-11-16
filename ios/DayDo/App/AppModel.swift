import Foundation
import GoogleSignIn
import Network
import Observation
import SwiftUI
import UserNotifications
import DayDoCore

enum SyncConfig {
    static let baseURL = URL(string: "https://daydo-api.audichuang.app")!

    static func accessHeaders(bundle: Bundle = .main) -> [String: String] {
        var headers: [String: String] = [:]
        if let id = bundle.object(forInfoDictionaryKey: "DayDoAccessClientId") as? String {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                headers["CF-Access-Client-Id"] = trimmed
            }
        }
        if let secret = bundle.object(forInfoDictionaryKey: "DayDoAccessClientSecret") as? String {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                headers["CF-Access-Client-Secret"] = trimmed
            }
        }
        return headers
    }
}

struct PendingInvitePrompt: Identifiable, Equatable {
    var id: String { code }
    let code: String
    var info: InviteInfo?
    var isLoading: Bool
    var error: String?
    fileprivate let requestId = UUID()
}

/// App-wide state. Views read cached lookups (projects, tags, counts) from
/// here and send every write through `api` (the same `DayDoAPI` contract the
/// sync server and MCP will use).
@MainActor
@Observable
final class AppModel {
    private let store: DeviceStore
    let api: any DayDoAPI
    let syncEngine: SyncEngine
    let sharing: any ListSharing
    let tokenStore: any SyncTokenStore
    let syncEnabled: Bool

    // Lookups shared by many screens
    var projects: [Project] = []
    var folders: [Folder] = []
    var tags: [Tag] = []
    var members: [Member] = []
    var counts = SmartCounts(today: 0, tomorrow: 0, next7Days: 0, inbox: 0, assignedToMe: 0, completed: 0, trash: 0)

    /// Bumped after every write or sync change; screens reload with `.task(id: revision)`.
    private(set) var revision = 0
    /// False until initial launch state is resolved.
    var ready = false
    var isSignedIn = false
    var isSigningIn = false
    var isSyncing = false
    var errorMessage: String?

    // Invites
    var pendingInviteCode: String?
    var pendingManualInviteCode: String?
    var invitePrompt: PendingInvitePrompt?
    var showingJoinInvite = false
    var showingMeNamePrompt = false

    // Navigation
    var tab: MainTab = .tasks
    var scope: TaskScope = .smart(.today) {
        didSet {
            if oldValue != scope {
                selectedTaskId = nil
            }
        }
    }
    var drawerOpen = false
    var detailTaskId: String?
    var selectedTaskId: String? {
        didSet {
            if oldValue != selectedTaskId {
                inlineDetailSubpageTaskId = nil
                inlineDetailFocusedTaskId = nil
            }
        }
    }
    var inlineDetailSubpageTaskId: String?
    var inlineDetailFocusedTaskId: String?
    var searchFocusTrigger = 0
    var detailFocusTrigger = 0

    var inlineDetailAllowsSelectionShortcuts: Bool {
        guard let selectedTaskId else { return false }
        return inlineDetailSubpageTaskId != selectedTaskId && inlineDetailFocusedTaskId != selectedTaskId
    }
    /// Task opened from a notification while another detail sheet was open;
    /// shown after that sheet is dismissed so unsaved edits are not replaced.
    var pendingDetailTaskId: String?

    /// Opens a task's detail without replacing a sheet that is already open.
    func openDetailFromNotification(_ id: String) {
        if detailTaskId == id { return }
        if hasActiveRootSheet {
            pendingDetailTaskId = id
        } else {
            detailTaskId = id
        }
    }

    var canComposeForCurrentScope: Bool {
        guard tab == .tasks else { return true }
        switch scope {
        case .smart(.trash), .smart(.completed):
            return false
        case .project(let id):
            return !isViewer(projectId: id)
        default:
            return true
        }
    }

    func openComposerForCurrentScope() {
        guard canComposeForCurrentScope else { return }
        var req = ComposeRequest()
        switch scope {
        case .project(let id):
            if !isViewer(projectId: id) { req.projectId = id }
        case .tag(let t): req.tag = t
        case .smart(.today): req.day = today
        case .smart(.tomorrow): req.day = today.adding(days: 1)
        default: break
        }
        composing = req
    }

    func deleteSelectedTask(id: String) {
        let inTrash = scope == .smart(.trash)
        Task {
            guard let task = try? await api.getTask(id: id) else {
                if selectedTaskId == id {
                    selectedTaskId = nil
                }
                return
            }
            if task.deletedAt != nil {
                if inTrash && scope == .smart(.trash) {
                    await purgeTask(id: id)
                } else if selectedTaskId == id {
                    selectedTaskId = nil
                }
            } else if inTrash || scope == .smart(.trash) {
                if selectedTaskId == id {
                    selectedTaskId = nil
                }
            } else if !isViewer(projectId: task.projectId) {
                await perform { try await $0.deleteTask(id: id) }
                if selectedTaskId == id {
                    selectedTaskId = nil
                }
            }
        }
    }

    func purgeTask(id: String) async {
        guard scope == .smart(.trash),
              let task = try? await api.getTask(id: id),
              scope == .smart(.trash),
              !isViewer(projectId: task.projectId),
              task.deletedAt != nil else { return }
        await perform { try await $0.purgeTask(id: id) }
        if selectedTaskId == id {
            selectedTaskId = nil
        }
    }

    var hasActiveRootSheet: Bool {
        detailTaskId != nil
            || composing != nil
            || editingProjectId != nil
            || sharingProjectId != nil
            || invitePrompt != nil
            || showingJoinInvite
            || showingMeNamePrompt
    }

    /// Presents the next queued root-level sheet once the current sheet has dismissed.
    func flushPendingPresentations() {
        guard !hasActiveRootSheet else { return }
        if pendingManualInviteCode != nil {
            flushManualInviteIfNeeded()
            return
        }
        if isSignedIn, pendingInviteCode != nil {
            Task { [weak self] in
                await self?.processPendingInviteIfNeeded()
            }
            return
        }
        if let next = pendingDetailTaskId {
            pendingDetailTaskId = nil
            detailTaskId = next
        }
    }
    var composing: ComposeRequest?
    var editingProjectId: String?
    var sharingProjectId: String?

    // Preferences
    var accentHex: String { didSet { UserDefaults.standard.set(accentHex, forKey: "accent") } }
    var compact: Bool { didSet { UserDefaults.standard.set(compact, forKey: "compact") } }
    var textScale: Double { didSet { UserDefaults.standard.set(textScale, forKey: "textScale") } }
    var openFolders: Set<String> { didSet { UserDefaults.standard.set(Array(openFolders), forKey: "openFolders") } }

    /// Task ids currently executing `completeTask` to ignore double-taps.
    private(set) var completingIds: Set<String> = []

    let reminders = ReminderScheduler()
    let notificationDelegate = NotificationDelegate()

#if DEBUG
    var debugAccountPreview = false
    var debugInviteAppearCount = 0
#endif

    private var debounceSyncTask: Task<Void, Never>?
    private var retrySyncTask: Task<Void, Never>?
    private var notificationObserverTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var pathSatisfied: Bool?
    private var didAttemptGoogleAvatarSyncOnLaunch = false

    init(
        store: DeviceStore,
        tokenStore: any SyncTokenStore = KeychainSyncTokenStore(),
        syncEnabled: Bool = !ProcessInfo.processInfo.arguments.contains("-DayDoSkipLogin"),
        transport: (any SyncTransport)? = nil
    ) {
        self.store = store
        self.api = store.api
        self.tokenStore = tokenStore
        self.syncEnabled = syncEnabled
        let resolvedTransport: any SyncTransport = transport ?? HTTPSyncTransport(
            baseURL: SyncConfig.baseURL,
            extraHeaders: SyncConfig.accessHeaders()
        )
        let engine = store.makeSyncEngine(
            transport: resolvedTransport,
            tokenStore: tokenStore
        )
        self.syncEngine = engine
        self.sharing = syncEnabled
            ? RemoteListSharing(syncEngine: engine)
            : store.makeLocalSharing()
        let d = UserDefaults.standard
        accentHex = d.string(forKey: "accent") ?? "#FF8A1E"
        compact = d.bool(forKey: "compact")
        textScale = d.object(forKey: "textScale") as? Double ?? 1
        openFolders = Set(d.stringArray(forKey: "openFolders") ?? [])
        notificationDelegate.model = self
    }

    var accent: AccentTheme { AccentTheme(hex: accentHex) }
    var me: Member? { members.first(where: \.isMe) }
    var today: LocalDay { store.today }
    var editableProjects: [Project] { projects.filter { !$0.isViewer } }

    func project(_ id: String?) -> Project? { projects.first { $0.id == id } }
    func isViewer(projectId: String?) -> Bool { project(projectId)?.isViewer ?? false }
    func editableTaskIds(in tasks: [TodoTask]) -> [String] {
        tasks.filter { !isViewer(projectId: $0.projectId) }.map(\.id)
    }

    func postponeOverdue(tasks: [TodoTask]) {
        let ids = editableTaskIds(in: tasks)
        guard !ids.isEmpty else { return }
        Task { await perform { try await $0.postponeOverdue(taskIds: ids) } }
    }
    var inbox: Project? { projects.first(where: \.isInbox) }

    func launch() async {
        if !syncEnabled {
            try? await store.bootstrap()
            if ProcessInfo.processInfo.arguments.contains("-DayDoDemo") {
                try? await DemoData.load(into: api, today: today)
            }
            await reloadData()
            isSignedIn = true
            ready = true
            await DebugLaunch.apply(to: self)
            return
        }

#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-DayDoDebugStub"), !args.contains("-DayDoDebugSignedOut") {
            if !((try? await syncEngine.isSignedIn) ?? false) {
                try? await syncEngine.signIn(with: .apple(identityToken: "debug", nonce: "debug"))
            }
            if !args.contains("-DayDoDebugKeepDefaultName"),
               let currentMe = (try? await api.listMembers())?.first(where: \.isMe),
               currentMe.name == "我" {
                _ = try? await api.updateMe(name: "測試者", color: nil)
                try? await syncEngine.syncNow()
            }
            if args.contains("-DayDoDemo") {
                try? await DemoData.load(into: api, today: today)
            }
            if args.contains("-DayDoDebugForcedSignOut") {
                _ = try? await api.createTask(CreateTaskInput(title: "舊帳號未同步任務", start: today.description, allDay: true))
                tokenStore.accessToken = nil
                tokenStore.refreshToken = nil
                await handleSyncError(.signedOut)
            }
        }
#endif

        let signedIn = (try? await syncEngine.isSignedIn) ?? false
        if signedIn {
            isSignedIn = true
            await reloadData()
            if me?.name == "我" {
                showingMeNamePrompt = true
            }
            ready = true
            startSyncObservers()
            await DebugLaunch.apply(to: self)
            await processPendingInviteIfNeeded()
            triggerSyncNow()
            syncGoogleAvatarOnLaunchIfNeeded()
        } else {
            isSignedIn = false
            ready = true
            await DebugLaunch.apply(to: self)
        }
    }

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
    func perform<T>(_ work: @escaping @Sendable (any DayDoAPI) async throws -> T) async -> T? {
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
        guard !isViewer(projectId: task.projectId) else { return }
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

    /// Reloads UI state and reminders without triggering sync. Used for remote
    /// change notifications, scene foreground, and date boundary refreshes.
    func reloadData() async {
        await refreshLookups()
        if showingMeNamePrompt, let currentMe = me, currentMe.name != "我" {
            showingMeNamePrompt = false
        }
        revision += 1
        // Never block the UI on the notification permission prompt.
        let scheduler = reminders, api = api
        Task.detached { await scheduler.reschedule(api: api) }
    }

    /// Called after local writes: reloads UI and schedules a ~1s debounced sync.
    func didWrite() async {
        await reloadData()
        scheduleDebouncedSync()
    }

    // MARK: - Auth & Sync

    func signIn(with credential: SyncAuthCredential, displayName: String? = nil, avatarUrl: String? = nil) async throws {
        isSigningIn = true
        defer { isSigningIn = false }
        startSyncObservers()
        do {
            try await syncEngine.signIn(with: credential)
            isSignedIn = true
            await reloadData()
            await resolveMeProfileAfterSignIn(suggestedName: displayName)
            await processPendingInviteIfNeeded()
            syncGoogleAvatarAfterSignIn(credential: credential, explicitAvatarUrl: avatarUrl)
        } catch {
            let stillSignedIn = (try? await syncEngine.isSignedIn) ?? false
            if !stillSignedIn {
                stopSyncObservers()
            } else if let syncError = error as? SyncError, case .retryable = syncError {
                isSignedIn = true
                await reloadData()
                await resolveMeProfileAfterSignIn(suggestedName: displayName)
                await handleSyncError(syncError)
                await processPendingInviteIfNeeded()
                syncGoogleAvatarAfterSignIn(credential: credential, explicitAvatarUrl: avatarUrl)
                return
            }
            throw error
        }
    }

    private func syncGoogleAvatarOnLaunchIfNeeded() {
        guard syncEnabled, isSignedIn, !didAttemptGoogleAvatarSyncOnLaunch else { return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DayDoDebugStub") {
            return
        }
#endif
        didAttemptGoogleAvatarSyncOnLaunch = true
        Task { [weak self] in
            guard let self else { return }
            let googleUser: GIDGoogleUser?
            if let current = GIDSignIn.sharedInstance.currentUser {
                googleUser = current
            } else if GIDSignIn.sharedInstance.hasPreviousSignIn() {
                googleUser = try? await GIDSignIn.sharedInstance.restorePreviousSignIn()
            } else {
                googleUser = nil
            }
            guard let avatarUrl = self.googleProfileAvatarURL(from: googleUser) else { return }
            await self.syncGoogleAvatarIfNeeded(avatarUrl)
        }
    }

    private func syncGoogleAvatarAfterSignIn(credential: SyncAuthCredential, explicitAvatarUrl: String?) {
        guard case .google = credential else { return }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DayDoDebugStub") {
            return
        }
#endif
        let resolvedAvatarUrl = explicitAvatarUrl ?? googleProfileAvatarURL(from: GIDSignIn.sharedInstance.currentUser)
        guard let resolvedAvatarUrl else { return }
        Task { [weak self] in
            await self?.syncGoogleAvatarIfNeeded(resolvedAvatarUrl)
        }
    }

    private func googleProfileAvatarURL(from user: GIDGoogleUser?) -> String? {
        guard let profile = user?.profile,
              profile.hasImage,
              let url = profile.imageURL(withDimension: 256),
              url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url.absoluteString
    }

    private func syncGoogleAvatarIfNeeded(_ avatarUrl: String) async {
        guard syncEnabled, isSignedIn else { return }
        // A nil stored value is the case this sync exists for (accounts signed in before avatars), so only
        // a failed read or an identical URL skips the upload.
        let storedAvatarUrl: String?
        do { storedAvatarUrl = try await syncEngine.meAvatarUrl } catch { return }
        guard storedAvatarUrl != avatarUrl else { return }
        _ = try? await syncEngine.updateMeAvatar(avatarUrl)
    }

    private func resolveMeProfileAfterSignIn(suggestedName: String?) async {
        guard let currentMe = me else { return }
        let legacyColorFix = currentMe.color == Member.legacyDefaultColor
            ? Member.defaultColor(for: currentMe.id)
            : nil

        if currentMe.name == "我" {
            let cleaned = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleaned, !cleaned.isEmpty, cleaned != "我" {
                if (try? await api.updateMe(name: cleaned, color: legacyColorFix)) != nil {
                    await didWrite()
                }
                showingMeNamePrompt = false
            } else {
                showingMeNamePrompt = true
            }
        } else {
            if let legacyColorFix {
                if (try? await api.updateMe(name: currentMe.name, color: legacyColorFix)) != nil {
                    await didWrite()
                }
            }
            showingMeNamePrompt = false
        }
    }

    func unsyncedChangeCount() async -> Int {
        (try? await store.unsyncedChangeCount()) ?? 0
    }

    func signOut() async {
        stopSyncObservers()
        GIDSignIn.sharedInstance.signOut()
        if syncEnabled {
            do {
                try await syncEngine.signOut()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        resetLocalUIState()
    }

    func replaceAccountAndSignIn(with credential: SyncAuthCredential, displayName: String? = nil, avatarUrl: String? = nil) async throws {
        isSigningIn = true
        defer { isSigningIn = false }
        stopSyncObservers()
        GIDSignIn.sharedInstance.signOut()
        if syncEnabled {
            try await syncEngine.signOut()
        }
        resetLocalUIState()
        try await signIn(with: credential, displayName: displayName, avatarUrl: avatarUrl)
    }

    private func resetLocalUIState() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        projects = []
        folders = []
        tags = []
        members = []
        counts = SmartCounts(today: 0, tomorrow: 0, next7Days: 0, inbox: 0, assignedToMe: 0, completed: 0, trash: 0)
        scope = .smart(.today)
        tab = .tasks
        drawerOpen = false
        detailTaskId = nil
        selectedTaskId = nil
        pendingDetailTaskId = nil
        composing = nil
        editingProjectId = nil
        sharingProjectId = nil
        invitePrompt = nil
        pendingInviteCode = nil
        pendingManualInviteCode = nil
        showingJoinInvite = false
        showingMeNamePrompt = false
        isSignedIn = false
        revision += 1
    }

    func scheduleDebouncedSync() {
        guard syncEnabled, isSignedIn else { return }
        debounceSyncTask?.cancel()
        debounceSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.runSyncNow()
        }
    }

    func triggerSyncNow() {
        guard syncEnabled, isSignedIn else { return }
        Task { [weak self] in
            await self?.runSyncNow()
        }
    }

    func runSyncNow() async {
        guard syncEnabled, isSignedIn else { return }
        retrySyncTask?.cancel()
        retrySyncTask = nil
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await syncEngine.syncNow()
        } catch is CancellationError {
            return
        } catch let error as SyncError {
            await handleSyncError(error)
        } catch {
            // Unexpected error; keep local state intact.
        }
    }

    func handleErrorIfSignedOut(_ error: Error) async -> Bool {
        if case SyncError.signedOut = error {
            await handleSyncError(.signedOut)
            return true
        }
        return false
    }

    private func handleSyncError(_ error: SyncError) async {
        switch error {
        case .signedOut:
            stopSyncObservers()
            isSignedIn = false
        case let .retryable(retryAfter, _, _):
            retrySyncTask?.cancel()
            let delay = max(0.5, retryAfter)
            retrySyncTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.runSyncNow()
            }
        case .protocolError:
            break
        }
    }

    private func startSyncObservers() {
        guard syncEnabled else { return }
        if notificationObserverTask == nil {
            notificationObserverTask = Task { [weak self] in
                guard let self else { return }
                let stream = await self.syncEngine.changeNotifications()
                for await _ in stream {
                    if Task.isCancelled { break }
                    await self.reloadData()
                }
            }
        }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let previous = self.pathSatisfied
                    self.pathSatisfied = satisfied
                    if previous == false && satisfied && self.syncEnabled && self.isSignedIn {
                        self.triggerSyncNow()
                    }
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.audichuang.daydo.network"))
            pathMonitor = monitor
        }
    }

    private func stopSyncObservers() {
        debounceSyncTask?.cancel()
        debounceSyncTask = nil
        retrySyncTask?.cancel()
        retrySyncTask = nil
        notificationObserverTask?.cancel()
        notificationObserverTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pathSatisfied = nil
    }

    // MARK: - Invites

    func handleIncomingInvite(code: String) {
        pendingInviteCode = code
        guard ready, isSignedIn else { return }
        Task { [weak self] in
            await self?.processPendingInviteIfNeeded()
        }
    }

    func flushManualInviteIfNeeded() {
        guard let code = pendingManualInviteCode else { return }
        pendingManualInviteCode = nil
        handleIncomingInvite(code: code)
    }

    func processPendingInviteIfNeeded() async {
        guard isSignedIn, !hasActiveRootSheet, let code = pendingInviteCode else { return }
        pendingInviteCode = nil
        let prompt = PendingInvitePrompt(code: code, info: nil, isLoading: true, error: nil)
        invitePrompt = prompt
        do {
            let info = try await sharing.inviteInfo(code: code)
            guard invitePrompt?.requestId == prompt.requestId else { return }
            invitePrompt?.info = info
            invitePrompt?.isLoading = false
            invitePrompt?.error = nil
        } catch let error as SyncError {
            if case .signedOut = error {
                if invitePrompt?.requestId == prompt.requestId {
                    invitePrompt = nil
                }
                pendingInviteCode = code
                await handleSyncError(.signedOut)
            } else {
                guard invitePrompt?.requestId == prompt.requestId else { return }
                invitePrompt?.isLoading = false
                invitePrompt?.error = error.localizedDescription
            }
        } catch {
            guard invitePrompt?.requestId == prompt.requestId else { return }
            invitePrompt?.isLoading = false
            invitePrompt?.error = error.localizedDescription
        }
    }

    func acceptPendingInvite(code: String) async throws {
        do {
            let accepted = try await sharing.acceptInvite(code: code)
            await reloadData()
            scope = .project(accepted.projectId)
            tab = .tasks
            drawerOpen = false
            detailTaskId = nil
            selectedTaskId = nil
            invitePrompt = nil
        } catch let error as SyncError {
            if case .signedOut = error {
                invitePrompt = nil
                pendingInviteCode = code
                await handleSyncError(.signedOut)
            }
            throw error
        }
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
