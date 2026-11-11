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

    func testManualEntryShowsEditableCategoryAndRemembersIt() {
        let app = makeApp()
        app.launch()
        completeSetup(in: app)

        func openForm(store: String, amount: String) {
            app.buttons["new-entry"].tap()
            let field = app.textFields["entry-amount"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(amount)
            let memo = app.textFields["entry-note"]
            memo.tap()
            memo.typeText(store)
        }
        func hint() -> String { app.staticTexts["entry-category-hint"].label }

        // A known brand is guessed and shown below the fields.
        openForm(store: "Starbucks", amount: "4.50")
        let picker = app.descendants(matching: .any)["entry-category"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("咖啡"), "The suggested category must be visible: \(picker.label)")
        XCTAssertTrue(hint().contains("自动判断"), hint())
        app.buttons["save-entry"].tap()
        XCTAssertTrue(app.staticTexts["咖啡 · Tester"].waitForExistence(timeout: 5))

        // An unknown store is put under 其他 until the person chooses; the choice is saved with the entry.
        openForm(store: "Zed Shop", amount: "10.00")
        XCTAssertTrue(app.descendants(matching: .any)["entry-category"].firstMatch.label.contains("其他"))
        XCTAssertTrue(hint().contains("没能判断"), hint())
        app.descendants(matching: .any)["entry-category"].firstMatch.tap()
        app.buttons["购物"].tap()
        XCTAssertTrue(hint().contains("保存后会记住"), hint())
        app.buttons["save-entry"].tap()
        XCTAssertTrue(app.staticTexts["购物 · Tester"].waitForExistence(timeout: 5))

        // The same store, even typed differently, now comes with the remembered category.
        openForm(store: "zed shop", amount: "3.00")
        XCTAssertTrue(app.descendants(matching: .any)["entry-category"].firstMatch.label.contains("购物"))
        XCTAssertTrue(hint().contains("已记住"), hint())
        app.buttons["取消"].tap()

        // The memory survives a restart.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["new-entry"].waitForExistence(timeout: 10))
        openForm(store: "Zed Shop", amount: "1.00")
        XCTAssertTrue(app.descendants(matching: .any)["entry-category"].firstMatch.label.contains("购物"))
        XCTAssertTrue(hint().contains("已记住"), hint())
        app.terminate()
    }

    func testMonthlyAnalysisBreaksSpendingDownByCategoryAndStore() {
        let app = makeApp()
        app.launch()
        completeSetup(in: app)
        app.terminate()

        app.launchEnvironment["LEDGER_TEST_CAPTURE"] =
            "4.50|Starbucks;20.00|Safeway;30.00|Trader Joes;80.00|PG&E electric"
        app.launch()
        XCTAssertTrue(app.buttons["analysis-button"].waitForExistence(timeout: 10))
        app.buttons["analysis-button"].tap()

        let expense = app.staticTexts["month-expense"]
        XCTAssertTrue(expense.waitForExistence(timeout: 5))
        XCTAssertTrue(expense.label.contains("$134.50"), expense.label)
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "analysis-overview"
        overview.lifetime = .keepAlways
        add(overview)
        let utilities = app.descendants(matching: .any)["category-水电网络"].firstMatch
        XCTAssertTrue(utilities.waitForExistence(timeout: 5), "Utilities must be its own category")
        XCTAssertTrue(utilities.label.contains("$80.00") && utilities.label.contains("59.5%"), utilities.label)
        let grocery = app.descendants(matching: .any)["category-超市"].firstMatch
        XCTAssertTrue(grocery.label.contains("$50.00") && grocery.label.contains("37.2%"), grocery.label)

        grocery.tap()
        let safeway = app.descendants(matching: .any)["merchant-Safeway"].firstMatch
        XCTAssertTrue(safeway.waitForExistence(timeout: 5), "Opening a category must list its stores")
        XCTAssertTrue(safeway.label.contains("$20.00") && safeway.label.contains("40.0%"), safeway.label)
        let traderJoes = app.descendants(matching: .any)["merchant-Trader Joes"].firstMatch
        XCTAssertTrue(traderJoes.label.contains("$30.00") && traderJoes.label.contains("60.0%"), traderJoes.label)
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "analysis-category"
        detail.lifetime = .keepAlways
        add(detail)

        traderJoes.tap()
        XCTAssertTrue(app.staticTexts["$30.00"].firstMatch.waitForExistence(timeout: 5), "A store must list its purchases")
        app.terminate()
    }

    func testAutomaticCardPaymentIsRecordedOnceAndSurvivesRelaunch() {
        let app = makeApp()
        app.launch()
        completeSetup(in: app)
        app.terminate()

        // Same code path as the Shortcuts action: the app is started with a payment to record.
        app.launchEnvironment["LEDGER_TEST_CAPTURE"] = "$4.50|Starbucks"
        app.launch()
        let total = app.staticTexts["expense-total"]
        XCTAssertTrue(total.waitForExistence(timeout: 10))
        XCTAssertEqual(total.label, "$4.50")
        XCTAssertTrue(app.staticTexts["咖啡 · Tester"].exists, "The store must be categorized automatically")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "自动记录")).firstMatch.exists,
                      "Automatic entries must be marked")
        app.terminate()

        // The same payment reported again within two minutes (a trigger firing twice) is not counted twice.
        app.launch()
        XCTAssertTrue(app.staticTexts["expense-total"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["expense-total"].label, "$4.50")
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
