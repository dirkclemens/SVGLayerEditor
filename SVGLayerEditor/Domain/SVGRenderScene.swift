import CoreGraphics
import Foundation

// MARK: - Geometry

enum SVGShapeGeometry {
    static let shapeElements: Set<String> = ["path", "rect", "circle", "ellipse", "line", "polygon", "polyline", "text"]

    /// Elements whose content is never painted directly.
    static let nonRenderingElements: Set<String> = [
        "defs", "clipPath", "mask", "symbol", "pattern", "marker", "linearGradient", "radialGradient",
        "filter", "style", "title", "desc", "metadata", "script", "font", "font-face"
    ]

    /// Elements that may contain graphics (targets for new shapes, indent and drop).
    static let containerElements: Set<String> = ["svg", "g", "a", "switch"]

    static func isRenderable(_ node: LayerNode) -> Bool {
        !nonRenderingElements.contains(node.elementName) && !node.elementName.contains(":")
    }

    static func path(for node: LayerNode, strict: Bool = false) -> CGPath? {
        path(elementName: node.elementName, attributes: node.attributes, text: node.text, strict: strict)
    }

    /// Geometry of a basic shape in its own user space (before its `transform`).
    static func path(elementName: String, attributes: [String: String], text: String?, strict: Bool = false) -> CGPath? {
        func n(_ key: String) -> CGFloat? { SVGLength.number(attributes, key) }
        switch elementName {
        case "path":
            guard let d = attributes["d"] else { return nil }
            return SVGPathParser.toPath(d, strict: strict)
        case "rect":
            guard let w = n("width"), let h = n("height"), w > 0, h > 0 else { return nil }
            let rect = CGRect(x: n("x") ?? 0, y: n("y") ?? 0, width: w, height: h)
            var rx = n("rx")
            var ry = n("ry")
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cornerWidth = min(max(rx ?? 0, 0), w / 2)
            let cornerHeight = min(max(ry ?? 0, 0), h / 2)
            if cornerWidth > 0 && cornerHeight > 0 {
                return CGPath(roundedRect: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: nil)
            }
            return CGPath(rect: rect, transform: nil)
        case "circle":
            guard let r = n("r"), r > 0 else { return nil }
            let cx = n("cx") ?? 0
            let cy = n("cy") ?? 0
            return CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
        case "ellipse":
            guard let rx = n("rx"), let ry = n("ry"), rx > 0, ry > 0 else { return nil }
            let cx = n("cx") ?? 0
            let cy = n("cy") ?? 0
            return CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
        case "line":
            let path = CGMutablePath()
            path.move(to: CGPoint(x: n("x1") ?? 0, y: n("y1") ?? 0))
            path.addLine(to: CGPoint(x: n("x2") ?? 0, y: n("y2") ?? 0))
            return path
        case "polygon", "polyline":
            guard let points = SVGPoints.parse(attributes["points"]), let first = points.first else { return nil }
            let path = CGMutablePath()
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            if elementName == "polygon" { path.closeSubpath() }
            return path
        case "text":
            guard let bounds = SVGTextMetrics.bounds(attributes: attributes, text: text) else { return nil }
            return CGPath(rect: bounds, transform: nil)
        default:
            return nil
        }
    }

    /// The transform an element applies to its content (its `transform`, or the viewport of a nested `<svg>`).
    static func localTransform(of node: LayerNode, isDocumentRoot: Bool) -> CGAffineTransform {
        if node.elementName == "svg" {
            return isDocumentRoot ? .identity : SVGViewBox.viewportTransform(of: node.attributes)
        }
        return SVGTransform.parse(node.attributes["transform"]) ?? .identity
    }

    /// Transform from a node's parent user space to the document canvas (viewBox) space.
    static func parentTransform(of nodeID: UUID, in root: LayerNode) -> CGAffineTransform? {
        guard let chain = ancestorChain(of: nodeID, in: root) else { return nil }
        var ctm = CGAffineTransform.identity
        for (index, ancestor) in chain.enumerated() {
            ctm = localTransform(of: ancestor, isDocumentRoot: index == 0).concatenating(ctm)
        }
        return ctm
    }

