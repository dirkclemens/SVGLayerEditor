import CoreGraphics
import XCTest
@testable import SVGLayerEditor

func XCTAssertNear(_ a: CGFloat, _ b: CGFloat, accuracy: CGFloat = 0.01, _ message: String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a, b, accuracy: accuracy, message, file: file, line: line)
}

func XCTAssertNear(_ a: CGRect?, _ b: CGRect, accuracy: CGFloat = 0.05, _ message: String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    guard let a else { return XCTFail("rect is nil. \(message)", file: file, line: line) }
    for (lhs, rhs) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
        XCTAssertEqual(lhs, rhs, accuracy: accuracy, "\(a) != \(b). \(message)", file: file, line: line)
    }
}

extension LayerNode {
    /// Finds a descendant (or self) by its SVG `id` attribute.
    func node(withSVGID id: String) -> LayerNode? {
        if attributes["id"] == id { return self }
        for child in children {
            if let found = child.node(withSVGID: id) { return found }
        }
        return nil
    }
}
