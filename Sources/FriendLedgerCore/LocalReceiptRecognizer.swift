import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import ImageIO
import Vision

public enum LocalReceiptRecognizer {
    private struct Pass {
        let text: String
        let confidence: Double
    }

    public static func recognize(imageData: Data) async throws -> ReceiptDraft {
        try await recognize(pages: [imageData])
    }

    /// Long receipts can be scanned in several pages, in reading order, without overlap.
    public static func recognize(pages: [Data]) async throws -> ReceiptDraft {
        guard !pages.isEmpty, pages.count <= 6 else {
            throw FinanceError.invalidField("收据照片数量，一次最多 6 页")
        }
        let worker = Task.detached(priority: .userInitiated) { try recognizeBlocking(pages) }
        return try await withTaskCancellationHandler {
            let draft = try await worker.value
            try Task.checkCancellation()
            return draft
        } onCancel: {
            worker.cancel()
        }
    }

    private static func recognizeBlocking(_ pages: [Data]) throws -> ReceiptDraft {
        var texts: [String] = []
        var weighted = 0.0
        var weight = 0.0
        for data in pages {
            try Task.checkCancellation()
            let (image, orientation) = try decode(data)
            let pass = try bestPass(image, orientation)
            texts.append(pass.text)
            weighted += pass.confidence * Double(pass.text.count)
            weight += Double(pass.text.count)
        }
        let fingerprint = pages.count == 1 ? sha(pages[0])
            : sha(Data(pages.map(sha).joined().utf8))
        return try ReceiptTextParser.parse(
            texts.joined(separator: "\n"), imageFingerprint: fingerprint,
            textConfidence: weight > 0 ? weighted / weight : nil
        )
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decode(_ data: Data) throws -> (CGImage, CGImagePropertyOrientation) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw FinanceError.invalidField("收据照片，无法读取图片")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else {
            throw FinanceError.invalidField("收据照片，无法解码有效图片")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let value = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        guard let orientation = CGImagePropertyOrientation(rawValue: value) else {
            throw FinanceError.invalidField("照片方向")
        }
        return (image, orientation)
    }

    /// Reads the photo as taken, and, unless that already verifies cleanly, a flattened and cropped copy.
    /// The reading whose own cross-checks look best wins; a tie keeps the untouched photo.
    private static func bestPass(_ image: CGImage, _ orientation: CGImagePropertyOrientation) throws -> Pass {
        var candidates: [(pass: Pass, score: Int)] = []
        if let original = try? read(image, orientation) {
            let draft = try? ReceiptTextParser.parse(original.text, textConfidence: original.confidence)
            if let draft, draft.checks.total == .high, draft.checks.date == .high { return original }
            candidates.append((original, draft?.checks.score ?? -1000))
        }
        for corrected in flattened(image, orientation) {
            try Task.checkCancellation()
            guard let pass = try? read(corrected, .up) else { continue }
            let draft = try? ReceiptTextParser.parse(pass.text, textConfidence: pass.confidence)
            candidates.append((pass, draft?.checks.score ?? -1000))
        }
        try Task.checkCancellation()
        var best: (pass: Pass, score: Int)?
        for candidate in candidates where candidate.score > (best?.score ?? Int.min) { best = candidate }
        guard let best else { throw FinanceError.invalidField("收据照片，未识别到文字") }
        return best.pass
    }

    private static func read(_ image: CGImage, _ orientation: CGImagePropertyOrientation) throws -> Pass {
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
        var pieces: [ReceiptTextPiece] = []
        var confidenceSum = 0.0
        var characters = 0.0
        for observation in results {
            guard let candidate = observation.topCandidates(1).first else { continue }
            pieces.append(ReceiptTextPiece(
                text: candidate.string, topLeft: observation.topLeft,
                topRight: observation.topRight, bottomLeft: observation.bottomLeft
            ))
            confidenceSum += Double(candidate.confidence) * Double(candidate.string.count)
            characters += Double(candidate.string.count)
        }
        let swapped = orientation.rawValue >= 5
        let aspect = swapped ? CGFloat(image.height) / CGFloat(image.width)
            : CGFloat(image.width) / CGFloat(image.height)
        let text = ReceiptLayout.rows(pieces, aspectRatio: aspect).joined(separator: "\n")
        guard !text.isEmpty else { throw FinanceError.invalidField("收据照片，未识别到文字") }
        return Pass(text: text, confidence: characters > 0 ? confidenceSum / characters : 0)
    }

    /// Finds the paper in the photo and flattens its perspective. Receipts are tall, so a wide result
    /// is also offered turned both ways.
    private static func flattened(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> [CGImage] {
        let upright = CIImage(cgImage: image).oriented(orientation)
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: upright, options: [:])
        guard (try? handler.perform([request])) != nil,
              let paper = request.results?.first, paper.confidence >= 0.5 else { return [] }
        let corners = [paper.topLeft, paper.topRight, paper.bottomRight, paper.bottomLeft]
        var area = 0.0
        for index in corners.indices {
            let next = corners[(index + 1) % corners.count]
            area += Double(corners[index].x * next.y - next.x * corners[index].y)
        }
        guard abs(area) / 2 >= 0.15 else { return [] }
        let extent = upright.extent
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + normalized.x * extent.width, y: extent.minY + normalized.y * extent.height)
        }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = upright
        filter.topLeft = point(paper.topLeft)
        filter.topRight = point(paper.topRight)
        filter.bottomLeft = point(paper.bottomLeft)
        filter.bottomRight = point(paper.bottomRight)
        let context = CIContext()
        guard let output = filter.outputImage, output.extent.width.isFinite, output.extent.width >= 200,
              output.extent.height >= 200, let flat = context.createCGImage(output, from: output.extent) else {
            return []
        }
        var results = [flat]
        if CGFloat(flat.width) > CGFloat(flat.height) * 1.1 {
            for turn in [CGImagePropertyOrientation.right, .left] {
                let turned = CIImage(cgImage: flat).oriented(turn)
                if let rotated = context.createCGImage(turned, from: turned.extent) { results.append(rotated) }
            }
        }
        return results
    }
}
