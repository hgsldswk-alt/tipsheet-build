import XCTest

final class FlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testFirstShiftAndTwoTapRepeat() {
        let app = launch(["-ui-testing"])
        let card = app.textFields["cardTips"]
        XCTAssertTrue(card.waitForExistence(timeout: 6))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        app.typeText("140")
        app.buttons["saveShift"].tap()
        XCTAssertTrue(app.buttons["logShift"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["recentShift-0"].firstMatch.exists)
        app.buttons["logShift"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        app.typeText("95")
        app.buttons["saveShift"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recentShift-1"].firstMatch.waitForExistence(timeout: 4))
    }

    func testDeleteUndoAndPrivacy() {
        let app = launch(["-demo"])
        let first = app.descendants(matching: .any)["recentShift-0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        first.swipeLeft()
        let remove = app.buttons["Delete"].firstMatch
        if remove.waitForExistence(timeout: 1) { remove.tap() }
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(first.exists)

        app.buttons["privacyButton"].tap()
        let total = app.staticTexts["weeklyTotal"].firstMatch
        XCTAssertTrue(total.exists)
        XCTAssertTrue(total.label.contains("••••"))
        XCTAssertTrue(app.staticTexts["Amounts hidden"].exists)
    }

    func testExpiredTrialKeepsLoggingAndExportEntry() {
        let app = launch(["-demo", "-expired"])
        app.buttons["insightsTab"].tap()
        XCTAssertTrue(app.buttons["Explore Pro"].waitForExistence(timeout: 4))
        app.buttons["homeTab"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recentShift-0"].firstMatch.exists)
        app.buttons["logShift"].tap()
        XCTAssertTrue(app.buttons["saveShift"].waitForExistence(timeout: 4))
        app.buttons["Cancel"].tap()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["exportCSV"].waitForExistence(timeout: 4))
    }

    @discardableResult
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        return app
    }
}
