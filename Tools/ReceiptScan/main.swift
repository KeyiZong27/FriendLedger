import Foundation
import FriendLedgerCore

// Usage: swift run ReceiptScan [--raw] photo1.jpg photo2.jpg ...
// Runs the same on-device recognizer as the app and prints what it would pre-fill.
let arguments = Array(CommandLine.arguments.dropFirst())
let showRaw = arguments.contains("--raw")
let paths = arguments.filter { $0 != "--raw" }
guard !paths.isEmpty else {
    print("Usage: ReceiptScan [--raw] photo...")
    exit(2)
}

func money(_ cents: Int64) -> String {
    String(format: "$%lld.%02lld", cents / 100, cents % 100)
}

for path in paths {
    print("=== \(URL(fileURLWithPath: path).lastPathComponent)")
    do {
        let draft = try await LocalReceiptRecognizer.recognize(imageData: Data(contentsOf: URL(fileURLWithPath: path)))
        let merchant = draft.suggestedMerchantName ?? "(none)"
        let type = draft.suggestedMerchantName.flatMap {
            MerchantTypeClassifier.suggest(merchantName: $0, itemNames: draft.suggestedItems.map(\.name))
        } ?? "(cannot tell)"
        print("store:  \(merchant)  ->  type: \(type)")
        if let day = draft.suggestedDay { print("date:   \(day.year)-\(day.month)-\(day.day)") } else { print("date:   (none)") }
        print("total:  \(draft.suggestedTotalCents.map(money) ?? "(none)")   candidates: "
              + draft.totalCandidates.map { "\($0.label)=\(money($0.amountCents))" }.joined(separator: ", "))
        print("tax:    \(draft.suggestedTaxCents.map(money) ?? "(none)")")
        print("items:  \(draft.suggestedItems.count)")
        print("trust:  store=\(draft.checks.merchant.rawValue) date=\(draft.checks.date.rawValue) "
              + "total=\(draft.checks.total.rawValue) ocr=\(draft.textConfidence.map { String(format: "%.0f%%", $0 * 100) } ?? "-")")
        for note in draft.checks.confirmations { print("  ok:   \(note)") }
        for problem in draft.checks.problems { print("  CHECK: \(problem)") }
        for item in draft.suggestedItems { print("   \(item.name)  \(money(item.lineTotalCents))") }
        for warning in draft.warnings.dropFirst() { print("warn:   \(warning)") }
        if showRaw { print("--- raw OCR text ---\n\(draft.rawText)\n--- end ---") }
    } catch {
        print("FAILED: \(error.localizedDescription)")
    }
}
