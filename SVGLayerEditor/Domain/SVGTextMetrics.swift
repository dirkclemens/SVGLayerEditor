import AppKit
import CoreGraphics

enum SVGTextMetrics {
    static func bounds(attributes: [String: String], text: String?) -> CGRect? {
        guard let x = number(attributes["x"]),
              let y = number(attributes["y"]) else { return nil }

        let fontSize = resolvedFontSize(attributes: attributes)
        let font = NSFont.systemFont(ofSize: fontSize)
        let measured = ((text ?? "") as NSString).size(withAttributes: [.font: font])
        let width = max(measured.width, 1)
        let height = max(measured.height, font.ascender - font.descender)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func resolvedFontSize(attributes: [String: String]) -> CGFloat {
        max(number(attributes["font-size"]) ?? 16, 1)
    }

    static func scaleFactor(from transform: CGAffineTransform) -> CGFloat {
        let sx = max(abs(transform.a), 0.01)
        let sy = max(abs(transform.d), 0.01)
        return max(sx, sy)
    }

    private static func number(_ value: String?) -> CGFloat? {
        guard let value, let number = Double(value) else { return nil }
        return CGFloat(number)
    }
}
