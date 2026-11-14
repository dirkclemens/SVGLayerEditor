import CoreGraphics
import Foundation

// Standalone test runner (no XCTest target). Build and run with Tests/run.sh.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if !condition() {
        print("FAIL [line \(line)]: \(message)")
        failures += 1
    }
}

private func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.01) -> Bool { abs(a - b) <= eps }
private func near(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 0.05) -> Bool {
    near(a.minX, b.minX, eps) && near(a.minY, b.minY, eps) && near(a.width, b.width, eps) && near(a.height, b.height, eps)
}

private func check(_ name: String, _ body: () throws -> Void) {
    do { try body() } catch { print("FAIL [\(name)]: \(error)"); failures += 1 }
}

private func testParserAndSerializer() {
    check("round trip") {
        let sample = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <g id="layer1">
            <rect id="rect1" width="10" height="20" />
          </g>
        </svg>
        """
        let doc = try SVGParser.parseDocument(from: sample)
        expect(doc.root.elementName == "svg", "Root element should be svg")
        expect(doc.root.children.count == 1, "Root should have one child")
        let doc2 = try SVGParser.parseDocument(from: SVGSerializer().serialize(document: doc))
        expect(doc2.root.elementName == "svg", "Round trip root should be svg")
    }

    check("fragment") {
        let nodes = try SVGParser.parseFragment(from: "<g id=\"layer2\"><circle id=\"circle1\" /></g>")
        expect(nodes.count == 1 && nodes.first?.elementName == "g", "Fragment should yield one g")
    }

    check("icon composer layout") {
        // Apple's icon assets: only xmlns + viewBox on the root.
        let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">
          <rect height="550.00" width="700" x="50" y="50" fill="#000" id="a"/>
        </svg>
        """
        let doc = try SVGParser.parseDocument(from: sample)
        let out = SVGSerializer().serialize(document: doc)
        expect(out.contains("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">"),
               "Root attributes should be xmlns, width, height, viewBox:\n\(out)")
        expect(out.contains("<rect id=\"a\" x=\"50\" y=\"50\" width=\"700\" height=\"550.00\" fill=\"#000\"/>"),
               "Element attributes should be id, geometry, paint:\n\(out)")
    }

    check("missing xmlns is added") {
        let doc = try SVGParser.parseDocument(from: "<svg viewBox=\"0 0 10 10\"><rect width=\"1\" height=\"1\"/></svg>")
        expect(SVGSerializer().serialize(document: doc).contains("<svg xmlns=\"http://www.w3.org/2000/svg\""),
               "Document root must always declare the SVG namespace")
    }
}

private func testNumbersAndValues() {
    let numbers = SVGNumberScanner.numbers(in: "10-20.5.5e1,1e-2 -.5")
    expect(numbers == [10, -20.5, 5, 0.01, -0.5], "Number list scanning: \(numbers)")
    expect(SVGFormat.number(550) == "550" && SVGFormat.number(1.50) == "1.5" && SVGFormat.number(-0.001) == "0",
           "Compact number formatting")
    expect(SVGLength.parse("10px") == 10 && SVGLength.parse("1in") == 96 && SVGLength.parse("50%") == nil, "Lengths")
    expect(SVGViewBox.parse("0,0\t1024 1024") == CGRect(x: 0, y: 0, width: 1024, height: 1024), "viewBox separators")
    expect(SVGPoints.parse("10,20 30-40")?.count == 2, "points without separators")

    expect(SVGColor.parse("#fff") == SVGColor(red: 1, green: 1, blue: 1), "3-digit hex")
    expect(SVGColor.parse("rgb(100%, 0%, 0%)") == SVGColor(red: 1, green: 0, blue: 0), "rgb percentages")
    expect(SVGColor.parse("RebeccaPurple")?.hexString == "#663399", "named colors")
    expect(SVGColor.parse("rgba(0,0,255,0.5)")?.alpha == 0.5, "rgba alpha")

    var attributes = ["style": "fill: red; stroke: blue", "fill": "green"]
    expect(SVGStyle.value("fill", in: attributes) == "red", "style overrides attribute")
    SVGStyle.set("fill", to: "#000000", in: &attributes)
    expect(SVGStyle.value("fill", in: attributes) == "#000000" && attributes["fill"] == nil, "set updates style declaration")
}

private func testTransforms() {
    let t = SVGTransform.parse("translate(10 20) scale(2)")!
    expect(CGPoint(x: 1, y: 1).applying(t) == CGPoint(x: 12, y: 22), "translate(10 20) scale(2) applies scale first")
    expect(SVGTransform.parse("rotate(") == nil, "malformed transform is rejected")

    let rotation = CGAffineTransform(translationX: 50, y: 50).rotated(by: 15 * .pi / 180).translatedBy(x: -50, y: -50)
    expect(SVGTransform.format(rotation) == "rotate(15 50 50)", "rotation formatted: \(SVGTransform.format(rotation) ?? "nil")")
    expect(SVGTransform.format(.identity) == nil, "identity has no attribute")
    expect(SVGTransform.format(CGAffineTransform(translationX: 3, y: -4)) == "translate(3 -4)", "translation formatted")
    let parsedBack = SVGTransform.parse(SVGTransform.format(rotation))!
    expect(near(parsedBack.tx, rotation.tx) && near(parsedBack.b, rotation.b, 0.0001), "format/parse round trip")
}

private func testPathParser() {
    // Arc commands were not supported before: moving such a path truncated it to its first point.
    let arc = SVGPathParser.toPath("M10 10 A 10 10 0 0 1 30 10", strict: true)
    expect(arc != nil, "Arc path parses strictly")
    if let arc { expect(near(arc.boundingBoxOfPath, CGRect(x: 10, y: 0, width: 20, height: 10), 0.2), "Arc bounds \(arc.boundingBoxOfPath)") }

    let compactArc = SVGPathParser.toPath("M0 0a5 5 0 105 5", strict: true)
    expect(compactArc != nil, "Arc flags without separators")

    let curves = SVGPathParser.toPath("M0 0 Q 10 10 20 0 T 40 0 S 50 10 60 0 s 10 10 20 0 h10 v10 H0 z", strict: true)
    expect(curves != nil, "Q/T/S/s/h/v/H/z parse")

    let implicitLine = SVGPathParser.toPath("M0 0 10 0 10 10z", strict: true)
    expect(implicitLine.map { near($0.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 10, height: 10)) } ?? false,
           "Pairs after M are line-tos")

    expect(SVGPathParser.toPath("M0 0 L 10 10 X 5", strict: true) == nil, "Strict parse rejects garbage")
    expect(SVGPathParser.toPath("M0 0 L 10 10 X 5", strict: false) != nil, "Lenient parse renders up to the error")

    let serialized = SVGPathParser.serialize(path: SVGPathParser.toPath("M1.50 2 L3 4")!)
    expect(serialized == "M1.5 2 L3 4", "Compact path output: \(serialized)")
}

