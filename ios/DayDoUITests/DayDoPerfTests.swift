import XCTest

/// Drives the main animations under a heavy data load (`-DayDoSeedPerf`) for the trace analysis in
/// `ios/scripts/perf/`. Each measure block returns the UI to where it started, so iterations are comparable.
/// Skipped unless `TEST_RUNNER_DAYDO_PERF=1`, so the normal suite doesn't pay ~20 minutes for it.
final class DayDoPerfTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DAYDO_PERF"] == "1", "perf run only (TEST_RUNNER_DAYDO_PERF=1)")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-DayDoReset", "-DayDoDemo", "-DayDoSkipLogin", "-DayDoSeedPerf"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["允許"].waitForExistence(timeout: 3) { springboard.buttons["允許"].tap() }
        // The seed runs after the UI is up; wait for it so measurements don't include it.
        let seeded = app.buttons.matching(NSPredicate(format: "label CONTAINS '壓測任務'")).firstMatch
        XCTAssertTrue(seeded.waitForExistence(timeout: 60), app.debugDescription)
        sleep(3)
    }

    private func hitches(_ block: () -> Void) {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTHitchMetric(application: app)], options: options, block: block)
    }

    private func openCalendar(_ mode: String) {
        app.buttons["日曆"].tap()
        app.buttons["calendarMode"].tap()
        app.buttons[mode].firstMatch.tap()
        sleep(1)
    }

    private var window: XCUIElement { app.windows.firstMatch }

    private func drag(_ from: CGVector, _ to: CGVector) {
        window.coordinate(withNormalizedOffset: from).press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: to))
    }

    /// Control: the same element queries a gesture makes, with no gesture. Main-thread time here is
    /// XCUITest's accessibility snapshot, not something users see.
    func testPerfControlQueriesOnly() {
        hitches {
            XCTAssertTrue(app.buttons["開啟清單抽屜"].exists); sleep(2)
            XCTAssertTrue(app.buttons["開啟清單抽屜"].exists); sleep(2)
        }
    }

    func testPerfTaskListScroll() {
        hitches { app.swipeUp(velocity: .fast); app.swipeDown(velocity: .fast) }
    }

    func testPerfDrawerOpenClose() {
        hitches {
            app.buttons["開啟清單抽屜"].tap()
            sleep(1)
            drag(CGVector(dx: 0.8, dy: 0.5), CGVector(dx: 0.05, dy: 0.5))
            sleep(1)
        }
    }

    func testPerfTabSwitch() {
        hitches {
            app.buttons["日曆"].tap(); sleep(1)
            app.buttons["搜尋"].tap(); sleep(1)
            app.buttons["任務"].tap(); sleep(1)
        }
    }

    func testPerfDetailSheetOpenClose() {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS '壓測任務' AND NOT (label BEGINSWITH '完成：')")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        hitches {
            row.tap()
            let save = app.buttons["儲存"]
            XCTAssertTrue(save.waitForExistence(timeout: 3))
            save.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            XCTAssertTrue(save.waitForNonExistence(timeout: 3))
        }
    }

    func testPerfMonthSwipe() {
        openCalendar("月")
        hitches {
            drag(CGVector(dx: 0.85, dy: 0.28), CGVector(dx: 0.15, dy: 0.28)); sleep(1)
            drag(CGVector(dx: 0.15, dy: 0.28), CGVector(dx: 0.85, dy: 0.28)); sleep(1)
        }
    }

    func testPerfMonthCollapseExpand() {
        openCalendar("清單")
        hitches {
            app.buttons["收合成單週"].tap(); sleep(1)
            app.buttons["展開整個月份"].tap(); sleep(1)
        }
    }

    func testPerfAgendaListScroll() {
        openCalendar("清單")
        hitches { app.swipeUp(velocity: .fast); app.swipeDown(velocity: .fast) }
    }

    func testPerfWeekPageAndScroll() {
        openCalendar("週")
        hitches {
            drag(CGVector(dx: 0.9, dy: 0.6), CGVector(dx: 0.2, dy: 0.6)); sleep(1)
            drag(CGVector(dx: 0.2, dy: 0.6), CGVector(dx: 0.9, dy: 0.6)); sleep(1)
            app.swipeUp(velocity: .fast); app.swipeDown(velocity: .fast)
        }
    }

    func testPerfDayTimeGridScroll() {
        openCalendar("日")
        hitches { app.swipeUp(velocity: .fast); app.swipeDown(velocity: .fast) }
    }

    func testPerfYearView() {
        openCalendar("年")
        hitches { app.swipeUp(velocity: .fast); app.swipeDown(velocity: .fast) }
    }
}
