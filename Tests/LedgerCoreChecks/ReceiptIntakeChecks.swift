import Foundation
import FriendLedgerCore

@MainActor
func runReceiptIntakeChecks() throws {
    var calendar = Calendar(identifier: .gregorian)
    guard let timezone = TimeZone(identifier: "America/Los_Angeles") else {
        throw CheckFailure.failed("Missing test timezone")
    }
    calendar.timeZone = timezone

    for (name, expected) in [
        ("STARBUCKS #1234", "咖啡"), ("Joe's Pizza Kitchen", "餐饮"), ("Trader Joe's", "超市"),
        ("Chevron 76", "加油"), ("Uber Trip", "交通"), ("CVS Pharmacy", "医疗药房"),
        ("Marriott Downtown", "住宿"), ("AMC Theatres", "娱乐"), ("AT&T", "账单服务"),
        ("Target Pharmacy", "医疗药房"), ("Walgreens Pharmacy", "医疗药房")
    ] {
        try check(MerchantTypeClassifier.suggest(merchantName: name) == expected,
                  "Wrong automatic type for \(name): \(String(describing: MerchantTypeClassifier.suggest(merchantName: name)))")
    }
    try check(MerchantTypeClassifier.suggest(merchantName: "Across Town LLC") == nil,
              "Short keywords must match whole words only")
    try check(MerchantTypeClassifier.suggest(merchantName: "Zed Co") == nil, "Unknown merchants must stay unclassified")
    try check(MerchantTypeClassifier.suggest(merchantName: "11 .FRADER JOE'S") == "超市", "One misread letter must still classify")
    try check(MerchantTypeClassifier.suggest(merchantName: "Wa1mart") == "超市", "One misread digit must still classify")
    try check(MerchantTypeClassifier.suggest(merchantName: "Hotel Intel") == "住宿", "Words containing tel must not be noise")

    let ok = try ReceiptTextParser.parse("""
    CORNER MARKET
    11/10/2026
    MILK 6.00
    SUBTOTAL 6.00
    TAX 0.48
    TOTAL 6.48
    VISA TEND 6.48
    """)
    try check(ok.checks.total == .high && ok.checks.date == .high && ok.checks.merchant == .high,
              "A receipt whose numbers agree must be highly trusted")
    try check(ok.checks.confirmations.contains { $0.contains("刷卡") } && ok.checks.confirmations.contains { $0.contains("小计 + 税") }
              && ok.checks.confirmations.contains { $0.contains("商品合计") }, "All agreeing cross-checks must be listed")
    let misread = try ReceiptTextParser.parse("TRADER JOES\nSUBTOTAL 186.06\nTOTAL $186.00\nUSD$ 186.06")
    try check(misread.checks.total == .low && misread.checks.problems.contains { $0.contains("付款金额") },
              "A total that differs from the card amount must be flagged: \(misread.checks)")
    let unverified = try ReceiptTextParser.parse("SHOP\nTOTAL 5.00")
    try check(unverified.checks.total == .medium && !unverified.checks.problems.isEmpty, "An isolated total is not verified")
    let missingTotal = try ReceiptTextParser.parse("SHOP\nMILK 5.00")
    try check(missingTotal.checks.total == .low, "A missing total is low confidence")
    try check(ok.checks.score > misread.checks.score && misread.checks.score > missingTotal.checks.score,
              "Scores must rank clean readings above doubtful ones")
    let walmart = try ReceiptTextParser.parse("""
    Give us feedback @ survey.walmart.com
    Thank you! ID #: 7QDD9S15SK2
    Walmart.
    ST# 00109 OP# 009046 TE# 46 TR# 06069 4.72 Y
    HUMMUS W/RO 040822017510 F 4.72 Y
    SUBTOTAL 27.13
    TAX2 6.9750 % 1.89
    TOTAL 29.02
    VISA TEND 29.02
    CHANGE DUE 0.00
    29.02 TOTAL PURCHASE
    09/08/21 21:03:40
    """)
    try check(walmart.suggestedMerchantName == "Walmart", "Noise rows must not become the store: \(String(describing: walmart.suggestedMerchantName))")
    try check(walmart.suggestedTotalCents == 2902 && walmart.suggestedTaxCents == 189, "Price-first totals and TAX2 must parse")
    try check(walmart.suggestedItems.map(\.name) == ["HUMMUS W/RO"], "Product codes and receipt IDs must not become items: \(walmart.suggestedItems)")
    try check(walmart.suggestedDay == ReceiptDay(year: 2021, month: 9, day: 8), "Two-digit-year receipt date must parse")
    try check(MerchantTypeClassifier.suggest(merchantName: "Zed Co", itemNames: ["Chicken Burger", "Pizza Slice"]) == "餐饮",
              "Two matching items can classify an unknown merchant")
    try check(MerchantTypeClassifier.suggest(merchantName: "Zed Co", itemNames: ["Burger", "Hotel Fee"]) == nil,
              "Conflicting weak evidence must not classify")

    func parse(_ date: String) throws -> ReceiptDraft {
        try ReceiptTextParser.parse("CORNER MARKET\n\(date)\nMILK 6.00\nTOTAL 6.00")
    }
    try check(try parse("11/10/2026 03:15 PM").suggestedDay == ReceiptDay(year: 2026, month: 11, day: 10),
              "Month/day/year dates must parse")
    try check(try parse("2026-11-10").suggestedDay == ReceiptDay(year: 2026, month: 11, day: 10), "ISO dates must parse")
    try check(try parse("Nov 10, 2026").suggestedDay == ReceiptDay(year: 2026, month: 11, day: 10),
              "Month-name dates must parse")
    try check(try parse("11/10/26").suggestedDay == ReceiptDay(year: 2026, month: 11, day: 10), "Two-digit years must parse")
    try check(try parse("13/45/2026").suggestedDay == nil, "Impossible dates must be ignored")
    try check(try parse("02/30/2026").suggestedDay == nil, "Calendar-invalid dates must be ignored")
    let two = try ReceiptTextParser.parse("CORNER MARKET\n11/10/2026\n11/12/2026\nTOTAL 6.00")
    try check(two.suggestedDay == nil && two.warnings.contains { $0.contains("多个不同日期") },
              "Conflicting dates must not be guessed")
    try check(try parse("no date").warnings.contains { $0.contains("未识别到消费日期") }, "Missing dates must warn")

    let draft = try ReceiptTextParser.parse(
        "TRADER JOES\n11/10/2026\nMILK 6.00\nBREAD 3.50\nTAX 0.75\nTOTAL 10.25", imageFingerprint: "photo-1"
    )
    let date = try localDate(2026, 11, 10, calendar: calendar)
    var book = HouseholdBook()
    let receipt = try book.submitReceipt(
        draft, ReceiptSubmission(merchantName: "Trader Joes", businessType: "超市", totalCents: 1025,
                                 date: date, author: "小明"), calendar: calendar
    )
    try check(book.entries.count == 1 && book.entries[0].amountCents == 1025 && book.entries[0].category == "超市",
              "One receipt must create one expense categorized by merchant type")
    try check(book.entries[0].note == "Trader Joes" && book.entries[0].author == "小明", "Entry must show merchant and member")
    try check(receipt.items.count == 2 && receipt.taxCents == 75, "Details must stay analytical on the receipt")
    try check(book.merchants.count == 1, "First receipt must remember the merchant")

    let second = try ReceiptTextParser.parse("TRADER JOES\nEGGS 4.00\nTOTAL 4.00", imageFingerprint: "photo-2")
    try book.submitReceipt(
        second, ReceiptSubmission(merchantName: "trader  joes", businessType: "超市", totalCents: 400,
                                  date: date, author: "小红"), calendar: calendar
    )
    try check(book.merchants.count == 1 && book.entries.count == 2, "Known merchants must be reused")
    let third = try ReceiptTextParser.parse("TRADER JOES\nGUM 1.00\nTOTAL 1.00", imageFingerprint: "photo-3")
    try book.submitReceipt(
        third, ReceiptSubmission(merchantName: "Trader Joes", businessType: "购物", totalCents: 100,
                                 date: date, author: "小红"), calendar: calendar
    )
    try check(book.merchants[0].businessType == "购物" && book.entries.first { $0.amountCents == 1025 }?.category == "超市",
              "Correcting a type updates future receipts without rewriting history")

    try expectFinanceError(.duplicateReceipt) {
        var copy = book
        try copy.submitReceipt(draft, ReceiptSubmission(merchantName: "Trader Joes", businessType: "超市",
                                                        totalCents: 1025, date: date, author: "小明"), calendar: calendar)
    }
    let sameDay = try ReceiptTextParser.parse("TRADER JOES\nEGGS 4.00\nTOTAL 4.00", imageFingerprint: "photo-4")
    try expectFinanceError(.possibleDuplicateReceipt) {
        var copy = book
        try copy.submitReceipt(sameDay, ReceiptSubmission(merchantName: "Trader Joes", businessType: "超市",
                                                          totalCents: 400, date: date, author: "小明"), calendar: calendar)
    }
    var allowed = book
    try allowed.submitReceipt(sameDay, ReceiptSubmission(merchantName: "Trader Joes", businessType: "超市", totalCents: 400,
                                                         date: date, author: "小明", allowPossibleDuplicate: true),
                              calendar: calendar)
    try check(allowed.entries.count == 4, "Explicitly confirmed same-day receipt must be saved")

    let ledger = Ledger(zoneName: "FriendLedger-\(UUID().uuidString)", ownerName: "owner", database: .personal, name: "Atomic")
    var stored = StoredLedger(ledger: ledger)
    let broken = try ReceiptTextParser.parse("NEW SHOP\nTAX 9.00\nTOTAL 5.00", imageFingerprint: "photo-5")
    do {
        try stored.edit {
            try $0.submitReceipt(broken, ReceiptSubmission(merchantName: "New Shop", businessType: "其他", totalCents: 500,
                                                           date: date, author: "小明"), calendar: calendar)
        }
        throw CheckFailure.failed("Tax larger than total must be rejected")
    } catch is FinanceError {}
    try check(stored.book.merchants.isEmpty && stored.book.entries.isEmpty,
              "A rejected receipt must not leave a half-created merchant")
    try expectFinanceError(.invalidField("商店名称")) {
        var copy = HouseholdBook()
        try copy.submitReceipt(draft, ReceiptSubmission(merchantName: "  ", businessType: "超市", totalCents: 1025,
                                                        date: date, author: "小明"), calendar: calendar)
    }
}
