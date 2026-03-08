import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        print("Test failed: \(message)")
        return false
    }
    return true
}

private func runTests() -> Int32 {
    var failures = 0

    let sample = """
    <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\">
      <g id=\"layer1\">
        <rect id=\"rect1\" width=\"10\" height=\"20\" />
      </g>
    </svg>
    """

    do {
        let doc = try SVGParser.parseDocument(from: sample)
        if !expect(doc.root.elementName == "svg", "Root element should be svg") { failures += 1 }
        if !expect(doc.root.children.count == 1, "Root should have one child") { failures += 1 }
        let serialized = SVGSerializer().serialize(document: doc)
        let doc2 = try SVGParser.parseDocument(from: serialized)
        if !expect(doc2.root.elementName == "svg", "Round trip root should be svg") { failures += 1 }
    } catch {
        print("Test failed: \(error)")
        failures += 1
    }

    do {
        let fragment = "<g id=\"layer2\"><circle id=\"circle1\" /></g>"
        let nodes = try SVGParser.parseFragment(from: fragment)
        if !expect(nodes.count == 1, "Fragment should yield one node") { failures += 1 }
        if !expect(nodes.first?.elementName == "g", "Fragment node should be g") { failures += 1 }
    } catch {
        print("Test failed: \(error)")
        failures += 1
    }

    do {
        let sample = """
        <?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>
        <svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 800 650\" text-rendering=\"geometricPrecision\" shape-rendering=\"geometricPrecision\">
          <g id=\"display\">
            <path id=\"Pfad\" fill=\"#000000\" stroke=\"none\" opacity=\"0\" d=\"M20,-4.25L778.5,-4.25L778.5,656L20,656L20,-4.25z\"/>
          </g>
        </svg>
        """
        let doc = try SVGParser.parseDocument(from: sample)
        let serialized = SVGSerializer().serialize(document: doc)
        if !expect(serialized.contains("xmlns=\"http://www.w3.org/2000/svg\""), "Serialized SVG should keep xmlns") { failures += 1 }
        if !expect(serialized.contains("viewBox=\"0 0 800 650\""), "Serialized SVG should keep viewBox") { failures += 1 }
    } catch {
        print("Test failed: \(error)")
        failures += 1
    }

    return failures == 0 ? 0 : 1
}

@main
struct TestHarness {
    static func main() {
        exit(runTests())
    }
}
