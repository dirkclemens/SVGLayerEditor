import Foundation

struct SVGDocument {
    var root: LayerNode
    var sourceURL: URL?
    var isDirty: Bool
    /// Comments before the root element (after the XML declaration).
    var leadingComments: [String]
    /// Comments after the root element.
    var trailingComments: [String]

    init(
        root: LayerNode,
        sourceURL: URL? = nil,
        isDirty: Bool = false,
        leadingComments: [String] = [],
        trailingComments: [String] = []
    ) {
        self.root = root
        self.sourceURL = sourceURL
        self.isDirty = isDirty
        self.leadingComments = leadingComments
        self.trailingComments = trailingComments
    }

    /// Independent copy of the tree (LayerNode is a reference type).
    func deepCopy() -> SVGDocument {
        var copy = self
        copy.root = root.deepCopy()
        return copy
    }
}