private func testRenderScene() {
    check("render scene") {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <defs>
            <linearGradient id="g"><stop offset="0" stop-color="#f00"/><stop offset="1" stop-color="#00f"/></linearGradient>
            <clipPath id="c"><rect width="10" height="10"/></clipPath>
          </defs>
          <g fill="#00ff00" transform="translate(10 0)" opacity="0.5">
            <rect id="inherits" width="10" height="10"/>
            <rect id="styled" width="10" height="10" style="fill: url(#g); stroke: red"/>
          </g>
          <path id="default" d="M0 0 L10 0 L10 10 Z" fill-rule="evenodd"/>
          <rect id="hidden" width="5" height="5" display="none"/>
        </svg>
        """
        let doc = try SVGParser.parseDocument(from: svg)
        let scene = SVGRenderScene(root: doc.root, canvas: CGRect(x: 0, y: 0, width: 100, height: 100)) {
            SVGStyle.value("display", in: $0.attributes) == "none"
        }
        let byName = Dictionary(uniqueKeysWithValues: scene.items.map { item in
            (doc.root.findNode(by: item.id)?.attributes["id"] ?? "?", item)
        })
        expect(scene.items.count == 3, "defs content and hidden elements are not painted (\(scene.items.count) items)")
        expect(byName["inherits"]?.fill == .color(SVGColor(red: 0, green: 1, blue: 0)), "fill inherited from group")
        expect(byName["inherits"]?.opacity == 0.5, "group opacity applies")
        expect(byName["inherits"].map { near($0.canvasBounds, CGRect(x: 10, y: 0, width: 10, height: 10)) } ?? false,
               "group transform applies")
        if case .gradient = byName["styled"]?.fill {} else { expect(false, "style url(#g) resolves to gradient") }
        expect(byName["styled"]?.stroke == .color(SVGColor(red: 1, green: 0, blue: 0)), "style stroke")
        expect(byName["default"]?.fill == .color(.black), "default fill is black")
        expect(byName["default"]?.evenOdd == true, "fill-rule evenodd")
    }

    check("stylesheet and clip-path") {
        // Illustrator-style export: CSS classes and a clip path.
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <defs>
            <style>/* comment */ .cls-1 { fill: #ffffff; } #special { fill: blue } rect.cls-1, .other { stroke: red; }</style>
            <clipPath id="clip"><rect width="50" height="50"/></clipPath>
          </defs>
          <g clip-path="url(#clip)">
            <rect id="a" class="cls-1" width="100" height="100"/>
            <rect id="special" class="cls-1" width="10" height="10" style="stroke: green"/>
          </g>
        </svg>
        """
        let doc = try SVGParser.parseDocument(from: svg)
        let scene = SVGRenderScene(root: doc.root, canvas: CGRect(x: 0, y: 0, width: 100, height: 100)) { _ in false }
        expect(scene.items.count == 2, "two painted rects")
        let a = scene.items.first { doc.root.findNode(by: $0.id)?.attributes["id"] == "a" }
        let special = scene.items.first { doc.root.findNode(by: $0.id)?.attributes["id"] == "special" }
        expect(a?.fill == .color(SVGColor(red: 1, green: 1, blue: 1)) && a?.stroke == .color(SVGColor(red: 1, green: 0, blue: 0)),
               "class rules apply")
        expect(special?.fill == .color(SVGColor(red: 0, green: 0, blue: 1)), "id rule beats class rule")
        expect(special?.stroke == .color(SVGColor(red: 0, green: 128.0 / 255, blue: 0)), "style attribute beats rules")
        expect(a.map { near($0.canvasBounds, CGRect(x: 0, y: 0, width: 50, height: 50)) } == true, "clip-path limits bounds")
        expect(a?.isClipped(canvasPoint: CGPoint(x: 75, y: 75)) == true, "points outside the clip are clipped")
    }
}

