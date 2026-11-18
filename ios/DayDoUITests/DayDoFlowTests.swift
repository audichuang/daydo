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
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
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
        shot("01-today")
        row.tap()
        // The row leaves 今天 and goes to the (collapsed) 已完成 section.
        XCTAssertTrue(app.buttons["完成：去全聯買菜"].waitForNonExistence(timeout: 3))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '已完成'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["取消完成：去全聯買菜"].waitForExistence(timeout: 3))

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
        shot("04-list-work")
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '明天 19:00 – 19:30'")).firstMatch.waitForExistence(timeout: 3))
        shot("10-detail-after-date")
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
        XCTAssertTrue(app.staticTexts["之後"].waitForExistence(timeout: 3))
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
}
