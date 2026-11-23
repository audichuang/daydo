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
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            } catch {
                XCTFail("DAYDO_SHOTS: could not write \(name).png to \(dir): \(error)")
            }
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

    // MARK: - Regression tests for iPad layout fixes

    @MainActor
    func testTrashScopeDeleteDoesNotPurgeNonDeletedTask() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .landscapeLeft)

        let taskRow = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).element(boundBy: 1)
        XCTAssertTrue(taskRow.waitForExistence(timeout: 5), app.debugDescription)
        taskRow.tap()

        let titleField = app.descendants(matching: .any)["taskTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))

        // Switch to 垃圾桶 in sidebar; selection should clear and Return/Delete must NOT act on Today's task.
        app.buttons["垃圾桶"].tap()
        XCTAssertTrue(app.staticTexts["刪除的任務可在這裡還原"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(titleField.exists, "Changing scope to 垃圾桶 should clear selectedTaskId")

        app.typeKey(XCUIKeyboardKey(rawValue: "\n"), modifierFlags: [])
        XCTAssertFalse(titleField.exists, "Return should not focus Today's task after scope change")

        // Switch back to 今天 and confirm the task is still there.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '今天'")).firstMatch.tap()
        let preservedTask = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).element(boundBy: 1)
        XCTAssertTrue(preservedTask.waitForExistence(timeout: 3), "Non-deleted task must not be purged by Trash scope")

        // Soft-delete the task via context menu, open 垃圾桶, and verify permanent purge from Trash works.
        preservedTask.press(forDuration: 1.0)
        app.buttons["刪除"].tap()
        XCTAssertTrue(preservedTask.waitForNonExistence(timeout: 3))

        app.buttons["垃圾桶"].tap()
        let trashedRow = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).element(boundBy: 1)
        XCTAssertTrue(trashedRow.waitForExistence(timeout: 3), app.debugDescription)
        trashedRow.press(forDuration: 1.0)
        app.buttons["永久刪除"].tap()
        XCTAssertTrue(trashedRow.waitForNonExistence(timeout: 3), "Soft-deleted task in 垃圾桶 should purge cleanly")
    }

    @MainActor
    func testInlineDetailAutoSavesOnTaskAndTabSwitch() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .landscapeLeft)

        let taskA = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).element(boundBy: 1)
        XCTAssertTrue(taskA.waitForExistence(timeout: 5), app.debugDescription)
        taskA.tap()

        let titleField = app.descendants(matching: .any)["taskTitleField"]
        let contentField = app.descendants(matching: .any)["taskContentField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        titleField.tap()
        titleField.typeText(" [草稿1]")
        contentField.tap()
        contentField.typeText(" [描述草稿]")

        // Switch to another task without tapping 儲存.
        let taskB = app.buttons.matching(NSPredicate(format: "label CONTAINS '去全聯買菜'")).element(boundBy: 1)
        XCTAssertTrue(taskB.waitForExistence(timeout: 3))
        taskB.tap()

        // Re-select task A and verify title and description were auto-saved.
        let updatedTaskA = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報' AND label CONTAINS '[草稿1]'")).element(boundBy: 1)
        XCTAssertTrue(updatedTaskA.waitForExistence(timeout: 3), app.debugDescription)
        updatedTaskA.tap()
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        XCTAssertTrue(((titleField.value as? String) ?? "").contains("[草稿1]"))
        XCTAssertTrue(((contentField.value as? String) ?? "").contains("[描述草稿]"))

        // Edit again and switch tab with ⌘2, then return with ⌘1.
        titleField.tap()
        titleField.typeText(" [切頁]")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["calendarMode"].waitForExistence(timeout: 3))
        app.typeKey("1", modifierFlags: .command)

        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        XCTAssertTrue(((titleField.value as? String) ?? "").contains("[切頁]"), "Tab switch should auto-save dirty inline title")
    }

    @MainActor
    func testSettingsSubpageDoesNotCoverOtherTabs() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .landscapeLeft)

        app.buttons["sidebar.settings"].tap()
        let appearanceBtn = app.buttons["外觀"]
        XCTAssertTrue(appearanceBtn.waitForExistence(timeout: 3), app.debugDescription)
        appearanceBtn.tap()
        XCTAssertTrue(app.staticTexts["主題色"].waitForExistence(timeout: 3), app.debugDescription)

        // Switch to Calendar and Search; AppearanceSettingsView must not cover them.
        app.buttons["sidebar.calendar"].tap()
        XCTAssertTrue(app.buttons["calendarMode"].waitForExistence(timeout: 3), "Calendar should be visible after Settings sub-page")
        XCTAssertFalse(app.staticTexts["主題色"].exists)

        app.buttons["sidebar.search"].tap()
        XCTAssertTrue(app.textFields["搜尋任務、描述、標籤、子任務"].waitForExistence(timeout: 3), "Search should be visible after Settings sub-page")

        // Switch back to Settings; should reset to Settings root, not stay on AppearanceSettingsView.
        app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(appearanceBtn.waitForExistence(timeout: 3), "Settings should reset to root after tab switch")

        // Verify Portrait mode still shows sidebar toggle and Settings/Calendar navigation works.
        XCUIDevice.shared.orientation = .portrait
        appearanceBtn.tap()
        XCTAssertTrue(app.staticTexts["主題色"].waitForExistence(timeout: 3))
        let sidebarToggle = app.buttons["顯示側邊欄"]
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 3), app.debugDescription)
        sidebarToggle.tap()
        XCTAssertTrue(app.buttons["sidebar.calendar"].waitForExistence(timeout: 3))
        app.buttons["sidebar.calendar"].tap()
        XCTAssertTrue(app.buttons["calendarMode"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["主題色"].exists)
    }

    @MainActor
    func testRootSheetsInheritIsRegularWindow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .landscapeLeft)

        let windowWidth = app.windows.firstMatch.frame.width

        // Open ComposerSheet via ⌘N; with isRegularWindow == true it gets .presentationSizing(.form)
        // (narrower than full window) and "新增並開啟詳細設定" selects inline instead of opening a sheet.
        app.typeKey("n", modifierFlags: .command)
        let composer = app.descendants(matching: .any)["composerTitle"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("表單環境測試")

        app.buttons["composerMore"].tap()
        let openDetail = app.buttons["新增並開啟詳細設定"]
        XCTAssertTrue(openDetail.waitForExistence(timeout: 3))
        openDetail.tap()

        // Inline detail should open (no phone full-screen toggle) and show the newly created task.
        let titleField = app.descendants(matching: .any)["taskTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertFalse(app.buttons["展開為全屏"].exists, "ComposerSheet should see isRegularWindow == true and open inline detail")
        XCTAssertEqual(titleField.value as? String, "表單環境測試")
        XCTAssertLessThan(titleField.frame.width, windowWidth * 0.7)
    }

    @MainActor
    func testInlineDetailDatePageIgnoresReturnAndDelete() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .landscapeLeft)

        let taskRow = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).element(boundBy: 1)
        XCTAssertTrue(taskRow.waitForExistence(timeout: 5), app.debugDescription)
        taskRow.tap()

        let titleField = app.descendants(matching: .any)["taskTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3), app.debugDescription)

        let dateButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '設定日期與時間：'")).firstMatch
        XCTAssertTrue(dateButton.waitForExistence(timeout: 3), app.debugDescription)
        dateButton.tap()

        let confirmBtn = app.buttons["確定"]
        XCTAssertTrue(confirmBtn.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["持續時間"].exists, app.debugDescription)
        XCTAssertFalse(titleField.exists)

        app.typeKey(XCUIKeyboardKey(rawValue: "\n"), modifierFlags: [])
        app.typeKey(.delete, modifierFlags: [])

        XCTAssertTrue(confirmBtn.exists, "Return/Delete must not close DatePanel")
        XCTAssertTrue(app.buttons["持續時間"].exists)
        XCTAssertFalse(titleField.exists, "Return must not switch back to detail page")

        app.buttons["取消"].tap()
        XCTAssertTrue(titleField.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(taskRow.exists, "Delete on DatePanel must not delete the task")
    }

    @MainActor
    func testTrashScopeCommandNDoesNotOpenComposer() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .landscapeLeft)

        let trashBtn = app.buttons["垃圾桶"]
        XCTAssertTrue(trashBtn.waitForExistence(timeout: 5), app.debugDescription)
        trashBtn.tap()
        XCTAssertTrue(app.staticTexts["刪除的任務可在這裡還原"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["新增任務"].exists)

        let composer = app.descendants(matching: .any)["composerTitle"]
        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(composer.waitForExistence(timeout: 1.5), "⌘N must not open composer in 垃圾桶")

        app.buttons["已完成"].tap()
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["新增任務"].exists)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(composer.waitForExistence(timeout: 1.5), "⌘N must not open composer in 已完成")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '今天'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["新增任務"].waitForExistence(timeout: 3))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(composer.waitForExistence(timeout: 3), "⌘N should open composer in 今天")
    }

    @MainActor
    func testIPadShareActionsPresentSystemShareSheet() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .landscapeLeft)
        openListWorkFromSidebar()

        // 1. Task-list more menu -> 更多 -> 分享
        let moreOptions = app.buttons["更多選項"]
        XCTAssertTrue(moreOptions.waitForExistence(timeout: 3), app.debugDescription)
        moreOptions.tap()
        let moreSubmenu = app.buttons["更多"]
        XCTAssertTrue(moreSubmenu.waitForExistence(timeout: 3), app.debugDescription)
        moreSubmenu.tap()
        let shareMenuItem = app.buttons["分享"]
        XCTAssertTrue(shareMenuItem.waitForExistence(timeout: 3), app.debugDescription)
        shareMenuItem.tap()

        assertSystemShareSheetPresented(context: "iPad task-list share menu")
        dismissSystemShareSheet()

        // 2. ShareListSheet -> 建立邀請連結 -> 分享邀請連結
        let shareToolbarBtn = app.buttons["共享"]
        XCTAssertTrue(shareToolbarBtn.waitForExistence(timeout: 3), app.debugDescription)
        shareToolbarBtn.tap()
        let createInvite = app.buttons["share.createInviteLink"]
        XCTAssertTrue(createInvite.waitForExistence(timeout: 3), app.debugDescription)
        createInvite.tap()
        let shareLinkBtn = app.buttons["share.shareLink"]
        XCTAssertTrue(shareLinkBtn.waitForExistence(timeout: 3), app.debugDescription)
        shareLinkBtn.tap()

        assertSystemShareSheetPresented(context: "iPad ShareListSheet")
    }

    @MainActor
    func testIPadCustomListKanbanView() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        launchDemo(orientation: .landscapeLeft)
        openListWorkFromSidebar()

        let moreOptions = app.buttons["更多選項"]
        XCTAssertTrue(moreOptions.waitForExistence(timeout: 3), app.debugDescription)
        moreOptions.tap()
        let viewMenu = app.buttons["視圖"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 3), app.debugDescription)
        viewMenu.tap()
        let kanbanItem = app.buttons["看板"]
        XCTAssertTrue(kanbanItem.waitForExistence(timeout: 3), app.debugDescription)
        kanbanItem.tap()

        // Columns and cards from DemoData's 工作 list (已逾期 / 今天 / 明天 / 之後 + fixed 無日期 / 已完成).
        XCTAssertTrue(app.otherElements["kanban.column.overdue"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(app.otherElements["kanban.column.today"].exists, app.debugDescription)
        XCTAssertTrue(app.otherElements["kanban.column.tomorrow"].exists, app.debugDescription)
        XCTAssertTrue(app.otherElements["kanban.column.nodate"].exists, app.debugDescription)
        XCTAssertTrue(app.otherElements["kanban.column.completed"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["今天"].exists)
        XCTAssertTrue(app.staticTexts["明天"].exists)
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS '準備週一產品會議簡報'")).element(boundBy: 1)
        XCTAssertTrue(card.waitForExistence(timeout: 3), app.debugDescription)
        shot("ipad-landscape-kanban")

        // Tapping a Kanban card opens inline detail on regular layout.
        card.tap()
        let titleField = app.descendants(matching: .any)["taskTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["展開為全屏"].exists)

        // Switch back to list view and verify Kanban columns disappear.
        let navMoreOptions = app.navigationBars.buttons["更多選項"].firstMatch
        XCTAssertTrue(navMoreOptions.waitForExistence(timeout: 3))
        navMoreOptions.tap()
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 3))
        viewMenu.tap()
        let listItem = app.buttons["列表"]
        XCTAssertTrue(listItem.waitForExistence(timeout: 3))
        listItem.tap()
        XCTAssertTrue(app.otherElements["kanban.column.today"].waitForNonExistence(timeout: 3))
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
        let closeAction = app.buttons.matching(NSPredicate(format: "label == '關閉' OR label == 'Close'")).firstMatch
        if closeAction.exists {
            closeAction.tap()
        } else if app.otherElements["PopoverDismissRegion"].exists {
            app.otherElements["PopoverDismissRegion"].tap()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        let activityList = app.otherElements["ActivityListView"]
        XCTAssertTrue(activityList.waitForNonExistence(timeout: 4), app.debugDescription)
    }
}