    /// Ancestors from the root down to (excluding) the node; nil if the node is not in the tree.
    static func ancestorChain(of nodeID: UUID, in root: LayerNode) -> [LayerNode]? {
        if root.id == nodeID { return [] }
        for child in root.children {
            if let chain = ancestorChain(of: nodeID, in: child) {
                return [root] + chain
            }
        }
        return nil
    }
}

// MARK: - Paint

struct SVGGradient: Equatable {
    enum Kind: Equatable {
        case linear(start: CGPoint, end: CGPoint)
        case radial(center: CGPoint, radius: CGFloat)
    }

    struct Stop: Equatable {
        var offset: CGFloat
        var color: SVGColor
    }

    var kind: Kind
    var stops: [Stop]
    var usesObjectBoundingBox: Bool
    var transform: CGAffineTransform
}

enum SVGPaint: Equatable {
    case none
    case color(SVGColor)
    case gradient(SVGGradient)

    var isNone: Bool { self == .none }
}

struct SVGTextRun {
    let string: String
    let properties: [String: String]
    /// Top-left of the text box in the element's user space.
    let origin: CGPoint
}

struct SVGRenderItem: Identifiable {
    let id: UUID
    let elementName: String
    /// Ancestors from the document root down to the parent.
    let ancestorIDs: [UUID]
    /// Geometry in the element's user space.
    let path: CGPath
    /// Element user space → canvas (viewBox) space.
    let transform: CGAffineTransform
    let fill: SVGPaint
    let fillOpacity: Double
    let evenOdd: Bool
    let stroke: SVGPaint
    let strokeOpacity: Double
    let strokeWidth: CGFloat
    let lineCap: CGLineCap
    let lineJoin: CGLineJoin
    let miterLimit: CGFloat
    let dashes: [CGFloat]
    let dashOffset: CGFloat
    let opacity: Double
    let text: SVGTextRun?
    /// Clip paths (`clip-path` on the element or its ancestors) in canvas space.
    let clipPaths: [CGPath]

    var canvasBounds: CGRect {
        clipPaths.reduce(path.boundingBoxOfPath.applying(transform)) { $0.intersection($1.boundingBoxOfPath) }
    }

    func isClipped(canvasPoint: CGPoint) -> Bool {
        clipPaths.contains { !$0.contains(canvasPoint) }
    }

    /// Outline of the stroke in user space (dashes applied), or nil without stroke.
    func strokeOutline(minimumWidth: CGFloat = 0) -> CGPath? {
        let width = max(strokeWidth, minimumWidth)
        guard width > 0 else { return nil }
        var source = path
        if !dashes.isEmpty, dashes.contains(where: { $0 > 0 }) {
            source = path.copy(dashingWithPhase: dashOffset, lengths: dashes)
        }
        return source.copy(strokingWithWidth: width, lineCap: lineCap, lineJoin: lineJoin, miterLimit: miterLimit)
    }
}

// MARK: - Scene

/// Flattens a document into paint-ready items, resolving inherited presentation
/// properties, `style` attributes, transforms and gradient references.
struct SVGRenderScene {
    private(set) var items: [SVGRenderItem] = []
    /// Canvas-space bounds of every painted node, including groups (union of their content).
    private(set) var boundsByID: [UUID: CGRect] = [:]
    let canvas: CGRect

    private var elementsByID: [String: LayerNode] = [:]
    private var styleRules: [SVGStyleSheet.Rule] = []
    private let isHidden: (LayerNode) -> Bool

