import AppKit
import Foundation

enum ClipboardInsertMode: String, CaseIterable, Identifiable {
    case svgContents
    case svgAsLayer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .svgContents:
            return "Insert SVG contents"
        case .svgAsLayer:
            return "Insert SVG as layer"
        }
    }
}

enum ClipboardError: Error, LocalizedError {
    case emptyClipboard
    case invalidContent

    var errorDescription: String? {
        switch self {
        case .emptyClipboard:
            return "Clipboard is empty."
        case .invalidContent:
            return "Clipboard does not contain valid SVG content."
        }
    }
}

final class ClipboardService {
    func readNodes(mode: ClipboardInsertMode) throws -> [LayerNode] {
        guard let content = NSPasteboard.general.string(forType: .string), !content.isEmpty else {
            throw ClipboardError.emptyClipboard
        }

        if content.lowercased().contains("<svg") {
            switch mode {
            case .svgContents:
                let document = try SVGParser.parseDocument(from: content)
                return document.root.children
            case .svgAsLayer:
                let document = try SVGParser.parseDocument(from: content)
                return [document.root]
            }
        }

        let nodes = try SVGParser.parseFragment(from: content)
        if nodes.isEmpty {
            throw ClipboardError.invalidContent
        }
        return nodes
    }
}
