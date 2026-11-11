import CoreGraphics
import Foundation

public struct ReceiptTextPiece: Sendable {
    public let text: String
    /// Normalized image points with a bottom-left origin, as returned by Vision.
    public let topLeft: CGPoint
    public let topRight: CGPoint
    public let bottomLeft: CGPoint

    public init(text: String, topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint) {
        self.text = text
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
    }

    public init(text: String, box: CGRect) {
        self.init(
            text: text, topLeft: CGPoint(x: box.minX, y: box.maxY),
            topRight: CGPoint(x: box.maxX, y: box.maxY), bottomLeft: CGPoint(x: box.minX, y: box.minY)
        )
    }
}

/// Vision returns separate text blocks, so a label on the left and its price on the right often arrive
/// far apart, and a tilted photo shifts the right side up or down. Rotating block centers by the
/// receipt's median text angle and joining blocks in one horizontal band restores "TOTAL 29.02" rows.
public enum ReceiptLayout {
    private struct Placed {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
    }

    /// `aspectRatio` is image width divided by height, needed because Vision coordinates are normalized per axis.
    public static func rows(_ pieces: [ReceiptTextPiece], aspectRatio: CGFloat = 1) -> [String] {
        let aspect = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
        let usable = pieces.filter { piece in
            let values = [piece.topLeft.x, piece.topLeft.y, piece.topRight.x, piece.topRight.y,
                          piece.bottomLeft.x, piece.bottomLeft.y]
            return values.allSatisfy(\.isFinite) && !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return [] }

        let angles = usable.filter { $0.text.count >= 4 }.map {
            atan2($0.topRight.y - $0.topLeft.y, ($0.topRight.x - $0.topLeft.x) * aspect)
        }.sorted()
        // Ignore implausible angles: a short block can look steep without the page being tilted.
        let skew = angles.isEmpty ? 0 : max(-0.5, min(0.5, angles[angles.count / 2]))
        let cosine = cos(skew)
        let sine = sin(skew)

        let placed = usable.compactMap { piece -> Placed? in
            let centerX = (piece.topLeft.x + piece.topRight.x) / 2 * aspect
            let centerY = (piece.topLeft.y + piece.bottomLeft.y) / 2
            let height = hypot((piece.topLeft.x - piece.bottomLeft.x) * aspect, piece.topLeft.y - piece.bottomLeft.y)
            guard height > 0 else { return nil }
            return Placed(
                text: piece.text.trimmingCharacters(in: .whitespacesAndNewlines),
                x: centerX * cosine + centerY * sine, y: -centerX * sine + centerY * cosine, height: height
            )
        }
        guard !placed.isEmpty else { return [] }
        let heights = placed.map(\.height).sorted()
        let tolerance = heights[heights.count / 2] * 0.5

        var rows: [(center: CGFloat, items: [Placed])] = []
        for item in placed.sorted(by: { $0.y > $1.y }) {
            if let index = rows.indices.min(by: { abs(rows[$0].center - item.y) < abs(rows[$1].center - item.y) }),
               abs(rows[index].center - item.y) <= tolerance {
                rows[index].items.append(item)
                rows[index].center = rows[index].items.map(\.y).reduce(0, +) / CGFloat(rows[index].items.count)
            } else {
                rows.append((item.y, [item]))
            }
        }
        return rows.sorted { $0.center > $1.center }.map { row in
            row.items.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
        }
    }
}
