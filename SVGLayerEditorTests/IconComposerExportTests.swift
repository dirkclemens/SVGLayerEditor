import XCTest
@testable import SVGLayerEditor

final class IconComposerExportTests: XCTestCase {
    private let sample = """
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

    private func makeExport() throws -> IconComposerExport {
        try IconComposerExport(document: try SVGParser.parseDocument(from: sample)) { $0.attributes["display"] == "none" }
    }

    func testGroupsAndLayers() throws {
        let export = try makeExport()
        XCTAssertEqual(export.groups.map(\.name), ["Foreground", "Background"], "front-most group first")
        XCTAssertEqual(export.groups.first?.layers.map(\.name), ["Bar", "Dot"], "front-most layer first")
    }

    func testLayerFiles() throws {
        let layer = try makeExport().groups[0].layers[0].svg
        XCTAssertTrue(layer.contains("width=\"1024\" height=\"1024\" viewBox=\"0 -75 800 800\""), layer)
        XCTAssertTrue(layer.contains("<g fill=\"red\">"), "group paint kept")
        XCTAssertTrue(layer.contains("<linearGradient id=\"g\">"), "shared definitions copied")
        XCTAssertFalse(layer.contains("Hidden"))
    }

    func testIconJSONAndBundle() throws {
        let export = try makeExport()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try export.iconJSON()) as? [String: Any])
        let groups = try XCTUnwrap(json["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        let layers = try XCTUnwrap(groups.first?["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.first?["image-name"] as? String, "Bar.svg")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Test.icon")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try export.write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("icon.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("Assets/Dot.svg").path))
    }
}
