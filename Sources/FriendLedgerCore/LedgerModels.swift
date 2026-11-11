import Foundation

public enum EntryKind: String, Codable, CaseIterable, Sendable {
    case expense
    case income

    public var title: String { self == .expense ? "支出" : "收入" }
}

public enum LedgerDatabase: String, Codable, Sendable {
    case personal
    case shared
}

public struct Ledger: Identifiable, Codable, Hashable, Sendable {
    public let zoneName: String
    public let ownerName: String
    public let database: LedgerDatabase
    public let name: String

    public var id: String { "\(database.rawValue):\(ownerName):\(zoneName)" }
    public var isOwner: Bool { database == .personal }

    public init(zoneName: String, ownerName: String, database: LedgerDatabase, name: String) {
        self.zoneName = zoneName
        self.ownerName = ownerName
        self.database = database
        self.name = name
    }
}

public struct LedgerEntry: Identifiable, Codable, Sendable {
    public let id: String
    public let amountCents: Int64
    public let kind: EntryKind
    public let category: String
    public let note: String
    public let author: String
    public let date: Date

    public init(
        id: String, amountCents: Int64, kind: EntryKind, category: String,
        note: String, author: String, date: Date
    ) {
        self.id = id
        self.amountCents = amountCents
        self.kind = kind
        self.category = category
        self.note = note
        self.author = author
        self.date = date
    }
}

public enum AmountError: LocalizedError, Equatable {
    case invalid
    case outOfRange

    public var errorDescription: String? {
        switch self {
        case .invalid: "请输入正数金额，最多两位小数，例如 12.50。"
        case .outOfRange: "单笔金额不能超过 1 亿元。"
        }
    }
}

public enum Currency: String, Codable, Sendable {
    case usd = "USD"
    case cny = "CNY"
}

public enum Money {
    public static let maximumCents: Int64 = 10_000_000_000

    public static func parse(_ text: String) throws -> Int64 {
        try parse(text, allowingZero: false)
    }

    public static func parseNonnegative(_ text: String) throws -> Int64 {
        try parse(text, allowingZero: true)
    }

    public static func exactCents(amount: Decimal) throws -> Int64 {
        guard !amount.isNaN, amount > 0 else { throw AmountError.invalid }
        guard amount <= Decimal(maximumCents) / 100 else { throw AmountError.outOfRange }
        var scaled = amount * 100
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { throw AmountError.invalid }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    private static func parse(_ text: String, allowingZero: Bool) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              !parts[0].isEmpty,
              parts.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              parts.count == 1 || (1...2).contains(parts[1].count)
        else { throw AmountError.invalid }

        guard let whole = Int64(parts[0]), whole <= maximumCents / 100 else {
            throw AmountError.outOfRange
        }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard let fractionCents = Int64(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) else {
            throw AmountError.invalid
        }
        let cents = whole * 100 + fractionCents
        guard cents > 0 || (allowingZero && cents == 0) else { throw AmountError.invalid }
        guard cents <= maximumCents else { throw AmountError.outOfRange }
        return cents
    }

    public static func format(cents: Decimal, currency: Currency = .cny) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: currency == .usd ? "en_US" : "zh_CN")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        return formatter.string(from: NSDecimalNumber(decimal: cents / 100))
            ?? "金额格式化失败"
    }
}

public struct LedgerTotals: Equatable, Sendable {
    public let incomeCents: Decimal
    public let expenseCents: Decimal
    public var balanceCents: Decimal { incomeCents - expenseCents }

    public init(entries: [LedgerEntry]) {
        incomeCents = entries.filter { $0.kind == .income }
            .reduce(Decimal.zero) { $0 + Decimal($1.amountCents) }
        expenseCents = entries.filter { $0.kind == .expense }
            .reduce(Decimal.zero) { $0 + Decimal($1.amountCents) }
    }
}