    init(root: LayerNode, canvas: CGRect, isHidden: @escaping (LayerNode) -> Bool) {
        self.canvas = canvas
        self.isHidden = isHidden
        var styleText = ""
        indexElements(root, styleText: &styleText)
        styleRules = SVGStyleSheet.parse(styleText)
        visit(root, style: InheritedStyle(), parentTransform: .identity, ancestors: [], clips: [], isDocumentRoot: true)
    }

    private mutating func indexElements(_ node: LayerNode, styleText: inout String) {
        if let id = node.attributes["id"], elementsByID[id] == nil {
            elementsByID[id] = node
        }
        if node.elementName == "style", let text = node.text {
            styleText += text + "\n"
        }
        for child in node.children { indexElements(child, styleText: &styleText) }
    }

    /// Cascade: presentation attributes < `<style>` rules (by specificity) < `style` attribute.
    private func properties(of node: LayerNode) -> [String: String] {
        guard !styleRules.isEmpty else { return SVGStyle.properties(of: node.attributes) }
        var result = node.attributes
        result.removeValue(forKey: "style")
        for rule in styleRules where rule.selector.matches(node) {
            result.merge(rule.declarations) { _, new in new }
        }
        result.merge(SVGStyle.declarations(node.attributes["style"])) { _, new in new }
        return result
    }

    private mutating func visit(_ node: LayerNode, style inherited: InheritedStyle,
                                parentTransform: CGAffineTransform, ancestors: [UUID], clips inheritedClips: [CGPath],
                                isDocumentRoot: Bool) {
        if isHidden(node) || !SVGShapeGeometry.isRenderable(node) { return }

        let properties = properties(of: node)
        if properties["display"]?.trimmingCharacters(in: .whitespaces) == "none" { return }
        var style = inherited
        style.apply(properties)
        let transform = SVGShapeGeometry.localTransform(of: node, isDocumentRoot: isDocumentRoot).concatenating(parentTransform)
        var clips = inheritedClips
        if let clip = clipPath(properties["clip-path"], userSpace: transform) {
            clips.append(clip)
        }

        if SVGShapeGeometry.shapeElements.contains(node.elementName),
           style.visibility != "hidden" && style.visibility != "collapse",
           let path = geometry(of: node, style: style, properties: properties) {
            let item = makeItem(node: node, path: path, style: style, properties: properties,
                                transform: transform, ancestors: ancestors, clips: clips)
            items.append(item)
            let bounds = item.canvasBounds
            for id in ancestors + [node.id] where !bounds.isNull {
                boundsByID[id] = boundsByID[id].map { $0.union(bounds) } ?? bounds
            }
        }

        for child in node.children {
            visit(child, style: style, parentTransform: transform, ancestors: ancestors + [node.id],
                  clips: clips, isDocumentRoot: false)
        }
    }

    /// Resolves `clip-path="url(#id)"` (userSpaceOnUse) to a canvas-space path.
    private func clipPath(_ value: String?, userSpace: CGAffineTransform) -> CGPath? {
        guard let id = Self.urlReference(value),
              let clipNode = elementsByID[id], clipNode.elementName == "clipPath",
              clipNode.attributes["clipPathUnits"] != "objectBoundingBox" else { return nil }
        let clipTransform = (SVGTransform.parse(clipNode.attributes["transform"]) ?? .identity).concatenating(userSpace)
        let result = CGMutablePath()
        for child in clipNode.children where SVGShapeGeometry.shapeElements.contains(child.elementName) {
            guard let path = SVGShapeGeometry.path(for: child) else { continue }
            let childTransform = (SVGTransform.parse(child.attributes["transform"]) ?? .identity).concatenating(clipTransform)
            result.addPath(path, transform: childTransform)
        }
        // An empty clip path hides the element, as in browsers.
        return result
    }

