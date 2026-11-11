import Foundation
import FriendLedgerCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): message }
    }
}

var passed = 0

@MainActor
func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure.failed(message) }
    passed += 1
}

@MainActor
func checkAmountError(_ input: String, expected: AmountError) throws {
    do {
        _ = try Money.parse(input)
    } catch let error as AmountError {
        try check(error == expected, "Wrong error for \(input): \(error)")
        return
    }
    throw CheckFailure.failed("Unexpected acceptance of \(input)")
}

func entry(cents: Int64, kind: EntryKind) -> LedgerEntry {
    LedgerEntry(
        id: UUID().uuidString, amountCents: cents, kind: kind, category: "其他",
        note: "", author: "测试成员", date: Date(timeIntervalSince1970: 0)
    )
}

for (text, expected) in [
    ("1", Int64(100)), ("12.5", 1250), ("12.50", 1250),
    ("0.01", 1), (" 18.99\n", 1899), ("100000000", 10_000_000_000)
] {
    try check(try Money.parse(text) == expected, "Incorrect cents for \(text)")
}

for text in ["", "0", "0.00", "-1", "1.234", "1.", ".50", "1,000", "NaN", "1e2", "１２"] {
    try checkAmountError(text, expected: .invalid)
}
for text in ["100000000.01", "100000001", "999999999999999999999999"] {
    try checkAmountError(text, expected: .outOfRange)
}

let totals = LedgerTotals(entries: [
    entry(cents: 10, kind: .expense),
    entry(cents: 20, kind: .expense),
    entry(cents: 100, kind: .income)
])
try check(totals.expenseCents == 30, "Expense cents must be exact")
try check(totals.incomeCents == 100, "Incorrect income")
try check(totals.balanceCents == 70, "Incorrect balance")
try check(Money.format(cents: totals.expenseCents).contains("0.30"), "Incorrect display")
let empty = LedgerTotals(entries: [])
try check(empty.balanceCents == 0 && empty.incomeCents == 0 && empty.expenseCents == 0, "Nonzero empty totals")
let loss = LedgerTotals(entries: [entry(cents: 50, kind: .expense)])
try check(loss.balanceCents == -50, "Negative balance must be preserved")
let large = LedgerTotals(entries: [
    entry(cents: Int64.max, kind: .income), entry(cents: Int64.max, kind: .income)
])
try check(large.incomeCents == Decimal(Int64.max) * 2, "Totals must not overflow Int64")

let owner = Ledger(zoneName: "zone", ownerName: "owner", database: .personal, name: "旅行")
let participant = Ledger(zoneName: "zone", ownerName: "owner", database: .shared, name: "旅行")
try check(owner.id != participant.id, "Database scopes must not collide")
try check(owner.isOwner && !participant.isOwner, "Incorrect owner identification")
let encoded = try JSONEncoder().encode([owner, participant])
let decoded = try JSONDecoder().decode([Ledger].self, from: encoded)
try check(decoded == [owner, participant], "Ledger encoding round-trip failed")

try runFinanceChecks()
try runBankChecks()
try runLocalCacheChecks()
print("PASS: \(passed) ledger core checks")
