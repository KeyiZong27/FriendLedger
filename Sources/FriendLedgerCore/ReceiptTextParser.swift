import Foundation

public enum ReceiptTextParser {
    public static func parse(_ text: String, imageFingerprint: String? = nil) throws -> ReceiptDraft {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FinanceError.invalidField("收据识别文本，未发现可识别内容")
        }
        let pricePattern = try NSRegularExpression(
            pattern: #"(?<![\d.\-])(?:\$\s*)?((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})(?![\d.])"#
        )
        let totalPattern = try NSRegularExpression(
            pattern: #"^(?:GRAND\s+TOTAL|TOTAL(?:\s+(?:DUE|SALE|AMOUNT))?|AMOUNT\s+DUE|BALANCE\s+DUE)\b"#,
            options: .caseInsensitive
        )
        let lines = text.components(separatedBy: .newlines)
        var totals: [ReceiptTotalCandidate] = []
        var items: [ReceiptItem] = []
        var taxes: [Int64] = []
        var warnings = ["识别结果必须核对；商家、日期、金额及明细均可能识别不完整。"]
        var merchant: String?
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = pricePattern.matches(in: line, range: range)
            if merchant == nil, matches.isEmpty,
               line.rangeOfCharacter(from: .letters) != nil,
               !["WELCOME", "THANK YOU", "RECEIPT"].contains(line.uppercased()) {
                merchant = line
            }
            guard let match = matches.last,
                  let priceRange = Range(match.range(at: 1), in: line),
                  let fullRange = Range(match.range, in: line) else { continue }
            let amount = try Money.parseNonnegative(String(line[priceRange]).replacingOccurrences(of: ",", with: ""))
            let label = String(line[..<fullRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(line[fullRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.hasSuffix("-"), !label.hasSuffix("-$"), !suffix.hasPrefix("-") else {
                warnings.append("第 \(index + 1) 行可能是负数或优惠，请手动核对，不按正数商品处理。")
                continue
            }
            let upper = label.uppercased()
            let excludedTotal = ["SAVING", "DISCOUNT", "ITEM", "TAX", "SUBTOTAL", "SUB TOTAL"]
                .contains { upper.contains($0) }
            if totalPattern.firstMatch(in: label, range: NSRange(label.startIndex..<label.endIndex, in: label)) != nil,
               !excludedTotal {
                if matches.count == 1, amount > 0 {
                    totals.append(ReceiptTotalCandidate(label: label, amountCents: amount, lineNumber: index + 1))
                } else {
                    warnings.append("第 \(index + 1) 行总额不明确，请手动核对。")
                }
            } else if (upper == "TAX" || upper == "SALES TAX"), matches.count == 1 {
                taxes.append(amount)
            } else if !label.isEmpty, matches.count == 1,
                      !["TOTAL", "TAX", "CASH", "CHANGE", "TENDER", "VISA", "MASTERCARD",
                        "AMEX", "DEBIT", "CREDIT", "BALANCE", "SAVING", "DISCOUNT", "COUPON",
                        "TIP", "GRATUITY", "SERVICE", "PAYMENT", "APPROVED", "AMOUNT", "QTY", "@"]
                        .contains(where: { upper.contains($0) }) {
                items.append(ReceiptItem(name: label, lineTotalCents: amount))
            }
        }
        if totals.isEmpty { warnings.append("未找到明确的 TOTAL / AMOUNT DUE，请手动输入总额。") }
        if Set(totals.map(\.amountCents)).count > 1 {
            warnings.append("发现多个不同总额，不能自动选择；请核对最终支付金额及小费。")
        }
        if taxes.count > 1 { warnings.append("发现多条税额，请核对合计税额。") }
        return ReceiptDraft(
            imageFingerprint: imageFingerprint, rawText: text, suggestedMerchantName: merchant,
            totalCandidates: totals, suggestedItems: items,
            suggestedTaxCents: taxes.count == 1 ? taxes.first : nil, warnings: warnings
        )
    }
}
