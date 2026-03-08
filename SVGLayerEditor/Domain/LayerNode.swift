import Foundation

final class LayerNode: Identifiable {
    let id: UUID
    var name: String?
    var elementName: String
    var attributes: [String: String]
    var children: [LayerNode]
    var text: String?

    init(
        id: UUID = UUID(),
        name: String? = nil,
        elementName: String,
        attributes: [String: String] = [:],
        children: [LayerNode] = [],
        text: String? = nil
    ) {
        self.id = id
        self.name = name
        self.elementName = elementName
        self.attributes = attributes
        self.children = children
        self.text = text
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
        let copiedChildren = children.map { $0.deepCopy() }
        return LayerNode(
            id: id,
            name: name,
            elementName: elementName,
            attributes: attributes,
            children: copiedChildren,
            text: text
        )
    }
}