private func testIconComposerExport() {
    check("export") {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 650">
          <defs><linearGradient id="g"><stop offset="0" stop-color="#fff"/></linearGradient></defs>
          <rect id="Background" width="800" height="650" fill="url(#g)"/>
          <g id="Foreground" fill="red">
            <circle id="Dot" cx="400" cy="325" r="100"/>
            <rect id="Bar" x="100" y="100" width="50" height="50"/>
          </g>
          <circle id="Hidden" r="5" display="none"/>
        </svg>
        """
        let doc = try SVGParser.parseDocument(from: svg)
        let export = try IconComposerExport(document: doc) { $0.attributes["display"] == "none" }
        expect(export.groups.map(\.name) == ["Foreground", "Background"], "Front-most group first: \(export.groups.map(\.name))")
        expect(export.groups.first?.layers.map(\.name) == ["Bar", "Dot"], "Front-most layer first")
        let layer = export.groups[0].layers[0].svg
        expect(layer.contains("width=\"1024\" height=\"1024\" viewBox=\"0 -75 800 800\""),
               "Layer uses the 1024 pt canvas with a squared viewBox:\n\(layer)")
        expect(layer.contains("<g fill=\"red\">"), "Group paint is kept around the layer")
        expect(layer.contains("<linearGradient id=\"g\">"), "Shared definitions copied into each layer")
        expect(!layer.contains("Hidden"), "Hidden layers are not exported")

        let json = try JSONSerialization.jsonObject(with: try export.iconJSON()) as? [String: Any]
        let groups = json?["groups"] as? [[String: Any]]
        expect(groups?.count == 2, "icon.json has one entry per group")
        let firstLayers = groups?.first?["layers"] as? [[String: Any]]
        expect(firstLayers?.first?["image-name"] as? String == "Bar.svg", "icon.json references the layer files")

        if let outputDirectory = ProcessInfo.processInfo.environment["EXPORT_DIR"] {
            try export.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("Test.icon"))
        }
    }
}

@MainActor
private func testViewModelTransforms() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <rect id="r" x="10" y="10" width="20" height="10"/>
      <circle id="c" cx="50" cy="50" r="10"/>
      <path id="p" d="M10 80 A 10 10 0 0 1 30 80"/>
      <g id="g" transform="translate(5 5)"><rect id="inner" x="0" y="0" width="10" height="10"/></g>
      <rect id="rotated" x="0" y="0" width="10" height="10" transform="rotate(90 5 5)"/>
    </svg>
    """
    guard let doc = try? SVGParser.parseDocument(from: svg) else { expect(false, "parse"); return }
    let vm = SVGLayerEditorViewModel()
    vm.document = doc
    func node(_ id: String) -> LayerNode? {
        func find(_ n: LayerNode) -> LayerNode? {
            if n.attributes["id"] == id { return n }
            for child in n.children { if let found = find(child) { return found } }
            return nil
        }
        return find(doc.root)
    }

    // Rotating a rect used to shrink it; now it gets a rotate() transform and keeps its size.
    vm.selectedNodeID = node("r")!.id
    vm.rotateSelected(by: 15)
    expect(node("r")?.attributes["width"] == "20" && node("r")?.attributes["transform"] == "rotate(15 20 15)",
           "rect rotation: \(node("r")!.attributes)")

    // Rotating a circle about its center must not change its radius.
    vm.selectedNodeID = node("c")!.id
    vm.rotateSelected(by: 15)
    expect(node("c")?.attributes["r"] == "10" && node("c")?.attributes["transform"] == nil, "circle rotation keeps r")

    // Moving an arc path keeps the arc (previously the path was cut after "M").
    vm.transformElement(nodeID: node("p")!.id, transform: CGAffineTransform(translationX: 5, y: 0))
    let movedPath = node("p")?.attributes["d"] ?? ""
    expect(movedPath.hasPrefix("M15 80 C") && SVGPathParser.toPath(movedPath).map { near($0.boundingBoxOfPath.maxX, 35) } == true,
           "arc path moved intact: \(movedPath)")

    // Moving an element inside a translated group moves it by exactly the canvas delta.
    vm.transformElement(nodeID: node("inner")!.id, transform: CGAffineTransform(translationX: 10, y: 0))
    expect(node("inner")?.attributes["x"] == "10", "child of transformed group: \(node("inner")!.attributes)")
    expect(vm.canvasBounds(of: node("inner")!.id).map { near($0, CGRect(x: 15, y: 5, width: 10, height: 10)) } == true,
           "canvas bounds include group transform")

    // Groups are moved through their transform attribute.
    vm.transformElement(nodeID: node("g")!.id, transform: CGAffineTransform(translationX: 1, y: 2))
    expect(node("g")?.attributes["transform"] == "translate(6 7)", "group move: \(node("g")!.attributes)")

    // Moving a rotated rect changes x/y in its own (rotated) coordinate system.
    vm.transformElement(nodeID: node("rotated")!.id, transform: CGAffineTransform(translationX: 10, y: 0))
    let rotatedBounds = vm.canvasBounds(of: node("rotated")!.id)
    expect(rotatedBounds.map { near($0, CGRect(x: 10, y: 0, width: 10, height: 10)) } == true,
           "rotated rect moved on canvas: \(String(describing: rotatedBounds)) \(node("rotated")!.attributes)")

    // Undo coalescing: a drag is one undo step.
    for _ in 0..<5 {
        vm.transformElement(nodeID: node("c")!.id, transform: CGAffineTransform(translationX: 1, y: 0), coalescingKey: "drag")
    }
    vm.endInteractiveChange()
    vm.undo()
    expect(vm.document?.root.children.first(where: { $0.attributes["id"] == "c" })?.attributes["cx"] == "50",
           "one undo reverts the whole drag")
}

@main
struct TestHarness {
    static func main() {
        testParserAndSerializer()
        testNumbersAndValues()
        testTransforms()
        testPathParser()
        testRenderScene()
        testIconComposerExport()
        MainActor.assumeIsolated { testViewModelTransforms() }
        print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
