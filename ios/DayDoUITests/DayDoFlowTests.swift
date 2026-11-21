import XCTest

/// Drives the real app on the simulator through the main flows from the
/// design boards. Screenshots are kept as attachments (and written to
/// $DAYDO_SHOTS when set) for comparison with `design/shots`.
final class DayDoFlowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin"]
        addUIInterruptionMonitor(withDescription: "notifications") { alert in
            let allow = alert.buttons["允許"].exists ? alert.buttons["允許"] : alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        app.launch()
    }

    func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["DAYDO_SHOTS"] {
            // The directory is caller-supplied and often does not exist yet; a silent skip here once
            // left a whole run without screenshots.
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            } catch {
                XCTFail("DAYDO_SHOTS: could not write \(name).png to \(dir): \(error)")
            }
        }
    }

    func dayString(offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    func dismissNotificationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["允許"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    @MainActor
    func testTodayCompleteAndDrawer() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        let row = app.buttons["完成：去全聯買菜"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let todayBrief = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報' AND NOT (label BEGINSWITH '完成：')")).firstMatch
        XCTAssertTrue(todayBrief.label.contains("工作"), "Mixed-list views keep the list name: \(todayBrief.label)")
        shot("01-today")
        row.tap()
        // The row leaves 今天 and goes to the (collapsed) 已完成 section.
        XCTAssertTrue(app.buttons["完成：去全聯買菜"].waitForNonExistence(timeout: 3))
        // Under the 明天 header a row shows only its time, not "明天" again.
        let scroll = app.scrollViews.firstMatch
        let weekly = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '週會' AND label CONTAINS '10:00'")).firstMatch
        for _ in 0..<4 where !weekly.exists {
            scroll.swipeUp()
        }
        XCTAssertTrue(weekly.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(weekly.label.contains("明天"), weekly.label)
        let completedHeader = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '已完成'")).firstMatch
        for _ in 0..<4 where !completedHeader.isHittable {
            scroll.swipeUp()
        }
        completedHeader.tap()
        let uncompleteRow = app.buttons["取消完成：去全聯買菜"]
        for _ in 0..<3 where !uncompleteRow.exists {
            scroll.swipeUp()
        }
        XCTAssertTrue(uncompleteRow.waitForExistence(timeout: 3))

        // Density toggle → compact (1c) via ⋯ menu
        app.buttons["更多選項"].tap()
        let hideDetails = app.buttons["隱藏詳情"]
        XCTAssertTrue(hideDetails.waitForExistence(timeout: 3))
        shot("01b-task-menu")
        hideDetails.tap()
        shot("02-today-compact")
        app.buttons["更多選項"].tap()
        let showDetails = app.buttons["顯示詳情"]
        XCTAssertTrue(showDetails.waitForExistence(timeout: 3))
        showDetails.tap()

        // Drawer (1a): expand folder, pick a list
        app.buttons["開啟清單抽屜"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '工作與學習'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.tap()
        shot("03-drawer")
        let work = app.buttons["drawer.list.工作"]
        XCTAssertTrue(work.waitForExistence(timeout: 3))
        work.tap()
        XCTAssertTrue(app.staticTexts["工作"].waitForExistence(timeout: 3))
        // Rows inside a single list don't repeat the list name the title already shows.
        let brief = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報' AND NOT (label BEGINSWITH '完成：')")).firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(brief.label.contains("工作"), brief.label)
        shot("04-list-work")

        // 未來 7 天 groups by day; rows under a day header show only the time.
        app.buttons["開啟清單抽屜"].tap()
        let next7 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '未來 7 天'")).firstMatch
        XCTAssertTrue(next7.waitForExistence(timeout: 3), app.debugDescription)
        next7.tap()
        let weeklyNext7 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '週會' AND label CONTAINS '10:00'")).firstMatch
        if !weeklyNext7.waitForExistence(timeout: 2) {
            for _ in 0..<4 where !weeklyNext7.exists {
                app.scrollViews.firstMatch.swipeUp()
            }
        }
        XCTAssertTrue(weeklyNext7.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(weeklyNext7.label.contains("明天"), weeklyNext7.label)
        shot("04b-next7")

        app.buttons["開啟清單抽屜"].tap()
        let inbox = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '收件匣'")).firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 3), app.debugDescription)
        inbox.tap()
        XCTAssertTrue(app.staticTexts["收件匣"].waitForExistence(timeout: 3), app.debugDescription)
        shot("04c-inbox")
    }

    @MainActor
    func testDetailDateAndTimeBlock() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        let title = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).element(boundBy: 1)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        let save = app.buttons["儲存"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled, "儲存 is disabled until something changes")
        shot("05-detail-half")

        // Edit the title → 儲存 lights up, then commit.
        let field = app.descendants(matching: .any)["taskTitleField"]
        field.tap()
        field.typeText("（v2）")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["已儲存"].waitForExistence(timeout: 3))

        // Expand to full and check a subtask.
        app.buttons["展開為全屏"].tap()
        app.buttons["完成：更新路線圖頁面"].tap()
        XCTAssertTrue(app.staticTexts["2 / 3"].waitForExistence(timeout: 3))
        shot("06-detail-full")

        // Date panel: pick tomorrow in the calendar, switch to 持續時間, open timeline.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '設定日期與時間'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["確定"].waitForExistence(timeout: 3))
        shot("07-date-panel")
        let tomorrow = app.buttons["monthDay.\(dayString(offset: 1))"].firstMatch
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 3), app.debugDescription)
        tomorrow.tap()
        app.buttons["durationTab"].tap()

        // Time block: open timeline and drag the block down by ~60 min (18:00 -> 19:00).
        let openTimeline = app.buttons["openTimeline"]
        XCTAssertTrue(openTimeline.waitForExistence(timeout: 3))
        sleep(1)
        shot("08-date-duration")
        openTimeline.tap()
        let block = app.otherElements["正在編輯的時間區塊，可拖曳移動或調整起訖"]
        XCTAssertTrue(block.waitForExistence(timeout: 3))
        let start = block.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        // Quick drag over the block scrolls instead of moving it.
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)))
        XCTAssertTrue(app.staticTexts["18:00 – 18:30"].waitForExistence(timeout: 2))
        // Long press (~0.3s+) then drag moves the block.
        start.press(forDuration: 0.4, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 65)))
        sleep(1)
        shot("09-time-block")
        XCTAssertTrue(app.staticTexts["19:00 – 19:30"].waitForExistence(timeout: 3), app.debugDescription)
        // End handle past midnight is covered by unit tests; save and confirm.
        app.buttons["儲存"].tap()
        XCTAssertTrue(app.buttons["確定"].waitForExistence(timeout: 3))
        app.buttons["確定"].tap()
        let updatedDate = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '設定日期與時間' AND label CONTAINS '19:00 – 19:30'")).firstMatch
        XCTAssertTrue(updatedDate.waitForExistence(timeout: 3), app.debugDescription)
        shot("10-detail-after-date")

        // Dismiss detail sheet and scroll to the moved row under 明天 in the lazy task list.
        let collapseBtn = app.buttons["收合為半屏"]
        if collapseBtn.exists {
            collapseBtn.tap()
        }
        let expandBtn = app.buttons["展開為全屏"]
        XCTAssertTrue(expandBtn.waitForExistence(timeout: 3), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(expandBtn.waitForNonExistence(timeout: 3), app.debugDescription)

        let updatedRow = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報' AND label CONTAINS '19:00 – 19:30'")).firstMatch
        let listScroll = app.scrollViews.firstMatch
        for _ in 0..<4 where !updatedRow.exists {
            listScroll.swipeUp()
        }
        XCTAssertTrue(updatedRow.waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testCalendarViews() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        app.buttons["日曆"].tap()
        let title = app.buttons["calendarTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3), app.debugDescription)
        shot("11-calendar-list")

        for (mode, shotName) in [("月", "12-calendar-month"), ("週", "13-calendar-week"), ("日", "14-calendar-day"), ("年", "15-calendar-year")] {
            app.buttons["calendarMode"].tap()
            let item = app.buttons[mode].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Calendar mode \(mode) not found")
            item.tap()
            sleep(1)
            if mode == "週" || mode == "日" {
                let hour = Calendar.current.component(.hour, from: Date())
                // The grid opens two hours before now (CalendarScreen.initialHour).
                let first = String(format: "%02d", max(0, hour - 2))
                let label = app.staticTexts[first].firstMatch
                XCTAssertTrue(label.waitForExistence(timeout: 3) && label.isHittable, "\(mode): Hour \(first) should be hittable without scrolling")
                if hour > 14 {
                    let brief = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).firstMatch
                    XCTAssertTrue(brief.waitForExistence(timeout: 3) && brief.isHittable, "\(mode): 18:00 event should be hittable without scrolling")
                }
                if hour >= 5 {
                    XCTAssertFalse(app.staticTexts["01"].firstMatch.isHittable, "\(mode): TimeGrid should scroll past 01:00")
                }
            }
            shot(shotName)
        }
    }

    @MainActor
    func testCalendarAgendaRowsSkipDayAndListAlreadyShown() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        app.buttons["日曆"].tap()
        XCTAssertTrue(app.buttons["calendarTitle"].waitForExistence(timeout: 3), app.debugDescription)

        let now = Calendar.current.dateComponents([.month, .day], from: Date())
        let todayText = "\(now.month!)月\(now.day!)日"
        let brief = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報' AND NOT (label BEGINSWITH '完成：')")).firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 5), app.debugDescription)
        // The card header already names the day: rows show only the time, plus the list while unfiltered.
        XCTAssertTrue(brief.label.contains("18:00"), brief.label)
        XCTAssertFalse(brief.label.contains(todayText), brief.label)
        XCTAssertTrue(brief.label.contains("工作"), brief.label)
        shot("agenda-card-all-lists")

        app.buttons["切換為時間軸清單"].tap()
        XCTAssertTrue(app.buttons["切換為卡片清單"].waitForExistence(timeout: 3), app.debugDescription)
        shot("agenda-timeline-all-lists")
        app.buttons["切換為卡片清單"].tap()
        XCTAssertTrue(app.buttons["切換為時間軸清單"].waitForExistence(timeout: 3), app.debugDescription)

        app.buttons["更多選項"].tap()
        let filterMenu = app.buttons["清單篩選"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 3), app.debugDescription)
        filterMenu.tap()
        let work = app.buttons["工作"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 3), app.debugDescription)
        work.tap()
        XCTAssertTrue(app.buttons["移除清單篩選：工作"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(brief.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(brief.label.contains("工作"), brief.label)
        shot("agenda-card-list-filter")

        let timeline = app.buttons["切換為時間軸清單"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3), app.debugDescription)
        timeline.tap()
        XCTAssertTrue(app.buttons["切換為卡片清單"].waitForExistence(timeout: 3), app.debugDescription)
        let mmdd = String(format: "%02d-%02d", now.month!, now.day!)
        XCTAssertFalse(app.staticTexts[mmdd].exists, "Timeline rows should not repeat the day under its header")
        shot("agenda-timeline")
        app.buttons["切換為卡片清單"].tap()
    }

    @MainActor
    func testCreateTaskAndEditList() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        app.buttons["新增任務"].firstMatch.tap()
        let field = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("UI 測試新增的任務")
        shot("16-composer")
        app.buttons["新增"].tap()
        XCTAssertTrue(app.buttons["完成：UI 測試新增的任務"].waitForExistence(timeout: 3))

        // Composer stays open for quick capture; close it before opening the drawer.
        app.buttons["composerMore"].tap()
        app.buttons["關閉"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))

        app.buttons["開啟清單抽屜"].tap()
        app.buttons["新增清單或資料夾"].tap()
        app.buttons["新增清單"].tap()
        let name = app.textFields["清單名稱"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("旅行")
        shot("17a-edit-list-new")
        app.buttons["儲存"].tap()
        XCTAssertTrue(app.staticTexts["旅行"].waitForExistence(timeout: 3))
    }

    func testComposerDurationTask() {
        dismissNotificationPrompt()
        app.buttons["新增任務"].firstMatch.tap()
        let field = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("帶時間區段的任務")

        app.buttons["composerDate"].tap()
        XCTAssertTrue(app.buttons["確定"].waitForExistence(timeout: 3))
        app.buttons["durationTab"].tap()

        let allDay = app.switches["allDayToggle"].firstMatch
        XCTAssertTrue(allDay.waitForExistence(timeout: 3))
        allDay.tap()

        let chip = app.buttons["1 小時"]
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        chip.tap()
        shot("18-composer-duration")
        app.buttons["確定"].tap()

        XCTAssertTrue(app.buttons["新增"].waitForExistence(timeout: 3))
        app.buttons["新增"].tap()
        app.buttons["composerMore"].tap()
        app.buttons["關閉"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS '帶時間區段的任務' AND label CONTAINS '09:00 – 10:00'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), app.debugDescription)
        shot("19-task-with-duration")
    }

    @MainActor
    func testSearchDeleteAndRestore() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        app.buttons["搜尋"].firstMatch.tap()
        let field = app.textFields["搜尋任務、描述、標籤、子任務"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("訂位")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS '晚餐：巷口火鍋'")).element(boundBy: 1)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        shot("20-search")

        // Delete from the context menu, then restore from 垃圾桶.
        row.press(forDuration: 1.0)
        app.buttons["刪除"].tap()
        XCTAssertTrue(app.staticTexts["找不到「訂位」"].waitForExistence(timeout: 3))
        app.buttons["任務"].firstMatch.tap()
        app.buttons["開啟清單抽屜"].tap()
        app.buttons["垃圾桶"].tap()
        let trashed = app.buttons.matching(NSPredicate(format: "label CONTAINS '晚餐：巷口火鍋'")).element(boundBy: 0)
        XCTAssertTrue(trashed.waitForExistence(timeout: 3))
        shot("21-trash")
        trashed.press(forDuration: 1.0)
        app.buttons["還原"].tap()
        XCTAssertTrue(trashed.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testMultilineComposerYearTapAndArchive() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        // 1. Composer with a 3-line wrapping title keeps send button visible.
        app.buttons["新增任務"].firstMatch.tap()
        let field = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("這是一個會自動換行到第三行的長標題任務用來測試快速輸入面板的高度會隨著內容自動調整而不會遮擋下方按鈕")
        let send = app.buttons["新增"]
        XCTAssertTrue(send.waitForExistence(timeout: 3) && send.isHittable)
        shot("22-composer-multiline")
        app.buttons["composerMore"].tap()
        app.buttons["關閉"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))

        // 2. Year view tap a day -> opens day view at that date.
        app.buttons["日曆"].tap()
        let calMode = app.buttons["calendarMode"]
        XCTAssertTrue(calMode.waitForExistence(timeout: 3))
        calMode.tap()
        app.buttons["年"].firstMatch.tap()
        let todayCell = app.buttons["yearDay.\(dayString(offset: 0))"].firstMatch
        XCTAssertTrue(todayCell.waitForExistence(timeout: 3))
        todayCell.tap()
        let dayModeBtn = app.buttons["切換檢視：目前日"]
        XCTAssertTrue(dayModeBtn.waitForExistence(timeout: 3), app.debugDescription)
        sleep(1)
        shot("23-year-tap-day")

        // 3. Archive a list, inspect 已封存的清單 in Settings, and restore it.
        app.buttons["任務"].firstMatch.tap()
        app.buttons["開啟清單抽屜"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '工作與學習'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.tap()
        let work = app.buttons["drawer.list.工作"]
        XCTAssertTrue(work.waitForExistence(timeout: 3))
        work.tap()
        app.buttons["更多選項"].tap()
        app.buttons["編輯"].tap()
        let archiveBtn = app.buttons["歸檔清單"]
        XCTAssertTrue(archiveBtn.waitForExistence(timeout: 3))
        archiveBtn.tap()

        app.buttons["設定"].firstMatch.tap()
        let archivedRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '已封存的清單'")).firstMatch
        XCTAssertTrue(archivedRow.waitForExistence(timeout: 3), app.debugDescription)
        archivedRow.tap()
        let unarchiveBtn = app.buttons["取消封存"].firstMatch
        XCTAssertTrue(unarchiveBtn.waitForExistence(timeout: 3), app.debugDescription)
        shot("24-archived")
        unarchiveBtn.tap()
        XCTAssertTrue(unarchiveBtn.waitForNonExistence(timeout: 3))
    }

    func testDayAllDayManyScrolls() {
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin", "-DayDoSeedManyAllDay", "-DayDoScreen", "day"]
        app.launch()
        dismissNotificationPrompt()

        let dayModeBtn = app.buttons["切換檢視：目前日"]
        XCTAssertTrue(dayModeBtn.waitForExistence(timeout: 5), app.debugDescription)
        let firstSeeded = app.buttons["全天壓測 1"].firstMatch
        XCTAssertTrue(firstSeeded.waitForExistence(timeout: 3), app.debugDescription)
        let lastSeeded = app.buttons["全天壓測 8"].firstMatch
        XCTAssertTrue(lastSeeded.exists)
        // Verify time grid stays visible below the capped 4-lane all-day strip.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH '空白時段，點兩下新增'")).firstMatch.isHittable)
        shot("25-day-allday-many")
    }

    @MainActor
    func testSettingsTabAndAppearance() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        app.buttons["設定"].firstMatch.tap()
        let appearance = app.buttons["外觀"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 3), app.debugDescription)
        shot("26-settings")
        appearance.tap()
        XCTAssertTrue(app.staticTexts["主題色"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["列表密度"].waitForExistence(timeout: 3))
        shot("27-settings-appearance")
    }

    @MainActor
    func testAllViewShowsTasksBeyondNextSevenDays() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        // 搬家整理 starts 13 days out, so 今天 and 未來 7 天 never show it.
        XCTAssertFalse(app.staticTexts["搬家整理：打包書櫃"].exists)
        app.buttons["開啟清單抽屜"].tap()
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '全部'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 3))
        // Read the badge before the tap closes the drawer.
        let badge = all.label.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        XCTAssertFalse(badge.isEmpty, all.label)
        all.tap()
        XCTAssertTrue(app.staticTexts["全部"].waitForExistence(timeout: 3))
        // Header count matches the drawer badge even though 花蓮小旅行 spans 今天 and 明天.
        XCTAssertTrue(app.staticTexts["\(badge) 項待辦"].waitForExistence(timeout: 3), "drawer badge \(badge) vs header")
        let laterHeader = app.staticTexts["之後"]
        for _ in 0..<3 where !laterHeader.exists { app.swipeUp() }
        XCTAssertTrue(laterHeader.waitForExistence(timeout: 3))
        let far = app.staticTexts["搬家整理：打包書櫃"]
        for _ in 0..<4 where !far.exists { app.swipeUp() }
        XCTAssertTrue(far.waitForExistence(timeout: 3))
        shot("50-all-view")
    }

    @MainActor
    func testDrawerSwipePinAndDelete() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        app.buttons["開啟清單抽屜"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '工作與學習'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.tap()

        let work = app.buttons["drawer.list.工作"]
        let study = app.buttons["drawer.list.學習"]
        XCTAssertTrue(work.waitForExistence(timeout: 3))
        XCTAssertTrue(study.waitForExistence(timeout: 3))
        XCTAssertLessThan(work.frame.minY, study.frame.minY)

        // Short left swipe -> 1 button (刪除)
        let start = study.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -60, dy: 0)))
        XCTAssertTrue(app.buttons["刪除"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["編輯"].exists)
        XCTAssertFalse(app.buttons["置頂"].exists)
        shot("28a-drawer-swipe-1")

        // Swipe further left -> all 3 buttons (置頂, 編輯, 刪除)
        let start2 = study.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start2.press(forDuration: 0.05, thenDragTo: start2.withOffset(CGVector(dx: -130, dy: 0)))
        let pin = app.buttons["置頂"]
        XCTAssertTrue(pin.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["編輯"].exists)
        XCTAssertTrue(app.buttons["刪除"].exists)
        shot("28-drawer-swipe")

        // Tap 置頂 -> 學習 moves to top of 工作與學習 folder (above 工作)
        pin.tap()
        let movedUp = NSPredicate { _, _ in
            study.exists && work.exists && study.frame.minY < work.frame.minY
        }
        let exp = XCTNSPredicateExpectation(predicate: movedUp, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed)

        // Swipe -> 刪除 -> confirm removes 學習
        let start3 = study.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
        start3.press(forDuration: 0.05, thenDragTo: start3.withOffset(CGVector(dx: -70, dy: 0)))
        let del = app.buttons["刪除"]
        XCTAssertTrue(del.waitForExistence(timeout: 3), app.debugDescription)
        del.tap()
        let confirm = app.buttons["刪除清單"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(study.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testShareListInviteAndEditMembers() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        app.buttons["開啟清單抽屜"].tap()
        XCTAssertTrue(app.staticTexts["我"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["drawer.settings"].exists)
        shot("34-drawer-header")

        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '工作與學習'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.tap()
        let work = app.buttons["drawer.list.工作"]
        XCTAssertTrue(work.waitForExistence(timeout: 3))
        work.tap()

        // Project ⋯ menu: inspect top-level items + 更多 submenu.
        app.buttons["更多選項"].tap()
        XCTAssertTrue(app.buttons["編輯"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["視圖"].exists)
        XCTAssertTrue(app.buttons["更多"].exists)
        shot("32-list-menu")
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["共享協作"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["分享"].exists)
        XCTAssertTrue(app.buttons["複製清單"].exists)
        shot("33-list-menu-more")
        app.buttons["複製清單"].tap()
        XCTAssertTrue(app.staticTexts["工作 副本"].waitForExistence(timeout: 3), app.debugDescription)

        // Open EditListSheet on existing list (工作 副本): check 清單顏色/視圖類型/成員數量/轉移擁有者/歸檔/刪除.
        app.buttons["更多選項"].tap()
        XCTAssertTrue(app.buttons["編輯"].waitForExistence(timeout: 3))
        app.buttons["編輯"].tap()
        XCTAssertTrue(app.staticTexts["清單顏色"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["視圖類型"].exists)
        let membersRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '成員數量'")).firstMatch
        XCTAssertTrue(membersRow.exists, app.debugDescription)
        let transferRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '轉移清單擁有者'")).firstMatch
        XCTAssertTrue(transferRow.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["歸檔清單"].exists)
        XCTAssertTrue(app.buttons["刪除清單"].exists)
        shot("17-edit-list")

        // 轉移清單擁有者 empty state when no other members exist.
        transferRow.tap()
        XCTAssertTrue(app.staticTexts["目前沒有其他成員"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons.matching(NSPredicate(format: "label == '取消'")).element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["目前沒有其他成員"].waitForNonExistence(timeout: 3))

        // Edit the list name, open 成員數量 -> ShareListSheet, close sharing, verify draft survives and saves.
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.exists, app.debugDescription)
        let beforeName = (nameField.value as? String) ?? ""
        nameField.tap()
        nameField.typeText("X")
        let editedName = (nameField.value as? String) ?? ""
        XCTAssertNotEqual(editedName, beforeName)
        XCTAssertTrue(editedName.contains("X"), editedName)

        membersRow.tap()
        XCTAssertTrue(app.staticTexts["共享清單"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["共享清單"].waitForNonExistence(timeout: 3))
        XCTAssertEqual((nameField.value as? String) ?? "", editedName)
        app.buttons["儲存"].tap()
        XCTAssertTrue(app.staticTexts["編輯清單"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[editedName].waitForExistence(timeout: 3), app.debugDescription)

        // Open ShareListSheet via toolbar 共享 button.
        let shareBtn = app.buttons["共享"]
        XCTAssertTrue(shareBtn.waitForExistence(timeout: 3), app.debugDescription)
        shareBtn.tap()
        XCTAssertTrue(app.staticTexts["共享清單"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["所有者"].exists)
        XCTAssertTrue(app.staticTexts["我（你）"].exists)
        XCTAssertTrue(app.staticTexts["邀請連結"].exists)
        XCTAssertTrue(app.buttons["share.createInviteLink"].waitForExistence(timeout: 3), app.debugDescription)
        shot("29-share-sheet")

        // Create preview invite link under skip-login and verify ShareLink / copy / revoke render.
        app.buttons["share.createInviteLink"].tap()
        XCTAssertTrue(app.staticTexts["daydo://invite/preview"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["share.shareLink"].exists)
        XCTAssertTrue(app.buttons["share.copyLink"].exists)
        XCTAssertTrue(app.buttons["share.revokeLink"].exists)
        shot("30-share-invite")

        app.buttons["share.revokeLink"].tap()
        XCTAssertTrue(app.buttons["share.createInviteLink"].waitForExistence(timeout: 3))

        // Close ShareListSheet, verify 視圖 submenu updates viewMode, then Drawer gear -> Settings tab.
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["共享清單"].waitForNonExistence(timeout: 3))
        app.buttons["更多選項"].tap()
        let viewMenu = app.buttons["視圖"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 3))
        viewMenu.tap()
        let kanbanItem = app.buttons["看板"]
        XCTAssertTrue(kanbanItem.waitForExistence(timeout: 3))
        kanbanItem.tap()

        app.buttons["更多選項"].tap()
        XCTAssertTrue(app.buttons["編輯"].waitForExistence(timeout: 3))
        app.buttons["編輯"].tap()
        let kanbanOption = app.buttons["看板"]
        XCTAssertTrue(kanbanOption.waitForExistence(timeout: 3))
        XCTAssertTrue(kanbanOption.isSelected)
        app.buttons["取消"].tap()
        XCTAssertTrue(kanbanOption.waitForNonExistence(timeout: 3))

        app.buttons["設定"].firstMatch.tap()
        XCTAssertTrue(app.buttons["外觀"].waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testLaunchSplashHeld() {
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoHoldSplash"]
        app.launch()

        let splash = app.otherElements["splash.overlay"]
        XCTAssertTrue(splash.waitForExistence(timeout: 5), app.debugDescription)
        shot("00-splash")
    }

    @MainActor
    func testSignInScreenShownWhenSignedOut() {
        app.terminate()
        app.launchArguments = ["-DayDoReset"]
        app.launch()

        let appleButton = app.buttons["signIn.apple"]
        XCTAssertTrue(appleButton.waitForExistence(timeout: 5), app.debugDescription)
        let googleButton = app.buttons["signIn.google"]
        XCTAssertTrue(googleButton.waitForExistence(timeout: 3), app.debugDescription)
        shot("35-sign-in")
    }

    @MainActor
    func testSettingsAccountAndInviteConfirmSheets() {
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin", "-DayDoDebugAccount", "-DayDoScreen", "settings"]
        app.launch()
        dismissNotificationPrompt()

        let signOutButton = app.buttons["settings.signOut"]
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["settings.joinInvite"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["加入共享清單"].exists, app.debugDescription)
        shot("36-settings-account")

        signOutButton.tap()
        let confirmTitle = app.staticTexts["確定要登出？"]
        XCTAssertTrue(confirmTitle.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '尚未同步的變更'")).firstMatch.exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(confirmTitle.waitForNonExistence(timeout: 3), app.debugDescription)

        app.open(URL(string: "daydo://invite/preview")!)
        XCTAssertTrue(app.staticTexts["小安 邀請你加入「家庭採買」"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["invite.accept"].exists)
        app.buttons["關閉"].tap()
        XCTAssertTrue(app.staticTexts["清單邀請"].waitForNonExistence(timeout: 3))

        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin", "-DayDoScreen", "invite"]
        app.launch()
        dismissNotificationPrompt()

        XCTAssertTrue(app.staticTexts["小安 邀請你加入「家庭採買」"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["invite.accept"].exists)
        shot("37-invite-confirm")
    }

    @MainActor
    func testInviteConfirmLoadingToLoadedAndCancelError() {
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoScreen", "settings"]
        app.launch()
        dismissNotificationPrompt()

        let accountRow = app.buttons["settings.accountRow"]
        XCTAssertTrue(accountRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["settings.joinInvite"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["加入共享清單"].exists, app.debugDescription)

        // 1. loading -> loaded updates in place without closing/reopening the sheet.
        app.open(URL(string: "daydo://invite/slow-ok")!)
        XCTAssertTrue(app.staticTexts["正在讀取邀請資訊…"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["小安 邀請你加入「家庭採買」"].waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertEqual(app.staticTexts["清單邀請"].value as? String, "appear:1", "Sheet should not dismiss and reopen during loading -> loaded")
        app.buttons["關閉"].tap()
        XCTAssertTrue(app.staticTexts["清單邀請"].waitForNonExistence(timeout: 3))

        // 2. Closing during loading suppresses generic (404) error from reopening the sheet.
        app.open(URL(string: "daydo://invite/slow-404")!)
        XCTAssertTrue(app.staticTexts["正在讀取邀請資訊…"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["關閉"].tap()
        XCTAssertTrue(app.staticTexts["清單邀請"].waitForNonExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(app.staticTexts["清單邀請"].exists, "Closed invite sheet should not reopen on 404 error")

        // 3. Closing during loading suppresses SyncError.retryable (500) from reopening the sheet.
        app.open(URL(string: "daydo://invite/slow-500")!)
        XCTAssertTrue(app.staticTexts["正在讀取邀請資訊…"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["關閉"].tap()
        XCTAssertTrue(app.staticTexts["清單邀請"].waitForNonExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(app.staticTexts["清單邀請"].exists, "Closed invite sheet should not reopen on SyncError.retryable")
    }

    @MainActor
    func testSmartTodayOverdueViewerOnlyHidesPostpone() {
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoSeedViewerOverdueOnly"]
        app.launch()
        dismissNotificationPrompt()

        XCTAssertTrue(app.staticTexts["已逾期"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '唯讀逾期任務'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["全部延到今天"].exists, "Viewer-only overdue section should hide 全部延到今天")

        app.buttons["更多選項"].tap()
        XCTAssertTrue(app.buttons["隱藏詳情"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["全部延到今天"].exists, "Toolbar menu should hide 全部延到今天 when no editable overdue tasks exist")
    }

    @MainActor
    func testSmartTodayOverdueMixedPostponesOnlyEditable() {
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoDebugStub", "-DayDoSeedViewerOverdue"]
        app.launch()
        dismissNotificationPrompt()

        XCTAssertTrue(app.staticTexts["已逾期"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '唯讀逾期任務'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '回覆客戶報價信'")).firstMatch.exists)

        let postponeBtn = app.buttons["全部延到今天"]
        XCTAssertTrue(postponeBtn.waitForExistence(timeout: 3), app.debugDescription)
        postponeBtn.tap()

        // Only the editable task should move to 今天; the viewer task remains in 已逾期 and 全部延到今天 hides.
        XCTAssertTrue(postponeBtn.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["已逾期"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '唯讀逾期任務'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '回覆客戶報價信'")).firstMatch.exists)
    }

    @MainActor
    func testEditListHidesTransferOwnerInSyncMode() {
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoDebugStub", "-DayDoScreen", "editlist"]
        app.launch()
        dismissNotificationPrompt()

        XCTAssertTrue(app.staticTexts["清單顏色"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '成員數量'")).firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["刪除清單"].exists, app.debugDescription)
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH '轉移清單擁有者'")).firstMatch.exists,
            "Sync mode should hide 轉移清單擁有者"
        )
    }

    @MainActor
    func testForcedSignOutSwitchAccountAlertCancelAndConfirm() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoDebugForcedSignOut"]
        app.launch()

        let googleButton = app.buttons["signIn.google"]
        XCTAssertTrue(googleButton.waitForExistence(timeout: 5), app.debugDescription)
        googleButton.tap()

        let alertMsg = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '這支手機上還有另一個帳號的資料。要清除這些資料並改用這個帳號登入嗎？'")
        ).firstMatch
        XCTAssertTrue(alertMsg.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '其中 1 筆修改還沒同步，會一併刪除'")).firstMatch.exists,
            app.debugDescription
        )

        app.buttons["取消"].tap()
        XCTAssertTrue(alertMsg.waitForNonExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(googleButton.exists, "Cancel should keep user on sign-in screen")

        googleButton.tap()
        XCTAssertTrue(alertMsg.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["清除並登入"].tap()

        dismissNotificationPrompt()
        XCTAssertTrue(app.buttons["開啟清單抽屜"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label CONTAINS '舊帳號未同步任務'")).firstMatch.exists,
            "Old account local data should be wiped after switching accounts"
        )
    }

    @MainActor
    func testTaskDetailPerFieldEditPreservesRemoteContentOnSave() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoDebugRemoteContentUpdate"]
        app.launch()
        dismissNotificationPrompt()

        let taskRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '同步測試任務' AND NOT (label BEGINSWITH '完成：')")
        ).firstMatch
        XCTAssertTrue(taskRow.waitForExistence(timeout: 5), app.debugDescription)
        taskRow.tap()

        let titleField = app.descendants(matching: .any)["taskTitleField"]
        let contentField = app.descendants(matching: .any)["taskContentField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(contentField.exists, app.debugDescription)
        XCTAssertEqual(contentField.value as? String, "初始描述")

        titleField.tap()
        titleField.typeText("（已改）")

        let checklistBtn = app.buttons["完成：觸發同步子任務"]
        XCTAssertTrue(checklistBtn.waitForExistence(timeout: 3), app.debugDescription)
        checklistBtn.tap()

        let remoteContentArrived = NSPredicate { _, _ in
            (contentField.value as? String) == "遠端更新後的描述"
        }
        let exp = XCTNSPredicateExpectation(predicate: remoteContentArrived, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(((titleField.value as? String) ?? "").contains("（已改）"))

        let saveBtn = app.buttons["儲存"]
        XCTAssertTrue(saveBtn.isEnabled)
        saveBtn.tap()
        XCTAssertTrue(app.buttons["已儲存"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(contentField.value as? String, "遠端更新後的描述")

        // Dismiss from the non-scrolling header and reopen to verify persisted state in SQLite.
        let headerBtn = app.buttons["展開為全屏"]
        let start = headerBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)))
        XCTAssertTrue(contentField.waitForNonExistence(timeout: 3), app.debugDescription)

        let updatedRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '（已改）' AND label CONTAINS '同步測試任務' AND NOT (label BEGINSWITH '完成：')")
        ).firstMatch
        XCTAssertTrue(updatedRow.waitForExistence(timeout: 5), app.debugDescription)
        updatedRow.tap()
        XCTAssertTrue(contentField.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(contentField.value as? String, "遠端更新後的描述")
        XCTAssertTrue(((titleField.value as? String) ?? "").contains("（已改）"))
    }

    @MainActor
    func testMeNamePromptAndSettingsEdit() {
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoDebugKeepDefaultName", "-DayDoScreen", "settings"]
        app.launch()
        dismissNotificationPrompt()

        // 1. Name prompt appears when my name is still 「我」 and 完成 is disabled until non-empty.
        XCTAssertTrue(app.staticTexts["你的名字"].waitForExistence(timeout: 5), app.debugDescription)
        let nameField = app.textFields["meProfile.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual((nameField.value as? String) ?? "", "輸入你的名字")
        let submitBtn = app.buttons["meProfile.submit"]
        XCTAssertTrue(submitBtn.exists, app.debugDescription)
        XCTAssertFalse(submitBtn.isEnabled, "完成 should be disabled until name is non-empty")
        shot("39-name-prompt")

        nameField.tap()
        nameField.typeText("阿迪")
        let tealColorBtn = app.buttons["meProfile.color.#4FC3A1"]
        XCTAssertTrue(tealColorBtn.exists, app.debugDescription)
        tealColorBtn.tap()
        XCTAssertTrue(submitBtn.isEnabled)
        submitBtn.tap()

        XCTAssertTrue(app.staticTexts["你的名字"].waitForNonExistence(timeout: 3), app.debugDescription)

        // 2. Settings account row reflects saved name & initial, and opens edit sheet on tap.
        let accountRow = app.buttons["settings.accountRow"]
        XCTAssertTrue(accountRow.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(accountRow.label.contains("阿迪"), accountRow.label)
        XCTAssertTrue(accountRow.label.contains("阿"), accountRow.label)

        accountRow.tap()
        XCTAssertTrue(app.staticTexts["個人資料"].waitForExistence(timeout: 3), app.debugDescription)
        let editField = app.textFields["meProfile.nameField"]
        XCTAssertTrue(editField.waitForExistence(timeout: 3))
        XCTAssertEqual(editField.value as? String, "阿迪")
        shot("40-settings-edit-profile")

        let clearBtn = app.buttons["清除名字"]
        XCTAssertTrue(clearBtn.exists)
        clearBtn.tap()
        editField.tap()
        editField.typeText("Audi")
        let orangeColorBtn = app.buttons["meProfile.color.#E98A5B"]
        XCTAssertTrue(orangeColorBtn.exists)
        orangeColorBtn.tap()
        app.buttons["meProfile.submit"].tap()

        XCTAssertTrue(app.staticTexts["個人資料"].waitForNonExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(accountRow.label.contains("Audi"), accountRow.label)
        XCTAssertTrue(accountRow.label.contains("A"), accountRow.label)
    }

    @MainActor
    func testShareSheetTwoMembersShowsNamesColorsAndYouBadge() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoSeedSharedList"]
        app.launch()
        dismissNotificationPrompt()

        app.buttons["開啟清單抽屜"].tap()
        let sharedList = app.buttons["drawer.list.家庭採買"]
        XCTAssertTrue(sharedList.waitForExistence(timeout: 5), app.debugDescription)
        sharedList.tap()

        let shareBtn = app.buttons["共享"]
        XCTAssertTrue(shareBtn.waitForExistence(timeout: 3), app.debugDescription)
        shareBtn.tap()

        XCTAssertTrue(app.staticTexts["共享清單"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["測試者（你）"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["小安"].exists, app.debugDescription)

        let ownerAvatar = app.staticTexts["share.ownerAvatar"]
        let memberAvatar = app.staticTexts["share.memberAvatar.debug-other-member-1"]
        XCTAssertTrue(ownerAvatar.exists, app.debugDescription)
        XCTAssertTrue(memberAvatar.exists, app.debugDescription)
        XCTAssertNotEqual(ownerAvatar.label, memberAvatar.label)
        XCTAssertNotEqual(ownerAvatar.value as? String, memberAvatar.value as? String)
        shot("41-share-sheet-two-members")
    }

    @MainActor
    func testShareSheetShowsMemberAvatarPhotoAndInitialFallback() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoSeedSharedList", "-DayDoSeedAvatarPhoto"]
        app.launch()
        dismissNotificationPrompt()

        let openDrawer = app.buttons["開啟清單抽屜"]
        XCTAssertTrue(openDrawer.waitForExistence(timeout: 5), app.debugDescription)
        openDrawer.tap()

        let sharedList = app.buttons["drawer.list.家庭採買"]
        XCTAssertTrue(sharedList.waitForExistence(timeout: 5), app.debugDescription)
        sharedList.tap()

        let shareBtn = app.buttons["共享"]
        XCTAssertTrue(shareBtn.waitForExistence(timeout: 3), app.debugDescription)
        shareBtn.tap()

        XCTAssertTrue(app.staticTexts["共享清單"].waitForExistence(timeout: 3), app.debugDescription)
        // Owner has no avatarUrl -> falls back to initial+color label
        let ownerAvatar = app.staticTexts["share.ownerAvatar"]
        XCTAssertTrue(ownerAvatar.waitForExistence(timeout: 3), app.debugDescription)
        // Co-member has bundled file:// DebugAvatar.png -> renders Image
        let memberPhoto = app.images["share.memberAvatar.debug-other-member-1"]
        XCTAssertTrue(memberPhoto.waitForExistence(timeout: 3), app.debugDescription)
        shot("42-share-sheet-avatar-photo")
    }

    @MainActor
    func testPendingInviteWaitsForMeNamePrompt() {
        // 1. Sign-in path: invite arrives while signed out, sign-in lacks displayName -> name prompt first, then invite confirm.
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoDebugSignedOut", "-DayDoDebugNoProviderName"]
        app.launch()

        let googleButton = app.buttons["signIn.google"]
        XCTAssertTrue(googleButton.waitForExistence(timeout: 5), app.debugDescription)
        app.open(URL(string: "daydo://invite/slow-ok")!)
        googleButton.tap()
        dismissNotificationPrompt()

        XCTAssertTrue(app.staticTexts["你的名字"].waitForExistence(timeout: 5), app.debugDescription)
        let nameField = app.textFields["meProfile.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3), app.debugDescription)
        nameField.tap()
        nameField.typeText("阿迪")
        app.buttons["meProfile.submit"].tap()

        XCTAssertTrue(app.staticTexts["你的名字"].waitForNonExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["小安 邀請你加入「家庭採買」"].waitForExistence(timeout: 6), app.debugDescription)
        app.buttons["關閉"].tap()
        XCTAssertTrue(app.staticTexts["清單邀請"].waitForNonExistence(timeout: 3), app.debugDescription)

        // 2. Launch/in-session path: invite arrives while required name prompt is already showing.
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoDebugKeepDefaultName"]
        app.launch()
        dismissNotificationPrompt()

        XCTAssertTrue(app.staticTexts["你的名字"].waitForExistence(timeout: 5), app.debugDescription)
        app.open(URL(string: "daydo://invite/slow-ok")!)

        let secondNameField = app.textFields["meProfile.nameField"]
        XCTAssertTrue(secondNameField.waitForExistence(timeout: 3), app.debugDescription)
        secondNameField.tap()
        secondNameField.typeText("阿迪")
        app.buttons["meProfile.submit"].tap()

        XCTAssertTrue(app.staticTexts["你的名字"].waitForNonExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["小安 邀請你加入「家庭採買」"].waitForExistence(timeout: 6), app.debugDescription)
    }

    @MainActor
    func testIPhoneShareActionsPresentSystemShareSheet() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        app.buttons["開啟清單抽屜"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '工作與學習'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3), app.debugDescription)
        folder.tap()
        let work = app.buttons["drawer.list.工作"]
        XCTAssertTrue(work.waitForExistence(timeout: 3), app.debugDescription)
        work.tap()

        // 1. Task-list more menu -> 更多 -> 分享
        app.buttons["更多選項"].tap()
        let moreSubmenu = app.buttons["更多"]
        XCTAssertTrue(moreSubmenu.waitForExistence(timeout: 3), app.debugDescription)
        moreSubmenu.tap()
        let shareMenuItem = app.buttons["分享"]
        XCTAssertTrue(shareMenuItem.waitForExistence(timeout: 3), app.debugDescription)
        shareMenuItem.tap()

        assertSystemShareSheetPresented(context: "iPhone task-list share menu")
        dismissSystemShareSheet()

        // 2. ShareListSheet -> 建立邀請連結 -> 分享邀請連結
        let shareBtn = app.buttons["共享"]
        XCTAssertTrue(shareBtn.waitForExistence(timeout: 3), app.debugDescription)
        shareBtn.tap()
        let createInvite = app.buttons["share.createInviteLink"]
        XCTAssertTrue(createInvite.waitForExistence(timeout: 3), app.debugDescription)
        createInvite.tap()
        let shareLinkBtn = app.buttons["share.shareLink"]
        XCTAssertTrue(shareLinkBtn.waitForExistence(timeout: 3), app.debugDescription)
        shareLinkBtn.tap()

        assertSystemShareSheetPresented(context: "iPhone ShareListSheet")
    }

    private func assertSystemShareSheetPresented(context: String, file: StaticString = #filePath, line: UInt = #line) {
        let activityList = app.otherElements["ActivityListView"]
        let copyAction = app.buttons.matching(NSPredicate(format: "label == '拷貝' OR label == 'Copy'")).firstMatch
        let closeAction = app.buttons.matching(NSPredicate(format: "label == '關閉' OR label == 'Close'")).firstMatch
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if activityList.exists || copyAction.exists || closeAction.exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected system share sheet (UIActivityViewController) for \(context)\n\(app.debugDescription)", file: file, line: line)
    }

    private func dismissSystemShareSheet() {
        let closeAction = app.buttons.matching(NSPredicate(format: "label IN {'關閉', 'Close', '完成', 'Done', '取消', 'Cancel'}")).firstMatch
        if closeAction.exists {
            closeAction.tap()
        } else if app.otherElements["PopoverDismissRegion"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        } else {
            app.swipeDown()
        }
        let activityList = app.otherElements["ActivityListView"]
        XCTAssertTrue(activityList.waitForNonExistence(timeout: 4), app.debugDescription)
    }

    @MainActor
    func testWidgetDeepLinkOpensTaskDetailAndTabs() {
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoSeedSharedList"]
        app.launch()
        dismissNotificationPrompt()

        // Ensure seeded shared task "買鮮奶" (id: debug-shared-task-1) has arrived.
        XCTAssertTrue(app.buttons["完成：買鮮奶"].waitForExistence(timeout: 5), app.debugDescription)

        // Switch away to Calendar first via widget calendar deep link.
        app.open(URL(string: "daydo://calendar")!)
        XCTAssertTrue(app.buttons["calendarTitle"].waitForExistence(timeout: 5), app.debugDescription)

        // Apply both member and project filters on Calendar, then open daydo://calendar/<today>
        // and verify filters reset to "全部" so tasks are not hidden.
        let memberChip = app.buttons["小安的"]
        XCTAssertTrue(memberChip.waitForExistence(timeout: 3), app.debugDescription)
        memberChip.tap()
        XCTAssertTrue(memberChip.isSelected)

        app.buttons["更多選項"].tap()
        let filterMenu = app.buttons["清單篩選"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 3), app.debugDescription)
        filterMenu.tap()
        let inboxFilter = app.buttons["收件匣"]
        XCTAssertTrue(inboxFilter.waitForExistence(timeout: 3), app.debugDescription)
        inboxFilter.tap()

        XCTAssertTrue(app.buttons["移除清單篩選：收件匣"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["完成：買鮮奶"].exists)

        app.open(URL(string: "daydo://calendar/\(dayString(offset: 0))")!)
        XCTAssertTrue(app.buttons["移除清單篩選：收件匣"].waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["全部"].isSelected)
        XCTAssertFalse(app.buttons["小安的"].isSelected)
        XCTAssertTrue(app.buttons["完成：買鮮奶"].waitForExistence(timeout: 5), app.debugDescription)

        // Open task detail via widget task deep link.
        app.open(URL(string: "daydo://task/debug-shared-task-1")!)
        let titleField = app.descendants(matching: .any)["taskTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), app.debugDescription)
        let titleValue = (titleField.value as? String) ?? ""
        XCTAssertTrue(titleValue.contains("買鮮奶"), "Expected task detail for 買鮮奶, got: \(titleValue)")

        // Dismiss detail and navigate back to Today via widget today deep link.
        let closeButton = app.buttons["關閉"]
        if closeButton.exists { closeButton.tap() }
        app.open(URL(string: "daydo://today")!)
        XCTAssertTrue(app.buttons["完成：買鮮奶"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testEdgeDragOpensDrawer() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        XCTAssertTrue(app.buttons["開啟清單抽屜"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["垃圾桶"].exists)

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let mid = window.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.5))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5))

        // Drag halfway, capture screenshot on the main runloop while held, then release (< 50% -> snaps back).
        nonisolated(unsafe) let testSelf = self
        let midShotTimer = Timer(timeInterval: 0.55, repeats: false) { _ in
            MainActor.assumeIsolated {
                testSelf.shot("46-drawer-half-drag")
            }
        }
        RunLoop.current.add(midShotTimer, forMode: .common)
        start.press(forDuration: 0.05, thenDragTo: mid, withVelocity: 300, thenHoldForDuration: 0.7)
        midShotTimer.invalidate()

        // Released before half -> snaps back closed; then drag past half -> opens drawer.
        XCTAssertTrue(app.buttons["垃圾桶"].waitForNonExistence(timeout: 2), app.debugDescription)
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(app.buttons["垃圾桶"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["drawer.settings"].exists)
        shot("47-drawer-edge-opened")
    }

    @MainActor
    func testEdgeDragFromThumbDistanceOpensDrawer() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()
        XCTAssertTrue(app.buttons["開啟清單抽屜"].waitForExistence(timeout: 5), app.debugDescription)
        // A real thumb starts ~30 pt in, over the task list; that must still open the drawer.
        let window = app.windows.firstMatch
        let startX = 30 / window.frame.width
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.45))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45))
        start.press(forDuration: 0.02, thenDragTo: end, withVelocity: 1200, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["垃圾桶"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["drawer.settings"].exists)
    }

    @MainActor
    func testOptimisticTaskCompletionUpdatesLabelThenMovesToCompleted() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        let checkbox = app.buttons["完成：去全聯買菜"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5), app.debugDescription)
        let completedHeader = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '已完成'")).firstMatch
        XCTAssertTrue(completedHeader.waitForExistence(timeout: 3))
        let initialDigits = completedHeader.label.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        let initialCount = Int(initialDigits) ?? -1
        XCTAssertGreaterThanOrEqual(initialCount, 0, "Expected numeric count in \(completedHeader.label)")
        shot("43-complete-before")

        // XCUITest's tap() spins the main runloop waiting for animation quiescence (~0.8-1s),
        // which outlasts the 350ms window. Observe the optimistic state safely on the main runloop.
        nonisolated(unsafe) var sawOptimistic = false
        nonisolated(unsafe) let testSelf = self
        nonisolated(unsafe) let optimisticUndo = app.buttons["取消完成：去全聯買菜"]
        let pollTimer = Timer(timeInterval: 0.08, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !sawOptimistic && optimisticUndo.exists {
                    sawOptimistic = true
                    testSelf.shot("44-complete-optimistic")
                }
            }
        }
        RunLoop.current.add(pollTimer, forMode: .common)

        checkbox.tap()
        pollTimer.invalidate()

        XCTAssertTrue(sawOptimistic || optimisticUndo.waitForExistence(timeout: 0.5), "Expected optimistic 取消完成 label within 350ms window")

        // After ~350ms write + reload, the row leaves the active section and 已完成 count increments.
        XCTAssertTrue(optimisticUndo.waitForNonExistence(timeout: 3), app.debugDescription)
        let expectedCount = "\(initialCount + 1)"
        let incremented = NSPredicate { _, _ in
            completedHeader.exists && completedHeader.label.contains(expectedCount)
        }
        let exp = XCTNSPredicateExpectation(predicate: incremented, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed, "Expected 已完成 count \(expectedCount), got: \(completedHeader.label)")
        shot("45-complete-after")
    }

    @MainActor
    func testCalendarHorizontalSwipeChangesMonth() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        app.buttons["日曆"].tap()
        let title = app.buttons["calendarTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3), app.debugDescription)
        let initialTitle = title.label

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.28))
        start.press(forDuration: 0.05, thenDragTo: end)

        let monthChanged = NSPredicate { _, _ in
            title.exists && title.label != initialTitle
        }
        let exp = XCTNSPredicateExpectation(predicate: monthChanged, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed, "Expected calendar title to change from \(initialTitle), got \(title.label)")

        let backStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.28))
        let backEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.28))
        backStart.press(forDuration: 0.05, thenDragTo: backEnd)

        let monthRestored = NSPredicate { _, _ in
            title.exists && title.label == initialTitle
        }
        let expBack = XCTNSPredicateExpectation(predicate: monthRestored, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expBack], timeout: 3), .completed, "Expected calendar title to return to \(initialTitle), got \(title.label)")
    }

    @MainActor
    func testCollapsedCalendarIgnoresTapsOnHiddenWeeks() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        app.buttons["日曆"].tap()
        let title = app.buttons["calendarTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3), app.debugDescription)

        // Pick day 12 of the current month so the selected week is never the first or last row.
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        let m = comps.month!
        let day12Label = "\(m)月12日"
        let day12Prefix = "\(m) 月 12 日"
        let day12Cell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", day12Prefix)).firstMatch
        XCTAssertTrue(day12Cell.waitForExistence(timeout: 3), app.debugDescription)
        day12Cell.tap()
        XCTAssertTrue(day12Cell.isSelected)
        let agendaHeading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", day12Label)).firstMatch
        XCTAssertTrue(agendaHeading.waitForExistence(timeout: 3), app.debugDescription)

        // Collapse to a single week via the handle.
        let collapseHandle = app.buttons["收合成單週"]
        XCTAssertTrue(collapseHandle.waitForExistence(timeout: 3), app.debugDescription)
        collapseHandle.tap()
        let expandHandle = app.buttons["展開整個月份"]
        XCTAssertTrue(expandHandle.waitForExistence(timeout: 3), app.debugDescription)

        // Tap 1: top edge of the weekday symbol header ("三") directly above the visible week,
        // where the hidden previous-week row sits if hit-testing isn't disabled.
        let wednesdayHeader = app.staticTexts["三"].firstMatch
        XCTAssertTrue(wednesdayHeader.waitForExistence(timeout: 3), app.debugDescription)
        wednesdayHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)).tap()
        XCTAssertTrue(expandHandle.exists, "Tap on weekday header should keep calendar collapsed")
        XCTAssertTrue(day12Cell.isSelected, "Tap on weekday header should not select a hidden week's day")
        XCTAssertTrue(agendaHeading.exists, "Agenda heading should remain on \(day12Label)")

        // Tap 2: in the gap right below the collapse handle (just above the agenda card),
        // where the hidden next-week row sits if hit-testing isn't disabled.
        let gapPoint = expandHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)).withOffset(CGVector(dx: 0, dy: 11))
        gapPoint.tap()
        XCTAssertTrue(day12Cell.isSelected, "Tap below collapse handle should not select a hidden week's day")
        XCTAssertTrue(agendaHeading.exists, "Agenda heading should remain on \(day12Label)")
    }

    @MainActor
    func testAppearanceSwitchDarkToSystemToLightWithSheet() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        app.buttons["設定"].firstMatch.tap()
        let appearanceRow = app.buttons["外觀"].firstMatch
        XCTAssertTrue(appearanceRow.waitForExistence(timeout: 3), app.debugDescription)
        appearanceRow.tap()

        let darkBtn = app.buttons["深色"].firstMatch
        let systemBtn = app.buttons["跟隨系統"].firstMatch
        let lightBtn = app.buttons["淺色"].firstMatch
        XCTAssertTrue(darkBtn.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(darkBtn.isSelected)

        // Switch 深色 -> 跟隨系統 (with simulator in light mode), then present a sheet over it.
        systemBtn.tap()
        XCTAssertTrue(systemBtn.isSelected)
        shot("light-switch-01-system")

        app.typeKey("n", modifierFlags: .command)
        let composer = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3), "⌘N should present ComposerSheet over AppearanceSettingsView")
        shot("light-switch-02-system-sheet")
        app.buttons["composerMore"].tap()
        app.buttons["關閉"].tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 3))

        // Switch 跟隨系統 -> 淺色, then present the sheet again.
        lightBtn.tap()
        XCTAssertTrue(lightBtn.isSelected)
        shot("light-switch-03-light")

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        shot("light-switch-04-light-sheet")
        app.buttons["composerMore"].tap()
        app.buttons["關閉"].tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testLightAppearanceWalkthroughScreenshots() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin", "-appearance", "light"]
        app.launch()
        dismissNotificationPrompt()

        // 1. 今天
        let grocery = app.buttons["完成：去全聯買菜"]
        XCTAssertTrue(grocery.waitForExistence(timeout: 5), app.debugDescription)
        shot("light-01-today")

        // 2. Task detail (from 今天)
        let brief = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).element(boundBy: 1)
        XCTAssertTrue(brief.waitForExistence(timeout: 5), app.debugDescription)
        brief.tap()
        XCTAssertTrue(app.buttons["儲存"].waitForExistence(timeout: 3), app.debugDescription)
        shot("light-06-detail")
        let headerBtn = app.buttons["展開為全屏"]
        let dragStart = headerBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.05, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: 420)))
        XCTAssertTrue(headerBtn.waitForNonExistence(timeout: 3))

        // 3. Composer
        app.buttons["新增任務"].firstMatch.tap()
        let composerField = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(composerField.waitForExistence(timeout: 3), app.debugDescription)
        shot("light-07-composer")
        app.buttons["composerMore"].tap()
        app.buttons["關閉"].tap()
        XCTAssertTrue(composerField.waitForNonExistence(timeout: 3))

        // 4. Drawer
        app.buttons["開啟清單抽屜"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '工作與學習'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3), app.debugDescription)
        folder.tap()
        shot("light-02-drawer")

        // 5. 全部
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '全部'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 3), app.debugDescription)
        all.tap()
        XCTAssertTrue(app.staticTexts["全部"].waitForExistence(timeout: 3))
        shot("light-03-all")

        // 6. 日曆 (月 and 週)
        app.buttons["日曆"].tap()
        XCTAssertTrue(app.buttons["calendarTitle"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["calendarMode"].tap()
        app.buttons["月"].firstMatch.tap()
        sleep(1)
        shot("light-04-calendar-month")

        app.buttons["calendarMode"].tap()
        app.buttons["週"].firstMatch.tap()
        sleep(1)
        shot("light-05-calendar-week")

        // 7. 搜尋
        app.buttons["搜尋"].firstMatch.tap()
        let searchField = app.textFields["搜尋任務、描述、標籤、子任務"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), app.debugDescription)
        searchField.tap()
        searchField.typeText("簡報")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).firstMatch.waitForExistence(timeout: 3))
        shot("light-08-search")

        // 8. 設定 -> 外觀
        app.buttons["設定"].firstMatch.tap()
        let appearanceBtn = app.buttons["外觀"].firstMatch
        XCTAssertTrue(appearanceBtn.waitForExistence(timeout: 3), app.debugDescription)
        shot("light-09-settings")
        appearanceBtn.tap()
        XCTAssertTrue(app.buttons["淺色"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["淺色"].isSelected)
        shot("light-10-settings-appearance")
    }

    @MainActor
    func testAppearanceChoicePersistsAcrossRelaunch() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        app.buttons["設定"].firstMatch.tap()
        app.buttons["外觀"].firstMatch.tap()
        let darkBtn = app.buttons["深色"].firstMatch
        let lightBtn = app.buttons["淺色"].firstMatch
        XCTAssertTrue(darkBtn.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(darkBtn.isSelected)
        XCTAssertFalse(lightBtn.isSelected)

        lightBtn.tap()
        XCTAssertTrue(lightBtn.isSelected)
        XCTAssertFalse(darkBtn.isSelected)

        // Relaunch without -DayDoReset and verify 淺色 remains selected.
        app.terminate()
        app.launchArguments = ["-DayDoDemo", "-DayDoSkipLogin"]
        app.launch()
        dismissNotificationPrompt()

        app.buttons["設定"].firstMatch.tap()
        app.buttons["外觀"].firstMatch.tap()
        let lightAfterRelaunch = app.buttons["淺色"].firstMatch
        let darkAfterRelaunch = app.buttons["深色"].firstMatch
        XCTAssertTrue(lightAfterRelaunch.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(lightAfterRelaunch.isSelected)
        XCTAssertFalse(darkAfterRelaunch.isSelected)
    }

    @MainActor
    func testAllViewMemberFilterChips() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoSeedSharedList"]
        app.launch()
        dismissNotificationPrompt()

        XCTAssertTrue(app.buttons["完成：買鮮奶"].waitForExistence(timeout: 5), app.debugDescription)

        app.buttons["開啟清單抽屜"].tap()
        let allRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '全部'")).firstMatch
        XCTAssertTrue(allRow.waitForExistence(timeout: 3), app.debugDescription)
        let badge = allRow.label.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        XCTAssertEqual(badge, "4", allRow.label)
        allRow.tap()

        let allChip = app.buttons["memberFilter.all"]
        let meChip = app.buttons["memberFilter.me"]
        let partnerChip = app.buttons["memberFilter.debug-other-member-1"]
        XCTAssertTrue(allChip.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(meChip.exists)
        XCTAssertTrue(partnerChip.exists)
        XCTAssertEqual(meChip.label, "我的")
        XCTAssertEqual(partnerChip.label, "小安的")
        XCTAssertTrue(allChip.isSelected)
        XCTAssertTrue(app.staticTexts["4 項待辦"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["買鮮奶"].exists)
        XCTAssertTrue(app.staticTexts["繳水電費"].exists)
        XCTAssertTrue(app.staticTexts["訂機票"].exists)
        XCTAssertTrue(app.staticTexts["換日幣"].exists)
        shot("all-member-filter-all")

        meChip.tap()
        XCTAssertTrue(meChip.isSelected)
        XCTAssertTrue(app.staticTexts["2 項待辦"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["買鮮奶"].exists)
        XCTAssertTrue(app.staticTexts["換日幣"].exists)
        XCTAssertTrue(app.staticTexts["繳水電費"].waitForNonExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.staticTexts["訂機票"].exists)
        shot("all-member-filter-me")

        partnerChip.tap()
        XCTAssertTrue(partnerChip.isSelected)
        XCTAssertTrue(app.staticTexts["2 項待辦"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["繳水電費"].exists)
        XCTAssertTrue(app.staticTexts["訂機票"].exists)
        XCTAssertTrue(app.staticTexts["買鮮奶"].waitForNonExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.staticTexts["換日幣"].exists)
        shot("all-member-filter-partner")

        // Verify opening the drawer while on 「全部」 still resolves the drawer row and unfiltered badge.
        app.buttons["開啟清單抽屜"].tap()
        let drawerAllAgain = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '全部'")).firstMatch
        XCTAssertTrue(drawerAllAgain.waitForExistence(timeout: 3), app.debugDescription)
        let badgeAgain = drawerAllAgain.label.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        XCTAssertEqual(badgeAgain, "4", drawerAllAgain.label)
    }

    @MainActor
    func testCalendarOwnerAvatarUnderAllFilter() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDebugStub", "-DayDoSeedSharedList"]
        app.launch()
        dismissNotificationPrompt()

        XCTAssertTrue(app.buttons["完成：買鮮奶"].waitForExistence(timeout: 5), app.debugDescription)

        app.buttons["日曆"].tap()
        XCTAssertTrue(app.buttons["calendarTitle"].waitForExistence(timeout: 3), app.debugDescription)

        let allChip = app.buttons["memberFilter.all"]
        let meChip = app.buttons["memberFilter.me"]
        let partnerChip = app.buttons["memberFilter.debug-other-member-1"]
        XCTAssertTrue(allChip.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(allChip.isSelected)

        func rowButton(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }
        let buyMilk = rowButton("買鮮奶")
        let exchangeJpy = rowButton("換日幣")
        let bookFlight = rowButton("訂機票")
        let payBills = rowButton("繳水電費")
        XCTAssertTrue(buyMilk.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(exchangeJpy.exists, app.debugDescription)
        XCTAssertTrue(bookFlight.exists, app.debugDescription)
        XCTAssertTrue(payBills.exists, app.debugDescription)

        func ownerValue(_ row: XCUIElement) -> String {
            (row.value as? String) ?? ""
        }
        // Under 「全部」: partner rows expose "小安的" on the task button itself (no separate avatar element);
        // my rows and checkbox labels remain unchanged.
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "ownerAvatar").count, 0)
        XCTAssertEqual(ownerValue(bookFlight), "小安的")
        XCTAssertEqual(ownerValue(payBills), "小安的")
        XCTAssertFalse(ownerValue(buyMilk).contains("小安的"))
        XCTAssertFalse(ownerValue(exchangeJpy).contains("小安的"))
        XCTAssertTrue(app.buttons["完成：買鮮奶"].exists)
        XCTAssertTrue(app.buttons["完成：訂機票"].exists)
        shot("calendar-owner-avatar-all")

        // Switch to 「我的」: no owner announced.
        meChip.tap()
        XCTAssertTrue(meChip.isSelected)
        XCTAssertTrue(buyMilk.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(exchangeJpy.exists)
        XCTAssertTrue(bookFlight.waitForNonExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(ownerValue(buyMilk).contains("小安的"))
        XCTAssertFalse(ownerValue(exchangeJpy).contains("小安的"))

        // Switch to 「小安的」: no owner announced either.
        partnerChip.tap()
        XCTAssertTrue(partnerChip.isSelected)
        XCTAssertTrue(bookFlight.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(payBills.exists)
        XCTAssertFalse(ownerValue(bookFlight).contains("小安的"))
        XCTAssertFalse(ownerValue(payBills).contains("小安的"))

        // Switch back to 「全部」 and verify partner row remains tappable.
        allChip.tap()
        XCTAssertTrue(bookFlight.waitForExistence(timeout: 3), app.debugDescription)
        bookFlight.tap()
        let titleField = app.descendants(matching: .any)["taskTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(titleField.value as? String, "訂機票")
    }

    @MainActor
    func testRemoteAttachmentDownloadsAndOpensPreview() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = [
            "-DayDoReset",
            "-DayDoDebugStub",
            "-DayDoDebugRemoteAttachment",
            "-DayDoDebugRemoteAttachmentFailOnce",
        ]
        app.launch()
        dismissNotificationPrompt()

        let taskRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '遠端附件任務' AND NOT (label BEGINSWITH '完成：')")
        ).firstMatch
        XCTAssertTrue(taskRow.waitForExistence(timeout: 5), app.debugDescription)
        taskRow.tap()

        let attRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'notes.txt'")).firstMatch
        XCTAssertTrue(attRow.waitForExistence(timeout: 3), app.debugDescription)

        // First tap hits 500 -> shows inline retry prompt.
        attRow.tap()
        let retryLabel = app.staticTexts["下載失敗，點一下重試"]
        XCTAssertTrue(retryLabel.waitForExistence(timeout: 5), app.debugDescription)
        shot("remote-attachment-retry")

        // Second tap downloads and opens QuickLook preview.
        attRow.tap()
        // QuickLook titles the bar with the file name without its extension.
        let qlNav = app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'notes'")).firstMatch
        XCTAssertTrue(qlNav.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testDuplicateProjectShowsProgressAndPreventsDuplicateTap() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = [
            "-DayDoReset",
            "-DayDoDebugStub",
            "-DayDoDebugRemoteAttachment",
            "-DayDoDebugRemoteAttachmentSlow",
        ]
        app.launch()
        dismissNotificationPrompt()

        app.buttons["開啟清單抽屜"].tap()
        let sourceList = app.buttons["drawer.list.附件測試清單"]
        XCTAssertTrue(sourceList.waitForExistence(timeout: 5), app.debugDescription)
        sourceList.tap()

        app.buttons["更多選項"].tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["複製清單"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["複製清單"].tap()

        let status = app.staticTexts["複製中…"]
        XCTAssertTrue(status.waitForExistence(timeout: 3), app.debugDescription)
        shot("duplicate-list-in-progress")

        // Re-opening the menu while duplicating shows the disabled "複製中…" item and does not create a second copy.
        app.buttons["更多選項"].tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["更多"].tap()
        let disabledDuplicateItem = app.buttons["複製中…"]
        XCTAssertTrue(disabledDuplicateItem.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(disabledDuplicateItem.isEnabled)
        XCTAssertFalse(app.buttons["複製清單"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()

        XCTAssertTrue(app.staticTexts["附件測試清單 副本"].waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(status.waitForNonExistence(timeout: 3), app.debugDescription)

        app.buttons["開啟清單抽屜"].tap()
        let copyRows = app.buttons.matching(NSPredicate(format: "identifier == 'drawer.list.附件測試清單 副本'"))
        XCTAssertTrue(copyRows.firstMatch.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(copyRows.count, 1)
    }

    private func parseTimeRangeMinutes(_ text: String) -> (Int, Int)? {
        let regex = try! NSRegularExpression(pattern: #"(\d{2}):(\d{2})"#)
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return nil }
        func mins(_ m: NSTextCheckingResult) -> Int {
            Int(ns.substring(with: m.range(at: 1)))! * 60 + Int(ns.substring(with: m.range(at: 2)))!
        }
        let s = mins(matches[0])
        var e = mins(matches[1])
        if e <= s { e += 1440 }
        return (s, e)
    }

    private func isVisibleInGrid(
        _ element: XCUIElement,
        scrollView: XCUIElement,
        topOffsetRange: ClosedRange<CGFloat>? = nil
    ) -> Bool {
        guard element.exists && element.isHittable else { return false }
        let f = element.frame
        let s = scrollView.frame
        if let range = topOffsetRange {
            let offset = f.minY - s.minY
            return offset >= range.lowerBound && offset <= range.upperBound && f.maxY <= s.maxY - 96
        }
        // Keep clear of the top edge and bottom floating nav bar so taps/drags land cleanly.
        return f.minY >= s.minY + 12 && f.maxY <= s.maxY - 96
    }

    private func dragScrollGrid(_ scrollView: XCUIElement, contentDeltaY: CGFloat) {
        let s = scrollView.frame
        // Drag inside the left hour-label gutter so we never touch task blocks or empty-slot taps.
        let x = s.minX + 20
        let topY = s.minY + 48
        let bottomY = s.maxY - 120
        let maxSpan = max(80, bottomY - topY)
        // Compensate ~12pt for UIScrollView pan recognition threshold; hold before lift to avoid inertia.
        let step = min(max(abs(contentDeltaY) + 12, 36), maxSpan)
        let startY = contentDeltaY > 0 ? bottomY : topY
        let endY = contentDeltaY > 0 ? startY - step : startY + step
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: x, dy: startY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: endY)), withVelocity: .slow, thenHoldForDuration: 0.25)
    }

    private func ensureVisibleInGrid(
        _ element: XCUIElement,
        scrollView: XCUIElement,
        topOffsetRange: ClosedRange<CGFloat>? = nil,
        maxSteps: Int = 12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if isVisibleInGrid(element, scrollView: scrollView, topOffsetRange: topOffsetRange) { return }
        let s = scrollView.frame
        let desiredTop = s.minY + (topOffsetRange.map { ($0.lowerBound + $0.upperBound) / 2 } ?? max(48, s.height * 0.3))
        for stepIndex in 0..<maxSteps {
            if isVisibleInGrid(element, scrollView: scrollView, topOffsetRange: topOffsetRange) { return }
            if element.exists {
                let delta = element.frame.minY - desiredTop
                dragScrollGrid(scrollView, contentDeltaY: abs(delta) < 1 ? 80 : delta)
            } else {
                dragScrollGrid(scrollView, contentDeltaY: stepIndex < maxSteps / 2 ? 220 : -220)
            }
        }
        XCTFail(
            "Target element not visible in timeGridScroll (exists=\(element.exists), hittable=\(element.isHittable), frame=\(element.frame), scrollFrame=\(scrollView.frame))",
            file: file,
            line: line
        )
    }

    private func scrollGridToTop(_ gridScroll: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let hour01 = app.staticTexts["01"].firstMatch
        ensureVisibleInGrid(hour01, scrollView: gridScroll, topOffsetRange: 24...110, file: file, line: line)
    }

    @MainActor
    func testTimeGridDragMoveScrollAndTap() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin", "-DayDoScreen", "day"]
        app.launch()
        dismissNotificationPrompt()

        let dayModeBtn = app.buttons["切換檢視：目前日"]
        XCTAssertTrue(dayModeBtn.waitForExistence(timeout: 5), app.debugDescription)
        sleep(1)

        let gridScroll = app.scrollViews["timeGridScroll"]
        XCTAssertTrue(gridScroll.waitForExistence(timeout: 3), app.debugDescription)
        let brief = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '準備週一產品會議簡報'")).firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 3), app.debugDescription)

        // Start from 00:00 (18:00 task off-screen) so the test does not depend on wall-clock launch time.
        scrollGridToTop(gridScroll)
        XCTAssertFalse(brief.isHittable, "18:00 task should not be visible when scrolled to 00:00")

        ensureVisibleInGrid(brief, scrollView: gridScroll)
        XCTAssertTrue(brief.label.contains("18:00 – 18:30"), brief.label)

        // 1. Tap opens task detail.
        brief.tap()
        let titleField = app.descendants(matching: .any)["taskTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(titleField.value as? String, "準備週一產品會議簡報")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 3))

        // 2. Quick vertical drag scrolls without moving the task.
        // Since brief sits at 18:00 (~1008pt down), ScrollView always has >=350pt of room above it.
        ensureVisibleInGrid(brief, scrollView: gridScroll)
        let yBeforeQuickScroll = brief.frame.minY
        let quickStart = brief.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        quickStart.press(forDuration: 0.05, thenDragTo: quickStart.withOffset(CGVector(dx: 0, dy: 120)))
        XCTAssertTrue(brief.label.contains("18:00 – 18:30"), "Quick drag should scroll, not move task: \(brief.label)")
        XCTAssertGreaterThan(brief.frame.minY - yBeforeQuickScroll, 20, "Quick vertical drag should scroll the time grid")

        // 3. Long-press + drag down moves the task later (~18:00 -> ~19:00, 15m snap tolerance).
        ensureVisibleInGrid(brief, scrollView: gridScroll)
        let dragStart = brief.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.45, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: 56)))

        let moved = NSPredicate { _, _ in
            guard brief.exists, let (s, e) = self.parseTimeRangeMinutes(brief.label) else { return false }
            return s >= 18 * 60 + 45 && s <= 19 * 60 + 15 && (e - s) == 30
        }
        let exp = XCTNSPredicateExpectation(predicate: moved, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed, "Expected task around 19:00–19:30, got: \(brief.label)")
        shot("timegrid-drag-moved")

        // Verify persisted schedule in TaskDetailSheet (independent of pendingMove optimistic state).
        brief.tap()
        let dateBtn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '設定日期與時間'")).firstMatch
        XCTAssertTrue(dateBtn.waitForExistence(timeout: 3), app.debugDescription)
        let persistedRange = try XCTUnwrap(parseTimeRangeMinutes(dateBtn.label), dateBtn.label)
        XCTAssertTrue(persistedRange.0 >= 18 * 60 + 45 && persistedRange.0 <= 19 * 60 + 15 && (persistedRange.1 - persistedRange.0) == 30,
                      "Expected persisted detail time around 19:00–19:30, got: \(dateBtn.label)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(dateBtn.waitForNonExistence(timeout: 3))

        // Verify scroll lock is released after drag ends.
        ensureVisibleInGrid(brief, scrollView: gridScroll)
        let yBeforePostScroll = brief.frame.minY
        let postStart = brief.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        postStart.press(forDuration: 0.05, thenDragTo: postStart.withOffset(CGVector(dx: 0, dy: 120)))
        XCTAssertGreaterThan(brief.frame.minY - yBeforePostScroll, 20, "Time grid should remain scrollable after drag ends")
    }

    @MainActor
    func testTimeGridDragAcrossColumnsDoesNotPage() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin", "-DayDoScreen", "week"]
        app.launch()
        dismissNotificationPrompt()

        let weekModeBtn = app.buttons["切換檢視：目前週"]
        XCTAssertTrue(weekModeBtn.waitForExistence(timeout: 5), app.debugDescription)
        sleep(1)

        let titleBtn = app.buttons["calendarTitle"]
        let initialTitle = titleBtn.label
        let todayComps = Calendar.current.dateComponents([.month, .day], from: Date())
        let todayHeaderPrefix = "\(todayComps.month!) 月 \(todayComps.day!) 日"
        let todayHeader = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", todayHeaderPrefix)).firstMatch
        XCTAssertTrue(todayHeader.waitForExistence(timeout: 3), app.debugDescription)

        // Quick horizontal swipe without long-press still pages the week.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45)))
        XCTAssertTrue(todayHeader.waitForNonExistence(timeout: 3), "Quick horizontal swipe should page week")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
        XCTAssertTrue(todayHeader.waitForExistence(timeout: 3), "Quick horizontal swipe back should return to current week")

        let brief = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '準備週一產品會議簡報'")).firstMatch
        let gridScroll = app.scrollViews["timeGridScroll"]
        XCTAssertTrue(gridScroll.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(brief.waitForExistence(timeout: 3), app.debugDescription)
        ensureVisibleInGrid(brief, scrollView: gridScroll)
        XCTAssertTrue(brief.isHittable, app.debugDescription)

        let weekday = Calendar.current.component(.weekday, from: Date()) - 1 // 0 = Sun ... 6 = Sat
        let colW = brief.frame.width
        let dx = weekday < 6 ? colW : -colW
        let expectedDayToken = weekday < 6 ? "明天" : "昨天"
        let startMidX = brief.frame.midX

        let dragStart = brief.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.45, thenDragTo: dragStart.withOffset(CGVector(dx: dx, dy: 0)))

        let shifted = NSPredicate { _, _ in
            brief.exists && abs((brief.frame.midX - startMidX) - dx) < colW * 0.45
        }
        let exp = XCTNSPredicateExpectation(predicate: shifted, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed, "Expected block to move across column without paging")
        XCTAssertEqual(titleBtn.label, initialTitle, "Dragging block horizontally must not flip week")
        XCTAssertTrue(todayHeader.exists, "Dragging block horizontally must stay on the same week")

        // Verify persisted day changed by opening task detail.
        brief.tap()
        let dateBtn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '設定日期與時間'")).firstMatch
        XCTAssertTrue(dateBtn.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(dateBtn.label.contains(expectedDayToken), "Expected \(expectedDayToken) in \(dateBtn.label)")
        shot("timegrid-drag-column")
    }

    @MainActor
    func testTimeGridEmptyTapAndDragCreate() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        app.terminate()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin", "-DayDoScreen", "day"]
        app.launch()
        dismissNotificationPrompt()

        let dayModeBtn = app.buttons["切換檢視：目前日"]
        XCTAssertTrue(dayModeBtn.waitForExistence(timeout: 5), app.debugDescription)
        sleep(1)

        let gridScroll = app.scrollViews["timeGridScroll"]
        XCTAssertTrue(gridScroll.waitForExistence(timeout: 3), app.debugDescription)
        let brief = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '準備週一產品會議簡報'")).firstMatch
        XCTAssertTrue(brief.waitForExistence(timeout: 3), app.debugDescription)

        // Start from 00:00 (18:00 task off-screen) so scrolling to 10:00–12:00 does not depend on launch time.
        scrollGridToTop(gridScroll)
        XCTAssertFalse(brief.isHittable, "18:00 task should not be visible when scrolled to 00:00")

        // Today has no timed demo tasks before 18:00; position 10:00 in the upper safe band (60–200pt from grid top)
        // so both 10:00 and 12:00 stay comfortably visible at once.
        let hour10 = app.staticTexts["10"].firstMatch
        let hour12 = app.staticTexts["12"].firstMatch
        ensureVisibleInGrid(hour10, scrollView: gridScroll, topOffsetRange: 60...200)
        XCTAssertTrue(isVisibleInGrid(hour12, scrollView: gridScroll), "Expected 12:00 label visible alongside 10:00 (10=\(hour10.frame), 12=\(hour12.frame), scroll=\(gridScroll.frame))")

        let emptySlot = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH '空白時段，點兩下新增'")).firstMatch
        XCTAssertTrue(emptySlot.waitForExistence(timeout: 3), app.debugDescription)

        let slotX = (hour10.frame.maxX + gridScroll.frame.maxX) / 2
        let startCoord = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: slotX, dy: hour10.frame.midY))
        let endCoord = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: slotX, dy: hour12.frame.midY))

        // 1. Tap 10:00 empty slot opens composer with ~10:00 start and default 60-minute duration.
        startCoord.tap()
        let composerTitle = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(composerTitle.waitForExistence(timeout: 3), app.debugDescription)
        let composerDate = app.buttons["composerDate"]
        XCTAssertTrue(composerDate.waitForExistence(timeout: 3), app.debugDescription)
        let tapRange = try XCTUnwrap(parseTimeRangeMinutes(composerDate.label), composerDate.label)
        XCTAssertTrue(tapRange.0 >= 9 * 60 + 30 && tapRange.0 <= 10 * 60 + 30,
                      "Expected tap start around 10:00 (within 09:30–10:30), got \(composerDate.label)")
        XCTAssertEqual(tapRange.1 - tapRange.0, 60, "Tap should create default 60m duration: \(composerDate.label)")

        app.buttons["composerMore"].tap()
        app.buttons["關閉"].tap()
        XCTAssertTrue(composerTitle.waitForNonExistence(timeout: 3))

        // 2. Long-press at 10:00 and drag down to 12:00 opens composer with ~10:00–12:00 (15m snap tolerance).
        startCoord.press(forDuration: 0.45, thenDragTo: endCoord)
        XCTAssertTrue(composerTitle.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(composerDate.waitForExistence(timeout: 3), app.debugDescription)
        let dragRange = try XCTUnwrap(parseTimeRangeMinutes(composerDate.label), composerDate.label)
        XCTAssertTrue(dragRange.0 >= 9 * 60 + 45 && dragRange.0 <= 10 * 60 + 15,
                      "Expected drag start around 10:00 (±15m), got \(composerDate.label)")
        XCTAssertTrue(dragRange.1 >= 11 * 60 + 45 && dragRange.1 <= 12 * 60 + 15,
                      "Expected drag end around 12:00 (±15m), got \(composerDate.label)")
        shot("timegrid-drag-create")
    }

    @MainActor
    func testTaskCountdownBadgeToggleAndListDisplay() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        // Navigate to 工作 list which has future task 交 Q4 報告 (+5 days) and other tasks without countdown.
        app.buttons["開啟清單抽屜"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '工作與學習'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.tap()
        let work = app.buttons["drawer.list.工作"]
        XCTAssertTrue(work.waitForExistence(timeout: 3))
        work.tap()
        XCTAssertTrue(app.staticTexts["工作"].waitForExistence(timeout: 3))

        // Before enabling countdown, no countdown badge should be shown.
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS '還有 5 天'")).count,
            0
        )

        // Open future task 交 Q4 報告 (+5 days) and turn on 倒數.
        let futureRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '交 Q4 報告' AND NOT (label BEGINSWITH '完成：')")
        ).firstMatch
        XCTAssertTrue(futureRow.waitForExistence(timeout: 3), app.debugDescription)
        futureRow.tap()

        XCTAssertTrue(app.buttons["儲存"].waitForExistence(timeout: 3), app.debugDescription)
        let toggle = app.switches["countdownToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "0")
        sleep(1)
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")

        // Dismiss detail sheet and verify badge appears only on 交 Q4 報告.
        let headerBtn = app.buttons["展開為全屏"]
        let dragStart = headerBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.05, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: 420)))
        XCTAssertTrue(headerBtn.waitForNonExistence(timeout: 3))

        let updatedRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '交 Q4 報告' AND label CONTAINS '還有 5 天'")
        ).firstMatch
        XCTAssertTrue(updatedRow.waitForExistence(timeout: 3), app.debugDescription)
        let otherRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '週會' AND NOT (label BEGINSWITH '完成：')")
        ).firstMatch
        XCTAssertTrue(otherRow.exists, app.debugDescription)
        XCTAssertFalse(otherRow.label.contains("明天、"), otherRow.label)
        XCTAssertFalse(otherRow.label.contains("還有"), otherRow.label)

        let todayRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '準備週一產品會議簡報' AND NOT (label BEGINSWITH '完成：')")
        ).firstMatch
        XCTAssertTrue(todayRow.exists, app.debugDescription)
        XCTAssertFalse(todayRow.label.contains("今天"), todayRow.label)

        shot("countdown-list")
    }

    @MainActor
    func testWeekAgendaToggleAndNavigation() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        app.buttons["日曆"].tap()
        XCTAssertTrue(app.buttons["calendarTitle"].waitForExistence(timeout: 3), app.debugDescription)

        app.buttons["calendarMode"].tap()
        let weekItem = app.buttons["週"].firstMatch
        XCTAssertTrue(weekItem.waitForExistence(timeout: 3))
        weekItem.tap()

        // Default week mode is TimeGrid; toggle switches to 週清單.
        XCTAssertTrue(app.scrollViews["timeGridScroll"].waitForExistence(timeout: 3), app.debugDescription)
        let toggle = app.buttons["weekLayoutToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(toggle.label, "切換為週清單")
        toggle.tap()

        let agenda = app.otherElements["weekAgenda"]
        XCTAssertTrue(agenda.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(toggle.label, "切換為週時間軸")

        let cal = Calendar.current
        let now = Date()
        let weekday = cal.component(.weekday, from: now) - 1 // 0 = Sun ... 6 = Sat
        let sunday = cal.date(byAdding: .day, value: -weekday, to: now)!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for i in 0..<7 {
            let d = cal.date(byAdding: .day, value: i, to: sunday)!
            let cell = app.descendants(matching: .any)["weekAgendaDay-\(fmt.string(from: d))"]
            XCTAssertTrue(cell.waitForExistence(timeout: 3), "Missing day cell for offset \(i)")
        }
        shot("week-agenda")

        // Tap the first-sorted task on today (independent of cell height) -> opens task detail sheet.
        let todayCell = app.descendants(matching: .any)["weekAgendaDay-\(fmt.string(from: now))"]
        let firstTask = todayCell.buttons.matching(NSPredicate(format: "label CONTAINS '去全聯買菜'")).firstMatch
        XCTAssertTrue(firstTask.waitForExistence(timeout: 3), app.debugDescription)
        firstTask.tap()
        XCTAssertTrue(app.buttons["儲存"].waitForExistence(timeout: 3), app.debugDescription)
        let expandBtn = app.buttons["展開為全屏"]
        let dragStart = expandBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dragStart.press(forDuration: 0.05, thenDragTo: dragStart.withOffset(CGVector(dx: 0, dy: 420)))
        XCTAssertTrue(expandBtn.waitForNonExistence(timeout: 3))

        // Tap a mini-month day in another week -> changes the displayed week.
        let sundayDayOfMonth = cal.component(.day, from: sunday)
        let otherWeekOffset = sundayDayOfMonth <= 14 ? 7 : -7
        let otherSunday = cal.date(byAdding: .day, value: otherWeekOffset, to: sunday)!
        let miniBtn = app.buttons["weekAgendaMini-\(fmt.string(from: otherSunday))"]
        XCTAssertTrue(miniBtn.waitForExistence(timeout: 3), app.debugDescription)
        miniBtn.tap()

        let currentSundayCell = app.descendants(matching: .any)["weekAgendaDay-\(fmt.string(from: sunday))"]
        let otherSundayCell = app.descendants(matching: .any)["weekAgendaDay-\(fmt.string(from: otherSunday))"]
        XCTAssertTrue(otherSundayCell.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(currentSundayCell.waitForNonExistence(timeout: 3))

        // Horizontal swipe pages back to the current week.
        let window = app.windows.firstMatch
        let startX: CGFloat = otherWeekOffset > 0 ? 0.25 : 0.85
        let endX: CGFloat = otherWeekOffset > 0 ? 0.85 : 0.25
        window.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.45)))
        XCTAssertTrue(currentSundayCell.waitForExistence(timeout: 3), app.debugDescription)

        // Tap a different mini-month day in the same week -> selects it without changing the displayed week.
        let sameWeekOffset = weekday == 0 ? 1 : 0
        let sameWeekDay = cal.date(byAdding: .day, value: sameWeekOffset, to: sunday)!
        let sameWeekStr = fmt.string(from: sameWeekDay)
        let sameWeekMiniBtn = app.buttons["weekAgendaMini-\(sameWeekStr)"]
        XCTAssertTrue(sameWeekMiniBtn.waitForExistence(timeout: 3), app.debugDescription)
        sameWeekMiniBtn.tap()
        XCTAssertTrue(sameWeekMiniBtn.isSelected, "Selected mini-month button should have isSelected trait")
        let sameWeekDayCell = app.descendants(matching: .any)["weekAgendaDay-\(sameWeekStr)"]
        XCTAssertTrue(sameWeekDayCell.isSelected, "Selected day cell should have isSelected trait")
        XCTAssertTrue(currentSundayCell.exists, "Tapping a day in the same week must not change the displayed week")

        // Tap empty space in a sparse day cell (<= 1 task in DemoData) -> opens composer.
        let sparseOffset = weekday <= 4 ? weekday + 2 : weekday - 5
        let sparseDay = cal.date(byAdding: .day, value: sparseOffset, to: sunday)!
        let sparseCell = app.descendants(matching: .any)["weekAgendaDay-\(fmt.string(from: sparseDay))"]
        XCTAssertTrue(sparseCell.waitForExistence(timeout: 3))
        sparseCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        let composerTitle = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(composerTitle.waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["composerMore"].tap()
        app.buttons["關閉"].tap()
        XCTAssertTrue(composerTitle.waitForNonExistence(timeout: 3))

        // Capture light appearance (100%) and 130% text scale screenshots.
        app.buttons["設定"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '外觀'")).firstMatch.tap()
        let lightChip = app.buttons["淺色"]
        XCTAssertTrue(lightChip.waitForExistence(timeout: 3))
        lightChip.tap()
        app.buttons["日曆"].firstMatch.tap()
        XCTAssertTrue(agenda.waitForExistence(timeout: 3))
        shot("week-agenda-light")

        app.buttons["設定"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '外觀'")).firstMatch.tap()
        let scale130 = app.buttons["130%"]
        XCTAssertTrue(scale130.waitForExistence(timeout: 3), app.debugDescription)
        scale130.tap()
        app.buttons["日曆"].firstMatch.tap()
        XCTAssertTrue(agenda.waitForExistence(timeout: 3))
        shot("week-agenda-130")

        // Toggle back -> restores TimeGrid.
        toggle.tap()
        XCTAssertTrue(app.scrollViews["timeGridScroll"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(agenda.waitForNonExistence(timeout: 3))
        XCTAssertEqual(toggle.label, "切換為週清單")

        // Switch back to week agenda and tap today's +N overflow -> switches to .day mode on today.
        toggle.tap()
        let moreBtn = app.buttons["weekAgendaMore-\(fmt.string(from: now))"]
        XCTAssertTrue(moreBtn.waitForExistence(timeout: 3), app.debugDescription)
        moreBtn.tap()
        XCTAssertTrue(app.buttons["切換檢視：目前日"].waitForExistence(timeout: 3), app.debugDescription)
        let todayComps = cal.dateComponents([.year, .month, .day], from: now)
        let expectedTitlePrefix = "\(todayComps.month!)月"
        XCTAssertTrue(app.buttons["calendarTitle"].label.hasPrefix(expectedTitlePrefix), app.buttons["calendarTitle"].label)
        let todayHeaderPrefix = "\(todayComps.month!) 月 \(todayComps.day!) 日"
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", todayHeaderPrefix)).firstMatch.waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testTaskListScopeSwitchWhileHiddenShowsOnlyNewList() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        // 1. Open list A (工作) on Tasks tab and confirm its task is shown.
        app.buttons["開啟清單抽屜"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '工作與學習'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3), app.debugDescription)
        folder.tap()
        let workList = app.buttons["drawer.list.工作"]
        XCTAssertTrue(workList.waitForExistence(timeout: 3), app.debugDescription)
        workList.tap()
        XCTAssertTrue(app.staticTexts["工作"].waitForExistence(timeout: 3), app.debugDescription)
        let workTask = app.buttons["完成：準備週一產品會議簡報"]
        XCTAssertTrue(workTask.waitForExistence(timeout: 3), app.debugDescription)
        let inboxTask = app.buttons["完成：整理 Q1 OKR 草稿"]
        XCTAssertFalse(inboxTask.exists)

        // 2. Switch to Calendar tab, then open drawer via left-edge swipe and pick list B (收件匣).
        app.buttons["日曆"].tap()
        XCTAssertTrue(app.buttons["calendarTitle"].waitForExistence(timeout: 3), app.debugDescription)

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        let inbox = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '收件匣'")).firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 3), app.debugDescription)
        inbox.tap()

        // 3. Back on Tasks tab: only list B's tasks should appear; list A's tasks must not remain.
        XCTAssertTrue(app.staticTexts["收件匣"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(inboxTask.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(workTask.exists, "Old list A task must not remain after switching to list B while hidden")
    }

    @MainActor
    func testCalendarResetsSelectionAndFiltersWhenReturningFromOtherTab() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        app.buttons["日曆"].tap()
        XCTAssertTrue(app.buttons["calendarTitle"].waitForExistence(timeout: 3), app.debugDescription)

        let comps = Calendar.current.dateComponents([.month, .day], from: Date())
        let m = comps.month!
        let todayDay = comps.day!
        let otherDay = todayDay == 12 ? 15 : 12
        let otherPrefix = "\(m) 月 \(otherDay) 日"
        let otherCell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", otherPrefix)).firstMatch
        XCTAssertTrue(otherCell.waitForExistence(timeout: 3), app.debugDescription)
        otherCell.tap()
        XCTAssertTrue(otherCell.isSelected)
        let otherHeading = app.staticTexts["\(m)月\(otherDay)日"]
        XCTAssertTrue(otherHeading.waitForExistence(timeout: 3), app.debugDescription)

        // Apply a project filter as well.
        app.buttons["更多選項"].tap()
        let filterMenu = app.buttons["清單篩選"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 3), app.debugDescription)
        filterMenu.tap()
        let workFilter = app.buttons["工作"].firstMatch
        XCTAssertTrue(workFilter.waitForExistence(timeout: 3), app.debugDescription)
        workFilter.tap()
        let activeFilterChip = app.buttons["移除清單篩選：工作"]
        XCTAssertTrue(activeFilterChip.waitForExistence(timeout: 3), app.debugDescription)

        // Switch away to Tasks and come back to Calendar.
        app.buttons["任務"].firstMatch.tap()
        XCTAssertTrue(app.buttons["開啟清單抽屜"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["日曆"].tap()

        let todayHeading = app.staticTexts["\(m)月\(todayDay)日・今天"]
        XCTAssertTrue(todayHeading.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(activeFilterChip.exists, "Project filter should reset on returning to Calendar")
    }

    @MainActor
    func testSearchResetsQueryAndRefocusesKeyboardWhenReturningFromOtherTab() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        app.buttons["搜尋"].firstMatch.tap()
        let field = app.textFields["搜尋任務、描述、標籤、子任務"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), app.debugDescription)
        field.tap()
        field.typeText("訂位")
        let resultRow = app.buttons.matching(NSPredicate(format: "label CONTAINS '晚餐：巷口火鍋'")).firstMatch
        XCTAssertTrue(resultRow.waitForExistence(timeout: 3), app.debugDescription)
        let activeOnlyChip = app.buttons["只看未完成"]
        activeOnlyChip.tap()
        XCTAssertTrue(activeOnlyChip.isSelected)

        // Switch away to Tasks and return to Search.
        app.buttons["任務"].firstMatch.tap()
        XCTAssertTrue(app.buttons["開啟清單抽屜"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["搜尋"].firstMatch.tap()

        XCTAssertTrue(field.waitForExistence(timeout: 3), app.debugDescription)
        let fieldText = (field.value as? String) ?? ""
        XCTAssertTrue(fieldText.isEmpty || fieldText == "搜尋任務、描述、標籤、子任務", "Expected cleared search query, got: \(fieldText)")
        XCTAssertFalse(resultRow.exists, "Previous search results should be cleared on re-entry")
        XCTAssertFalse(activeOnlyChip.isSelected, "activeOnly filter should reset on re-entry")
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 3)
                || ((field.value(forKey: "hasKeyboardFocus") as? Bool) == true),
            "Search field should automatically focus keyboard on re-entry"
        )
    }

    @MainActor
    func testResidentTabsStatusBarScrollsToTopAndTaskTabResetsScroll() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout only")
        dismissNotificationPrompt()

        // Visit Calendar and Search so all resident tabs' ScrollViews are mounted in the window.
        app.buttons["日曆"].tap()
        XCTAssertTrue(app.buttons["calendarTitle"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["搜尋"].firstMatch.tap()
        XCTAssertTrue(app.textFields["搜尋任務、描述、標籤、子任務"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["任務"].firstMatch.tap()

        let topTitle = app.staticTexts["今天"].firstMatch
        XCTAssertTrue(topTitle.waitForExistence(timeout: 3), app.debugDescription)
        let initialTopY = topTitle.frame.minY
        let scroll = app.scrollViews.firstMatch

        // 1. Scroll down, then tap the status bar (left clock area, clear of Dynamic Island) -> scrolls back to top.
        scroll.swipeUp()
        scroll.swipeUp()
        XCTAssertLessThan(topTitle.frame.minY, initialTopY - 60, "Expected task list to scroll down before status-bar tap")

        let statusBarTap = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.02))
        statusBarTap.tap()
        let backToTop = NSPredicate { _, _ in
            topTitle.exists && abs(topTitle.frame.minY - initialTopY) < 20
        }
        let exp = XCTNSPredicateExpectation(predicate: backToTop, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed, "Status-bar tap should scroll Tasks to top even when hidden tabs are resident (topY=\(topTitle.frame.minY), initial=\(initialTopY))")

        // 2. Scroll down again, switch to Calendar and back to Tasks -> scroll position resets to top.
        scroll.swipeUp()
        scroll.swipeUp()
        XCTAssertLessThan(topTitle.frame.minY, initialTopY - 60, "Expected task list to scroll down before tab switch")

        app.buttons["日曆"].tap()
        XCTAssertTrue(app.buttons["calendarTitle"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["任務"].firstMatch.tap()
        XCTAssertTrue(topTitle.waitForExistence(timeout: 3), app.debugDescription)
        let expReset = XCTNSPredicateExpectation(predicate: backToTop, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expReset], timeout: 3), .completed, "Returning to Tasks tab should reset scroll to top (topY=\(topTitle.frame.minY), initial=\(initialTopY))")
    }
}
