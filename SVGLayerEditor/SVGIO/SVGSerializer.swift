import Foundation

/// Writes SVG in the layout used by Apple's icon templates and Icon Composer assets:
/// XML declaration, two-space indentation, self-closing empty elements. Attributes keep
/// their source order; attributes without one (new elements, added attributes) follow in
/// a fixed order: `xmlns` first, then identity, geometry and paint. Comments are kept.
final class SVGSerializer {
    static let svgNamespace = "http://www.w3.org/2000/svg"

    func serialize(document: SVGDocument) -> String {
        var result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        result += document.leadingComments.map { comment($0, indent: "") }.joined()
        result += serialize(node: document.root, indentLevel: 0, isDocumentRoot: true)
        result += document.trailingComments.map { comment($0, indent: "") }.joined()
        return result
    }

    func serialize(node: LayerNode) -> String {
        serialize(node: node, indentLevel: 0, isDocumentRoot: false)
    }

    private func serialize(node: LayerNode, indentLevel: Int, isDocumentRoot: Bool) -> String {
        let indent = String(repeating: "  ", count: indentLevel)
        var attributes = node.attributes
        if isDocumentRoot, node.elementName == "svg", attributes["xmlns"] == nil {
            // Without the namespace CoreSVG (Icon Composer, NSImage) and browsers render nothing.
            attributes["xmlns"] = Self.svgNamespace
        }
        let attrs = renderAttributes(attributes, sourceOrder: node.attributeOrder)
        let opening = "<\(node.elementName)\(attrs)>"
        let leading = node.leadingComments.map { comment($0, indent: indent) }.joined()
        let trailing = node.trailingComments.map { "<!--\(sanitizeComment($0))-->" }.joined()
        let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if node.children.isEmpty, !text.isEmpty || !trailing.isEmpty {
            return "\(leading)\(indent)\(opening)\(escapeText(text))\(trailing)</\(node.elementName)>\n"
        }

        if node.children.isEmpty {
            return "\(leading)\(indent)<\(node.elementName)\(attrs)/>\n"
        }

        var result = "\(leading)\(indent)\(opening)\n"
        for child in node.children {
            result += serialize(node: child, indentLevel: indentLevel + 1, isDocumentRoot: false)
        }
        let childIndent = String(repeating: "  ", count: indentLevel + 1)
        result += node.trailingComments.map { comment($0, indent: childIndent) }.joined()
        result += "\(indent)</\(node.elementName)>\n"
        return result
    }

    private func comment(_ text: String, indent: String) -> String {
        "\(indent)<!--\(sanitizeComment(text))-->\n"
    }

    /// "--" is not allowed inside XML comments.
    private func sanitizeComment(_ text: String) -> String {
        var result = text
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "- -")
        }
        if result.hasSuffix("-") { result += " " }
        return result
    }

    private func renderAttributes(_ attributes: [String: String], sourceOrder: [String]) -> String {
        Self.orderedKeys(attributes.keys, sourceOrder: sourceOrder).map { key in
            " \(key)=\"\(escapeAttribute(attributes[key] ?? ""))\""
        }.joined()
    }

    /// Source order first, then the remaining keys in canonical order.
    static func orderedKeys<S: Sequence>(_ keys: S, sourceOrder: [String] = []) -> [String] where S.Element == String {
        let present = Set(keys)
        var seen = Set<String>()
        let preserved = sourceOrder.filter { present.contains($0) && seen.insert($0).inserted }
        let remaining = present.subtracting(preserved).sorted { lhs, rhs in
            let l = rank(lhs)
            let r = rank(rhs)
            return l != r ? l < r : lhs < rhs
        }
        // An added namespace declaration still goes first.
        if remaining.first == "xmlns" {
            return ["xmlns"] + preserved + remaining.dropFirst()
        }
        return preserved + remaining
    }

    private static func rank(_ key: String) -> Int {
        if key == "xmlns" { return 0 }
        if key.hasPrefix("xmlns:") { return 1 }
        if let index = attributeOrder.firstIndex(of: key) { return 10 + index }
        if key == "style" { return 1_000 }
        return 500
    }

    private static let attributeOrder = [
        "version", "id", "class", "data-name",
        "x", "y", "width", "height", "viewBox", "preserveAspectRatio",
        "cx", "cy", "r", "rx", "ry", "fx", "fy",
        "x1", "y1", "x2", "y2", "points", "d",
        "href", "xlink:href", "gradientUnits", "gradientTransform", "offset",
        "transform", "clip-path", "mask", "filter",
        "fill", "fill-opacity", "fill-rule", "clip-rule",
        "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin",
        "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset",
        "stop-color", "stop-opacity", "color", "opacity", "display", "visibility",
        "font-family", "font-size", "font-weight", "font-style", "text-anchor"
    ]

    private func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
