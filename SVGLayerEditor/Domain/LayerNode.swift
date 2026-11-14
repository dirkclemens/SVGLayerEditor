import Foundation

final class LayerNode: Identifiable {
    let id: UUID
    var name: String?
    var elementName: String
    var attributes: [String: String]
    /// Attribute names in source order; attributes added later are written after them.
    var attributeOrder: [String]
    var children: [LayerNode]
    var text: String?
    /// XML comments directly before this element. They travel with the element when it is moved.
    var leadingComments: [String]
    /// XML comments after the last child, before the closing tag.
    var trailingComments: [String]

    init(
        id: UUID = UUID(),
        name: String? = nil,
        elementName: String,
        attributes: [String: String] = [:],
        attributeOrder: [String] = [],
        children: [LayerNode] = [],
        text: String? = nil,
        leadingComments: [String] = [],
        trailingComments: [String] = []
    ) {
        self.id = id
        self.name = name
        self.elementName = elementName
        self.attributes = attributes
        self.attributeOrder = attributeOrder
        self.children = children
        self.text = text
        self.leadingComments = leadingComments
        self.trailingComments = trailingComments
    }

    /// The same content under another identity (used when replacing a node with edited XML).
    func withID(_ newID: UUID) -> LayerNode {
        LayerNode(
            id: newID,
            name: name,
            elementName: elementName,
            attributes: attributes,
            attributeOrder: attributeOrder,
            children: children,
            text: text,
            leadingComments: leadingComments,
            trailingComments: trailingComments
        )
    }

    /// A shallow copy with other children (same identity).
    func withChildren(_ newChildren: [LayerNode]) -> LayerNode {
        LayerNode(
            id: id,
            name: name,
            elementName: elementName,
            attributes: attributes,
            attributeOrder: attributeOrder,
            children: newChildren,
            text: text,
            leadingComments: leadingComments,
            trailingComments: trailingComments
        )
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        if let idValue = attributes["id"], !idValue.isEmpty {
            return "#\(idValue)"
        }
        return elementName
    }

    var childNodes: [LayerNode]? {
        children
    }

    func findNode(by nodeID: UUID) -> LayerNode? {
        if id == nodeID {
            return self
        }
        for child in children {
            if let found = child.findNode(by: nodeID) {
                return found
            }
        }
        return nil
    }

    func findParent(of nodeID: UUID) -> LayerNode? {
        for child in children {
            if child.id == nodeID {
                return self
            }
            if let found = child.findParent(of: nodeID) {
                return found
            }
        }
        return nil
    }

    func contains(nodeID: UUID) -> Bool {
        if id == nodeID {
            return true
        }
        return children.contains { $0.contains(nodeID: nodeID) }
    }

    func deepCopy() -> LayerNode {
        withChildren(children.map { $0.deepCopy() })
    }
}
