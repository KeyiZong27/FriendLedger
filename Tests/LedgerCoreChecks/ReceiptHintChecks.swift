import Foundation
import FriendLedgerCore

@MainActor
func runReceiptHintChecks() throws {
    func parse(_ text: String, _ hint: ReceiptInterpretation) throws -> ReceiptDraft {
        try ReceiptTextParser.parse(text, interpretation: hint)
    }

    // Misread digit: the rules take $186.00 from the TOTAL row, the card slip prints $186.06.
    let slip = "TRADER JOES\nTOTAL $186.00\nUSD$ 186.06\nSUBTOTAL 186.06"
    let baseline = try ReceiptTextParser.parse(slip)
    try check(baseline.suggestedTotalCents == 18600 && baseline.checks.total == .low && !baseline.usedOnDeviceModel,
              "Rules alone must flag the mismatch")
    let corrected = try parse(slip, ReceiptInterpretation(totalCents: 18606))
    try check(corrected.suggestedTotalCents == 18606 && corrected.checks.total == .high && corrected.usedOnDeviceModel,
              "A model total confirmed by the card amount must replace the misread: \(corrected.checks)")
    try check(corrected.warnings.contains { $0.contains("修正为") }, "The correction must be explained")

    let invented = try parse(slip, ReceiptInterpretation(totalCents: 9999, taxCents: 777, paidCents: 5000))
    try check(invented.suggestedTotalCents == 18600 && invented.suggestedTaxCents == nil && !invented.usedOnDeviceModel,
              "Numbers the receipt never prints must be ignored")

    let missing = try parse("SHOP\nMILK 5.00\nAMT 5.00", ReceiptInterpretation(totalCents: 500))
    try check(missing.suggestedTotalCents == 500 && missing.usedOnDeviceModel && missing.checks.total == .medium,
              "A printed total the rules missed may be filled in, but stays unverified")
    try check(missing.warnings.contains { $0.contains("请对照小票") }, "Model-only totals must ask for review")

    let verifiedRule = try parse("SHOP\nSUBTOTAL 27.13\nTOTAL 29.02\nVISA TEND 29.02", ReceiptInterpretation(totalCents: 2713))
    try check(verifiedRule.suggestedTotalCents == 2902 && verifiedRule.checks.total == .high,
              "A verified rule reading must not be overridden by the model")

    let disputedText = "SHOP\nWIDGET 12.00\nTOTAL 10.00"
    let disputed = try parse(disputedText, ReceiptInterpretation(totalCents: 1200))
    try check(disputed.suggestedTotalCents == 1000 && disputed.checks.total == .low
              && disputed.checks.problems.contains { $0.contains("大模型") },
              "Unverifiable disagreement must keep the rules' total and be flagged: \(disputed.checks)")

    let ambiguous = try parse("SHOP\nTOTAL 10.00\nGRAND TOTAL 12.00", ReceiptInterpretation(totalCents: 1200))
    try check(ambiguous.suggestedTotalCents == 1200, "The model may choose among the rules' own candidates")

    // The name sits after the 12 rows the rules inspect, e.g. on a long receipt with a logo-only header.
    let filler = (1...13).map { "LOGO LINE \($0)" }.joined(separator: "\n")
    let named = try parse("ZZ HEADER\n\(filler)\nTrader Joes Store\nTOTAL 5.00", ReceiptInterpretation(merchantName: "Trader Joes"))
    try check(named.suggestedMerchantName == "Trader Joes" && named.usedOnDeviceModel,
              "A printed, recognizable store name may replace an unrecognized header")
    let madeUp = try parse("ZZ HEADER\nTOTAL 5.00", ReceiptInterpretation(merchantName: "Costco"))
    try check(madeUp.suggestedMerchantName == "ZZ HEADER" && !madeUp.usedOnDeviceModel,
              "A store name that is not printed must be ignored")
    let keepKnown = try parse("Walmart\nTrader Joes\nTOTAL 5.00", ReceiptInterpretation(merchantName: "Trader Joes"))
    try check(keepKnown.suggestedMerchantName == "Walmart", "A recognized store from the rules must not be replaced")

    let supports = try parse("SHOP\nSUBTOTAL 6.00\nTAX 0.48\nTOTAL 6.48", ReceiptInterpretation(paidCents: 648))
    try check(supports.checks.total == .high && supports.checks.confirmations.contains { $0.contains("刷卡") },
              "A printed payment amount found by the model can verify the total")
}
