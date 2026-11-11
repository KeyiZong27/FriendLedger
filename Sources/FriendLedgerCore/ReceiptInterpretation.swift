import Foundation

/// What a language model read from the recognized text. Every value is only a suggestion: it is used
/// when the text itself backs it up, and never when it merely looks plausible.
public struct ReceiptInterpretation: Sendable {
    public var merchantName: String?
    public var totalCents: Int64?
    public var subtotalCents: Int64?
    public var taxCents: Int64?
    public var paidCents: Int64?

    public init(merchantName: String? = nil, totalCents: Int64? = nil, subtotalCents: Int64? = nil,
                taxCents: Int64? = nil, paidCents: Int64? = nil) {
        self.merchantName = merchantName
        self.totalCents = totalCents
        self.subtotalCents = subtotalCents
        self.taxCents = taxCents
        self.paidCents = paidCents
    }
}

public protocol ReceiptTextInterpreter: Sendable {
    func interpret(_ text: String) async throws -> ReceiptInterpretation
}

struct ReceiptHintOutcome {
    var merchant: String?
    var usedModel = false
    var disputedTotal = false
    var notes: [String] = []
}

/// Rules read the receipt first; the model's reading is accepted only where it can be verified.
enum ReceiptHints {
    private static func money(_ cents: Int64) -> String {
        String(format: "$%lld.%02lld", cents / 100, cents % 100)
    }

    static func apply(
        _ hint: ReceiptInterpretation, text: String, printed: Set<Int64>, merchant: String?,
        totals: inout [ReceiptTotalCandidate], subtotals: inout [Int64],
        taxes: inout [Int64], tenders: inout [Int64]
    ) -> ReceiptHintOutcome {
        var outcome = ReceiptHintOutcome(merchant: merchant)
        // A number the receipt never prints is an invention, whatever the model says.
        func seen(_ cents: Int64?) -> Int64? {
            guard let cents, cents > 0, printed.contains(cents) else { return nil }
            return cents
        }
        if let subtotal = seen(hint.subtotalCents), subtotals.isEmpty {
            subtotals.append(subtotal)
            outcome.usedModel = true
        }
        if let tax = seen(hint.taxCents), taxes.isEmpty {
            taxes.append(tax)
            outcome.usedModel = true
        }
        if let paid = seen(hint.paidCents), !tenders.contains(paid) {
            tenders.append(paid)
            outcome.usedModel = true
        }

        if let name = hint.merchantName?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let key = MerchantProfile.key(name)
            let known = MerchantTypeClassifier.suggest(merchantName: name, allowFuzzy: false) != nil
            let current = merchant.flatMap { MerchantTypeClassifier.suggest(merchantName: $0, allowFuzzy: false) }
            if key.count >= 3, MerchantProfile.key(text).contains(key), name != merchant,
               merchant == nil || (current == nil && known) {
                outcome.merchant = name
                outcome.usedModel = true
                if merchant != nil { outcome.notes.append("商店名称由本机大模型从识别文字中选定") }
            }
        }

        guard let modelTotal = seen(hint.totalCents) else { return outcome }
        let ruleAmounts = Set(totals.map(\.amountCents))
        // Card amount or subtotal + tax confirm a total strongly; a subtotal alone (no tax line) only weakly.
        func strength(_ value: Int64) -> Int {
            if tenders.contains(value) { return 2 }
            guard subtotals.count == 1 else { return 0 }
            if taxes.count == 1 { return subtotals[0] + taxes[0] == value ? 2 : 0 }
            return subtotals[0] == value ? 1 : 0
        }
        let candidate = ReceiptTotalCandidate(label: "本机大模型", amountCents: modelTotal, lineNumber: 0)
        if ruleAmounts.isEmpty {
            totals = [candidate]
            outcome.usedModel = true
            outcome.notes.append("总额由本机大模型从识别文字中读出，请对照小票")
        } else if ruleAmounts == [modelTotal] {
            outcome.usedModel = true
        } else if ruleAmounts.count > 1, ruleAmounts.contains(modelTotal) {
            totals = totals.filter { $0.amountCents == modelTotal }
            outcome.usedModel = true
            outcome.notes.append("多个总额候选中，本机大模型选定 \(money(modelTotal))")
        } else if ruleAmounts.count == 1, let ruleTotal = ruleAmounts.first {
            if strength(modelTotal) > strength(ruleTotal), strength(modelTotal) >= 1 {
                totals = [candidate]
                outcome.usedModel = true
                outcome.notes.append("总额由规则读出的 \(money(ruleTotal)) 修正为 \(money(modelTotal))，与付款金额 / 小计核对一致")
            } else if strength(ruleTotal) > strength(modelTotal) {
                outcome.notes.append("本机大模型读出 \(money(modelTotal))，但规则读出的 \(money(ruleTotal)) 通过了更强的核对，已保留后者")
            } else {
                outcome.disputedTotal = true
                outcome.notes.append("规则读出 \(money(ruleTotal))，本机大模型读出 \(money(modelTotal))，都未能验证，请对照小票")
            }
        } else {
            outcome.disputedTotal = true
        }
        return outcome
    }
}
