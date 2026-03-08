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

final class SVGParser: NSObject, XMLParserDelegate {
    private var nodeStack: [LayerNode] = []
    private var rootNode: LayerNode?
    private var parseError: Error?

    static func parseDocument(from data: Data) throws -> SVGDocument {
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
        let wrapped = "<svg xmlns=\"http://www.w3.org/2000/svg\">\n\(string)\n</svg>"
        let document = try parseDocument(from: wrapped)
        return document.root.children
    }

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
