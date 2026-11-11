import Foundation

public enum ReceiptTextParser {
    public static func parse(
        _ text: String, imageFingerprint: String? = nil, textConfidence: Double? = nil
    ) throws -> ReceiptDraft {
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
        var subtotals: [Int64] = []
        var tenders: [Int64] = []
        var warnings = ["识别结果必须核对；商家、日期、金额及明细均可能识别不完整。"]
        var candidateRows: [String] = []
        let taxLabelPattern = try NSRegularExpression(pattern: #"^(?:SALES\s+)?TAX\s*\d*(?:\s+[\d.]+\s*%)?$"#)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = pricePattern.matches(in: line, range: range)
            if matches.isEmpty, candidateRows.count < 12, line.rangeOfCharacter(from: .letters) != nil {
                candidateRows.append(line)
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
            // A price can lead the row ("29.02 TOTAL PURCHASE"); only totals are read that way.
            let totalLabel = label.isEmpty && suffix.filter(\.isLetter).count >= 4 ? suffix : label
            let upperTotalLabel = totalLabel.uppercased()
            let excludedTotal = ["SAVING", "DISCOUNT", "ITEM", "TAX", "SUBTOTAL", "SUB TOTAL"]
                .contains { upperTotalLabel.contains($0) }
            if totalPattern.firstMatch(in: totalLabel, range: NSRange(totalLabel.startIndex..<totalLabel.endIndex, in: totalLabel)) != nil,
               !excludedTotal {
                if matches.count == 1, amount > 0 {
                    totals.append(ReceiptTotalCandidate(label: totalLabel, amountCents: amount, lineNumber: index + 1))
                } else {
                    warnings.append("第 \(index + 1) 行总额不明确，请手动核对。")
                }
            } else if matches.count == 1,
                      taxLabelPattern.firstMatch(in: upper, range: NSRange(upper.startIndex..<upper.endIndex, in: upper)) != nil {
                taxes.append(amount)
            } else if matches.count == 1, upper.contains("SUBTOTAL") || upper.contains("SUB TOTAL") {
                subtotals.append(amount)
            } else if matches.count == 1, !upper.contains("CHANGE"),
                      ["VISA", "MASTERCARD", "AMEX", "DEBIT", "CREDIT", "TEND", "USD"].contains(where: { upper.contains($0) }) {
                tenders.append(amount)
            } else if !label.isEmpty, matches.count == 1,
                      !["TOTAL", "TAX", "CASH", "CHANGE", "TENDER", "VISA", "MASTERCARD",
                        "AMEX", "DEBIT", "CREDIT", "BALANCE", "SAVING", "DISCOUNT", "COUPON",
                        "TIP", "GRATUITY", "SERVICE", "PAYMENT", "APPROVED", "AMOUNT", "QTY", "@",
                        "#", "VOID", "TEND"]
                        .contains(where: { upper.contains($0) }),
                      let name = Self.itemName(label) {
                items.append(ReceiptItem(name: name, lineTotalCents: amount))
            }
        }
        let merchant = pickMerchant(candidateRows)
        if totals.isEmpty { warnings.append("未找到明确的 TOTAL / AMOUNT DUE，请手动输入总额。") }
        if Set(totals.map(\.amountCents)).count > 1 {
            warnings.append("发现多个不同总额，不能自动选择；请核对最终支付金额及小费。")
        }
        if taxes.count > 1 { warnings.append("发现多条税额，请核对合计税额。") }
        let days = receiptDays(in: text)
        if days.count > 1 { warnings.append("发现多个不同日期，未自动选择，请手动确认消费日期。") }
        if days.isEmpty { warnings.append("未识别到消费日期，默认使用今天，请核对。") }
        let singleTax = taxes.count == 1 ? taxes.first : nil
        let singleDay = days.count == 1 ? days.first : nil
        let checks = makeChecks(
            merchant: merchant, items: items, tax: singleTax, totals: totals, subtotals: subtotals,
            tenders: tenders, day: singleDay, textConfidence: textConfidence
        )
        return ReceiptDraft(
            imageFingerprint: imageFingerprint, rawText: text, suggestedMerchantName: merchant,
            totalCandidates: totals, suggestedItems: items,
            suggestedTaxCents: singleTax, warnings: warnings,
            suggestedDay: singleDay, checks: checks, textConfidence: textConfidence
        )
    }

    private static func money(_ cents: Int64) -> String {
        String(format: "$%lld.%02lld", cents / 100, cents % 100)
    }

    /// Cross-checks that need no extra data: the card amount, subtotal + tax and the item sum all point
    /// at the same total on a correctly read receipt, and rarely agree by accident on a misread one.
    private static func makeChecks(
        merchant: String?, items: [ReceiptItem], tax: Int64?, totals: [ReceiptTotalCandidate],
        subtotals: [Int64], tenders: [Int64], day: ReceiptDay?, textConfidence: Double?
    ) -> ReceiptChecks {
        var confirmations: [String] = []
        var problems: [String] = []
        let amounts = Set(totals.map(\.amountCents))
        var total = ReceiptConfidence.low
        if amounts.count == 1, let value = amounts.first {
            total = .medium
            if tenders.contains(value) {
                confirmations.append("总额与刷卡 / 付款金额一致")
                total = .high
            }
            if subtotals.count == 1, let subtotal = subtotals.first {
                if subtotal + (tax ?? 0) == value {
                    confirmations.append(tax == nil ? "小计等于总额" : "小计 + 税 = 总额")
                    total = .high
                } else if subtotal < value {
                    problems.append("小计 \(money(subtotal)) + 税 \(money(tax ?? 0)) 不等于总额 \(money(value))，可能有小费、服务费或识别错误")
                }
            }
            if !tenders.isEmpty, !tenders.contains(value) {
                let paid = Set(tenders).sorted().map(money).joined(separator: " / ")
                problems.append("付款金额 \(paid) 与总额 \(money(value)) 不一致，可能漏读了数字，请对照小票")
                if total != .high { total = .low }
            }
            if total == .medium { problems.append("总额没有被其他金额验证，请对照小票核对") }
        } else if amounts.count > 1 {
            problems.append("发现多个不同总额，请选择最终支付金额")
        } else {
            problems.append("未找到总额，请手动输入")
        }
        if subtotals.count == 1, let subtotal = subtotals.first, !items.isEmpty {
            let sum = items.reduce(Int64(0)) { $0 + $1.lineTotalCents }
            if sum == subtotal {
                confirmations.append("商品合计与小计一致")
            } else {
                problems.append("识别到的商品合计 \(money(sum)) 与小计 \(money(subtotal)) 不同，明细可能漏项（不影响记账金额）")
            }
        }
        var merchantLevel = ReceiptConfidence.low
        if let merchant {
            merchantLevel = MerchantTypeClassifier.suggest(merchantName: merchant, allowFuzzy: false) != nil ? .high : .medium
        } else {
            problems.append("未识别到商店名称")
        }
        if let textConfidence, textConfidence < 0.6 {
            problems.append("照片文字清晰度较低（约 \(Int(textConfidence * 100))%），建议重拍或逐项核对")
        }
        let dateLevel: ReceiptConfidence = day == nil ? .low : .high
        var score = total == .high ? 50 : total == .medium ? 25 : 0
        score += dateLevel == .high ? 10 : 0
        score += merchantLevel == .high ? 10 : merchantLevel == .medium ? 5 : 0
        score += confirmations.count * 5 - problems.count * 5 + min(items.count, 10) + (tax == nil ? 0 : 5)
        return ReceiptChecks(
            merchant: merchantLevel, date: dateLevel, total: total,
            confirmations: confirmations, problems: problems, score: score
        )
    }

    /// Drops product codes and department flags ("MILK 123456789012 F" -> "MILK"); code-only rows are not items.
    private static func itemName(_ label: String) -> String? {
        var words = label.split(separator: " ").map(String.init)
        words.removeAll { $0.count >= 8 && $0.filter(\.isNumber).count >= 8 }
        while let last = words.last, last.count == 1, last.first?.isLetter == true { words.removeLast() }
        let name = words.joined(separator: " ")
        return name.filter(\.isLetter).count >= 2 ? name : nil
    }

    /// Prefers a top row that looks like a known brand; otherwise the first plausible name row.
    private static func pickMerchant(_ rows: [String]) -> String? {
        let hardNoise = ["thank", "feedback", "survey", "www", "http", ".com", "@", "welcome", "receipt", "customer copy"]
        // Store numbers and phone lines often share a row with the name; keep only what precedes them.
        let softNoise = ["id #", "store #", "mgr"]
        let plausible = rows.compactMap { row -> String? in
            var text = row
            guard !hardNoise.contains(where: { text.lowercased().contains($0) }) else { return nil }
            for marker in softNoise {
                if let range = text.range(of: marker, options: .caseInsensitive) { text = String(text[..<range.lowerBound]) }
            }
            let cleaned = text.drop { !$0.isLetter }.reversed().drop { !$0.isLetter && $0 != "." && $0 != "'" }.reversed()
            let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            let letters = name.filter(\.isLetter).count
            return letters >= 2 && letters >= name.filter(\.isNumber).count ? name : nil
        }
        return plausible.first { MerchantTypeClassifier.suggest(merchantName: $0) != nil } ?? plausible.first
    }

    private static func receiptDays(in text: String) -> [ReceiptDay] {
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let patterns: [(String, ([String]) -> (Int, Int, Int)?)] = [
            (#"(?<![\d/])(\d{4})-(\d{1,2})-(\d{1,2})(?![\d/])"#, { g in
                guard let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) else { return nil }
                return (y, m, d)
            }),
            (#"(?<![\d/])(\d{1,2})/(\d{1,2})/(\d{4}|\d{2})(?![\d/])"#, { g in
                guard let m = Int(g[0]), let d = Int(g[1]), var y = Int(g[2]) else { return nil }
                if g[2].count == 2 { y += 2000 }
                return (y, m, d)
            }),
            (#"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})\b"#, { g in
                guard let m = months[g[0].lowercased()], let d = Int(g[1]), let y = Int(g[2]) else { return nil }
                return (y, m, d)
            })
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var found: [ReceiptDay] = []
        for (pattern, convert) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                let groups = (1..<match.numberOfRanges).compactMap { index in
                    Range(match.range(at: index), in: text).map { String(text[$0]) }
                }
                guard groups.count == match.numberOfRanges - 1, let (y, m, d) = convert(groups),
                      (2000...2100).contains(y),
                      let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
                      calendar.dateComponents([.year, .month, .day], from: date) ==
                        DateComponents(year: y, month: m, day: d) else { continue }
                let day = ReceiptDay(year: y, month: m, day: d)
                if !found.contains(day) { found.append(day) }
            }
        }
        return found
    }
}
