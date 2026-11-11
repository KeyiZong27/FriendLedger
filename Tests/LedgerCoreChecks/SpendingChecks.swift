import Foundation
import FriendLedgerCore

@MainActor
func runSpendingChecks() throws {
    var calendar = Calendar(identifier: .gregorian)
    guard let timezone = TimeZone(identifier: "America/Los_Angeles") else {
        throw CheckFailure.failed("Missing test timezone")
    }
    calendar.timeZone = timezone
    let march10 = try localDate(2025, 3, 10, calendar: calendar)
    let marchEnd = try localDate(2025, 3, 31, hour: 23, calendar: calendar)
    let april1 = try localDate(2025, 4, 1, hour: 0, calendar: calendar)
    var counter = 0
    func add(_ book: inout HouseholdBook, _ cents: Int64, _ category: String, _ note: String,
             _ date: Date, kind: EntryKind = .expense) throws {
        counter += 1
        try book.addManualEntry(LedgerEntry(
            id: "e\(counter)", amountCents: cents, kind: kind, category: category,
            note: note, author: "测试", date: date
        ))
    }

    var book = HouseholdBook()
    try add(&book, 3000, "超市", "Trader Joe's", march10)
    try add(&book, 2000, "超市", "TRADER JOES", marchEnd)
    try add(&book, 5000, "超市", "Safeway", march10)
    try add(&book, 8000, "水电网络", "PG&E", march10)
    try add(&book, 450, "咖啡", "Starbucks", march10)
    try add(&book, 700, "其他", "", march10)
    try add(&book, 999_99, "水电网络", "April rent", april1)
    try add(&book, 300_000, "收入", "Paycheck", march10, kind: .income)

    let march = try book.monthlySpending(containing: march10, calendar: calendar)
    let spent: Int64 = 3000 + 2000 + 5000 + 8000 + 450 + 700
    try check(march.expenseCents == spent, "Month total must include every March expense and nothing else")
    try check(march.incomeCents == 300_000, "Income is reported separately")
    try check(march.categories.map(\.name) == ["超市", "水电网络", "其他", "咖啡"],
              "Categories must be ordered by amount: \(march.categories.map(\.name))")
    try check(march.categories.contains { $0.name == "收入" } == false, "Income must not appear in a spending breakdown")
    try check(march.categories.reduce(Int64(0)) { $0 + $1.totalCents } == march.expenseCents,
              "Categories must add up to the month total")
    try check(abs(march.categories.reduce(0.0) { $0 + march.share(of: $1.totalCents) } - 1) < 1e-9,
              "Shares of categories must add up to 100%")

    guard let utilities = march.categories.first(where: { $0.name == "水电网络" }),
          let grocery = march.categories.first(where: { $0.name == "超市" }) else {
        throw CheckFailure.failed("Expected utilities and grocery categories")
    }
    try check(abs(march.share(of: utilities.totalCents) - 8000.0 / 19150.0) < 1e-9, "Category share must be exact")
    try check(grocery.totalCents == 10_000 && grocery.count == 3, "Grocery total and count")
    try check(grocery.merchants.map(\.totalCents) == [5000, 5000] && grocery.merchants.count == 2,
              "Spellings of one store must merge: \(grocery.merchants.map(\.name))")
    guard let traderJoes = grocery.merchants.first(where: { $0.totalCents == 5000 && $0.count == 2 }) else {
        throw CheckFailure.failed("Trader Joe's spellings must form one merchant")
    }
    try check(traderJoes.name == "Trader Joe's" && traderJoes.entries.count == 2
              && traderJoes.entries[0].date > traderJoes.entries[1].date,
              "Merchant keeps the earliest spelling and lists newest entries first")
    try check(grocery.merchants.reduce(Int64(0)) { $0 + $1.totalCents } == grocery.totalCents,
              "Merchants must add up to their category")

    guard let other = march.categories.first(where: { $0.name == "其他" }) else {
        throw CheckFailure.failed("Expected the unlabeled category")
    }
    try check(other.merchants.first?.name == "（无备注）", "Entries without a note need a readable name")

    let boundary = try book.monthlySpending(containing: april1, calendar: calendar)
    try check(boundary.expenseCents == 999_99 && boundary.categories.map(\.name) == ["水电网络"],
              "April 1 local midnight belongs to April, not March")
    let empty = try book.monthlySpending(containing: try localDate(2024, 1, 15, calendar: calendar), calendar: calendar)
    try check(empty.expenseCents == 0 && empty.categories.isEmpty && empty.share(of: 100) == 0,
              "A month without spending must be empty, not divide by zero")
    var rejected = false
    do { _ = try book.monthlySpending(containing: Date(timeIntervalSince1970: .nan), calendar: calendar) }
    catch { rejected = true }
    try check(rejected, "An invalid date must be refused")
}
