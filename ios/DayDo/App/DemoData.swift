import Foundation
import DayDoCore

/// The sample data from the design boards, placed relative to today. Loaded
/// on demand from Settings (and with `-DayDoDemo` for screenshots).
enum DemoData {
    static func load(into api: LocalDayDoAPI) async throws {
        let today = api.clock.today
        func d(_ offset: Int) -> LocalDay { today.adding(days: offset) }
        func t(_ offset: Int, _ s: Int, _ e: Int?) -> Schedule { .timed(d(offset), start: s, end: e, timeZone: TimeZone.current.identifier) }

        var projects = try await api.listProjects(includeArchived: false)
        func list(_ name: String, _ color: String, folder: String?) async throws -> String {
            if var p = projects.first(where: { $0.name == name }) {
                if p.folderId != folder {
                    var u = UpdateProjectInput(projectId: p.id)
                    u.folderId = folder.map { .set($0) } ?? .clear
                    p = try await api.updateProject(u)
                }
                return p.id
            }
            let p = try await api.createProject(CreateProjectInput(name: name, color: color, folderId: folder))
            projects.append(p)
            return p.id
        }
        let wf = try await api.createFolder(name: "工作與學習").id
        let life = try await api.createFolder(name: "生活").id
        let work = try await list("工作", "#4AA8E8", folder: wf)
        let study = try await list("學習", "#4FC3A1", folder: wf)
        let personal = try await list("個人", "#E98A5B", folder: life)
        let shop = try await list("購物", "#C77DDB", folder: life)
        let ours = try await list("我們的行程", "#E8C14E", folder: nil)

        func add(_ title: String, _ note: String = "", _ project: String, _ p: Priority = .none, _ s: Schedule?, rem: [String] = [], subs: [String] = [], tags: [String] = [], rep: String? = nil) async throws -> TodoTask {
            try await api.createTask(CreateTaskInput(projectId: project, title: title, content: note, priority: p, schedule: s, reminders: rem, repeat: rep, subtasks: subs, tags: tags))
        }
        _ = try await add("回覆客戶報價信，並附上修訂後的合約條款與付款時程說明", "確認折扣條件後再寄出，副本給主管", work, .high, t(-1, 1020, nil), tags: ["客戶"])
        let brief = try await add("準備週一產品會議簡報", "重點放在 Q4 上線時程與待決事項。簡報檔放在共用雲端「產品會議」資料夾，會前一天寄給與會者預讀。", work, .high, t(0, 1080, 1110),
                                  rem: ["TRIGGER:-PT15M"], subs: ["整理上週數據", "更新路線圖頁面", "預演一次 10 分鐘版本"], tags: ["會議", "Q4"])
        _ = try await api.updateChecklistItem(id: brief.items[0].id, title: nil, done: true)
        _ = try await add("花蓮小旅行", "火車票已訂，民宿待確認", ours, .none, .allDay(d(-2), through: d(1)))
        _ = try await add("去全聯買菜", "", shop, .medium, .allDay(d(0)))
        _ = try await add("晚餐：巷口火鍋", "記得先訂位，四個人", ours, .none, t(0, 1140, 1260))
        _ = try await add("健身房 — 腿部訓練", "深蹲 5×5、硬舉 3×5、伸展 10 分鐘", personal, .low, t(0, 1170, 1230))
        _ = try await add("週會", "", work, .low, t(1, 600, 660), rep: "RRULE:FREQ=WEEKLY")
        _ = try await add("繳信用卡帳單", "", personal, .medium, .allDay(d(1)))
        _ = try await add("Day 3｜Two Pointers 練習", "完成 3 題，記錄是否使用提示與解題時間", study, .medium, t(1, 1260, 1320), tags: ["刷題"])
        let dentist = try await add("預約牙醫洗牙", "", personal, .none, .allDay(d(0)))
        _ = try await api.completeTask(id: dentist.id)
        let club = try await add("讀書會", "", study, .none, t(-4, 1200, 1290))
        _ = try await api.completeTask(id: club.id)
        _ = try await add("小安 台中出差", "", ours, .none, .allDay(d(2), through: d(4)))
        _ = try await add("交 Q4 報告", "", work, .high, .allDay(d(5)))
        _ = try await add("媽媽生日", "訂蛋糕、買花", ours, .none, .allDay(d(7)))
        _ = try await add("年度健康檢查", "前一晚 10 點後禁食", personal, .none, t(12, 540, 660))
        _ = try await add("搬家整理：打包書櫃", "", ours, .none, .allDay(d(13), through: d(14)))
        _ = try await add("買咖啡豆", "", shop, .none, nil)
        _ = try await add("整理 Q1 OKR 草稿", "", api.listProjects(includeArchived: false).first(where: \.isInbox)!.id, .none, nil)
        _ = study
    }
}
