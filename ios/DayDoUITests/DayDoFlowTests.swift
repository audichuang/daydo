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

    func testTodayCompleteAndDrawer() {
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

    func testDetailDateAndTimeBlock() {
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

    func testCalendarViews() {
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

    func testCreateTaskAndEditList() {
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

    func testSearchDeleteAndRestore() {
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

    func testMultilineComposerYearTapAndArchive() {
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
    func testSettingsTabAndAppearance() {
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
    func testDrawerSwipePinAndDelete() {
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
    func testShareListInviteAndEditMembers() {
        dismissNotificationPrompt()
        app.buttons["開啟清單抽屜"].tap()
        XCTAssertTrue(app.staticTexts["我"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["設定"].exists)
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
        XCTAssertTrue(app.staticTexts["我"].exists)
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

        app.buttons["開啟清單抽屜"].tap()
        let settingsBtn = app.buttons["drawer.settings"]
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: 3))
        settingsBtn.tap()
        XCTAssertTrue(app.buttons["外觀"].waitForExistence(timeout: 3), app.debugDescription)
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
        let joinInviteButton = app.buttons["settings.joinInvite"]
        XCTAssertTrue(joinInviteButton.exists, app.debugDescription)
        shot("36-settings-account")

        signOutButton.tap()
        let confirmTitle = app.staticTexts["確定要登出？"]
        XCTAssertTrue(confirmTitle.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '尚未同步的變更'")).firstMatch.exists)
        app.buttons["取消"].tap()

        joinInviteButton.tap()
        let joinInput = app.textFields["joinInvite.input"]
        XCTAssertTrue(joinInput.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["joinInvite.submit"].exists, app.debugDescription)
        shot("38-join-invite")

        joinInput.tap()
        joinInput.typeText("daydo://invite/preview")
        app.buttons["joinInvite.submit"].tap()
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
}
