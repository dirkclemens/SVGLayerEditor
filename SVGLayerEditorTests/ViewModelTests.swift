import CoreGraphics
import XCTest
@testable import SVGLayerEditor

final class ViewModelTests: XCTestCase {
    private let sample = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <rect id="r" x="10" y="10" width="20" height="10"/>
      <circle id="c" cx="50" cy="50" r="10"/>
      <path id="p" d="M10 80 A 10 10 0 0 1 30 80"/>
      <g id="g" transform="translate(5 5)"><rect id="inner" x="0" y="0" width="10" height="10"/></g>
      <rect id="rotated" x="0" y="0" width="10" height="10" transform="rotate(90 5 5)"/>
    </svg>
    """

    private func makeViewModel() throws -> (SVGLayerEditorViewModel, LayerNode) {
        let vm = SVGLayerEditorViewModel()
        let doc = try SVGParser.parseDocument(from: sample)
        vm.document = doc
        return (vm, doc.root)
    }

    func testRotateRectUsesTransform() throws {
        let (vm, root) = try makeViewModel()
        vm.selectedNodeID = root.node(withSVGID: "r")?.id
        vm.rotateSelected(by: 15)
        XCTAssertEqual(root.node(withSVGID: "r")?.attributes["width"], "20")
        XCTAssertEqual(root.node(withSVGID: "r")?.attributes["transform"], "rotate(15 20 15)")
    }

    func testRotateCircleKeepsRadius() throws {
        let (vm, root) = try makeViewModel()
        vm.selectedNodeID = root.node(withSVGID: "c")?.id
        vm.rotateSelected(by: 15)
        XCTAssertEqual(root.node(withSVGID: "c")?.attributes["r"], "10")
        XCTAssertNil(root.node(withSVGID: "c")?.attributes["transform"])
    }

    func testMoveArcPathKeepsArc() throws {
        let (vm, root) = try makeViewModel()
        vm.transformElement(nodeID: try XCTUnwrap(root.node(withSVGID: "p")).id, transform: CGAffineTransform(translationX: 5, y: 0))
        let d = try XCTUnwrap(root.node(withSVGID: "p")?.attributes["d"])
        XCTAssertTrue(d.hasPrefix("M15 80 C"), d)
        XCTAssertNear(try XCTUnwrap(SVGPathParser.toPath(d)).boundingBoxOfPath.maxX, 35)
    }

    func testMoveInsideTransformedGroup() throws {
        let (vm, root) = try makeViewModel()
        let inner = try XCTUnwrap(root.node(withSVGID: "inner"))
        vm.transformElement(nodeID: inner.id, transform: CGAffineTransform(translationX: 10, y: 0))
        XCTAssertEqual(inner.attributes["x"], "10")
        XCTAssertNear(vm.canvasBounds(of: inner.id), CGRect(x: 15, y: 5, width: 10, height: 10))
    }

    func testMoveGroupAndRotatedRect() throws {
        let (vm, root) = try makeViewModel()
        vm.transformElement(nodeID: try XCTUnwrap(root.node(withSVGID: "g")).id, transform: CGAffineTransform(translationX: 1, y: 2))
        XCTAssertEqual(root.node(withSVGID: "g")?.attributes["transform"], "translate(6 7)")

        let rotated = try XCTUnwrap(root.node(withSVGID: "rotated"))
        vm.transformElement(nodeID: rotated.id, transform: CGAffineTransform(translationX: 10, y: 0))
        XCTAssertNear(vm.canvasBounds(of: rotated.id), CGRect(x: 10, y: 0, width: 10, height: 10))
    }

    func testDragIsOneUndoStepThroughUndoManager() throws {
        let (vm, root) = try makeViewModel()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        vm.undoManager = undoManager
        let circleID = try XCTUnwrap(root.node(withSVGID: "c")).id

        undoManager.beginUndoGrouping()
        for _ in 0..<5 {
            vm.transformElement(nodeID: circleID, transform: CGAffineTransform(translationX: 1, y: 0), coalescingKey: "drag")
        }
        undoManager.endUndoGrouping()
        vm.endInteractiveChange()
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        XCTAssertEqual(vm.document?.root.node(withSVGID: "c")?.attributes["cx"], "50", "one undo reverts the whole drag")
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertEqual(vm.document?.root.node(withSVGID: "c")?.attributes["cx"], "55")
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertFalse(undoManager.canRedo)
    }

    func testUndoKeepsComments() throws {
        let vm = SVGLayerEditorViewModel()
        vm.document = try SVGParser.parseDocument(from: "<!-- head --><svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 9 9\"><rect id=\"r\" width=\"1\" height=\"1\"/></svg>")
        vm.selectedNodeID = vm.document?.root.children.first?.id
        vm.alignSelectedToCanvas(.centerX)
        vm.undo()
        XCTAssertEqual(vm.document?.leadingComments, [" head "])
    }

    func testEditorTextIsThrottledDuringDrag() throws {
        let (vm, root) = try makeViewModel()
        let circleID = try XCTUnwrap(root.node(withSVGID: "c")).id
        // Let the initial (asynchronous) editor sync land.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let before = vm.documentXMLText

        vm.transformElement(nodeID: circleID, transform: CGAffineTransform(translationX: 1, y: 0), coalescingKey: "drag")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(vm.documentXMLText, before, "no re-serialization on every drag event")

        vm.endInteractiveChange()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(vm.documentXMLText.contains("cx=\"51\""), "editor is refreshed when the drag ends")
    }

    func testRootRawXMLAppliesToDocument() throws {
        let (vm, root) = try makeViewModel()
        vm.selectedNodeID = root.id
        // The editor refresh for the new selection is delivered asynchronously.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        vm.applySelectedNodeXMLText("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 50 50\"><circle r=\"1\"/></svg>")
        XCTAssertEqual(vm.document?.root.attributes["viewBox"], "0 0 50 50")
        XCTAssertEqual(vm.document?.root.id, root.id, "root keeps its identity")
    }

    func testNewShapeIsNotInsertedIntoRect() throws {
        let (vm, root) = try makeViewModel()
        vm.selectedNodeID = root.node(withSVGID: "r")?.id
        vm.addCircle()
        XCTAssertTrue(root.node(withSVGID: "r")?.children.isEmpty ?? false)
        XCTAssertEqual(vm.document?.root.children[1].elementName, "circle", "inserted right after the selected rect")
    }
}
