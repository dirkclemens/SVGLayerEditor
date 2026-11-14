import CoreGraphics
import XCTest
@testable import SVGLayerEditor

final class ValueTests: XCTestCase {
    func testNumberScanning() {
        XCTAssertEqual(SVGNumberScanner.numbers(in: "10-20.5.5e1,1e-2 -.5"), [10, -20.5, 5, 0.01, -0.5])
    }

    func testCompactFormatting() {
        XCTAssertEqual(SVGFormat.number(550), "550")
        XCTAssertEqual(SVGFormat.number(1.50), "1.5")
        XCTAssertEqual(SVGFormat.number(-0.001), "0")
    }

    func testLengthsPointsViewBox() {
        XCTAssertEqual(SVGLength.parse("10px"), 10)
        XCTAssertEqual(SVGLength.parse("1in"), 96)
        XCTAssertNil(SVGLength.parse("50%"))
        XCTAssertEqual(SVGViewBox.parse("0,0\t1024 1024"), CGRect(x: 0, y: 0, width: 1024, height: 1024))
        XCTAssertEqual(SVGPoints.parse("10,20 30-40")?.count, 2)
    }

    func testColors() {
        XCTAssertEqual(SVGColor.parse("#fff"), SVGColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(SVGColor.parse("rgb(100%, 0%, 0%)"), SVGColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(SVGColor.parse("RebeccaPurple")?.hexString, "#663399")
        XCTAssertEqual(SVGColor.parse("rgba(0,0,255,0.5)")?.alpha, 0.5)
    }

    func testStyleAttribute() {
        var attributes = ["style": "fill: red; stroke: blue", "fill": "green"]
        XCTAssertEqual(SVGStyle.value("fill", in: attributes), "red")
        SVGStyle.set("fill", to: "#000000", in: &attributes)
        XCTAssertEqual(SVGStyle.value("fill", in: attributes), "#000000")
        XCTAssertNil(attributes["fill"])
    }

    func testTransforms() throws {
        let t = try XCTUnwrap(SVGTransform.parse("translate(10 20) scale(2)"))
        XCTAssertEqual(CGPoint(x: 1, y: 1).applying(t), CGPoint(x: 12, y: 22))
        XCTAssertNil(SVGTransform.parse("rotate("))

        let rotation = CGAffineTransform(translationX: 50, y: 50).rotated(by: 15 * .pi / 180).translatedBy(x: -50, y: -50)
        XCTAssertEqual(SVGTransform.format(rotation), "rotate(15 50 50)")
        XCTAssertNil(SVGTransform.format(.identity))
        XCTAssertEqual(SVGTransform.format(CGAffineTransform(translationX: 3, y: -4)), "translate(3 -4)")
        let parsedBack = try XCTUnwrap(SVGTransform.parse(SVGTransform.format(rotation)))
        XCTAssertNear(parsedBack.tx, rotation.tx)
        XCTAssertNear(parsedBack.b, rotation.b, accuracy: 0.0001)
    }
}
