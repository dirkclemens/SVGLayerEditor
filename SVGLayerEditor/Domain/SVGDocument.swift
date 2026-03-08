import Foundation

struct SVGDocument {
    var root: LayerNode
    var sourceURL: URL?
    var isDirty: Bool

    init(root: LayerNode, sourceURL: URL? = nil, isDirty: Bool = false) {
        self.root = root
        self.sourceURL = sourceURL
        self.isDirty = isDirty
    }
}
