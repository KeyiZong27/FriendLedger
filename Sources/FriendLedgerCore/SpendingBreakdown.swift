import Foundation

public struct SpendingMerchant: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    /// The spelling used on the earliest entry of this merchant in the month.
    public let name: String
    public let totalCents: Int64
    public let count: Int
    /// Newest first.
    public let entries: [LedgerEntry]
}

public struct SpendingCategory: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let totalCents: Int64
    public let count: Int
    /// Largest first.
    public let merchants: [SpendingMerchant]
}

public struct MonthlySpending: Sendable {
    public let interval: DateInterval
    public let expenseCents: Int64
    public let incomeCents: Int64
    /// Largest first. Income is not part of a spending breakdown.
    public let categories: [SpendingCategory]

    /// Share of all spending in the month, 0...1. Zero when nothing was spent.
    public func share(of cents: Int64) -> Double {
        expenseCents > 0 ? Double(cents) / Double(expenseCents) : 0
    }
}

private func sumCents(_ entries: [LedgerEntry]) -> Int64 {
    var total: Int64 = 0
    for entry in entries { total += entry.amountCents }
    return total
}

private func makeMerchant(key: String, group: [LedgerEntry]) -> SpendingMerchant {
    let oldestFirst = group.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    let label = oldestFirst[0].note.trimmingCharacters(in: .whitespacesAndNewlines)
    return SpendingMerchant(
        key: key, name: label.isEmpty ? "（无备注）" : label, totalCents: sumCents(group),
        count: group.count, entries: Array(oldestFirst.reversed())
    )
}

private func makeCategory(name: String, items: [LedgerEntry]) -> SpendingCategory {
    let grouped = Dictionary(grouping: items) { MerchantProfile.key($0.note) }
    var merchants: [SpendingMerchant] = []
    for (key, group) in grouped { merchants.append(makeMerchant(key: key, group: group)) }
    merchants.sort { $0.totalCents == $1.totalCents ? $0.key < $1.key : $0.totalCents > $1.totalCents }
    return SpendingCategory(name: name, totalCents: sumCents(items), count: items.count, merchants: merchants)
}

extension HouseholdBook {
    /// Where one calendar month of money went: category, then merchant inside the category.
    /// Merchants are matched ignoring case and punctuation, so "TRADER JOES" and "Trader Joe's" are one store.
    public func monthlySpending(containing date: Date, calendar: Calendar) throws -> MonthlySpending {
        guard date.timeIntervalSince1970.isFinite, let month = calendar.dateInterval(of: .month, for: date) else {
            throw FinanceError.invalidField("月份")
        }
        let monthEntries = entries.filter { $0.date >= month.start && $0.date < month.end }
        let expenses = monthEntries.filter { $0.kind == .expense }
        let income = monthEntries.filter { $0.kind == .income }

        var categories: [SpendingCategory] = []
        for (name, items) in Dictionary(grouping: expenses, by: { $0.category }) {
            categories.append(makeCategory(name: name, items: items))
        }
        categories.sort { $0.totalCents == $1.totalCents ? $0.name < $1.name : $0.totalCents > $1.totalCents }
        return MonthlySpending(
            interval: month, expenseCents: sumCents(expenses), incomeCents: sumCents(income), categories: categories
        )
    }
}
