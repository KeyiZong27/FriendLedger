import CryptoKit
import Foundation
import ImageIO
import Vision

public enum LocalReceiptRecognizer {
    public static func recognize(imageData: Data) async throws -> ReceiptDraft {
        let worker = Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                throw FinanceError.invalidField("收据照片，无法读取图片")
            }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width > 0, image.height > 0 else {
                throw FinanceError.invalidField("收据照片，无法解码有效图片")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientationValue = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            guard let orientation = CGImagePropertyOrientation(rawValue: orientationValue) else {
                throw FinanceError.invalidField("照片方向")
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
            try Task.checkCancellation()
            try handler.perform([request])
            try Task.checkCancellation()
            guard let results = request.results, !results.isEmpty else {
                throw FinanceError.invalidField("收据照片，未识别到文字")
            }
            let text = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            let fingerprint = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
            return try ReceiptTextParser.parse(text, imageFingerprint: fingerprint)
        }
        return try await withTaskCancellationHandler {
            let draft = try await worker.value
            try Task.checkCancellation()
            return draft
        } onCancel: {
            worker.cancel()
        }
    }
}
