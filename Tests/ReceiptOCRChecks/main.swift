import CoreGraphics
import CoreText
import Foundation
import FriendLedgerCore
import ImageIO
import UniformTypeIdentifiers

enum OCRCheckError: Error {
    case imageCreation
    case recognition(String)
}

func receiptImage(orientation: CGImagePropertyOrientation = .up) throws -> Data {
    guard let context = CGContext(
        data: nil, width: 1000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw OCRCheckError.imageCreation }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
    if orientation == .down {
        context.translateBy(x: 1000, y: 1000)
        context.rotate(by: .pi)
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
    for (index, line) in [
        "CORNER MARKET", "11/10/2026", "MILK 4.00", "BREAD 3.00",
        "SUBTOTAL 7.00", "TAX 0.56", "TOTAL 7.56"
    ].enumerated() {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        let attributed = NSAttributedString(string: line, attributes: attributes)
        context.textPosition = CGPoint(x: 70, y: 880 - index * 120)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    guard let image = context.makeImage() else { throw OCRCheckError.imageCreation }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw OCRCheckError.imageCreation }
    CGImageDestinationAddImage(
        destination, image, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { throw OCRCheckError.imageCreation }
    return data as Data
}

let imageData = try receiptImage()

/// A receipt photographed on a table: paper tilted and smaller than the frame, on a dark background.
func tabletopPhoto(lines: [String], degrees: Double) throws -> Data {
    guard let context = CGContext(
        data: nil, width: 1600, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw OCRCheckError.imageCreation }
    context.setFillColor(CGColor(gray: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1600))
    context.translateBy(x: 800, y: 800)
    context.rotate(by: degrees * .pi / 180)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: -400, y: -700, width: 800, height: 1400))
    let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
    for (index, line) in lines.enumerated() {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        context.textPosition = CGPoint(x: -340, y: 620 - index * 100)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
    }
    guard let image = context.makeImage() else { throw OCRCheckError.imageCreation }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw OCRCheckError.imageCreation }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw OCRCheckError.imageCreation }
    return data as Data
}

let tilted = try await LocalReceiptRecognizer.recognize(imageData: tabletopPhoto(
    lines: ["TRADER JOES", "11/10/2026", "MILK 4.00", "BREAD 3.00", "SUBTOTAL 7.00", "TAX 0.56", "TOTAL 7.56", "VISA TEND 7.56"],
    degrees: 12
))
guard tilted.suggestedTotalCents == 756, tilted.checks.total == .high,
      tilted.suggestedDay == ReceiptDay(year: 2026, month: 11, day: 10) else {
    throw OCRCheckError.recognition("A tilted photo on a table must still verify: \(tilted.rawText) \(tilted.checks)")
}
// A long receipt scanned in two pages: the total and the card amount are on the second page.
let firstPage = try tabletopPhoto(lines: ["CORNER MARKET", "11/10/2026", "MILK 4.00", "BREAD 3.00"], degrees: 0)
let secondPage = try tabletopPhoto(lines: ["SUBTOTAL 7.00", "TAX 0.56", "TOTAL 7.56", "VISA TEND 7.56"], degrees: 0)
let paged = try await LocalReceiptRecognizer.recognize(pages: [firstPage, secondPage])
guard paged.suggestedTotalCents == 756, paged.suggestedItems.count == 2, paged.checks.total == .high,
      paged.suggestedMerchantName == "CORNER MARKET" else {
    throw OCRCheckError.recognition("Pages must be read as one receipt: \(paged.rawText)")
}
let pagedAgain = try await LocalReceiptRecognizer.recognize(pages: [firstPage, secondPage])
let reversedPages = try await LocalReceiptRecognizer.recognize(pages: [secondPage, firstPage])
guard pagedAgain.imageFingerprint == paged.imageFingerprint, reversedPages.imageFingerprint != paged.imageFingerprint,
      paged.imageFingerprint?.count == 64 else {
    throw OCRCheckError.recognition("Multi-page fingerprints must be stable and order-sensitive")
}
do {
    _ = try await LocalReceiptRecognizer.recognize(pages: [])
    throw OCRCheckError.recognition("Empty page list was accepted")
} catch FinanceError.invalidField(_) {}

let draft = try await LocalReceiptRecognizer.recognize(imageData: imageData)
guard draft.suggestedTotalCents == 756, draft.suggestedTaxCents == 56,
      draft.suggestedMerchantName == "CORNER MARKET",
      draft.suggestedItems.count == 2, draft.imageFingerprint?.count == 64,
      draft.suggestedDay == ReceiptDay(year: 2026, month: 11, day: 10) else {
    throw OCRCheckError.recognition("Synthetic receipt did not produce the expected structured draft: \(draft.rawText)")
}
let repeated = try await LocalReceiptRecognizer.recognize(imageData: imageData)
guard repeated.imageFingerprint == draft.imageFingerprint else {
    throw OCRCheckError.recognition("The same image must retain its fingerprint")
}
let rotated = try await LocalReceiptRecognizer.recognize(imageData: receiptImage(orientation: .down))
guard rotated.suggestedTotalCents == 756, rotated.suggestedItems.count == 2 else {
    throw OCRCheckError.recognition("EXIF orientation must be applied before recognition")
}
let cancelled = Task { try await LocalReceiptRecognizer.recognize(imageData: imageData) }
cancelled.cancel()
do {
    _ = try await cancelled.value
    throw OCRCheckError.recognition("Cancelled recognition returned a draft")
} catch is CancellationError {}
do {
    _ = try await LocalReceiptRecognizer.recognize(imageData: Data("not an image".utf8))
    throw OCRCheckError.recognition("Invalid image was accepted")
} catch FinanceError.invalidField(_) {
    print("PASS: on-device Vision OCR, items, tax, total, fingerprint, EXIF rotation, cancellation, and invalid image")
}
