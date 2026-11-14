import AppKit
import CoreGraphics

/// Approximate text layout for `<text>` elements. SVG positions text by its baseline
/// (`y`) and anchor (`x` + `text-anchor`); renderers without a `font-family` fall back
/// to a serif font (CoreSVG, which Icon Composer uses, renders Times).
enum SVGTextMetrics {
    static let defaultFontSize: CGFloat = 16

    static func font(properties: [String: String]) -> NSFont {
        let size = resolvedFontSize(properties: properties)
        let weight = properties["font-weight"]?.lowercased()
        let isBold = weight == "bold" || weight == "bolder" || (weight.flatMap(Int.init) ?? 400) >= 600
        let isItalic = properties["font-style"]?.lowercased() == "italic"

        var font: NSFont?
        let families = (properties["font-family"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        for family in families where !family.isEmpty {
            switch family.lowercased() {
            case "sans-serif", "system-ui", "-apple-system":
                font = NSFont(name: "Helvetica", size: size)
            case "serif":
                font = NSFont(name: "Times", size: size)
            case "monospace":
                font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            default:
                font = NSFont(name: family, size: size)
                    ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            }
            if font != nil { break }
        }
        var resolved = font ?? NSFont(name: "Times", size: size) ?? NSFont.systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if isBold { traits.insert(.boldFontMask) }
        if isItalic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: traits)
        }
        return resolved
    }

    /// Bounds in the element's user space: from ascender to descender around the baseline.
    static func bounds(attributes: [String: String], text: String?) -> CGRect? {
        bounds(properties: SVGStyle.properties(of: attributes), text: text)
    }

    static func bounds(properties: [String: String], text: String?) -> CGRect? {
        let x = firstCoordinate(properties["x"]) ?? 0
        let y = firstCoordinate(properties["y"]) ?? 0
        let font = font(properties: properties)
        let content = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let width = max((content as NSString).size(withAttributes: [.font: font]).width, 1)
        let ascent = font.ascender
        let height = max(font.ascender - font.descender, 1)

        let originX: CGFloat
        switch properties["text-anchor"]?.lowercased() {
        case "middle": originX = x - width / 2
        case "end": originX = x - width
        default: originX = x
        }
        return CGRect(x: originX, y: y - ascent, width: width, height: height)
    }

    static func resolvedFontSize(attributes: [String: String]) -> CGFloat {
        resolvedFontSize(properties: SVGStyle.properties(of: attributes))
    }

    static func resolvedFontSize(properties: [String: String]) -> CGFloat {
        max(SVGLength.parse(properties["font-size"]) ?? defaultFontSize, 1)
    }

    static func ascent(properties: [String: String]) -> CGFloat {
        font(properties: properties).ascender
    }

    /// `x`/`y` on text may be lists; the first value positions the first glyph.
    static func firstCoordinate(_ value: String?) -> CGFloat? {
        guard let value else { return nil }
        if let length = SVGLength.parse(value) { return length }
        return SVGNumberScanner.numbers(in: value).first
    }
}
