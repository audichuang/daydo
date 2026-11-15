import GoogleSignIn
import SwiftUI
import UserNotifications
import DayDoCore

@main
struct DayDoApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let (api, tokenStore) = Self.makeStorage()
        let m = AppModel(api: api, tokenStore: tokenStore)
        _model = State(initialValue: m)
        UNUserNotificationCenter.current().delegate = m.notificationDelegate
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
           !clientID.isEmpty {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    static let appGroup = "group.com.audichuang.daydo"

    /// The database lives in the App Group container so the widget extension
    /// can read it. Falls back to Application Support when the group is not
    /// provisioned (e.g. unsigned simulator builds).
    static func storageDirectory() -> URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group.appendingPathComponent("DayDo", isDirectory: true)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("DayDo", isDirectory: true)
    }

    static func makeStorage() -> (LocalDayDoAPI, KeychainSyncTokenStore) {
        let dir = storageDirectory()
        let tokenStore = KeychainSyncTokenStore()
        if ProcessInfo.processInfo.arguments.contains("-DayDoReset") {
            try? FileManager.default.removeItem(at: dir)
            if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
            tokenStore.clearAll()
        }
        do {
            let db = try AppDatabase.open(at: dir.appendingPathComponent("daydo.sqlite"))
            let api = LocalDayDoAPI(database: db, attachmentsDirectory: dir.appendingPathComponent("Attachments", isDirectory: true))
            return (api, tokenStore)
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
                .preferredColorScheme(.dark)
                .task {
                    await model.launch()
                }
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    if let code = SyncEngine.parseInviteCode(from: url) {
                        model.handleIncomingInvite(code: code)
                    }
                }
                // Day boundaries & sync: re-read and sync when returning to foreground.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active && model.ready && model.isSignedIn {
                        Task { await model.reloadData() }
                        model.triggerSyncNow()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    if model.ready && model.isSignedIn { Task { await model.reloadData() } }
                }
        }
    }
}

/// Schedules local notifications for the next reminders (iOS keeps at most
/// 64 pending requests per app, so only the nearest ones are registered).
actor ReminderScheduler {
    private var isRescheduling = false
    private var dirty = false

    func reschedule(api: LocalDayDoAPI) async {
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

    private func performReschedule(api: LocalDayDoAPI) async {
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
            model.detailTaskId = tasks.first?.id
            if screen != "detail" { UserDefaults.standard.set(screen, forKey: "debugDetailPage") }
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
