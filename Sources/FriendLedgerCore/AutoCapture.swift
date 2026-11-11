import Foundation

/// A card payment reported by the phone itself (for example by a Wallet automation in Shortcuts).
/// It is recorded straight away as an expense that is marked as automatic, so it can be reviewed or deleted.
public enum CapturedAmount {
    /// Accepts "12.34", "$1,234.56" and "12,34"; refuses negatives, so a refund is never recorded as a purchase.
    public static func parse(_ text: String) throws -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("-"), !trimmed.contains("("), !trimmed.contains("−") else {
            throw FinanceError.invalidField("金额为负数，退款请手动记录")
        }
        var digits = trimmed.replacingOccurrences(of: "USD", with: "", options: .caseInsensitive)
            .filter { $0.isNumber || $0 == "." || $0 == "," }
        if digits.contains(".") {
            digits.removeAll { $0 == "," }
        } else if let comma = digits.lastIndex(of: ","), digits.distance(from: comma, to: digits.endIndex) == 3 {
            digits.removeAll { $0 == "," }
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -2))
        } else {
            digits.removeAll { $0 == "," }
        }
        do { return try Money.parse(digits) }
        catch { throw FinanceError.invalidField("金额，无法识别：\(trimmed)") }
    }
}

public enum CaptureOutcome: Equatable, Sendable {
    case recorded(category: String)
    case duplicate
}

public enum CategorySource: Equatable, Sendable {
    case remembered, guessed, unknown
}

extension HouseholdBook {
    /// Adds a typed-in expense and remembers its store: the next entry with this name (or alias) gets the
    /// same category. Everything happens together or not at all; earlier entries keep their category.
    public mutating func addEntryRememberingStore(_ entry: LedgerEntry) throws {
        try addManualEntry(entry)
        guard entry.kind == .expense else { return }
        let name = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = entry.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !MerchantProfile.key(name).isEmpty, name.count <= 100, type.count <= 100 else { return }
        if let existing = self.merchant(matching: name) {
            guard existing.businessType != type else { return }
            try saveMerchant(MerchantProfile(
                id: existing.id, name: existing.name, businessType: type,
                aliases: existing.aliases, address: existing.address
            ))
        } else {
            try saveMerchant(MerchantProfile(name: name, businessType: type))
        }
    }

    /// The category a typed-in expense would get without any choice by the person.
    public func suggestedCategory(forStore text: String) -> (category: String, source: CategorySource) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = merchant(matching: name) { return (known.businessType, .remembered) }
        if let guess = MerchantTypeClassifier.suggest(merchantName: name) { return (guess, .guessed) }
        return ("其他", .unknown)
    }

    /// Standard types first, then any custom ones already used in this book.
    public var knownCategories: [String] {
        var result = MerchantTypeClassifier.types
        for name in merchants.map(\.businessType) + entries.map(\.category)
        where name != MerchantTypeClassifier.incomeType && !result.contains(name) {
            result.append(name)
        }
        return result
    }

    /// Records one automatic expense. The same payment reported twice within `duplicateWindow` seconds
    /// (a trigger that fires again, or both a Wallet and an alert path) is skipped instead of counted twice.
    @discardableResult
    public mutating func recordCapturedPurchase(
        amountCents: Int64, merchant: String, date: Date, author: String, duplicateWindow: TimeInterval = 120
    ) throws -> CaptureOutcome {
        guard amountCents > 0, amountCents <= Money.maximumCents else { throw AmountError.invalid }
        let name = String(merchant.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let key = MerchantProfile.key(name)
        if entries.contains(where: {
            $0.id.hasPrefix("auto-") && $0.amountCents == amountCents && $0.kind == .expense
                && abs($0.date.timeIntervalSince(date)) <= duplicateWindow
                && MerchantProfile.key($0.note) == key
        }) { return .duplicate }
        let category = self.merchant(matching: name)?.businessType
            ?? MerchantTypeClassifier.suggest(merchantName: name) ?? "其他"
        try addManualEntry(LedgerEntry(
            id: "auto-\(UUID().uuidString)", amountCents: amountCents, kind: .expense, category: category,
            note: name.isEmpty ? "刷卡交易" : name, author: author, date: date
        ))
        return .recorded(category: category)
    }
}
