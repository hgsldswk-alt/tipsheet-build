import XCTest

final class StoreShotsUITests: XCTestCase {
    private let languages = [("en", "en_US"), ("zh-Hans", "zh_CN"), ("zh-Hant", "zh_TW")]
    private let pages = [
        ("1-home", "homeScreen", [String]()),
        ("2-log-shift", "saveShift", ["-sample-shift"]),
        ("3-calendar", "calendarScreen", ["-calendar"]),
        ("4-insights", "insightsScreen", ["-insights"]),
        ("5-share", "shareCardButton", ["-share"]),
        ("6-paywall", "buyPro", ["-paywall"])
    ]

    override func setUp() { continueAfterFailure = false }

    func testStoreScreenshots() throws {
        for (language, locale) in languages {
            for (page, landmark, arguments) in pages {
                let app = XCUIApplication()
                app.launchArguments = ["-demo", "-AppleLanguages", "(\(language))", "-AppleLocale", locale] + arguments
                app.launch()
                let entry = app.descendants(matching: .any).matching(identifier: landmark).firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 8), "\(language) \(page)")
                if page == "2-log-shift" {
                    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
                }
                try save(app.screenshot(), name: "store-\(language)-\(page)")
            }
        }
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) throws {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let env = ProcessInfo.processInfo.environment
        if let path = env["SHOTS_DIR"] ?? env["TEST_RUNNER_SHOTS_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        }
    }
}
