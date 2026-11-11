import Foundation
import FriendLedgerCore

@MainActor
func runAutoCaptureChecks() throws {
    for (text, cents) in [("12.34", Int64(1234)), ("$1,234.56", 123_456), ("12,34", 1234), ("1,234", 123_400),
                          (" USD 5 ", 500), ("$0.99", 99), ("1,234.5", 123_450)] {
        try check(try CapturedAmount.parse(text) == cents, "Amount text must parse exactly: \(text)")
    }
    for text in ["", "abc", "-5.00", "($5.00)", "−5.00", "0", "0.00", "1.234", "999999999999"] {
        var rejected = false
        do { _ = try CapturedAmount.parse(text) } catch { rejected = true }
        try check(rejected, "Unusable or negative amounts must be refused: \(text)")
    }

    var book = HouseholdBook()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = try book.recordCapturedPurchase(amountCents: 450, merchant: " Starbucks ", date: now, author: "小明")
    try check(first == .recorded(category: "咖啡") && book.entries.count == 1, "A card payment must become one expense")
    let entry = book.entries[0]
    try check(entry.id.hasPrefix("auto-") && entry.kind == .expense && entry.note == "Starbucks"
              && entry.author == "小明" && entry.date == now, "Automatic entries must be identifiable and complete")

    let again = try book.recordCapturedPurchase(amountCents: 450, merchant: "STARBUCKS", date: now.addingTimeInterval(60), author: "小明")
    try check(again == .duplicate && book.entries.count == 1, "A repeated trigger must not count twice")
    let later = try book.recordCapturedPurchase(amountCents: 450, merchant: "Starbucks", date: now.addingTimeInterval(600), author: "小明")
    try check(later == .recorded(category: "咖啡") && book.entries.count == 2, "The same coffee ten minutes later is a new purchase")
    let other = try book.recordCapturedPurchase(amountCents: 451, merchant: "Starbucks", date: now, author: "小明")
    try check(other == .recorded(category: "咖啡"), "A different amount is a different purchase")

    let unknown = try book.recordCapturedPurchase(amountCents: 1000, merchant: "Zed Co", date: now, author: "小明")
    try check(unknown == .recorded(category: "其他"), "Unknown stores fall back to 其他")
    try book.saveMerchant(MerchantProfile(name: "Zed Co", businessType: "购物"))
    let remembered = try book.recordCapturedPurchase(amountCents: 1100, merchant: "zed co", date: now, author: "小明")
    try check(remembered == .recorded(category: "购物"), "Remembered stores keep their type")
    let blank = try book.recordCapturedPurchase(amountCents: 1200, merchant: "  ", date: now, author: "小明")
    try check(blank == .recorded(category: "其他") && book.entries.last?.note == "刷卡交易", "A missing merchant still records the payment")

    var rejected = false
    do { _ = try book.recordCapturedPurchase(amountCents: 0, merchant: "X", date: now, author: "小明") } catch { rejected = true }
    try check(rejected, "A zero amount must be refused")
    let total = LedgerTotals(entries: book.entries)
    try check(total.expenseCents == 450 + 450 + 451 + 1000 + 1100 + 1200, "Automatic expenses count in totals")

    // Typed-in entries: the person can change the suggested category and the app remembers the store.
    func typed(_ id: String, _ cents: Int64, _ category: String, _ note: String, kind: EntryKind = .expense) -> LedgerEntry {
        LedgerEntry(id: id, amountCents: cents, kind: kind, category: category, note: note, author: "测试", date: now)
    }
    var memory = HouseholdBook()
    try check(memory.suggestedCategory(forStore: "Starbucks") == ("咖啡", .guessed), "Known brands are guessed")
    try check(memory.suggestedCategory(forStore: "Zed Shop") == ("其他", .unknown), "Unknown stores are unknown")
    try check(memory.suggestedCategory(forStore: "") == ("其他", .unknown), "No store name means no guess")
    try memory.addEntryRememberingStore(typed("m1", 1000, "购物", "Zed Shop"))
    try check(memory.suggestedCategory(forStore: "  zed   SHOP ") == ("购物", .remembered), "A corrected category is remembered")
    try check(memory.merchants.count == 1, "One store is remembered once")
    try memory.addEntryRememberingStore(typed("m2", 500, "娱乐", "ZED shop"))
    try check(memory.merchants.count == 1 && memory.suggestedCategory(forStore: "Zed Shop") == ("娱乐", .remembered),
              "Changing the category again replaces the memory, without a duplicate store")
    try check(memory.entries.first { $0.id == "m1" }?.category == "购物", "Earlier entries keep their category")
    try memory.addEntryRememberingStore(typed("m3", 450, "购物", "Starbucks"))
    try check(memory.suggestedCategory(forStore: "Starbucks") == ("购物", .remembered), "A memory beats the keyword guess")
    try memory.addEntryRememberingStore(typed("m4", 700, "其他", ""))
    try memory.addEntryRememberingStore(typed("m5", 90_000, MerchantTypeClassifier.incomeType, "Paycheck", kind: .income))
    try check(memory.merchants.count == 2, "Entries without a store, and income, are not remembered")
    try memory.addEntryRememberingStore(typed("m6", 800, "宠物", "Happy Paws"))
    try check(memory.knownCategories.contains("宠物") && memory.knownCategories.first == "餐饮"
              && !memory.knownCategories.contains(MerchantTypeClassifier.incomeType),
              "Custom categories are offered next time, income is not a spending category")
    let roundTrip = try HouseholdBook.decode(memory.encoded())
    try check(roundTrip.suggestedCategory(forStore: "happy paws") == ("宠物", .remembered), "Memory survives saving and loading")
    var captured = roundTrip
    try check(try captured.recordCapturedPurchase(amountCents: 999, merchant: "zed shop", date: now.addingTimeInterval(9999), author: "测试")
              == .recorded(category: "娱乐"), "Automatic capture uses the remembered category")
    var failing = memory
    var rejectedEntry = false
    do { try failing.addEntryRememberingStore(typed("m7", 0, "购物", "Bad")) } catch { rejectedEntry = true }
    try check(rejectedEntry && failing.merchants.count == memory.merchants.count, "A rejected entry remembers nothing")
}
