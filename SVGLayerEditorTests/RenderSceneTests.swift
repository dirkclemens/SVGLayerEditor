import CoreGraphics
import XCTest
@testable import SVGLayerEditor

final class RenderSceneTests: XCTestCase {
    private func scene(_ svg: String, hideDisplayNone: Bool = true) throws -> (SVGDocument, [String: SVGRenderItem]) {
        let doc = try SVGParser.parseDocument(from: svg)
        let scene = SVGRenderScene(root: doc.root, canvas: CGRect(x: 0, y: 0, width: 100, height: 100)) {
            hideDisplayNone && SVGStyle.value("display", in: $0.attributes) == "none"
        }
        let items = Dictionary(uniqueKeysWithValues: scene.items.map { item in
            (doc.root.findNode(by: item.id)?.attributes["id"] ?? "?", item)
        })
        return (doc, items)
    }

    func testInheritanceDefaultsAndDefs() throws {
        let (_, items) = try scene("""
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
        """)
        XCTAssertEqual(items.count, 3, "defs content and hidden elements are not painted")
        XCTAssertEqual(items["inherits"]?.fill, .color(SVGColor(red: 0, green: 1, blue: 0)))
        XCTAssertEqual(items["inherits"]?.opacity, 0.5)
        XCTAssertNear(items["inherits"]?.canvasBounds, CGRect(x: 10, y: 0, width: 10, height: 10))
        guard case .gradient = items["styled"]?.fill else { return XCTFail("style url(#g) resolves to gradient") }
        XCTAssertEqual(items["styled"]?.stroke, .color(SVGColor(red: 1, green: 0, blue: 0)))
        XCTAssertEqual(items["default"]?.fill, .color(.black))
        XCTAssertEqual(items["default"]?.evenOdd, true)
    }

    func testStylesheetAndClipPath() throws {
        let (_, items) = try scene("""
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
        """)
        XCTAssertEqual(items["a"]?.fill, .color(SVGColor(red: 1, green: 1, blue: 1)))
        XCTAssertEqual(items["a"]?.stroke, .color(SVGColor(red: 1, green: 0, blue: 0)))
        XCTAssertEqual(items["special"]?.fill, .color(SVGColor(red: 0, green: 0, blue: 1)), "id beats class")
        XCTAssertEqual(items["special"]?.stroke, .color(SVGColor(red: 0, green: 128.0 / 255, blue: 0)), "style beats rules")
        XCTAssertNear(items["a"]?.canvasBounds, CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(items["a"]?.isClipped(canvasPoint: CGPoint(x: 75, y: 75)), true)
    }
}
