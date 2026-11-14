import Foundation

/// Writes SVG in the layout used by Apple's icon templates and Icon Composer assets:
/// XML declaration, `xmlns` first on the root, then identity, geometry and paint
/// attributes in a fixed order, two-space indentation, self-closing empty elements.
final class SVGSerializer {
    static let svgNamespace = "http://www.w3.org/2000/svg"

    func serialize(document: SVGDocument) -> String {
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        return header + serialize(node: document.root, indentLevel: 0, isDocumentRoot: true)
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
        let attrs = renderAttributes(attributes)
        let opening = "<\(node.elementName)\(attrs)>"

        if node.children.isEmpty, let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return "\(indent)\(opening)\(escapeText(text))</\(node.elementName)>\n"
        }

        if node.children.isEmpty {
            return "\(indent)<\(node.elementName)\(attrs)/>\n"
        }

        var result = "\(indent)\(opening)\n"
        for child in node.children {
            result += serialize(node: child, indentLevel: indentLevel + 1, isDocumentRoot: false)
        }
        result += "\(indent)</\(node.elementName)>\n"
        return result
    }

    private func renderAttributes(_ attributes: [String: String]) -> String {
        Self.orderedKeys(attributes.keys).map { key in
            " \(key)=\"\(escapeAttribute(attributes[key] ?? ""))\""
        }.joined()
    }

    /// Deterministic, readable attribute order (XMLParser does not report the source order).
    static func orderedKeys<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        keys.sorted { lhs, rhs in
            let l = rank(lhs)
            let r = rank(rhs)
            return l != r ? l < r : lhs < rhs
        }
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
