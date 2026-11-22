import MachO
import os
import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications
import DayDoCore

@MainActor
final class DatabaseSuspensionCoordinator {
    typealias ExpirationHandler = @MainActor @Sendable () -> Void
    typealias BeginBackgroundTask = (_ name: String?, _ expirationHandler: @escaping ExpirationHandler) -> UIBackgroundTaskIdentifier
    typealias EndBackgroundTask = (_ identifier: UIBackgroundTaskIdentifier) -> Void

    private let beginBackgroundTask: BeginBackgroundTask
    private let endBackgroundTask: EndBackgroundTask
    private let suspend: () -> Void
    private let resume: () -> Void

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isSuspended = false

    init(
        beginBackgroundTask: @escaping BeginBackgroundTask = { name, handler in
            UIApplication.shared.beginBackgroundTask(withName: name) {
                MainActor.assumeIsolated {
                    handler()
                }
            }
        },
        endBackgroundTask: @escaping EndBackgroundTask = { id in
            UIApplication.shared.endBackgroundTask(id)
        },
        suspend: @escaping () -> Void = DayDoStorage.suspendDatabaseAccess,
        resume: @escaping () -> Void = DayDoStorage.resumeDatabaseAccess
    ) {
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
        self.suspend = suspend
        self.resume = resume
    }

    func enterBackground() {
        guard backgroundTaskID == .invalid, !isSuspended else { return }
        var finishedDuringBegin = false
        var returnedID: UIBackgroundTaskIdentifier = .invalid
        let taskID = beginBackgroundTask("DayDo.DatabaseSuspension") { [weak self] in
            guard let self else { return }
            if self.backgroundTaskID != .invalid {
                self.finishExpiration(taskID: self.backgroundTaskID)
            } else if returnedID == .invalid {
                finishedDuringBegin = true
                self.suspendIfNeeded()
            }
        }
        returnedID = taskID
        if finishedDuringBegin {
            if taskID != .invalid {
                endBackgroundTask(taskID)
            }
            return
        }
        if taskID == .invalid {
            suspendIfNeeded()
            return
        }
        backgroundTaskID = taskID
    }

    func leaveBackground() {
        if backgroundTaskID != .invalid {
            let taskID = backgroundTaskID
            backgroundTaskID = .invalid
            endBackgroundTask(taskID)
        }
        if isSuspended {
            isSuspended = false
            resume()
        }
    }

    private func finishExpiration(taskID: UIBackgroundTaskIdentifier) {
        backgroundTaskID = .invalid
        suspendIfNeeded()
        endBackgroundTask(taskID)
    }

    private func suspendIfNeeded() {
        guard !isSuspended else { return }
        isSuspended = true
        suspend()
    }
}

