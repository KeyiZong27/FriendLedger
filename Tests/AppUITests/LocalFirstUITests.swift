import XCTest

@MainActor
final class LocalFirstUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeApp(slowCloud: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEDGER_TEST_CACHE_ID"] = UUID().uuidString
        if slowCloud { app.launchEnvironment["LEDGER_TEST_SLOW_CLOUD"] = "1" }
        return app
    }

    private func createLedger(in app: XCUIApplication) {
        let create = app.buttons["create-local-ledger"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let name = app.textFields["ledger-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Local test")
        app.buttons["save-ledger"].tap()
        XCTAssertTrue(app.buttons["new-entry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["local-sync-status"].label.contains("仅保存在本机"))
    }

    private func addEntry(in app: XCUIApplication, note: String) {
        app.buttons["new-entry"].tap()
        let amount = app.textFields["entry-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("12.34")
        let memo = app.textFields["entry-note"]
        memo.tap()
        memo.typeText(note)
        let author = app.textFields["entry-author"]
        if !author.isHittable { app.swipeUp() }
        author.tap()
        author.typeText("Tester")
        app.buttons["save-entry"].tap()
        let total = app.staticTexts["expense-total"]
        XCTAssertTrue(total.waitForExistence(timeout: 5))
        XCTAssertEqual(total.label, "$12.34")
    }

    func testLocalCreationAndEntrySurviveRelaunchWithoutCloud() {
        let app = makeApp()
        let start = Date()
        app.launch()
        XCTAssertTrue(app.buttons["create-local-ledger"].waitForExistence(timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(start), 15, "Local startup must not wait for iCloud")
        createLedger(in: app)
        addEntry(in: app, note: "Persistent entry")
        XCTAssertFalse(app.descendants(matching: .any)["ledger-error"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sync-progress"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["expense-total"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["expense-total"].label, "$12.34")
        XCTAssertTrue(app.staticTexts["Persistent entry"].exists)
        XCTAssertTrue(app.staticTexts["local-sync-status"].label.contains("仅保存在本机"))
        XCTAssertFalse(app.descendants(matching: .any)["ledger-error"].exists)
        app.terminate()
    }

    func testSlowCloudShowsProgressWithoutBlockingLocalEntry() {
        let app = makeApp(slowCloud: true)
        app.launch()
        createLedger(in: app)
        let toggle = app.switches["sync-toggle"]
        XCTAssertTrue(toggle.exists)
        toggle.switches.firstMatch.tap()
        let progress = app.descendants(matching: .any)["sync-progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(progress.frame.width, 0)
        XCTAssertLessThan(progress.frame.maxY, 320, "Loading indicator must be visible near the top, not below the records")
        XCTAssertTrue(app.buttons["new-entry"].isEnabled)
        let start = Date()
        addEntry(in: app, note: "Saved while connecting")
        XCTAssertLessThan(Date().timeIntervalSince(start), 45, "Local save must finish before the 60-second cloud response")
        XCTAssertTrue(progress.exists, "Progress must remain visible while cloud is still connecting")
        app.terminate()
    }

    func testCloudConfigurationFailureKeepsLocalBookUsable() {
        let app = makeApp()
        app.launch()
        createLedger(in: app)
        app.switches["sync-toggle"].switches.firstMatch.tap()
        let error = app.staticTexts["ledger-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("开启同步失败"))
        XCTAssertTrue(app.staticTexts["local-sync-status"].label.contains("仅保存在本机"))
        addEntry(in: app, note: "Saved after cloud failure")
        app.terminate()
    }
}
