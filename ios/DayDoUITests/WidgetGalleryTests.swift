import XCTest

/// Drives iPad SpringBoard to inspect the DayDo widget gallery (「本週」 and 「日曆」)
/// and add extra-large / portrait extra-large widgets to the home screen.
final class WidgetGalleryTests: XCTestCase {
    var app: XCUIApplication!
    var springboard: XCUIApplication!

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

    @MainActor
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

    @MainActor
    private func dumpSpringboardState(_ tag: String) {
        let buttons = springboard.buttons.allElementsBoundByIndex.prefix(40).map { "btn(\($0.identifier)|\($0.label))" }
        let texts = springboard.staticTexts.allElementsBoundByIndex.prefix(40).map { "txt(\($0.label))" }
        let fields = springboard.searchFields.allElementsBoundByIndex.prefix(5).map { "search(\($0.label)|\($0.placeholderValue ?? ""))" }
        let indicators = springboard.pageIndicators.allElementsBoundByIndex.prefix(5).map { "page(\($0.value ?? ""))" }
        let summary = "[\(tag)]\nbuttons: \(buttons)\ntexts: \(texts)\nsearchFields: \(fields)\npageIndicators: \(indicators)"
        print(summary)
        let att = XCTAttachment(string: summary)
        att.name = "sb-\(tag)"
        att.lifetime = .keepAlways
        add(att)
    }