    static func urlReference(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), value.hasPrefix("url("),
              let close = value.firstIndex(of: ")") else { return nil }
        var reference = value[value.index(value.startIndex, offsetBy: 4)..<close]
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        if reference.hasPrefix("#") { reference.removeFirst() }
        return reference.isEmpty ? nil : reference
    }

    private func geometry(of node: LayerNode, style: InheritedStyle, properties: [String: String]) -> CGPath? {
        guard node.elementName == "text" else { return SVGShapeGeometry.path(for: node) }
        // Font properties may be inherited from groups.
        let textProperties = style.textProperties(merging: properties)
        return SVGTextMetrics.bounds(properties: textProperties, text: node.text).map { CGPath(rect: $0, transform: nil) }
    }

    private func makeItem(node: LayerNode, path: CGPath, style: InheritedStyle, properties: [String: String],
                          transform: CGAffineTransform, ancestors: [UUID], clips: [CGPath]) -> SVGRenderItem {
        let currentColor = SVGColor.parse(style.color)
        var text: SVGTextRun?
        var fill = paint(style.fill, currentColor: currentColor)
        if node.elementName == "text" {
            let box = path.boundingBoxOfPath
            text = SVGTextRun(
                string: (node.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                properties: style.textProperties(merging: properties),
                origin: box.origin
            )
        } else if node.elementName == "line" {
            fill = .none // a line has no interior
        }
        let strokeWidth = SVGLength.parse(style.strokeWidth) ?? 1
        let dashes = style.dashArray.flatMap { $0 == "none" ? nil : SVGNumberScanner.numbers(in: $0) } ?? []

        return SVGRenderItem(
            id: node.id,
            elementName: node.elementName,
            ancestorIDs: ancestors,
            path: path,
            transform: transform,
            fill: fill,
            fillOpacity: style.fillOpacity,
            evenOdd: style.fillRule == "evenodd",
            stroke: paint(style.stroke, currentColor: currentColor),
            strokeOpacity: style.strokeOpacity,
            strokeWidth: max(strokeWidth, 0),
            lineCap: style.lineCap,
            lineJoin: style.lineJoin,
            miterLimit: style.miterLimit,
            dashes: dashes.count % 2 == 1 ? dashes + dashes : dashes,
            dashOffset: SVGLength.parse(style.dashOffset) ?? 0,
            opacity: style.opacity,
            text: text,
            clipPaths: clips
        )
    }

    private func paint(_ value: String?, currentColor: SVGColor?) -> SVGPaint {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return .none }
        if value.lowercased() == "none" { return .none }
        if value.hasPrefix("url(") {
            guard let close = value.firstIndex(of: ")") else { return .none }
            if let reference = Self.urlReference(value), let gradient = gradient(id: reference) {
                return .gradient(gradient)
            }
            let fallback = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return fallback.isEmpty ? .none : paint(fallback, currentColor: currentColor)
        }
        return SVGColor.parse(value, currentColor: currentColor).map(SVGPaint.color) ?? .none
    }

    private func gradient(id: String) -> SVGGradient? {
        guard let node = elementsByID[id],
              node.elementName == "linearGradient" || node.elementName == "radialGradient" else { return nil }

        // Attributes and stops may be inherited through href.
        var chain = [node]
        while chain.count < 10,
              let href = chain.last?.attributes["href"] ?? chain.last?.attributes["xlink:href"],
              href.hasPrefix("#"),
              let next = elementsByID[String(href.dropFirst())],
              !chain.contains(where: { $0 === next }) {
            chain.append(next)
        }
        func attribute(_ key: String) -> String? {
            chain.lazy.compactMap { $0.attributes[key] }.first
        }

        let stopNodes = chain.lazy.map { $0.children.filter { $0.elementName == "stop" } }.first { !$0.isEmpty } ?? []
        var stops: [SVGGradient.Stop] = []
        for stopNode in stopNodes {
            let properties = SVGStyle.properties(of: stopNode.attributes)
            var offset = Self.fraction(properties["offset"]) ?? 0
            offset = min(max(offset, stops.last?.offset ?? 0), 1)
            var color = SVGColor.parse(properties["stop-color"] ?? "black") ?? .black
            color.alpha *= Self.fraction(properties["stop-opacity"]) ?? 1
            stops.append(SVGGradient.Stop(offset: offset, color: color))
        }
        guard !stops.isEmpty else { return nil }

        let objectBoundingBox = attribute("gradientUnits") != "userSpaceOnUse"
        func coordinate(_ key: String, _ defaultValue: CGFloat, horizontal: Bool) -> CGFloat {
            guard let raw = attribute(key)?.trimmingCharacters(in: .whitespaces) else { return defaultValue }
            if raw.hasSuffix("%"), let percent = Double(raw.dropLast()) {
                let fraction = CGFloat(percent) / 100
                if objectBoundingBox { return fraction }
                return horizontal ? canvas.minX + fraction * canvas.width : canvas.minY + fraction * canvas.height
            }
            return SVGLength.parse(raw) ?? defaultValue
        }

        let kind: SVGGradient.Kind
        if node.elementName == "linearGradient" {
            let end = objectBoundingBox ? 1 : canvas.maxX
            kind = .linear(
                start: CGPoint(x: coordinate("x1", objectBoundingBox ? 0 : canvas.minX, horizontal: true),
                               y: coordinate("y1", objectBoundingBox ? 0 : canvas.minY, horizontal: false)),
                end: CGPoint(x: coordinate("x2", end, horizontal: true),
                             y: coordinate("y2", objectBoundingBox ? 0 : canvas.minY, horizontal: false))
            )
        } else {
            let half: CGFloat = 0.5
            kind = .radial(
                center: CGPoint(x: coordinate("cx", objectBoundingBox ? half : canvas.midX, horizontal: true),
                                y: coordinate("cy", objectBoundingBox ? half : canvas.midY, horizontal: false)),
                radius: coordinate("r", objectBoundingBox ? half : max(canvas.width, canvas.height) / 2, horizontal: true)
            )
        }
        return SVGGradient(
            kind: kind,
            stops: stops,
            usesObjectBoundingBox: objectBoundingBox,
            transform: SVGTransform.parse(attribute("gradientTransform")) ?? .identity
        )
    }

    private static func fraction(_ value: String?) -> CGFloat? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasSuffix("%") {
            return Double(raw.dropLast()).map { min(max(CGFloat($0) / 100, 0), 1) }
        }
        return Double(raw).map { min(max(CGFloat($0), 0), 1) }
    }
}

