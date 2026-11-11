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

    private func completeSetup(in app: XCUIApplication) {
        let name = app.textFields["setup-nickname"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Tester")
        app.buttons["setup-continue"].tap()
        XCTAssertTrue(app.buttons["new-entry"].waitForExistence(timeout: 5))
        let ledgerName = app.descendants(matching: .any)["ledger-name-label"].firstMatch
        XCTAssertTrue(ledgerName.waitForExistence(timeout: 5))
        XCTAssertTrue(ledgerName.label.contains("Tester的账本"), "Setup must create a personal ledger automatically")
    }

    private func openSettings(in app: XCUIApplication) {
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.switches["sync-toggle"].waitForExistence(timeout: 5))
    }

    private func addEntry(in app: XCUIApplication, note: String) {
        app.buttons["new-entry"].tap()
        app.buttons["add-manual"].tap()
        let amount = app.textFields["entry-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("12.34")
        let memo = app.textFields["entry-note"]
        memo.tap()
        memo.typeText(note)
        XCTAssertFalse(app.textFields["entry-author"].exists, "Nickname is configured once, not per entry")
        app.buttons["save-entry"].tap()
        let total = app.staticTexts["expense-total"]
        XCTAssertTrue(total.waitForExistence(timeout: 5))
        XCTAssertEqual(total.label, "$12.34")
    }

    func testLocalCreationAndEntrySurviveRelaunchWithoutCloud() {
        let app = makeApp()
        let start = Date()
        app.launch()
        XCTAssertTrue(app.textFields["setup-nickname"].waitForExistence(timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(start), 15, "Local startup must not wait for iCloud")
        completeSetup(in: app)
        addEntry(in: app, note: "Persistent entry")
        XCTAssertFalse(app.descendants(matching: .any)["ledger-error"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sync-progress"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["expense-total"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["setup-nickname"].exists, "Setup must not repeat after relaunch")
        XCTAssertEqual(app.staticTexts["expense-total"].label, "$12.34")
        XCTAssertTrue(app.staticTexts["Persistent entry"].exists)
        openSettings(in: app)
        XCTAssertTrue(app.staticTexts["local-sync-status"].label.contains("仅保存在本机"))
        XCTAssertFalse(app.descendants(matching: .any)["ledger-error"].exists)
        app.terminate()
    }

    func testSlowCloudShowsProgressWithoutBlockingLocalEntry() {
        let app = makeApp(slowCloud: true)
        app.launch()
        completeSetup(in: app)
        openSettings(in: app)
        app.switches["sync-toggle"].switches.firstMatch.tap()
        app.buttons["完成"].tap()
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

    private func scanTestReceipt(in app: XCUIApplication) {
        app.buttons["new-entry"].tap()
        XCTAssertTrue(app.buttons["add-camera"].exists)
        XCTAssertTrue(app.buttons["add-library"].exists)
        app.buttons["add-test-receipt"].tap()
    }

    func testReceiptPhotoRecognizesStoreAndCategorizesAutomatically() {
        let app = makeApp()
        app.launch()
        completeSetup(in: app)
        scanTestReceipt(in: app)
        let merchant = app.textFields["receipt-merchant"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 40), "Vision must read the store from the photo")
        XCTAssertTrue(((merchant.value as? String) ?? "").uppercased().contains("TRADER"))
        XCTAssertEqual(app.textFields["receipt-amount"].value as? String, "7.56")
        let type = app.descendants(matching: .any)["receipt-type"].firstMatch
        XCTAssertTrue(type.label.contains("超市"), "Store type must be chosen automatically, got \(type.label)")
        XCTAssertTrue(app.staticTexts["receipt-type-hint"].label.contains("自动判断"))
        app.buttons["save-receipt"].tap()
        let total = app.staticTexts["expense-total"]
        XCTAssertTrue(total.waitForExistence(timeout: 10))
        XCTAssertEqual(total.label, "$7.56")
        XCTAssertTrue(app.staticTexts["超市 · Tester"].exists, "Saved receipt must show the automatic type and member")

        scanTestReceipt(in: app)
        XCTAssertTrue(app.textFields["receipt-merchant"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts["receipt-type-hint"].label.contains("已记住"),
                      "A remembered store must reuse its type without asking again")
        app.buttons["save-receipt"].tap()
        XCTAssertTrue(app.staticTexts["receipt-error"].waitForExistence(timeout: 5), "The same photo must not be recorded twice")
        XCTAssertEqual(app.staticTexts["receipt-error"].label, "这张收据已经入账，不能重复添加。")
        app.buttons["取消"].tap()
        XCTAssertEqual(app.staticTexts["expense-total"].label, "$7.56")
        app.terminate()
    }

    func testManualEntryCategoryIsAutomatic() {
        let app = makeApp()
        app.launch()
        completeSetup(in: app)
        app.buttons["new-entry"].tap()
        app.buttons["add-manual"].tap()
        XCTAssertFalse(app.buttons["分类"].exists, "Category must not be a manual choice")
        let amount = app.textFields["entry-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("4.50")
        let memo = app.textFields["entry-note"]
        memo.tap()
        memo.typeText("Starbucks")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "分类自动设为“咖啡”")).firstMatch.exists)
        app.buttons["save-entry"].tap()
        XCTAssertTrue(app.staticTexts["咖啡 · Tester"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testCloudConfigurationFailureKeepsLocalBookUsable() {
        let app = makeApp()
        app.launch()
        completeSetup(in: app)
        openSettings(in: app)
        app.switches["sync-toggle"].switches.firstMatch.tap()
        let error = app.staticTexts["ledger-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5) || app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "开启同步失败")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["local-sync-status"].label.contains("仅保存在本机"))
        app.buttons["完成"].tap()
        addEntry(in: app, note: "Saved after cloud failure")
        app.terminate()
    }
}
