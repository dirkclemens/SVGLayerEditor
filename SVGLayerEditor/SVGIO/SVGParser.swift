import Foundation

enum SVGParseError: Error, LocalizedError {
    case invalidData
    case missingRoot
    case invalidFragment
    case parseFailed(message: String, line: Int, column: Int)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "E_DATA: Could not read SVG data. Hint: Ensure UTF-8 text."
        case .missingRoot:
            return "E_ROOT: No <svg> root element found. Hint: Wrap content in <svg>...</svg>."
        case .invalidFragment:
            return "E_FRAGMENT: Expected a single root element for the selected layer. Hint: Provide exactly one element."
        case .parseFailed(let message, let line, let column):
            let hint = "Hint: Check tag nesting and quote characters."
            if line > 0 && column > 0 {
                return "E_PARSE: Line \(line), Column \(column): \(message). \(hint)"
            }
            return "E_PARSE: \(message). \(hint)"
        }
    }
}

/// Reads SVG into `LayerNode`s.
///
/// `XMLDocument` is used because it keeps the attribute order and comments of the source.
/// `XMLParser` serves as fallback for input libxml2's tree builder rejects (e.g. an undeclared
/// `xlink:` prefix) and provides line/column information for error messages.
final class SVGParser: NSObject, XMLParserDelegate {
    private var nodeStack: [LayerNode] = []
    private var rootNode: LayerNode?
    private var parseError: Error?

    static func parseDocument(from data: Data) throws -> SVGDocument {
        if let document = try? parseWithXMLDocument(data) {
            return document
        }
        let parser = SVGParser()
        try parser.parse(data: data)
        guard let root = parser.rootNode else {
            throw SVGParseError.missingRoot
        }
        return SVGDocument(root: root)
    }

    static func parseDocument(from string: String) throws -> SVGDocument {
        guard let data = string.data(using: .utf8) else {
            throw SVGParseError.invalidData
        }
        return try parseDocument(from: data)
    }

    static func parseFragment(from string: String) throws -> [LayerNode] {
        let wrapped = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">\n\(string)\n</svg>"
        let document = try parseDocument(from: wrapped)
        return document.root.children
    }

    // MARK: XMLDocument

    private static func parseWithXMLDocument(_ data: Data) throws -> SVGDocument {
        // Never resolve external entities (XXE).
        let xml = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let rootElement = xml.rootElement() else { throw SVGParseError.missingRoot }

        var leading: [String] = []
        var trailing: [String] = []
        var seenRoot = false
        for child in xml.children ?? [] {
            if child === rootElement {
                seenRoot = true
            } else if child.kind == .comment {
                if seenRoot { trailing.append(child.stringValue ?? "") } else { leading.append(child.stringValue ?? "") }
            }
        }
        return SVGDocument(root: makeNode(rootElement), leadingComments: leading, trailingComments: trailing)
    }

    private static func makeNode(_ element: XMLElement) -> LayerNode {
        var attributes: [String: String] = [:]
        var order: [String] = []
        // libxml2 reports namespace declarations separately; they are written first, as usual.
        for namespace in element.namespaces ?? [] {
            let prefix = namespace.name ?? ""
            let key = prefix.isEmpty ? "xmlns" : "xmlns:\(prefix)"
            if attributes[key] == nil { order.append(key) }
            attributes[key] = namespace.stringValue ?? ""
        }
        for attribute in element.attributes ?? [] {
            guard let name = attribute.name else { continue }
            if attributes[name] == nil { order.append(name) }
            attributes[name] = attribute.stringValue ?? ""
        }

        let node = LayerNode(elementName: element.name ?? "", attributes: attributes, attributeOrder: order)
        var pendingComments: [String] = []
        var text: String?
        for child in element.children ?? [] {
            switch child.kind {
            case .element:
                guard let childElement = child as? XMLElement else { continue }
                let childNode = makeNode(childElement)
                childNode.leadingComments = pendingComments
                pendingComments = []
                node.children.append(childNode)
            case .comment:
                pendingComments.append(child.stringValue ?? "")
            case .text:
                text = (text ?? "") + (child.stringValue ?? "")
            default:
                break
            }
        }
        node.trailingComments = pendingComments
        node.text = text
        return node
    }

    // MARK: XMLParser fallback

    private func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        if !parser.parse() {
            let line = parser.lineNumber
            let column = parser.columnNumber
            let message = parser.parserError?.localizedDescription ?? "Unknown parse error."
            throw SVGParseError.parseFailed(message: message, line: line, column: column)
        }
        if let error = parseError {
            throw error
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        var attributes = attributeDict
        if elementName == "svg", attributes["xmlns"] == nil, let namespaceURI, !namespaceURI.isEmpty {
            attributes["xmlns"] = namespaceURI
        }
        let node = LayerNode(
            elementName: elementName,
            attributes: attributes
        )
        if rootNode == nil {
            rootNode = node
        } else {
            nodeStack.last?.children.append(node)
        }
        nodeStack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = nodeStack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let current = nodeStack.last else { return }
        let trimmed = string
        if current.text == nil {
            current.text = trimmed
        } else {
            current.text? += trimmed
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let current = nodeStack.last else { return }
        if let text = String(data: CDATABlock, encoding: .utf8) {
            if current.text == nil {
                current.text = text
            } else {
                current.text? += text
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        let line = parser.lineNumber
        let column = parser.columnNumber
        let message = parseError.localizedDescription
        self.parseError = SVGParseError.parseFailed(message: message, line: line, column: column)
    }
}