// MARK: - Inherited presentation properties

private struct InheritedStyle {
    var fill: String? = "black"
    var fillOpacity: Double = 1
    var fillRule = "nonzero"
    var stroke: String? = "none"
    var strokeOpacity: Double = 1
    var strokeWidth: String? = "1"
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var miterLimit: CGFloat = 4
    var dashArray: String?
    var dashOffset: String?
    var color: String?
    var visibility = "visible"
    var font: [String: String] = [:]
    /// Group opacity is not inherited in SVG, but multiplying it is the visible effect.
    var opacity: Double = 1

    private static let fontKeys = ["font-family", "font-size", "font-weight", "font-style", "text-anchor"]

    mutating func apply(_ properties: [String: String]) {
        func value(_ key: String) -> String? {
            guard let raw = properties[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw != "inherit" else { return nil }
            return raw
        }
        func unit(_ raw: String?) -> Double? {
            guard let raw else { return nil }
            if raw.hasSuffix("%") { return Double(raw.dropLast()).map { $0 / 100 } }
            return Double(raw)
        }
        if let v = value("fill") { fill = v }
        if let v = unit(value("fill-opacity")) { fillOpacity = min(max(v, 0), 1) }
        if let v = value("fill-rule") { fillRule = v }
        if let v = value("stroke") { stroke = v }
        if let v = unit(value("stroke-opacity")) { strokeOpacity = min(max(v, 0), 1) }
        if let v = value("stroke-width") { strokeWidth = v }
        if let v = value("stroke-linecap") {
            lineCap = v == "round" ? .round : v == "square" ? .square : .butt
        }
        if let v = value("stroke-linejoin") {
            lineJoin = v == "round" ? .round : v == "bevel" ? .bevel : .miter
        }
        if let v = value("stroke-miterlimit").flatMap(Double.init) { miterLimit = CGFloat(max(v, 1)) }
        if let v = value("stroke-dasharray") { dashArray = v }
        if let v = value("stroke-dashoffset") { dashOffset = v }
        if let v = value("color") { color = v }
        if let v = value("visibility") { visibility = v }
        for key in Self.fontKeys {
            if let v = value(key) { font[key] = v }
        }
        if let v = unit(value("opacity")) { opacity *= min(max(v, 0), 1) }
    }

    func textProperties(merging properties: [String: String]) -> [String: String] {
        var result = properties
        for (key, value) in font where result[key] == nil {
            result[key] = value
        }
        return result
    }
}

// MARK: - Stylesheet

/// A minimal CSS parser for `<style>` elements as written by Illustrator, Figma and Sketch
/// (`.cls-1 { fill: #fff; }`, `#Gears { … }`, `rect, circle { … }`). Selectors with
/// combinators, pseudo-classes or attribute tests are ignored.
enum SVGStyleSheet {
    struct Selector {
        let element: String?
        let id: String?
        let classes: [String]