@main
struct DayDoApp: App {
    @State private var model: AppModel
    @State private var suspensionCoordinator = DatabaseSuspensionCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let (store, tokenStore) = Self.makeStorage()
#if DEBUG
        let useStub = ProcessInfo.processInfo.arguments.contains("-DayDoDebugStub")
        let effectiveTokenStore: any SyncTokenStore = useStub ? InMemorySyncTokenStore() : tokenStore
        let m = AppModel(
            store: store,
            tokenStore: effectiveTokenStore,
            transport: useStub ? DebugStubTransport() : nil
        )
#else
        let m = AppModel(store: store, tokenStore: tokenStore)
#endif
        _model = State(initialValue: m)
        // Match the always-dark LaunchBackground (#0E0F10) on the connecting scene before the
        // first frame; RootView switches to `model.appearance` once SplashOverlay finishes dismissing.
        AppearanceApplier.applyStyle(.dark)
        UNUserNotificationCenter.current().delegate = m.notificationDelegate
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
           !clientID.isEmpty {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    @MainActor
    static func handleScenePhaseChange(
        from oldPhase: ScenePhase,
        to phase: ScenePhase,
        model: AppModel,
        coordinator: DatabaseSuspensionCoordinator
    ) {
        if phase == .background {
            coordinator.enterBackground()
            return
        }
        if oldPhase == .background {
            coordinator.leaveBackground()
        }
        if phase == .active && model.ready && model.isSignedIn {
            Task { await model.reloadData() }
            model.triggerSyncNow()
        }
    }

    static func makeStorage() -> (DeviceStore, KeychainSyncTokenStore) {
        let dir = DayDoStorage.defaultDirectory()
        let tokenStore = KeychainSyncTokenStore()
        if ProcessInfo.processInfo.arguments.contains("-DayDoReset") {
            try? FileManager.default.removeItem(at: dir)
            if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
            tokenStore.clearAll()
        }
        do {
            let store = try DayDoStorage.openForApp(in: dir)
            return (store, tokenStore)
        } catch {
            fatalError("Cannot open database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.accent, model.accent)
                .environment(\.textScale, CGFloat(model.textScale))
                .tint(model.accent.color)
                .task {
                    await model.launch()
                }
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    if let code = SyncEngine.parseInviteCode(from: url) {
                        model.handleIncomingInvite(code: code)
                        return
                    }
                    if let link = WidgetDeepLink(url: url) {
                        model.handleWidgetDeepLink(link)
                    }
                }
                // Database suspension & foreground refresh/sync.
                .onChange(of: scenePhase) { oldPhase, phase in
                    Self.handleScenePhaseChange(
                        from: oldPhase,
                        to: phase,
                        model: model,
                        coordinator: suspensionCoordinator
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    if model.ready && model.isSignedIn { Task { await model.reloadData() } }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新增任務") {
                    guard model.isSignedIn, !model.hasActiveRootSheet, model.canComposeForCurrentScope else { return }
                    model.openComposerForCurrentScope()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.isSignedIn || model.hasActiveRootSheet || !model.canComposeForCurrentScope)
            }
            CommandMenu("前往") {
                Button("任務") { model.tab = .tasks }
                    .keyboardShortcut("1", modifiers: .command)
                Button("日曆") { model.tab = .calendar }
                    .keyboardShortcut("2", modifiers: .command)
                Button("搜尋") {
                    guard model.isSignedIn, !model.hasActiveRootSheet else { return }
                    model.tab = .search
                    model.searchFocusTrigger += 1
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(!model.isSignedIn || model.hasActiveRootSheet)
                Button("搜尋任務") {
                    guard model.isSignedIn, !model.hasActiveRootSheet else { return }
                    model.tab = .search
                    model.searchFocusTrigger += 1
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!model.isSignedIn || model.hasActiveRootSheet)
                Button("設定") { model.tab = .settings }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}

/// Schedules local notifications for the next reminders (iOS keeps at most
/// 64 pending requests per app, so only the nearest ones are registered).
actor ReminderScheduler {
    private var isRescheduling = false
    private var dirty = false

    func reschedule(api: any DayDoAPI) async {
        if isRescheduling {
            dirty = true
            return
        }
        isRescheduling = true
        defer { isRescheduling = false }
        repeat {
            dirty = false
            await performReschedule(api: api)
        } while dirty
    }

    private func performReschedule(api: any DayDoAPI) async {
        let center = UNUserNotificationCenter.current()
        guard let upcoming = try? await api.upcomingReminders(limit: 60) else { return }
        let settings = await center.notificationSettings()
        let allowed: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            allowed = true
        case .notDetermined:
            guard !upcoming.isEmpty else { return }
            allowed = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            allowed = false
        @unknown default:
            allowed = false
        }
        guard allowed else { return }
        center.removeAllPendingNotificationRequests()
        for r in upcoming {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.userInfo = ["taskId": r.taskId]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireDate)
            let req = UNNotificationRequest(identifier: r.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(req)
        }
    }
}

@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo["taskId"] as? String else { return }
        await MainActor.run {
            model?.openDetailFromNotification(id)
        }
    }
}

/// `-DayDoScreen <name>` opens a screen directly (used for screenshots).
@MainActor
enum DebugLaunch {
    private static var isRegularWindow: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        return window?.traitCollection.horizontalSizeClass == .regular
    }

    static func apply(to model: AppModel) async {
        let args = ProcessInfo.processInfo.arguments
#if DEBUG
        if args.contains("-DayDoDebugAccount") {
            model.debugAccountPreview = true
        }
        if args.contains("-DayDoSeedManyAllDay") {
            let start = model.today.description
            for n in 1...8 {
                _ = try? await model.api.createTask(CreateTaskInput(title: "全天壓測 \(n)", start: start, allDay: true))
            }
            await model.reloadData()
        }
        if args.contains("-DayDoSeedLinkDescription") {
            let content = """
            12:00・3 人・冠安副理請客

            台北市內湖區瑞光路 333 號 1 樓（宏匯瑞光廣場）
            02-7756-6298
            [在地圖開啟](https://maps.apple.com/?q=一番地壽喜燒%20內湖宏匯店&address=台北市內湖區瑞光路333號1樓)

            待確認：用餐時間
            """
            _ = try? await model.api.createTask(CreateTaskInput(
                title: "連結描述測試任務",
                content: content,
                start: model.today.description,
                allDay: true
            ))
            await model.reloadData()
        }
        if args.contains("-DayDoSeedPerf") {
            // Heavy-family load for hitch measurement: ~600 tasks over ±90 days, ~20 on today.
            let projectIds = model.projects.filter(\.canEditTasks).map(\.id)
            let tz = TimeZone.current.identifier
            for n in 0..<600 {
                let offset = n % 20 == 0 ? 0 : (n * 37) % 181 - 90
                let day = model.today.adding(days: offset)
                let schedule: Schedule = n % 3 == 0
                    ? .allDay(day)
                    : .timed(day, start: 480 + (n * 53) % 720, end: 480 + (n * 53) % 720 + 60, timeZone: tz)
                _ = try? await model.api.createTask(CreateTaskInput(
                    projectId: projectIds[n % projectIds.count], title: "壓測任務 \(n)", content: n % 4 == 0 ? "備註 \(n)" : "",
                    priority: [Priority.none, .low, .medium, .high][n % 4], schedule: schedule,
                    subtasks: n % 5 == 0 ? ["子任務 A", "子任務 B"] : [], tags: n % 6 == 0 ? ["壓測"] : []))
            }
            await model.reloadData()
            // Image load addresses let ios/scripts/perf symbolicate with atos (xctrace can't for attached
            // simulator apps); the signpost marks where the analysis window starts.
            let images = (0..<_dyld_image_count()).map { i in
                "\(UInt(bitPattern: _dyld_get_image_header(i))) \((String(cString: _dyld_get_image_name(i)) as NSString).lastPathComponent)"
            }.joined(separator: "\n")
            try? images.write(toFile: NSTemporaryDirectory() + "perf-images.txt", atomically: true, encoding: .utf8)
            os_signpost(.event, log: OSLog(subsystem: "com.audichuang.daydo", category: .pointsOfInterest), name: "seedDone")
        }
#endif
        guard let i = args.firstIndex(of: "-DayDoScreen"), i + 1 < args.count else { return }
        let screen = args[i + 1]
        if args.contains("-DayDoCompact") { model.compact = true }
        let tasks = (try? await model.api.searchTasks(text: "簡報", activeOnly: true)) ?? []
        switch screen {
        case "drawer": model.drawerOpen = true
        case "calendar": model.tab = .calendar
        case "day": UserDefaults.standard.set("day", forKey: "calendarViewMode"); model.tab = .calendar
        case "events": UserDefaults.standard.set("month", forKey: "calendarViewMode"); model.tab = .calendar
        case "week": UserDefaults.standard.set("week", forKey: "calendarViewMode"); model.tab = .calendar
        case "search": model.tab = .search
        case "detail", "date", "time":
            if screen != "detail" { UserDefaults.standard.set(screen, forKey: "debugDetailPage") }
            if let id = tasks.first?.id {
                model.openTask(id, inlineAvailable: isRegularWindow)
            }
        case "editlist": model.editingProjectId = model.projects.first { !$0.isInbox }?.id
        case "compose": model.composing = ComposeRequest(day: model.today)
        case "settings": model.tab = .settings
#if DEBUG
        case "invite":
            model.invitePrompt = PendingInvitePrompt(
                code: "preview",
                info: InviteInfo(
                    projectName: "家庭採買",
                    inviterName: "小安",
                    role: "editor",
                    expiresAt: EpochMillis(Date().addingTimeInterval(7 * 86400).timeIntervalSince1970 * 1000)
                ),
                isLoading: false,
                error: nil
            )
#endif
        default: break
        }
    }
}

#if DEBUG
actor DebugStubTransport: SyncTransport {
    private var didPullSeed = false
    private var sawChecklistPush = false
    private var didPushRemoteContent = false
    private var didFailAttachmentOnce = false
    private var pushedMeId: String?
    private var pushedMeColor: String?

    func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
        let nowMs = EpochMillis(Date().timeIntervalSince1970 * 1000)
        let serverHLC = HLC(ms: nowMs, counter: 0, deviceId: "srv").description

        if method == "POST" && path == "/auth/apple" {
            return try jsonResponse(200, [
                "accessToken": "debug-access",
                "refreshToken": "debug-refresh",
                "user": ["id": "debug-user"],
                "isNewAccount": true,
                "hasData": false,
                "meMemberId": NSNull(),
                "inboxProjectId": NSNull(),
            ])
        }

        if method == "POST" && path == "/auth/google" {
            return try jsonResponse(200, [
                "accessToken": "debug-access-2",
                "refreshToken": "debug-refresh-2",
                "user": ["id": "debug-user-2"],
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
                    if let entity = op["entity"] as? String {
                        if entity == "checklistItem" {
                            sawChecklistPush = true
                        }
                        if entity == "member" {
                            if let entityId = op["entityId"] as? String {
                                pushedMeId = entityId
                            }
                            if let row = op["row"] as? [String: Any],
                               let color = row["color"] as? String {
                                pushedMeColor = color
                            }
                        }
                    }
                    if let opId = op["opId"] as? String {
                        results.append(["opId": opId, "status": "applied"])
                    }
                }
            }
            return try jsonResponse(200, [
                "results": results,
                "serverTime": serverHLC,
            ])
        }

        if method == "POST" && path == "/sync/pull" {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-DayDoDebugRemoteAttachment"), !didPullSeed {
                didPullSeed = true
                let today = Clock.system.today.description
                let projectId = "debug-att-proj-1"
                let taskId = "debug-att-task-1"
                let attId = "debug-remote-att-1"
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:debug-user",
                        "rows": [
                            [
                                "entity": "project",
                                "row": [
                                    "id": projectId,
                                    "name": "附件測試清單",
                                    "color": "#4AA8E8",
                                    "viewMode": "list",
                                    "kind": "TASK",
                                    "isInbox": false,
                                    "ownerId": "debug-owner-1",
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
                                    "projectId": projectId,
                                    "title": "遠端附件任務",
                                    "content": "",
                                    "priority": 0,
                                    "status": 0,
                                    "startDay": today,
                                    "reminders": [],
                                    "tags": [],
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["title": serverHLC, "schedule": serverHLC],
                                "serverSeq": 2,
                            ],
                            [
                                "entity": "attachment",
                                "row": [
                                    "id": attId,
                                    "taskId": taskId,
                                    "fileName": "notes.txt",
                                    "size": 12,
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
            let seedRemoteContent = args.contains("-DayDoDebugRemoteContentUpdate")
            if seedRemoteContent && !didPullSeed {
                didPullSeed = true
                let today = Clock.system.today.description
                let projectId = "debug-sync-proj-1"
                let taskId = "debug-sync-task-1"
                let itemId = "debug-sync-item-1"
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:debug-user",
                        "rows": [
                            [
                                "entity": "project",
                                "row": [
                                    "id": projectId,
                                    "name": "同步測試清單",
                                    "color": "#4AA8E8",
                                    "viewMode": "list",
                                    "kind": "TASK",
                                    "isInbox": false,
                                    "ownerId": "debug-owner-1",
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
                                    "projectId": projectId,
                                    "title": "同步測試任務",
                                    "content": "初始描述",
                                    "priority": 0,
                                    "status": 0,
                                    "startDay": today,
                                    "reminders": [],
                                    "tags": [],
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["title": serverHLC, "content": serverHLC, "schedule": serverHLC],
                                "serverSeq": 2,
                            ],
                            [
                                "entity": "checklistItem",
                                "row": [
                                    "id": itemId,
                                    "taskId": taskId,
                                    "title": "觸發同步子任務",
                                    "status": 0,
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["title": serverHLC, "status": serverHLC],
                                "serverSeq": 3,
                            ],
                        ],
                        "cursor": 3,
                        "hasMore": false,
                    ]],
                    "members": [],
                ])
            }
            if seedRemoteContent && sawChecklistPush && !didPushRemoteContent {
                didPushRemoteContent = true
                let today = Clock.system.today.description
                let futureHLC = HLC(ms: nowMs + 60_000, counter: 0, deviceId: "srv-other").description
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:debug-user",
                        "rows": [[
                            "entity": "task",
                            "row": [
                                "id": "debug-sync-task-1",
                                "projectId": "debug-sync-proj-1",
                                "title": "同步測試任務",
                                "content": "遠端更新後的描述",
                                "priority": 0,
                                "status": 0,
                                "startDay": today,
                                "reminders": [],
                                "tags": [],
                                "sortKey": "a0",
                                "createdAt": nowMs,
                                "updatedAt": nowMs + 60_000,
                            ],
                            "clocks": [
                                "title": serverHLC,
                                "content": futureHLC,
                                "schedule": serverHLC,
                            ],
                            "serverSeq": 4,
                        ]],
                        "cursor": 4,
                        "hasMore": false,
                    ]],
                    "members": [],
                ])
            }
            let seedViewer = args.contains("-DayDoSeedViewerOverdue") || args.contains("-DayDoSeedViewerOverdueOnly")
            if seedViewer && !didPullSeed {
                didPullSeed = true
                let yesterday = Clock.system.today.adding(days: -1).description
                let ownerId = "debug-owner-1"
                let projectId = "debug-viewer-proj-1"
                let taskId = "debug-viewer-task-1"
                return try jsonResponse(200, [
                    "scopes": [[
                        "scope": "u:debug-owner",
                        "rows": [
                            [
                                "entity": "project",
                                "row": [
                                    "id": projectId,
                                    "name": "唯讀共享清單",
                                    "color": "#5AC8FA",
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
                                "entity": "task",
                                "row": [
                                    "id": taskId,
                                    "projectId": projectId,
                                    "title": "唯讀逾期任務",
                                    "content": "",
                                    "priority": 0,
                                    "status": 0,
                                    "startDay": yesterday,
                                    "reminders": [],
                                    "tags": [],
                                    "sortKey": "a0",
                                    "createdAt": nowMs,
                                    "updatedAt": nowMs,
                                ],
                                "clocks": ["title": serverHLC, "schedule": serverHLC],
                                "serverSeq": 2,
                            ],
                        ],
                        "cursor": 2,
                        "hasMore": false,
                    ]],
                    "memberships": [
                        ["projectId": projectId, "scope": "u:debug-owner", "role": "viewer"],
                    ],
                    "members": [[
                        "id": ownerId,
                        "name": "小安",
                        "initial": "安",
                        "color": "#5AC8FA",
                        "isMe": false,
                        "createdAt": nowMs,
                        "updatedAt": nowMs,
                    ]],
                ])
            }
            if args.contains("-DayDoSeedSharedList"), !didPullSeed, let meId = pushedMeId {
                didPullSeed = true
                let today = Clock.system.today.description
                let otherId = "debug-other-member-1"
                let otherColor = Member.avatarColors.first { $0 != pushedMeColor } ?? Member.avatarColors[0]
                let projectId = "debug-shared-proj-1"
                let partnerProjectId = "debug-partner-proj-1"
                return try jsonResponse(200, [
                    "scopes": [
                        [
                            "scope": "u:debug-user",
                            "rows": [
                                [
                                    "entity": "project",
                                    "row": [
                                        "id": projectId,
                                        "name": "家庭採買",
                                        "color": "#4AA8E8",
                                        "viewMode": "list",
                                        "kind": "TASK",
                                        "isInbox": false,
                                        "ownerId": meId,
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
                                    "entity": "projectMember",
                                    "row": [
                                        "projectId": projectId,
                                        "memberId": meId,
                                        "role": "owner",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["role": serverHLC],
                                    "serverSeq": 2,
                                ],
                                [
                                    "entity": "projectMember",
                                    "row": [
                                        "projectId": projectId,
                                        "memberId": otherId,
                                        "role": "editor",
                                        "createdAt": nowMs + 1,
                                        "updatedAt": nowMs + 1,
                                    ],
                                    "clocks": ["role": serverHLC],
                                    "serverSeq": 3,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": "debug-shared-task-1",
                                        "projectId": projectId,
                                        "title": "買鮮奶",
                                        "content": "",
                                        "priority": 0,
                                        "status": 0,
                                        "startDay": today,
                                        "reminders": [],
                                        "tags": [],
                                        "sortKey": "a0",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC, "schedule": serverHLC],
                                    "serverSeq": 4,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": "debug-shared-task-2",
                                        "projectId": projectId,
                                        "title": "繳水電費",
                                        "content": "",
                                        "priority": 0,
                                        "status": 0,
                                        "startDay": today,
                                        "assigneeId": otherId,
                                        "reminders": [],
                                        "tags": [],
                                        "sortKey": "a1",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC, "schedule": serverHLC, "assigneeId": serverHLC],
                                    "serverSeq": 5,
                                ],
                            ],
                            "cursor": 5,
                            "hasMore": false,
                        ],
                        [
                            "scope": "u:debug-other",
                            "rows": [
                                [
                                    "entity": "project",
                                    "row": [
                                        "id": partnerProjectId,
                                        "name": "旅行規劃",
                                        "color": "#E8C14E",
                                        "viewMode": "list",
                                        "kind": "TASK",
                                        "isInbox": false,
                                        "ownerId": otherId,
                                        "sortKey": "z2",
                                        "showInSmart": "all",
                                        "notifyMode": "all",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["name": serverHLC],
                                    "serverSeq": 1,
                                ],
                                [
                                    "entity": "projectMember",
                                    "row": [
                                        "projectId": partnerProjectId,
                                        "memberId": otherId,
                                        "role": "owner",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["role": serverHLC],
                                    "serverSeq": 2,
                                ],
                                [
                                    "entity": "projectMember",
                                    "row": [
                                        "projectId": partnerProjectId,
                                        "memberId": meId,
                                        "role": "editor",
                                        "createdAt": nowMs + 1,
                                        "updatedAt": nowMs + 1,
                                    ],
                                    "clocks": ["role": serverHLC],
                                    "serverSeq": 3,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": "debug-partner-task-1",
                                        "projectId": partnerProjectId,
                                        "title": "訂機票",
                                        "content": "",
                                        "priority": 0,
                                        "status": 0,
                                        "startDay": today,
                                        "reminders": [],
                                        "tags": [],
                                        "sortKey": "a0",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC, "schedule": serverHLC],
                                    "serverSeq": 4,
                                ],
                                [
                                    "entity": "task",
                                    "row": [
                                        "id": "debug-partner-task-2",
                                        "projectId": partnerProjectId,
                                        "title": "換日幣",
                                        "content": "",
                                        "priority": 0,
                                        "status": 0,
                                        "startDay": today,
                                        "assigneeId": meId,
                                        "reminders": [],
                                        "tags": [],
                                        "sortKey": "a1",
                                        "createdAt": nowMs,
                                        "updatedAt": nowMs,
                                    ],
                                    "clocks": ["title": serverHLC, "schedule": serverHLC, "assigneeId": serverHLC],
                                    "serverSeq": 5,
                                ],
                            ],
                            "cursor": 5,
                            "hasMore": false,
                        ],
                    ],
                    "memberships": [
                        ["projectId": projectId, "scope": "u:debug-user", "role": "owner"],
                        ["projectId": partnerProjectId, "scope": "u:debug-other", "role": "editor"],
                    ],
                    "members": [[
                        "id": otherId,
                        "userId": "debug-other-user-1",
                        "name": "小安",
                        "initial": "小",
                        "color": otherColor,
                        "avatarUrl": (args.contains("-DayDoSeedAvatarPhoto")
                            ? Bundle.main.url(forResource: "DebugAvatar", withExtension: "png")?.absoluteString
                            : nil) as Any,
                        "isMe": false,
                        "createdAt": nowMs,
                        "updatedAt": nowMs,
                    ]],
                ])
            }
            return try jsonResponse(200, [
                "scopes": [],
                "members": [],
            ])
        }

        if method == "GET" && path == "/attachments/debug-remote-att-1/content" {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-DayDoDebugRemoteAttachmentFailOnce") && !didFailAttachmentOnce {
                didFailAttachmentOnce = true
                return try jsonResponse(500, ["error": "Temporary failure"])
            }
            let delayMs = args.contains("-DayDoDebugRemoteAttachmentSlow") ? 10000 : 250
            try await Task.sleep(for: .milliseconds(delayMs))
            return SyncHTTPResponse(status: 200, body: Data("hello remote".utf8))
        }

        if method == "GET" && path == "/invites/slow-ok" {
            try await Task.sleep(for: .milliseconds(2500))
            let expiresAt = EpochMillis(Date().addingTimeInterval(7 * 86400).timeIntervalSince1970 * 1000)
            return try jsonResponse(200, [
                "projectName": "家庭採買",
                "inviterName": "小安",
                "role": "editor",
                "expiresAt": expiresAt,
            ])
        }

        if method == "GET" && path == "/invites/slow-404" {
            try await Task.sleep(for: .milliseconds(2500))
            return try jsonResponse(404, ["error": "Invite not found"])
        }

        if method == "GET" && path == "/invites/slow-500" {
            try await Task.sleep(for: .milliseconds(2500))
            return try jsonResponse(500, ["error": "Server busy"])
        }

        return try jsonResponse(404, ["error": "Not found"])
    }

    private func jsonResponse(_ status: Int, _ object: Any) throws -> SyncHTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: object)
        return SyncHTTPResponse(status: status, body: data)
    }
}
#endif
