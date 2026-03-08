import Foundation

final class SVGSerializer {
    func serialize(document: SVGDocument) -> String {
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        return header + serialize(node: document.root, indentLevel: 0)
    }

    func serialize(node: LayerNode) -> String {
        serialize(node: node, indentLevel: 0)
    }

    private func serialize(node: LayerNode, indentLevel: Int) -> String {
        let indent = String(repeating: "  ", count: indentLevel)
        let attrs = renderAttributes(node.attributes)
        let opening = "<\(node.elementName)\(attrs)>"

        if node.children.isEmpty, let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let content = escape(text)
            return "\(indent)\(opening)\(content)</\(node.elementName)>\n"
        }

        if node.children.isEmpty {
            return "\(indent)<\(node.elementName)\(attrs)/>\n"
        }

        var result = "\(indent)\(opening)\n"
        for child in node.children {
            result += serialize(node: child, indentLevel: indentLevel + 1)
        }
        result += "\(indent)</\(node.elementName)>\n"
        return result
    }

    private func renderAttributes(_ attributes: [String: String]) -> String {
        if attributes.isEmpty {
            return ""
        }
        let parts = attributes.keys.sorted().compactMap { key -> String? in
            guard let value = attributes[key] else { return nil }
            return " \(key)=\"\(escape(value))\""
        }
        return parts.joined()
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
