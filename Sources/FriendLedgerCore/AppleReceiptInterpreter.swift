import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Uses Apple's on-device language model (never a cloud model) to point at values in the recognized text.
/// It is asked to copy, not calculate; `ReceiptHints` then accepts only values the printed text confirms.
@available(iOS 26.0, macOS 26.0, *)
public struct AppleReceiptInterpreter: ReceiptTextInterpreter {
    @Generable
    struct Reading {
        @Guide(description: "Store name exactly as printed near the top, or nil if there is none")
        var storeName: String?
        @Guide(description: "Final amount charged, copied exactly as printed, e.g. 29.02. nil if not printed")
        var total: String?
        @Guide(description: "Subtotal before tax, copied exactly as printed, or nil")
        var subtotal: String?
        @Guide(description: "Sales tax amount in dollars, copied exactly as printed, or nil")
        var tax: String?
        @Guide(description: "Amount paid by card or tender, copied exactly as printed, or nil")
        var paid: String?
    }

    public init() {}

    /// nil when the model cannot run here (unsupported device, Apple Intelligence off, unsupported region).
    public static func makeIfAvailable() -> AppleReceiptInterpreter? {
        SystemLanguageModel.default.isAvailable ? AppleReceiptInterpreter() : nil
    }

    public func interpret(_ text: String) async throws -> ReceiptInterpretation {
        let session = LanguageModelSession(instructions: """
        You extract fields from OCR text of a U.S. retail receipt. Copy values exactly as they appear in the \
        text. Never calculate, guess or invent a number. If a field is not clearly present, leave it nil. \
        The text may contain recognition mistakes and lines out of order.
        """)
        let response = try await session.respond(
            to: "Receipt text:\n\(Self.condensed(text))", generating: Reading.self
        )
        let reading = response.content
        return ReceiptInterpretation(
            merchantName: reading.storeName, totalCents: Self.cents(reading.total),
            subtotalCents: Self.cents(reading.subtotal), taxCents: Self.cents(reading.tax),
            paidCents: Self.cents(reading.paid)
        )
    }

    /// The model's context window is small. Keep the header and the payment block, where the answers are.
    static func condensed(_ text: String, limit: Int = 3000) -> String {
        guard text.count > limit else { return text }
        let rows = text.components(separatedBy: .newlines)
        let head = rows.prefix(12)
        let tail = rows.suffix(60)
        var result = (Array(head) + ["..."] + Array(tail)).joined(separator: "\n")
        if result.count > limit { result = String(result.suffix(limit)) }
        return result
    }

    static func cents(_ printed: String?) -> Int64? {
        guard let printed else { return nil }
        let cleaned = printed.filter { $0.isNumber || $0 == "." }
        return try? Money.parseNonnegative(cleaned)
    }
}
#endif