        var specificity: Int {
            (id == nil ? 0 : 100) + classes.count * 10 + (element == nil ? 0 : 1)
        }

        func matches(_ node: LayerNode) -> Bool {
            if let element, element != node.elementName { return false }
            if let id, node.attributes["id"] != id { return false }
            if !classes.isEmpty {
                let nodeClasses = Set((node.attributes["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
                if !classes.allSatisfy(nodeClasses.contains) { return false }
            }
            return true
        }

        init?(_ text: String) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.rangeOfCharacter(from: CharacterSet(charactersIn: " >+~:[*()\n\t")) == nil else { return nil }
            var element: String?
            var id: String?
            var classes: [String] = []
            var current = ""
            var kind: Character = "e"
            func flush() {
                guard !current.isEmpty else { return }
                switch kind {
                case "#": id = current
                case ".": classes.append(current)
                default: element = current
                }
                current = ""
            }
            for character in text {
                if character == "#" || character == "." {
                    flush()
                    kind = character
                } else {
                    current.append(character)
                }
            }
            flush()
            self.element = element
            self.id = id
            self.classes = classes
        }
    }

    struct Rule {
        let selector: Selector
        let declarations: [String: String]
    }

    /// Rules ordered by ascending specificity, then source order, ready to be applied in sequence.
    static func parse(_ css: String) -> [Rule] {
        var text = css
        while let start = text.range(of: "/*") {
            let end = text.range(of: "*/", range: start.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
            text.removeSubrange(start.lowerBound..<end)
        }

        var rules: [(rule: Rule, order: Int)] = []
        var prelude = ""
        var body = ""
        var depth = 0
        for character in text {
            switch character {
            case "{":
                depth += 1
                if depth > 1 { body.append(character) }
            case "}":
                depth -= 1
                if depth > 0 {
                    body.append(character)
                } else {
                    let selectorText = prelude.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !selectorText.hasPrefix("@") {
                        let declarations = SVGStyle.declarations(body)
                        for selectorPart in selectorText.split(separator: ",") {
                            if let selector = Selector(String(selectorPart)) {
                                rules.append((Rule(selector: selector, declarations: declarations), rules.count))
                            }
                        }
                    }
                    prelude = ""
                    body = ""
                    depth = 0
                }
            default:
                if depth == 0 { prelude.append(character) } else { body.append(character) }
            }
        }
        return rules
            .sorted { ($0.rule.selector.specificity, $0.order) < ($1.rule.selector.specificity, $1.order) }
            .map(\.rule)
    }
}
