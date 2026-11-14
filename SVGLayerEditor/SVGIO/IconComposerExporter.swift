import CoreGraphics
import Foundation

/// Builds an Icon Composer document (`.icon` bundle) from an SVG document.
///
/// Icon Composer places every layer image at its intrinsic size in points, centered on a
/// 1024 × 1024 pt canvas. Each layer is therefore written as its own SVG with
/// `width="1024" height="1024"` and the document's (squared) viewBox, so every layer keeps
/// its position relative to the others.
///
/// Mapping (front-most first, as in icon.json):
/// - top-level `<g>` with drawable children → group, each child → layer
/// - any other top-level drawable element → group with a single layer
/// - non-rendering top-level elements (`<defs>`, `<style>`, gradients, …) → copied into every layer
struct IconComposerExport {
    struct Layer {
        let name: String
        let fileName: String
        let svg: String
    }

    struct Group {
        let name: String
        let layers: [Layer]
    }

    static let canvasSize: CGFloat = 1024
    /// Icon Composer's layer panel works with up to four groups.
    static let recommendedMaxGroups = 4

    let groups: [Group]

    enum ExportError: LocalizedError {
        case noVisibleLayers

        var errorDescription: String? {
            switch self {
            case .noVisibleLayers:
                return "The document has no visible layers to export."
            }
        }
    }

    init(document: SVGDocument, isHidden: (LayerNode) -> Bool) throws {
        let root = document.root
        let serializer = SVGSerializer()
        let canvas = Self.squareCanvas(for: SVGViewBox.canvas(of: root.attributes)
            ?? CGRect(x: 0, y: 0, width: Self.canvasSize, height: Self.canvasSize))

        let sharedDefinitions = root.children.filter { !SVGShapeGeometry.isRenderable($0) && !$0.elementName.contains(":") }
        let content = root.children.filter { SVGShapeGeometry.isRenderable($0) && !isHidden($0) }

        var usedFileNames = Set<String>()
        func makeLayer(_ node: LayerNode, wrappedIn group: LayerNode?) -> Layer {
            let name = Self.layerName(for: node)
            let fileName = Self.uniqueFileName(for: name, used: &usedFileNames)
            var body = node.deepCopy()
            if let group {
                // Keep inherited paint, opacity and transform of the source group.
                var attributes = group.attributes
                attributes.removeValue(forKey: "id")
                let localDefinitions = group.children.filter { !SVGShapeGeometry.isRenderable($0) }.map { $0.deepCopy() }
                body = LayerNode(elementName: group.elementName, attributes: attributes, children: localDefinitions + [body])
            }
            var rootAttributes = root.attributes
            for key in ["id", "x", "y", "width", "height", "viewBox", "preserveAspectRatio"] {
                rootAttributes.removeValue(forKey: key)
            }
            rootAttributes["xmlns"] = SVGSerializer.svgNamespace
            rootAttributes["width"] = SVGFormat.number(Self.canvasSize)
            rootAttributes["height"] = SVGFormat.number(Self.canvasSize)
            rootAttributes["viewBox"] = SVGViewBox.serialize(canvas)
            let layerRoot = LayerNode(
                elementName: "svg",
                attributes: rootAttributes,
                children: sharedDefinitions.map { $0.deepCopy() } + [body]
            )
            return Layer(name: name, fileName: fileName, svg: serializer.serialize(document: SVGDocument(root: layerRoot)))
        }

        var groups: [Group] = []
        for node in content.reversed() {
            let drawableChildren = node.children.filter { SVGShapeGeometry.isRenderable($0) && !isHidden($0) }
            if node.elementName == "g", !drawableChildren.isEmpty {
                let layers = drawableChildren.reversed().map { makeLayer($0, wrappedIn: node) }
                groups.append(Group(name: Self.layerName(for: node), layers: layers))
            } else {
                let layer = makeLayer(node, wrappedIn: nil)
                groups.append(Group(name: layer.name, layers: [layer]))
            }
        }
        guard !groups.isEmpty else { throw ExportError.noVisibleLayers }
        self.groups = groups
    }

    /// icon.json in the format Icon Composer writes (pretty printed, sorted keys).
    func iconJSON() throws -> Data {
        let groupObjects: [[String: Any]] = groups.map { group in
            [
                "name": group.name,
                "layers": group.layers.map { layer in
                    ["image-name": layer.fileName, "name": layer.name, "glass": false, "hidden": false] as [String: Any]
                },
                "hidden": false,
                "shadow": ["kind": "neutral", "opacity": 0.5] as [String: Any],
                "translucency": ["enabled": true, "value": 0.5] as [String: Any]
            ]
        }
        let object: [String: Any] = [
            "fill": ["solid": "display-p3:1.00000,1.00000,1.00000,1.00000"],
            "groups": groupObjects,
            "supported-platforms": [
                "circles": ["watchOS"],
                "squares": "shared"
            ] as [String: Any]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes `<name>.icon/icon.json` and `<name>.icon/Assets/*.svg`, replacing an existing bundle.
    func write(to url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let assets = url.appendingPathComponent("Assets", isDirectory: true)
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
        for layer in groups.flatMap(\.layers) {
            try Data(layer.svg.utf8).write(to: assets.appendingPathComponent(layer.fileName), options: .atomic)
        }
        try iconJSON().write(to: url.appendingPathComponent("icon.json"), options: .atomic)
    }

    /// Centers the document canvas in a square so non-square artwork is not distorted.
    static func squareCanvas(for rect: CGRect) -> CGRect {
        let side = max(rect.width, rect.height)
        return CGRect(x: rect.minX - (side - rect.width) / 2, y: rect.minY - (side - rect.height) / 2, width: side, height: side)
    }

    private static func layerName(for node: LayerNode) -> String {
        if let name = node.name, !name.isEmpty { return name }
        if let id = node.attributes["id"], !id.isEmpty { return id }
        return node.elementName
    }

    private static func uniqueFileName(for name: String, used: inout Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        var base = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "layer" }
        var candidate = "\(base).svg"
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base) \(counter).svg"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
