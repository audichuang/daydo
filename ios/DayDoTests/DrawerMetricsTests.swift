import XCTest
@testable import DayDo

final class DrawerMetricsTests: XCTestCase {
    func testWidthScalesAndCapsAt340() {
        XCTAssertEqual(DrawerMetrics.width(for: 393), 393 * 0.82, accuracy: 0.001)
        XCTAssertEqual(DrawerMetrics.width(for: 414), 414 * 0.82, accuracy: 0.001)
        XCTAssertEqual(DrawerMetrics.width(for: 415), 340, accuracy: 0.001)
        XCTAssertEqual(DrawerMetrics.width(for: 800), 340, accuracy: 0.001)
    }

    func testEdgeWidthMatchesSharedGestureContract() {
        XCTAssertEqual(DrawerMetrics.edgeWidth, 40)
    }

    func testShouldOpenThreshold() {
        let width: CGFloat = 320

        // Distance alone opens past half the drawer width.
        XCTAssertFalse(DrawerMetrics.shouldOpen(translationX: 160, velocityX: 0, drawerWidth: width))
        XCTAssertTrue(DrawerMetrics.shouldOpen(translationX: 160.1, velocityX: 0, drawerWidth: width))

        // Fast rightward flick opens once past the 12pt minimum travel.
        XCTAssertFalse(DrawerMetrics.shouldOpen(translationX: 12, velocityX: 501, drawerWidth: width))
        XCTAssertFalse(DrawerMetrics.shouldOpen(translationX: 20, velocityX: 500, drawerWidth: width))
        XCTAssertTrue(DrawerMetrics.shouldOpen(translationX: 12.1, velocityX: 501, drawerWidth: width))
    }

    func testShouldCloseThreshold() {
        let width: CGFloat = 320

        // Distance threshold: < -width * 0.4 (-128).
        XCTAssertFalse(DrawerMetrics.shouldClose(translationX: -128, predictedEndTranslationX: -128, drawerWidth: width))
        XCTAssertTrue(DrawerMetrics.shouldClose(translationX: -128.1, predictedEndTranslationX: -128.1, drawerWidth: width))

        // Velocity/predicted-end threshold: < -width * 0.5 (-160).
        XCTAssertFalse(DrawerMetrics.shouldClose(translationX: -40, predictedEndTranslationX: -160, drawerWidth: width))
        XCTAssertTrue(DrawerMetrics.shouldClose(translationX: -40, predictedEndTranslationX: -160.1, drawerWidth: width))

        // Positive or zero drag never closes.
        XCTAssertFalse(DrawerMetrics.shouldClose(translationX: 0, predictedEndTranslationX: 0, drawerWidth: width))
        XCTAssertFalse(DrawerMetrics.shouldClose(translationX: 30, predictedEndTranslationX: 30, drawerWidth: width))
    }
}
