import Foundation
import FriendLedgerCore

@MainActor
func expectFinanceError(_ expected: FinanceError, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch let error as FinanceError {
        try check(error == expected, "Wrong finance error: \(error), expected \(expected)")
        return
    }
    throw CheckFailure.failed("Expected finance error: \(expected)")
}

func localDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, calendar: Calendar) throws -> Date {
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    else { throw CheckFailure.failed("Invalid test date") }
    return date
}

@MainActor
func runFinanceChecks() throws {
    var calendar = Calendar(identifier: .gregorian)
    guard let timezone = TimeZone(identifier: "America/Los_Angeles") else {
        throw CheckFailure.failed("Missing test timezone")
    }
    calendar.timeZone = timezone
    let openingDate = try localDate(2025, 2, 1, calendar: calendar)
    let marchDate = try localDate(2025, 3, 10, calendar: calendar)
    let aprilDate = try localDate(2025, 4, 1, calendar: calendar)

    try check(try Money.parseNonnegative("0") == 0, "Zero deductions must be accepted")
    try check(try Money.parseNonnegative("0.00") == 0, "Zero cents must be accepted")
    try check(Money.format(cents: 1234, currency: .usd) == "$12.34", "USD display must be explicit")
    let text = """
    CORNER MARKET
    MILK 6.00
    BREAD 3.50
    SUBTOTAL 9.50
    TAX 0.75
    TOTAL 10.25
    VISA 10.25
    CHANGE 0.00
    TOTAL SAVINGS 3.00
    """
    let draft = try ReceiptTextParser.parse(text, imageFingerprint: "test-image-1")
    try check(draft.suggestedTotalCents == 1025, "Subtotal, payment, and savings must not replace the total")
    try check(draft.suggestedItems.count == 2, "Only product lines should be suggested as items")
    try check(draft.suggestedTaxCents == 75, "Incorrect tax extraction")
    try check(draft.suggestedMerchantName == "CORNER MARKET", "Incorrect merchant suggestion")
    let conflicting = try ReceiptTextParser.parse("SHOP\nTOTAL 10.00\nGRAND TOTAL 12.00")
    try check(conflicting.suggestedTotalCents == nil && conflicting.totalCandidates.count == 2,
              "Conflicting totals must require manual choice")
    let thousand = try ReceiptTextParser.parse("SHOP\nTOTAL $1,234.56")
    try check(thousand.suggestedTotalCents == 123456, "Grouped USD total must parse exactly")
    let noTotal = try ReceiptTextParser.parse("SHOP\nSUBTOTAL 9.50\nVISA 10.25")
    try check(noTotal.suggestedTotalCents == nil && !noTotal.warnings.isEmpty,
              "Never infer a total from tender or subtotal")
    let duplicateTotals = try ReceiptTextParser.parse("SHOP\nTOTAL 5.00\nTOTAL DUE 5.00")
    try check(duplicateTotals.suggestedTotalCents == 500, "Identical total candidates are not ambiguous")
    let refundLine = try ReceiptTextParser.parse("SHOP\nRETURN -2.00\nTOTAL 5.00")
    try check(refundLine.suggestedItems.isEmpty, "Do not turn a negative line into a positive purchase")
    for line in ["RETURN -$2.00", "RETURN $2.00-", "RETURN 2.00-"] {
        let negative = try ReceiptTextParser.parse("SHOP\n\(line)\nTOTAL 5.00")
        try check(negative.suggestedItems.isEmpty, "Signed price must not become a positive item: \(line)")
    }
    try expectFinanceError(.invalidField("收据识别文本，未发现可识别内容")) {
        _ = try ReceiptTextParser.parse(" \n")
    }

    var book = HouseholdBook()
    try check(book.currency == .usd && book.targetCNYCents == 2_000_000_000,
              "Book must use USD and the confirmed RMB target")
    let merchant = MerchantProfile(id: "merchant-1", name: "Corner Market", businessType: "超市", aliases: ["CORNER MKT"])
    let review = ReceiptReview(
        merchantID: merchant.id, totalCents: 1025, items: draft.suggestedItems,
        taxCents: 75, date: marchDate, author: "成员 A"
    )
    try expectFinanceError(.merchantNotFound) {
        _ = try book.confirmReceipt(draft, review: review, calendar: calendar)
    }
    try check(book.entries.isEmpty && book.receipts.isEmpty, "Failed review must not partially mutate the book")
    try book.saveMerchant(merchant)
    try check(book.merchant(matching: " corner-mkt ")?.id == merchant.id, "Saved aliases must be reused locally")
    try check(book.merchant(matching: "Corner Market #2") == nil, "Do not guess a store from a fuzzy match")
    try expectFinanceError(.ambiguousMerchant) {
        try book.saveMerchant(MerchantProfile(name: "Other", businessType: "其他", aliases: ["corner mkt"]))
    }
    try check(book.merchants.count == 1, "Alias collision must not change the directory")
    let receipt = try book.confirmReceipt(draft, review: review, calendar: calendar)
    try check(book.entries.count == 1 && book.entries[0].amountCents == 1025, "One receipt must create one expense")
    try check(receipt.detailDifferenceCents == 0, "Items plus tax should reconcile for this fixture")
    try expectFinanceError(.duplicateReceipt) {
        _ = try book.confirmReceipt(draft, review: review, calendar: calendar)
    }
    let sameImage = try ReceiptTextParser.parse(text, imageFingerprint: "test-image-1")
    try expectFinanceError(.duplicateReceipt) {
        _ = try book.confirmReceipt(sameImage, review: review, calendar: calendar, allowPossibleDuplicate: true)
    }
    let similar = try ReceiptTextParser.parse(text, imageFingerprint: "test-image-2")
    try expectFinanceError(.possibleDuplicateReceipt) {
        _ = try book.confirmReceipt(similar, review: review, calendar: calendar)
    }
    try check(book.entries.count == 1, "Rejected duplicates must not add expenses")
    var possibleDuplicateBook = book
    _ = try possibleDuplicateBook.confirmReceipt(similar, review: review, calendar: calendar, allowPossibleDuplicate: true)
    try check(possibleDuplicateBook.entries.count == 2, "Different real receipts may be explicitly confirmed")
    var missingDetailsBook = HouseholdBook()
    try missingDetailsBook.saveMerchant(merchant)
    let missingDetails = try missingDetailsBook.confirmReceipt(draft, review: ReceiptReview(
        merchantID: merchant.id, totalCents: 1025, items: [], date: marchDate, author: "成员 A"
    ), calendar: calendar)
    try check(missingDetails.detailDifferenceCents == 1025 && missingDetailsBook.entries.count == 1,
              "Incomplete item analysis must remain visible without changing the payment")
    var discountsBook = HouseholdBook()
    try discountsBook.saveMerchant(merchant)
    let discounted = try discountsBook.confirmReceipt(draft, review: ReceiptReview(
        merchantID: merchant.id, totalCents: 1025,
        items: [ReceiptItem(name: "商品", lineTotalCents: 1200)],
        adjustments: [ReceiptAdjustment(name: "优惠券", amountCents: -250)],
        taxCents: 75, date: marchDate, author: "成员 A"
    ), calendar: calendar)
    try check(discounted.detailDifferenceCents == 0, "Signed adjustments must reconcile without a second expense")

    let wage = PayrollRecord(
        id: "wage-1", member: "成员 A", date: marchDate,
        grossCents: 100000, withheldTaxCents: 20000, otherDeductionCents: 10000, netCents: 70000
    )
    try book.addPayroll(wage)
    try check(book.entries.count == 2 && book.entries.last?.amountCents == 70000,
              "Only net payroll enters cash income")
    try expectFinanceError(.duplicateID) { try book.addPayroll(wage) }
    try expectFinanceError(.payrollMismatch) {
        try book.addPayroll(PayrollRecord(member: "成员 B", date: marchDate,
            grossCents: 100000, withheldTaxCents: 20000, otherDeductionCents: 10000, netCents: 71000))
    }
    try check(book.payroll.count == 1, "Invalid payroll must not partially save")
    var zeroNetBook = HouseholdBook()
    let zeroNet = PayrollRecord(id: "zero-net", member: "成员 B", date: marchDate,
                               grossCents: 100, withheldTaxCents: 100, otherDeductionCents: 0, netCents: 0)
    try zeroNetBook.addPayroll(zeroNet)
    try check(zeroNetBook.entries.isEmpty && zeroNetBook.payroll.count == 1, "Zero net pay must not create cash income")
    try zeroNetBook.validate()
    try zeroNetBook.removePayroll(id: zeroNet.id)
    try check(zeroNetBook.payroll.isEmpty, "Zero net payroll must remain removable")

    let manualExpense = LedgerEntry(id: "manual-1", amountCents: 500, kind: .expense,
                                   category: "交通", note: "", author: "成员 B", date: marchDate)
    try book.addManualEntry(manualExpense)
    try expectFinanceError(.duplicateID) { try book.addManualEntry(manualExpense) }
    try expectFinanceError(.savingsNotConfigured) { _ = try book.savingsProgress(asOf: marchDate) }
    let deposit = SavingsMovement(id: "deposit-1", direction: .deposit, amountCents: 50000, date: marchDate)
    try expectFinanceError(.savingsNotConfigured) { try book.addSavingsMovement(deposit) }
    try book.setSavingsOpening(SavingsOpening(amountCents: 100000, date: openingDate))
    try book.addSavingsMovement(deposit)
    try book.addSavingsMovement(SavingsMovement(id: "withdrawal-1", direction: .withdrawal, amountCents: 20000, date: marchDate))
    try book.addSavingsMovement(SavingsMovement(id: "future-deposit", direction: .deposit, amountCents: 5000, date: aprilDate))
    try expectFinanceError(.exchangeRateMissing) { _ = try book.savingsProgress(asOf: marchDate) }
    guard let rateValue = Decimal(string: "7.123457") else { throw CheckFailure.failed("Invalid fixture rate") }
    let rate = try ManualExchangeRate(cnyPerUSD: rateValue, effectiveDate: openingDate)
    try book.setSavingsGoal(targetCNYCents: 2_000_000_000, rate: rate)
    let progress = try book.savingsProgress(asOf: marchDate)
    try check(progress.balanceUSDCents == 130000, "Use opening plus deposits minus withdrawals, excluding future entries")
    try check(progress.estimatedBalanceCNYCents == 926049, "FX estimate must round to RMB cents")
    try check(progress.remainingCNYCents == 1_999_073_951, "Goal remaining calculation is incorrect")
    try check(progress.progressFraction == Decimal(926049) / Decimal(2_000_000_000),
              "Savings progress must use the confirmed goal")
    try expectFinanceError(.insufficientSavings) {
        try book.addSavingsMovement(SavingsMovement(direction: .withdrawal, amountCents: 150000,
            date: try localDate(2025, 2, 20, calendar: calendar)))
    }
    try check(book.savingsMovements.count == 3, "Rejected withdrawal must not be stored")
    try expectFinanceError(.savingsBeforeOpening) {
        try book.addSavingsMovement(SavingsMovement(direction: .deposit, amountCents: 1,
            date: try localDate(2025, 1, 31, calendar: calendar)))
    }
    try expectFinanceError(.savingsBeforeOpening) {
        _ = try book.savingsProgress(asOf: try localDate(2025, 1, 1, calendar: calendar))
    }
    for invalid in [Decimal.zero, Decimal(-1), Decimal.nan, Decimal(1001)] {
        try expectFinanceError(.invalidField("美元兑人民币汇率及日期")) {
            _ = try ManualExchangeRate(cnyPerUSD: invalid, effectiveDate: marchDate)
        }
    }
    var futureRateBook = book
    try futureRateBook.setSavingsGoal(targetCNYCents: 2_000_000_000,
        rate: ManualExchangeRate(cnyPerUSD: 7, effectiveDate: aprilDate))
    try expectFinanceError(.exchangeRateMissing) { _ = try futureRateBook.savingsProgress(asOf: marchDate) }

    let summary = try book.monthlySummary(containing: marchDate, calendar: calendar)
    try check(summary.incomeCents == 70000 && summary.expenseCents == 1525,
              "Receipt items, withholding, and savings must not be counted as separate cash expenses")
    try check(summary.cashFlowCents == 68475, "Monthly cash flow must remain distinct from savings balance")
    try check(summary.grossPayrollCents == 100000 && summary.withheldTaxCents == 20000
              && summary.otherPayrollDeductionCents == 10000 && summary.netPayrollCents == 70000,
              "Incorrect payroll analysis")
    try check(summary.depositedCents == 50000 && summary.withdrawnCents == 20000, "Incorrect monthly savings flows")
    try check(summary.merchantTotals.count == 1 && summary.merchantTotals[0].expenseCents == 1025
              && summary.merchantTotals[0].receiptCount == 1, "Merchant analysis must count whole receipts")
    try check(summary.businessTypeTotals["超市"] == 1025 && summary.unassignedExpenseCents == 500,
              "Manual unassigned expenses must not disappear")
    var boundaryBook = HouseholdBook()
    guard let midnightUTC = ISO8601DateFormatter().date(from: "2025-03-01T00:00:00Z") else {
        throw CheckFailure.failed("Invalid boundary date")
    }
    try boundaryBook.addManualEntry(LedgerEntry(id: "boundary", amountCents: 99, kind: .expense,
        category: "其他", note: "", author: "成员 A", date: midnightUTC))
    try check(try boundaryBook.monthlySummary(containing: marchDate, calendar: calendar).expenseCents == 0,
              "UTC dates must respect the household month timezone")
    try check(try boundaryBook.monthlySummary(containing: openingDate, calendar: calendar).expenseCents == 99,
              "Boundary transaction must appear in February for Los Angeles")

    let data = try book.encoded()
    let restored = try HouseholdBook.decode(data)
    try check(try restored.encoded() == data, "Finance archive round-trip must preserve all records and cents")
    try check(try restored.savingsProgress(asOf: marchDate).balanceUSDCents == 130000,
              "Archive must preserve the savings calculation")
    guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CheckFailure.failed("Invalid fixture archive")
    }
    payload["currency"] = "CNY"
    try expectFinanceError(.invalidField("账本版本或币种，当前内核只接受美元账本")) {
        _ = try HouseholdBook.decode(JSONSerialization.data(withJSONObject: payload))
    }
    payload["currency"] = "USD"
    payload["version"] = 2
    try expectFinanceError(.invalidField("账本版本或币种，当前内核只接受美元账本")) {
        _ = try HouseholdBook.decode(JSONSerialization.data(withJSONObject: payload))
    }
    payload["version"] = 1
    guard var damagedBook = payload["book"] as? [String: Any],
          var damagedEntries = damagedBook["entries"] as? [[String: Any]] else {
        throw CheckFailure.failed("Invalid nested fixture archive")
    }
    damagedEntries[0]["amountCents"] = 1000
    damagedBook["entries"] = damagedEntries
    payload["book"] = damagedBook
    try expectFinanceError(.inconsistentBook) {
        _ = try HouseholdBook.decode(JSONSerialization.data(withJSONObject: payload))
    }
    var oversized = HouseholdBook()
    try oversized.addManualEntry(LedgerEntry(id: "oversized", amountCents: 1, kind: .expense,
        category: "其他", note: String(repeating: "x", count: 900_001), author: "成员 A", date: marchDate))
    try expectFinanceError(.invalidField("账本容量，当前内核快照最多 900 KB，需要升级存储方式")) {
        _ = try oversized.encoded()
    }
    var removed = book
    try removed.removeEntry(id: receipt.entryID)
    try check(removed.receipts.isEmpty && removed.entries.count == 2, "Deleting a receipt must remove its analysis")
    try removed.removePayroll(id: wage.id)
    try check(removed.payroll.isEmpty && removed.entries.count == 1, "Deleting payroll must remove its net income")
    try removed.validate()

    var savingsRemoval = HouseholdBook()
    try savingsRemoval.setSavingsOpening(SavingsOpening(amountCents: 0, date: openingDate))
    try savingsRemoval.addSavingsMovement(deposit)
    try savingsRemoval.addSavingsMovement(SavingsMovement(direction: .withdrawal, amountCents: 50000, date: aprilDate))
    try expectFinanceError(.insufficientSavings) { try savingsRemoval.removeSavingsMovement(id: deposit.id) }
    try check(savingsRemoval.savingsMovements.count == 2, "Removing a needed deposit must not create a negative balance")
}
