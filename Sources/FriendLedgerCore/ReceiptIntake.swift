import Foundation

/// Offline keyword rules for U.S. merchants. It only suggests a type; unknown names return nil
/// so the person confirms once and the merchant directory remembers the answer.
public enum MerchantTypeClassifier {
    public static let types = ["餐饮", "咖啡", "超市", "加油", "交通", "医疗药房", "购物", "住宿", "娱乐", "账单服务", "其他"]
    public static let incomeType = "收入"

    private static let rules: [(String, [String])] = [
        ("咖啡", ["starbucks", "coffee", "cafe", "peet", "dunkin", "dutch bros", "boba", "bubble tea", "blue bottle"]),
        ("餐饮", ["restaurant", "grill", "kitchen", "pizza", "burger", "sushi", "ramen", "taco", "bbq", "diner",
                  "bistro", "bakery", "noodle", "mcdonald", "chipotle", "subway", "panda express", "wendy",
                  "kfc", "chick fil a", "in n out", "pho", "thai", "deli", "steakhouse", "eatery", "hot pot"]),
        ("超市", ["market", "grocery", "safeway", "trader joe", "whole foods", "costco", "walmart", "kroger",
                  "aldi", "albertsons", "ralphs", "vons", "99 ranch", "h mart", "sprouts", "supermarket", "target"]),
        ("加油", ["shell", "chevron", "arco", "exxon", "mobil", "texaco", "valero", "gas station", "fuel", "76"]),
        ("交通", ["uber", "lyft", "parking", "transit", "metro", "bart", "amtrak", "airlines", "airline",
                  "delta", "toll", "clipper", "taxi"]),
        ("医疗药房", ["cvs", "walgreens", "pharmacy", "rite aid", "clinic", "dental", "hospital", "urgent care"]),
        ("购物", ["amazon", "best buy", "apple store", "ikea", "home depot", "lowes", "nordstrom", "macys",
                  "tj maxx", "marshalls", "ross", "uniqlo", "nike", "bed bath"]),
        ("住宿", ["hotel", "motel", "airbnb", "marriott", "hilton", "hyatt", "resort", "inn"]),
        ("娱乐", ["cinema", "amc", "theatre", "theater", "netflix", "spotify", "ticketmaster", "bowling",
                  "golf", "museum", "steam"]),
        ("账单服务", ["comcast", "verizon", "t mobile", "pg e", "utility", "insurance", "electric", "internet", "at t"])
    ]

    /// Most specific (longest) matching keyword in the merchant name wins; item words are weaker evidence.
    public static func suggest(merchantName: String, itemNames: [String] = []) -> String? {
        if let match = bestMatch(in: merchantName) { return match }
        let itemTypes = itemNames.compactMap { bestMatch(in: $0) }
        let counts = Dictionary(grouping: itemTypes, by: { $0 }).mapValues(\.count)
        guard let top = counts.max(by: { $0.value < $1.value }), top.value >= 2,
              counts.values.filter({ $0 == top.value }).count == 1 else { return nil }
        return top.key
    }

    private static func bestMatch(in text: String) -> String? {
        let words = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let normalized = " " + String(words).split(separator: " ").joined(separator: " ") + " "
        var best: (type: String, length: Int)?
        for (type, keywords) in rules {
            for keyword in keywords {
                // Short keywords must be whole words so "ross" does not match "across".
                let matched = keyword.count >= 6 ? normalized.contains(keyword) : normalized.contains(" \(keyword) ")
                if matched, keyword.count > (best?.length ?? 0) { best = (type, keyword.count) }
            }
        }
        if best == nil {
            // Photos misread a letter or two ("FRADER JOES"); allow one error in long brand names only.
            for (type, keywords) in rules {
                for keyword in keywords where keyword.count >= 7 && fuzzyContains(normalized, keyword) {
                    if keyword.count > (best?.length ?? 0) { best = (type, keyword.count) }
                }
            }
        }
        return best?.type
    }

    private static func fuzzyContains(_ text: String, _ keyword: String) -> Bool {
        let haystack = Array(text)
        let needle = Array(keyword)
        for length in (needle.count - 1)...(needle.count + 1) where haystack.count >= length {
            for start in 0...(haystack.count - length)
            where editDistance(Array(haystack[start..<(start + length)]), needle) <= 1 {
                return true
            }
        }
        return false
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

public struct ReceiptSubmission: Sendable {
    public let merchantName: String
    public let businessType: String
    public let totalCents: Int64
    public let date: Date
    public let author: String
    public let allowPossibleDuplicate: Bool

    public init(merchantName: String, businessType: String, totalCents: Int64, date: Date,
                author: String, allowPossibleDuplicate: Bool = false) {
        self.merchantName = merchantName
        self.businessType = businessType
        self.totalCents = totalCents
        self.date = date
        self.author = author
        self.allowPossibleDuplicate = allowPossibleDuplicate
    }
}

extension HouseholdBook {
    /// Reuses a remembered merchant by name or alias, creates a new one on first sight, then records
    /// exactly one expense for the receipt. Callers run this on a copy, so any failure changes nothing.
    @discardableResult
    public mutating func submitReceipt(
        _ draft: ReceiptDraft, _ submission: ReceiptSubmission, calendar: Calendar
    ) throws -> ConfirmedReceipt {
        let name = submission.merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = submission.businessType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !MerchantProfile.key(name).isEmpty else { throw FinanceError.invalidField("商店名称") }
        guard !type.isEmpty else { throw FinanceError.invalidField("商店类型") }
        let merchant: MerchantProfile
        if let existing = self.merchant(matching: name) {
            merchant = existing.businessType == type ? existing : MerchantProfile(
                id: existing.id, name: existing.name, businessType: type,
                aliases: existing.aliases, address: existing.address
            )
        } else {
            merchant = MerchantProfile(name: name, businessType: type)
        }
        try saveMerchant(merchant)
        let review = ReceiptReview(
            merchantID: merchant.id, totalCents: submission.totalCents, items: draft.suggestedItems,
            taxCents: draft.suggestedTaxCents ?? 0, date: submission.date, author: submission.author,
            note: merchant.name
        )
        return try confirmReceipt(
            draft, review: review, calendar: calendar,
            allowPossibleDuplicate: submission.allowPossibleDuplicate
        )
    }
}
