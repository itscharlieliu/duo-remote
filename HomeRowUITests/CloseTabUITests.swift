import XCTest

/// Opens a Screen Sharing session via the debug demo hook and closes it
/// from the tab. Needs TEST_RUNNER_HOMEROW_UI_RFB=host:port:user:password.
final class CloseTabUITests: XCTestCase {
    private func launch(posture: String = "folded") throws -> XCUIApplication {
        guard let rfb = ProcessInfo.processInfo.environment["HOMEROW_UI_RFB"] else {
            throw XCTSkip("HOMEROW_UI_RFB not set")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HOMEROW_DEMO_RFB"] = rfb
        app.launchEnvironment["HOMEROW_DEMO_FOCUS"] = "screen"
        app.launchEnvironment["HOMEROW_DEMO_POSTURE"] = posture
        app.launch()
        return app
    }

    func testCloseKeyClosesScreenTab() throws { try closeKey(posture: "folded") }
    func testCloseKeyClosesScreenTabDeck() throws { try closeKey(posture: "deck") }
    func testContextMenuClosesScreenTab() throws { try contextMenu(posture: "folded") }
    func testContextMenuClosesScreenTabDeck() throws { try contextMenu(posture: "deck") }

    private func closeKey(posture: String) throws {
        let app = try launch(posture: posture)
        let close = app.buttons["Close studio — screen"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(app.staticTexts["studio — screen"].waitForNonExistence(timeout: 5))
    }

    private func contextMenu(posture: String) throws {
        let app = try launch(posture: posture)
        let tab = app.staticTexts["studio — screen"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.press(forDuration: 1.0)
        let menuClose = app.buttons["Close"]
        XCTAssertTrue(menuClose.waitForExistence(timeout: 5))
        menuClose.tap()
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5))
    }
}
