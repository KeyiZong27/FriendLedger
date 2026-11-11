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
        "CORNER MARKET", "MILK 4.00", "BREAD 3.00",
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
let draft = try await LocalReceiptRecognizer.recognize(imageData: imageData)
guard draft.suggestedTotalCents == 756, draft.suggestedTaxCents == 56,
      draft.suggestedMerchantName == "CORNER MARKET",
      draft.suggestedItems.count == 2, draft.imageFingerprint?.count == 64 else {
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
