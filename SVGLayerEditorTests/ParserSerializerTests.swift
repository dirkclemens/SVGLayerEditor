import XCTest
@testable import SVGLayerEditor

final class ParserSerializerTests: XCTestCase {
    func testRoundTrip() throws {
        let sample = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <g id="layer1">
            <rect id="rect1" width="10" height="20" />
          </g>
        </svg>
        """
        let doc = try SVGParser.parseDocument(from: sample)
        XCTAssertEqual(doc.root.elementName, "svg")
        XCTAssertEqual(doc.root.children.count, 1)
        let reparsed = try SVGParser.parseDocument(from: SVGSerializer().serialize(document: doc))
        XCTAssertEqual(SVGSerializer().serialize(document: reparsed), SVGSerializer().serialize(document: doc))
    }

    func testFragment() throws {
        let nodes = try SVGParser.parseFragment(from: "<g id=\"layer2\"><circle id=\"circle1\" /></g>")
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.elementName, "g")
    }

    func testFragmentWithXlinkPrefix() throws {
        let nodes = try SVGParser.parseFragment(from: "<use xlink:href=\"#a\"/>")
        XCTAssertEqual(nodes.first?.attributes["xlink:href"], "#a")
    }

    func testUndeclaredPrefixFallsBackToXMLParser() throws {
        // libxml2's tree builder rejects the undeclared prefix; the event parser accepts it.
        let doc = try SVGParser.parseDocument(from: "<svg xmlns=\"http://www.w3.org/2000/svg\"><use xlink:href=\"#a\"/></svg>")
        XCTAssertEqual(doc.root.children.first?.attributes["xlink:href"], "#a")
    }

    func testSourceAttributeOrderIsPreserved() throws {
        let sample = """
        <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
          <rect height="5" fill="red" width="5" id="r"/>
        </svg>
        """
        let doc = try SVGParser.parseDocument(from: sample)
        doc.root.children[0].attributes["stroke"] = "blue"
        let out = SVGSerializer().serialize(document: doc)
        XCTAssertTrue(out.contains("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\">"), out)
        XCTAssertTrue(out.contains("<rect height=\"5\" fill=\"red\" width=\"5\" id=\"r\" stroke=\"blue\"/>"),
                      "source order first, new attributes after it:\n\(out)")
    }

    func testCanonicalOrderForNewElements() {
        let root = LayerNode(elementName: "svg", attributes: [
            "viewBox": "0 0 1024 1024", "height": "1024", "width": "1024", "xmlns": SVGSerializer.svgNamespace
        ])
        root.children = [LayerNode(elementName: "rect", attributes: ["fill": "#000", "height": "5", "width": "5", "y": "1", "x": "1", "id": "a"])]
        let out = SVGSerializer().serialize(document: SVGDocument(root: root))
        XCTAssertTrue(out.contains("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">"), out)
        XCTAssertTrue(out.contains("<rect id=\"a\" x=\"1\" y=\"1\" width=\"5\" height=\"5\" fill=\"#000\"/>"), out)
    }

    func testMissingXmlnsIsAddedFirst() throws {
        let doc = try SVGParser.parseDocument(from: "<svg viewBox=\"0 0 10 10\"><rect width=\"1\" height=\"1\"/></svg>")
        XCTAssertTrue(SVGSerializer().serialize(document: doc).contains("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\">"))
    }

    func testCommentsArePreserved() throws {
        let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- Generator: Test -->
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
          <!-- background -->
          <rect id="bg" width="10" height="10"/>
          <g id="g">
            <circle id="c" r="1"/>
            <!-- end of group -->
          </g>
          <text id="t">Hi<!-- inline --></text>
        </svg>
        <!-- trailer -->
        """
        let doc = try SVGParser.parseDocument(from: sample)
        XCTAssertEqual(doc.leadingComments, [" Generator: Test "])
        XCTAssertEqual(doc.trailingComments, [" trailer "])
        XCTAssertEqual(doc.root.node(withSVGID: "bg")?.leadingComments, [" background "])
        XCTAssertEqual(doc.root.node(withSVGID: "g")?.trailingComments, [" end of group "])

        let out = SVGSerializer().serialize(document: doc)
        XCTAssertTrue(out.contains("<!-- Generator: Test -->\n<svg"), out)
        XCTAssertTrue(out.contains("  <!-- background -->\n  <rect id=\"bg\""), out)
        XCTAssertTrue(out.contains("    <!-- end of group -->\n  </g>"), out)
        XCTAssertTrue(out.contains("<text id=\"t\">Hi<!-- inline --></text>"), out)
        XCTAssertTrue(out.hasSuffix("<!-- trailer -->\n"), out)
        // Stable on a second round trip.
        XCTAssertEqual(SVGSerializer().serialize(document: try SVGParser.parseDocument(from: out)), out)
    }

    func testCommentsMoveWithTheirElement() throws {
        let doc = try SVGParser.parseDocument(from: "<svg xmlns=\"http://www.w3.org/2000/svg\"><!-- A --><rect id=\"a\"/><rect id=\"b\"/></svg>")
        doc.root.children.swapAt(0, 1)
        let out = SVGSerializer().serialize(document: doc)
        XCTAssertTrue(out.contains("<rect id=\"b\"/>\n  <!-- A -->\n  <rect id=\"a\"/>"), out)
    }

    func testDoubleHyphenInCommentIsSanitized() {
        let node = LayerNode(elementName: "rect", leadingComments: ["a -- b"])
        XCTAssertEqual(SVGSerializer().serialize(node: node), "<!--a - - b-->\n<rect/>\n")
    }

    func testParseErrorReportsLine() {
        XCTAssertThrowsError(try SVGParser.parseDocument(from: "<svg>\n<g>\n</svg>")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Line"), error.localizedDescription)
        }
    }

    func testExternalEntitiesAreNotLoaded() throws {
        let sample = """
        <?xml version="1.0"?>
        <!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/hosts">]>
        <svg xmlns="http://www.w3.org/2000/svg"><text>&x;</text></svg>
        """
        let doc = try? SVGParser.parseDocument(from: sample)
        XCTAssertFalse(doc?.root.children.first?.text?.contains("localhost") ?? false)
    }
}
