import XCTest

final class DayDoIPadTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "notifications") { alert in
            let allow = alert.buttons["允許"].exists ? alert.buttons["允許"] : alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchDemo(orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["允許"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["DAYDO_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func openListWorkFromSidebar() {
        if !app.buttons["drawer.list.工作"].waitForExistence(timeout: 2) {
            if app.buttons["顯示側邊欄"].exists {
                app.buttons["顯示側邊欄"].tap()
            }
        }
        if !app.buttons["drawer.list.工作"].waitForExistence(timeout: 2) {
            let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '工作與學習'")).firstMatch
            if folder.waitForExistence(timeout: 3) { folder.tap() }
        }
        let work = app.buttons["drawer.list.工作"]
        XCTAssertTrue(work.waitForExistence(timeout: 3), app.debugDescription)
        work.tap()
        XCTAssertTrue(app.staticTexts["工作"].waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testIPadSidebarDetailEditAndRotation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .portrait)

        let taskBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).element(boundBy: 1)
        XCTAssertTrue(taskBtn.waitForExistence(timeout: 5), app.debugDescription)
        taskBtn.tap()

        let titleField = app.descendants(matching: .any)["taskTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["展開為全屏"].exists, "Inline detail should not show phone full-screen toggle")

        let save = app.buttons["儲存"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled)
        shot("ipad-portrait-today-detail")

        titleField.tap()
        titleField.typeText("（v2）")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["已儲存"].waitForExistence(timeout: 3))

        // Rotate to landscape and verify selection survives.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["sidebar.calendar"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        let persistedTitle = (titleField.value as? String) ?? ""
        XCTAssertTrue(persistedTitle.contains("（v2）"), "Expected selection and title edit to survive rotation, got: \(persistedTitle)")
        shot("ipad-landscape-today-detail")

        // Navigate via sidebar to list 工作.
        openListWorkFromSidebar()
        shot("ipad-landscape-list-work")

        // Rotate back to portrait and verify list scope stays on 工作.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["工作"].waitForExistence(timeout: 3))
        shot("ipad-portrait-list-work")
    }

    @MainActor
    func testIPadShortcutsCalendarSettingsAndShare() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .landscapeLeft)

        XCTAssertTrue(app.buttons["完成：去全聯買菜"].waitForExistence(timeout: 5), app.debugDescription)

        // ⌘N opens composer.
        app.typeKey("n", modifierFlags: .command)
        let composer = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3), "⌘N should open ComposerSheet")
        composer.tap()
        composer.typeText("iPad快捷鍵任務")
        app.buttons["新增"].tap()
        XCTAssertTrue(app.buttons["完成：iPad快捷鍵任務"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        _ = composer.waitForNonExistence(timeout: 2)
        if composer.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()
            XCTAssertTrue(composer.waitForNonExistence(timeout: 3))
        }

        // Select newly created task and press Return to focus inline title field.
        let createdRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'iPad快捷鍵任務'")).element(boundBy: 1)
        XCTAssertTrue(createdRow.waitForExistence(timeout: 3), app.debugDescription)
        createdRow.tap()
        let titleField = app.descendants(matching: .any)["taskTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))

        app.typeKey(XCUIKeyboardKey(rawValue: "\n"), modifierFlags: [])
        app.typeText("!")
        XCTAssertEqual(titleField.value as? String, "iPad快捷鍵任務!")
        app.typeKey(XCUIKeyboardKey(rawValue: "\n"), modifierFlags: [])

        // ⌘2 switches to Calendar -> 週 mode.
        app.typeKey("2", modifierFlags: .command)
        let modeButton = app.buttons["calendarMode"]
        XCTAssertTrue(modeButton.waitForExistence(timeout: 3), app.debugDescription)
        modeButton.tap()
        XCTAssertTrue(app.buttons["週"].waitForExistence(timeout: 3))
        app.buttons["週"].tap()
        shot("ipad-landscape-calendar-week")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(modeButton.waitForExistence(timeout: 3))
        shot("ipad-portrait-calendar-week")

        // ⌘4 switches to Settings.
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["外觀"].waitForExistence(timeout: 3), app.debugDescription)
        shot("ipad-portrait-settings")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["外觀"].waitForExistence(timeout: 3))
        shot("ipad-landscape-settings")

        // ⌘F opens Search.
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.textFields["搜尋任務、描述、標籤、子任務"].waitForExistence(timeout: 3), app.debugDescription)

        // ⌘1 switches back to Tasks, navigate to 工作, open Share sheet.
        app.typeKey("1", modifierFlags: .command)
        openListWorkFromSidebar()

        let shareToolbarBtn = app.buttons["共享"]
        XCTAssertTrue(shareToolbarBtn.waitForExistence(timeout: 3), app.debugDescription)
        shareToolbarBtn.tap()
        XCTAssertTrue(app.staticTexts["共享清單"].waitForExistence(timeout: 3), app.debugDescription)
        shot("ipad-landscape-share-sheet")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts["共享清單"].waitForExistence(timeout: 3))
        shot("ipad-portrait-share-sheet")
    }

    @MainActor
    func testIPadSignInScreenshots() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-DayDoReset"]
        app.launch()

        XCTAssertTrue(app.buttons["signIn.apple"].waitForExistence(timeout: 5), app.debugDescription)
        shot("ipad-portrait-signin")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["signIn.apple"].waitForExistence(timeout: 3))
        shot("ipad-landscape-signin")
    }
}