    @MainActor
    private func firstExisting(_ elements: [XCUIElement], timeout: TimeInterval = 2) -> XCUIElement? {
        for el in elements {
            if el.exists { return el }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for el in elements where el.exists { return el }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    @MainActor
    private func openWidgetGallery() -> Bool {
        // Long-press an empty region on the home screen to enter edit (jiggle) mode.
        let emptySpots = [
            CGVector(dx: 0.88, dy: 0.45),
            CGVector(dx: 0.82, dy: 0.72),
            CGVector(dx: 0.50, dy: 0.82),
        ]
        var editButton: XCUIElement?
        var directAdd: XCUIElement?

        for spot in emptySpots {
            springboard.coordinate(withNormalizedOffset: spot).press(forDuration: 1.5)
            editButton = firstExisting([
                springboard.buttons["編輯"],
                springboard.buttons["Edit"],
            ], timeout: 2)
            directAdd = firstExisting([
                springboard.buttons["加入小工具"],
                springboard.buttons["Add Widget"],
                springboard.buttons["+"],
            ], timeout: 1)
            if editButton != nil || directAdd != nil { break }
        }

        shot("02-home-edit-mode")
        if let edit = editButton {
            edit.tap()
            let addItem = firstExisting([
                springboard.buttons["加入小工具"],
                springboard.buttons["Add Widget"],
                springboard.staticTexts["加入小工具"],
                springboard.staticTexts["Add Widget"],
            ], timeout: 3)
            if let addItem {
                addItem.tap()
                return true
            }
            dumpSpringboardState("after-edit-tap")
            return false
        }
        if let direct = directAdd {
            direct.tap()
            return true
        }
        dumpSpringboardState("no-edit-button")
        return false
    }

    @MainActor
    private func selectDayDoInGallery() -> Bool {
        // Prefer searching for DayDo in the gallery search field.
        let searchField = springboard.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 3) {
            searchField.tap()
            searchField.typeText("DayDo")
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        }
        shot("03b-gallery-searched")

        // Tap DayDo in the app list or search results.
        let candidates: [XCUIElement] = [
            springboard.cells.matching(NSPredicate(format: "label CONTAINS[c] 'DayDo'")).firstMatch,
            springboard.buttons.matching(NSPredicate(format: "label == 'DayDo'")).firstMatch,
            springboard.staticTexts["DayDo"].firstMatch,
        ]
        if let hit = firstExisting(candidates, timeout: 3) {
            hit.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            return true
        }
        dumpSpringboardState("daydo-not-found")
        return false
    }

    @MainActor
    private func galleryPageIndicator() -> XCUIElement? {
        let all = springboard.pageIndicators.allElementsBoundByIndex
        if all.count >= 2 { return all.last }
        return all.first
    }

    @MainActor
    private func galleryPreviewElement() -> XCUIElement? {
        let btn = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'DayDo,'")).firstMatch
        return btn.exists ? btn : nil
    }

    @MainActor
    private func currentGalleryTitle() -> String {
        let known = ["今日任務", "下一個行程", "日曆", "本週"]
        for name in known where springboard.staticTexts[name].exists {
            return name
        }
        return springboard.staticTexts.allElementsBoundByIndex.first?.label ?? "unknown"
    }

    @MainActor
    private func advanceGalleryPage(indicator: XCUIElement?) {
        // Swiping left on the preview button or the right pane advances the gallery pager reliably.
        if let preview = galleryPreviewElement() {
            preview.swipeLeft()
        } else {
            let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.50))
            let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.50))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        // Fallback: tap the right side of the gallery page indicator if swipe didn't move.
        _ = indicator
    }

    /// Walks all pages in DayDo's widget gallery, screenshotting every 「日曆」 and 「本週」 size,
    /// and returns a summary of `(index, title, pageIndicatorValue, previewSize)` for every page.
    @MainActor
    private func inspectAllDayDoGalleryPages() -> [(index: Int, title: String, page: String, size: CGSize)] {
        var pages: [(Int, String, String, CGSize)] = []
        let indicator = galleryPageIndicator()
        var lastPage = ""
        var calIdx = 0
        var weekIdx = 0

        for step in 0..<20 {
            let pageVal = (indicator?.exists == true) ? (indicator?.value as? String ?? "") : ""
            if step > 0 && !pageVal.isEmpty && pageVal == lastPage {
                // Retry once via tapping right half of the page indicator in case swipe missed.
                if let indicator, indicator.exists {
                    indicator.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                    let retryVal = indicator.value as? String ?? ""
                    if retryVal == lastPage { break }
                } else {
                    break
                }
            }
            let currentVal = (indicator?.exists == true) ? (indicator?.value as? String ?? "") : ""
            lastPage = currentVal
            let title = currentGalleryTitle()
            let size = galleryPreviewElement()?.frame.size ?? .zero
            pages.append((step, title, currentVal, size))
            print("GALLERY_PAGE[\(step)] title=\(title) page=\(currentVal) preview=\(Int(size.width))x\(Int(size.height))")

            if title == "日曆" {
                shot("05-calendar-size-\(calIdx)")
                calIdx += 1
            } else if title == "本週" {
                shot("05-week-size-\(weekIdx)")
                weekIdx += 1
            }

            advanceGalleryPage(indicator: indicator)
        }

        let report = pages.map { "[\($0.0)] \($0.1) (\($0.2)) preview=\(Int($0.3.width))x\(Int($0.3.height))" }.joined(separator: "\n")
        print("GALLERY_SUMMARY:\n\(report)")
        let att = XCTAttachment(string: report)
        att.name = "gallery-summary"
        att.lifetime = .keepAlways
        add(att)
        return pages
    }

    @MainActor
    private func addCurrentWidgetAndFinish(shotName: String) -> Bool {
        guard let addBtn = firstExisting([
            springboard.buttons.matching(NSPredicate(format: "label CONTAINS '加入小工具' OR label CONTAINS 'Add Widget'")).firstMatch,
        ], timeout: 2) else {
            return false
        }
        addBtn.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot(shotName)
        return true
    }

    @MainActor
    func testIPadWidgetGalleryAndHomeScreen() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Launch app once with demo data so App Group SQLite & widgets have content.
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin"]
        app.launch()
        let allow = springboard.buttons["允許"].exists ? springboard.buttons["允許"] : springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["完成：去全聯買菜"].waitForExistence(timeout: 6), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        // Return to iPad Home Screen.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        shot("01-home-initial")

        guard openWidgetGallery() else {
            shot("99-stopped-open-gallery")
            XCTFail("Could not open Widget Gallery from SpringBoard")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        shot("03-widget-gallery")

        guard selectDayDoInGallery() else {
            shot("99-stopped-select-daydo")
            XCTFail("Could not select DayDo in Widget Gallery")
            return
        }
        shot("04-daydo-gallery")

        // Walk every page in DayDo's gallery; ends on the last page (本週's largest offered size).
        let pages = inspectAllDayDoGalleryPages()
        XCTAssertTrue(pages.contains(where: { $0.title == "本週" }), "Expected 「本週」 in widget gallery")
        XCTAssertTrue(pages.contains(where: { $0.title == "日曆" }), "Expected 「日曆」 in widget gallery")

        // We are now on the last page of 本週 (extra-large or portrait extra-large). Add it to Home Screen.
        let weekPages = pages.filter { $0.title == "本週" }
        let hasPortraitXL = weekPages.contains { $0.size.height > $0.size.width * 1.3 }
        XCTAssertTrue(addCurrentWidgetAndFinish(shotName: "06-after-add-week-1"), "Could not add 本週 widget")

        // If both extra-large and portrait extra-large were offered, add the other one too.
        if hasPortraitXL {
            if openWidgetGallery(), selectDayDoInGallery() {
                let indicator = galleryPageIndicator()
                let targetIdx = max(0, pages.count - 2)
                for _ in 0..<targetIdx {
                    advanceGalleryPage(indicator: indicator)
                }
                _ = addCurrentWidgetAndFinish(shotName: "06b-after-add-week-2")
            }
        }

        if let doneBtn = firstExisting([
            springboard.buttons["完成"],
            springboard.buttons["Done"],
        ], timeout: 2) {
            doneBtn.tap()
        } else {
            XCUIDevice.shared.press(.home)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("07-home-final")
    }
}
