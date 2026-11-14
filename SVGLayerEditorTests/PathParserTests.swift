import CoreGraphics
import XCTest
@testable import SVGLayerEditor

final class PathParserTests: XCTestCase {
    func testArc() throws {
        // Arcs were unsupported before: moving such a path truncated it to its first point.
        let arc = try XCTUnwrap(SVGPathParser.toPath("M10 10 A 10 10 0 0 1 30 10", strict: true))
        XCTAssertNear(arc.boundingBoxOfPath, CGRect(x: 10, y: 0, width: 20, height: 10), accuracy: 0.2)
        XCTAssertNotNil(SVGPathParser.toPath("M0 0a5 5 0 105 5", strict: true), "flags without separators")
    }

    func testAllCommands() {
        XCTAssertNotNil(SVGPathParser.toPath("M0 0 Q 10 10 20 0 T 40 0 S 50 10 60 0 s 10 10 20 0 h10 v10 H0 z", strict: true))
    }

    func testImplicitLineTo() throws {
        let path = try XCTUnwrap(SVGPathParser.toPath("M0 0 10 0 10 10z", strict: true))
        XCTAssertNear(path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testStrictAndLenient() {
        XCTAssertNil(SVGPathParser.toPath("M0 0 L 10 10 X 5", strict: true))
        XCTAssertNotNil(SVGPathParser.toPath("M0 0 L 10 10 X 5", strict: false))
    }

    func testCompactSerialization() throws {
        XCTAssertEqual(SVGPathParser.serialize(path: try XCTUnwrap(SVGPathParser.toPath("M1.50 2 L3 4"))), "M1.5 2 L3 4")
    }
}
