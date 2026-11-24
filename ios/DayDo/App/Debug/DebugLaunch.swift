import MachO
import os
import GoogleSignIn
import SwiftUI
import UIKit
import UserNotifications
import DayDoCore

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
        case "day": model.defaults.set("day", forKey: "calendarViewMode"); model.tab = .calendar
        case "events": model.defaults.set("month", forKey: "calendarViewMode"); model.tab = .calendar
        case "week": model.defaults.set("week", forKey: "calendarViewMode"); model.tab = .calendar
        case "search": model.tab = .search
        case "detail", "date", "time":
            if screen != "detail" { model.defaults.set(screen, forKey: "debugDetailPage") }
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
