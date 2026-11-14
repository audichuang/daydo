import SwiftUI
import UserNotifications
import DayDoCore

@main
struct DayDoApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let api = Self.makeAPI()
        _model = State(initialValue: AppModel(api: api))
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

    static func makeAPI() -> LocalDayDoAPI {
        let dir = storageDirectory()
        if ProcessInfo.processInfo.arguments.contains("-DayDoReset") {
            try? FileManager.default.removeItem(at: dir)
            if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
        }
        do {
            let db = try AppDatabase.open(at: dir.appendingPathComponent("daydo.sqlite"))
            return LocalDayDoAPI(database: db, attachmentsDirectory: dir.appendingPathComponent("Attachments", isDirectory: true))
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
                    try? await model.api.bootstrap()
                    if ProcessInfo.processInfo.arguments.contains("-DayDoDemo") {
                        try? await DemoData.load(into: model.api)
                    }
                    await model.didWrite()
                    model.ready = true
                    await DebugLaunch.apply(to: model)
                }
                // Day boundaries: re-read when returning to the app or when the
                // date changes, so 今天／逾期 never show yesterday's view.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active && model.ready { Task { await model.didWrite() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    if model.ready { Task { await model.didWrite() } }
                }
        }
    }
}

/// Schedules local notifications for the next reminders (iOS keeps at most
/// 64 pending requests per app, so only the nearest ones are registered).
actor ReminderScheduler {
    private var authorized: Bool?

    func reschedule(api: LocalDayDoAPI) async {
        let center = UNUserNotificationCenter.current()
        guard let upcoming = try? await api.upcomingReminders(limit: 60) else { return }
        if authorized == nil {
            authorized = upcoming.isEmpty ? nil : ((try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false)
        }
        guard authorized == true else { return }
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

/// `-DayDoScreen <name>` opens a screen directly (used for screenshots).
@MainActor
enum DebugLaunch {
    static func apply(to model: AppModel) async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-DayDoScreen"), i + 1 < args.count else { return }
        let screen = args[i + 1]
        if args.contains("-DayDoCompact") { model.compact = true }
        let tasks = (try? await model.api.searchTasks(text: "簡報", activeOnly: true)) ?? []
        switch screen {
        case "drawer": model.drawerOpen = true
        case "calendar": model.tab = .calendar
        case "events": UserDefaults.standard.set("month", forKey: "calendarViewMode"); model.tab = .calendar
        case "week": UserDefaults.standard.set("week", forKey: "calendarViewMode"); model.tab = .calendar
        case "search": model.tab = .search
        case "shared": model.tab = .shared
        case "detail", "date", "time":
            model.detailTaskId = tasks.first?.id
            if screen != "detail" { UserDefaults.standard.set(screen, forKey: "debugDetailPage") }
        case "editlist": model.editingProjectId = model.projects.first { !$0.isInbox }?.id
        case "compose": model.composing = ComposeRequest(day: model.today)
        case "settings": model.showSettings = true
        default: break
        }
    }
}
