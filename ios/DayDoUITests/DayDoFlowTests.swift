import XCTest

/// Drives the real app on the simulator through the main flows from the
/// design boards. Screenshots are kept as attachments (and written to
/// $DAYDO_SHOTS when set) for comparison with `design/shots`.
final class DayDoFlowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo"]
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

        // Density toggle → compact (1c)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '切換密度'")).firstMatch.tap()
        shot("02-today-compact")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '切換密度'")).firstMatch.tap()

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

        // Date panel (4a/4b): open calendar + reminder options, pick tomorrow.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '設定日期與時間'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["確定"].waitForExistence(timeout: 3))
        shot("07-date-panel")
        app.buttons["dateCard"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '提醒'")).firstMatch.tap()
        shot("08-date-expanded")
        app.buttons["明天"].firstMatch.tap()

        // Time block (4c): drag the block down by ~60 min.
        app.buttons["timeCard"].tap()
        let block = app.otherElements["正在編輯的時間區塊，可拖曳移動或調整起訖"]
        XCTAssertTrue(block.waitForExistence(timeout: 3))
        let start = block.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)))
        sleep(1)
        shot("09-time-block")
        XCTAssertTrue(app.staticTexts["19:00 – 19:30"].waitForExistence(timeout: 3), app.debugDescription)
        // End handle past midnight is covered by unit tests; save and confirm.
        app.buttons["儲存"].tap()
        app.buttons["確定"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '明天 19:00 – 19:30'")).firstMatch.waitForExistence(timeout: 3))
        shot("10-detail-after-date")
    }

    func testCalendarViews() {
        dismissNotificationPrompt()
        app.buttons["日曆"].tap()
        let title = app.buttons["calendarTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3), app.debugDescription)
        shot("11-calendar")
        title.tap()
        shot("12-calendar-week")
        app.buttons["切換為事件月曆"].tap()
        shot("13-calendar-events")
    }

    func testCreateTaskAndEditList() {
        dismissNotificationPrompt()
        app.buttons["新增任務"].firstMatch.tap()
        let field = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("UI 測試新增的任務")
        shot("14-composer")
        app.buttons["新增"].tap()
        XCTAssertTrue(app.buttons["完成：UI 測試新增的任務"].waitForExistence(timeout: 3))

        app.buttons["開啟清單抽屜"].tap()
        app.buttons["新增清單或資料夾"].tap()
        app.buttons["新增清單"].tap()
        let name = app.textFields["清單名稱"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("旅行")
        app.buttons["看板"].tap()
        shot("15-edit-list")
        app.buttons["儲存"].tap()
        XCTAssertTrue(app.staticTexts["旅行"].waitForExistence(timeout: 3))
    }
}
