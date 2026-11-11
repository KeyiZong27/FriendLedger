import Foundation

public enum FinanceError: LocalizedError, Equatable {
    case invalidField(String)
    case duplicateReceipt
    case possibleDuplicateReceipt
    case merchantNotFound
    case ambiguousMerchant
    case duplicateID
    case payrollMismatch
    case savingsNotConfigured
    case savingsBeforeOpening
    case insufficientSavings
    case exchangeRateMissing
    case inconsistentBook

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field): "请检查\(field)。"
        case .duplicateReceipt: "这张收据已经入账，不能重复添加。"
        case .possibleDuplicateReceipt: "已有同商家、同日期、同金额的收据，请核对是否重复。"
        case .merchantNotFound: "请先确认并保存商家及商家类型。"
        case .ambiguousMerchant: "这个商家名称或别名已属于另一个商家，请手动区分。"
        case .duplicateID: "这条记录已经存在，请刷新后核对。"
        case .payrollMismatch: "税前工资减预扣税及其他扣款，必须等于实际到账。请补齐扣款或检查金额。"
        case .savingsNotConfigured: "请先记录初始存款及其日期。"
        case .savingsBeforeOpening: "存款流水日期不能早于初始存款日期。"
        case .insufficientSavings: "这笔取出会使存款余额为负，请检查金额和日期。"
        case .exchangeRateMissing: "请先设置有效的美元兑人民币汇率及日期。"
        case .inconsistentBook: "账本数据不一致，不能保存或分析，请检查关联记录。"
        }
    }
}

public struct MerchantProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let businessType: String
    public let aliases: [String]
    public let address: String?

    public init(id: String = UUID().uuidString, name: String, businessType: String,
                aliases: [String] = [], address: String? = nil) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.businessType = businessType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = aliases
        self.address = address
    }

    public static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    var keys: Set<String> { Set(([name] + aliases).map(Self.key)) }
}

public struct ReceiptItem: Codable, Equatable, Sendable {
    public let name: String
    public let lineTotalCents: Int64

    public init(name: String, lineTotalCents: Int64) {
        self.name = name
        self.lineTotalCents = lineTotalCents
    }
}

public struct ReceiptAdjustment: Codable, Equatable, Sendable {
    public let name: String
    public let amountCents: Int64

    public init(name: String, amountCents: Int64) {
        self.name = name
        self.amountCents = amountCents
    }
}

public struct ReceiptTotalCandidate: Codable, Equatable, Sendable {
    public let label: String
    public let amountCents: Int64
    public let lineNumber: Int

    public init(label: String, amountCents: Int64, lineNumber: Int) {
        self.label = label
        self.amountCents = amountCents
        self.lineNumber = lineNumber
    }
}

public enum ReceiptConfidence: String, Codable, Sendable {
    case high, medium, low
}

/// What the app could cross-check on its own. These guide your review; they never replace it.
public struct ReceiptChecks: Sendable {
    public let merchant: ReceiptConfidence
    public let date: ReceiptConfidence
    public let total: ReceiptConfidence
    /// Confirmations such as "小计 + 税 = 总额".
    public let confirmations: [String]
    /// Mismatches or weak spots to look at before saving.
    public let problems: [String]
    public let score: Int

    public init(merchant: ReceiptConfidence = .low, date: ReceiptConfidence = .low, total: ReceiptConfidence = .low,
                confirmations: [String] = [], problems: [String] = [], score: Int = 0) {
        self.merchant = merchant
        self.date = date
        self.total = total
        self.confirmations = confirmations
        self.problems = problems
        self.score = score
    }
}

public struct ReceiptDay: Codable, Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

public struct ReceiptDraft: Identifiable, Sendable {
    public let id: String
    public let imageFingerprint: String?
    public let rawText: String
    public let suggestedMerchantName: String?
    public let totalCandidates: [ReceiptTotalCandidate]
    public let suggestedItems: [ReceiptItem]
    public let suggestedTaxCents: Int64?
    public let warnings: [String]
    public let suggestedDay: ReceiptDay?
    public let checks: ReceiptChecks
    public var suggestedTotalCents: Int64? {
        let amounts = Set(totalCandidates.map(\.amountCents))
        return amounts.count == 1 ? amounts.first : nil
    }

    public init(
        id: String = UUID().uuidString, imageFingerprint: String? = nil, rawText: String,
        suggestedMerchantName: String?, totalCandidates: [ReceiptTotalCandidate],
        suggestedItems: [ReceiptItem], suggestedTaxCents: Int64?, warnings: [String],
        suggestedDay: ReceiptDay? = nil, checks: ReceiptChecks = ReceiptChecks()
    ) {
        self.id = id
        self.imageFingerprint = imageFingerprint
        self.rawText = rawText
        self.suggestedMerchantName = suggestedMerchantName
        self.totalCandidates = totalCandidates
        self.suggestedItems = suggestedItems
        self.suggestedTaxCents = suggestedTaxCents
        self.warnings = warnings
        self.suggestedDay = suggestedDay
        self.checks = checks
    }
}

public struct ReceiptReview: Sendable {
    public let merchantID: String
    public let totalCents: Int64
    public let items: [ReceiptItem]
    public let adjustments: [ReceiptAdjustment]
    public let taxCents: Int64
    public let date: Date
    public let author: String
    public let note: String

    public init(
        merchantID: String, totalCents: Int64, items: [ReceiptItem],
        adjustments: [ReceiptAdjustment] = [], taxCents: Int64 = 0,
        date: Date, author: String, note: String = ""
    ) {
        self.merchantID = merchantID
        self.totalCents = totalCents
        self.items = items
        self.adjustments = adjustments
        self.taxCents = taxCents
        self.date = date
        self.author = author
        self.note = note
    }
}

public struct ConfirmedReceipt: Identifiable, Codable, Sendable {
    public let id: String
    public let entryID: String
    public let imageFingerprint: String?
    public let merchant: MerchantProfile
    public let items: [ReceiptItem]
    public let adjustments: [ReceiptAdjustment]
    public let taxCents: Int64
    public let totalCents: Int64
    public let date: Date

    public var detailDifferenceCents: Decimal {
        Decimal(totalCents) - Decimal(taxCents)
            - items.reduce(Decimal.zero) { $0 + Decimal($1.lineTotalCents) }
            - adjustments.reduce(Decimal.zero) { $0 + Decimal($1.amountCents) }
    }
}
