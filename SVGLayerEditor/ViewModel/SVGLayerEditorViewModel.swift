import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SVGLayerEditorViewModel: ObservableObject {
    @Published var document: SVGDocument? {
        didSet {
            syncDocumentText()
        }
    }
    @Published var selectedNodeID: UUID? {
        didSet {
            if let oldValue, oldValue != selectedNodeID {
                lastReferenceNodeID = oldValue
            }
            syncSelectedNodeText()
        }
    }
    @Published var clipboardMode: ClipboardInsertMode = .svgContents
    @Published var errorMessage: String?
    @Published var isShowingError = false
    @Published private(set) var recentFiles: [URL] = []
    @Published var selectedNodeXMLText: String = ""
    @Published var selectedNodeXMLError: String?
    @Published var documentXMLText: String = ""
    @Published var documentXMLError: String?

    private var lastFillHex: String = "#4f8cff"
    private var lastStrokeHex: String = "#1c1c1c"

    private struct UndoSnapshot {
        let document: SVGDocument
        let selectedNodeID: UUID?
    }

    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    private let maxUndoCount = 50

    private let clipboard = ClipboardService()
    private let serializer = SVGSerializer()
    private let recentKey = "recentSVGFiles"
    private let maxRecentCount = 10
    private var isApplyingEditorUpdate = false
    private var isApplyingDocumentUpdate = false
    private var cancellables = Set<AnyCancellable>()

    private var lastReferenceNodeID: UUID?

    init() {
        loadRecentFiles()
        $selectedNodeXMLText
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] text in
                self?.applySelectedNodeXMLText(text)
            }
            .store(in: &cancellables)
    }

    var hasDocument: Bool {
        document != nil
    }

    var isDirty: Bool {
        document?.isDirty ?? false
    }

    var previewSVGData: Data? {
        guard let doc = document else { return nil }
        let filteredRoot = makeFilteredNode(from: doc.root)
        let filteredDoc = SVGDocument(root: filteredRoot, sourceURL: doc.sourceURL, isDirty: doc.isDirty)
        let svg = serializer.serialize(document: filteredDoc)
        return svg.data(using: String.Encoding.utf8)
    }

    private func makeFilteredNode(from node: LayerNode) -> LayerNode {
        let filteredChildren = node.children.compactMap { child -> LayerNode? in
            if isHidden(child) { return nil }
            return makeFilteredNode(from: child)
        }
        return LayerNode(
            id: node.id,
            name: node.name,
            elementName: node.elementName,
            attributes: node.attributes,
            children: filteredChildren,
            text: node.text
        )
    }

    var selectedNodeXML: String? {
        guard let doc = document, let selectedID = selectedNodeID,
              let node = doc.root.findNode(by: selectedID) else { return nil }
        return serializer.serialize(node: node)
    }

    var hasUndo: Bool {
        !undoStack.isEmpty
    }

    var hasRedo: Bool {
        !redoStack.isEmpty
    }

    var selectedFillColor: Color? {
        guard let doc = document, let selectedID = selectedNodeID,
              let node = doc.root.findNode(by: selectedID),
              let value = node.attributes["fill"] else { return nil }
        return Color(svg: value)
    }

    var selectedStrokeColor: Color? {
        guard let doc = document, let selectedID = selectedNodeID,
              let node = doc.root.findNode(by: selectedID),
              let value = node.attributes["stroke"] else { return nil }
        return Color(svg: value)
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        if let doc = document {
            redoStack.append(UndoSnapshot(
                document: SVGDocument(root: doc.root.deepCopy(), sourceURL: doc.sourceURL, isDirty: doc.isDirty),
                selectedNodeID: selectedNodeID
            ))
            if redoStack.count > maxUndoCount {
                redoStack.removeFirst()
            }
        }
        document = snapshot.document
        selectedNodeID = snapshot.selectedNodeID
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        if let doc = document {
            undoStack.append(UndoSnapshot(
                document: SVGDocument(root: doc.root.deepCopy(), sourceURL: doc.sourceURL, isDirty: doc.isDirty),
                selectedNodeID: selectedNodeID
            ))
            if undoStack.count > maxUndoCount {
                undoStack.removeFirst()
            }
        }
        document = snapshot.document
        selectedNodeID = snapshot.selectedNodeID
    }

    private func pushUndoSnapshot(for doc: SVGDocument) {
        let snapshot = UndoSnapshot(
            document: SVGDocument(root: doc.root.deepCopy(), sourceURL: doc.sourceURL, isDirty: doc.isDirty),
            selectedNodeID: selectedNodeID
        )
        undoStack.append(snapshot)
        if undoStack.count > maxUndoCount {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func resetUndoStack() {
        undoStack = []
        redoStack = []
    }

    func applySelectedNodeXMLText(_ text: String) {
        guard !isApplyingEditorUpdate else { return }
        guard var doc = document, let selectedID = selectedNodeID else { return }
        guard let parent = doc.root.findParent(of: selectedID),
              let index = parent.children.firstIndex(where: { $0.id == selectedID }) else { return }

        let parseResult = parseNode(from: text)
        switch parseResult {
        case .failure(let error):
            selectedNodeXMLError = error.localizedDescription
            return
        case .success(let parsedNode):
            let existingNode = parent.children[index]
            let existingXML = serializer.serialize(node: existingNode)
            let parsedXML = serializer.serialize(node: parsedNode)
            if existingXML == parsedXML {
                selectedNodeXMLError = nil
                return
            }

            pushUndoSnapshot(for: doc)
            var newNode = parsedNode
            newNode = LayerNode(
                id: selectedID,
                name: newNode.name,
                elementName: newNode.elementName,
                attributes: newNode.attributes,
                children: newNode.children,
                text: newNode.text
            )
            selectedNodeXMLError = nil
            parent.children[index] = newNode
            doc.isDirty = true
            document = doc
        }
    }

    func applyDocumentXMLText(_ text: String) {
        guard !isApplyingDocumentUpdate else { return }
        guard let currentDoc = document else { return }
        let selectionPath = selectedNodeID.flatMap { nodePath(for: $0, in: currentDoc) }
        do {
            var parsed = try SVGParser.parseDocument(from: text)
            parsed.sourceURL = currentDoc.sourceURL
            parsed.isDirty = true
            pushUndoSnapshot(for: currentDoc)
            documentXMLError = nil
            document = parsed
            if let selectionPath, let newID = nodeID(for: selectionPath, in: parsed) {
                selectedNodeID = newID
            } else {
                selectedNodeID = nil
            }
        } catch {
            documentXMLError = error.localizedDescription
        }
    }

    func applyDocumentXMLFromEditor() {
        applyDocumentXMLText(documentXMLText)
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openDocument(at: url)
        }
    }

    func openDocument(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            var doc = try SVGParser.parseDocument(from: data)
            doc.sourceURL = url
            doc.isDirty = false
            document = doc
            selectedNodeID = nil
            lastReferenceNodeID = nil
            resetUndoStack()
            addRecentFile(url)
        } catch {
            presentError(error)
        }
    }

    func openRecent(_ url: URL) {
        openDocument(at: url)
    }

    func clearRecentFiles() {
        recentFiles = []
        UserDefaults.standard.removeObject(forKey: recentKey)
    }

    func saveDocument() {
        guard var doc = document else { return }
        do {
            try validateDocument(doc)
        } catch {
            presentError(error)
            return
        }
        if let url = doc.sourceURL {
            do {
                try writeDocument(doc, to: url)
                doc.isDirty = false
                document = doc
                addRecentFile(url)
            } catch {
                presentError(error)
            }
        } else {
            saveDocumentAs()
        }
    }

    func saveDocumentAs() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.saveDocumentAs()
            }
            return
        }
        guard let doc = document else { return }
        do {
            try validateDocument(doc)
        } catch {
            presentError(error)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try writeDocument(doc, to: url)
                var updated = doc
                updated.sourceURL = url
                updated.isDirty = false
                document = updated
                addRecentFile(url)
            } catch {
                presentError(error)
            }
        }
    }

    private func validateDocument(_ doc: SVGDocument) throws {
        guard doc.root.elementName == "svg" else {
            throw SVGValidationError.invalidRoot
        }
        try validateDimension(doc.root.attributes["width"], name: "width")
        try validateDimension(doc.root.attributes["height"], name: "height")
    }

    private func validateDimension(_ value: String?, name: String) throws {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SVGValidationError.missingDimension(name: name)
        }
        if Double(value) == nil {
            throw SVGValidationError.invalidDimension(name: name, value: value)
        }
    }
    
    func insertFromClipboard() {
        guard var doc = document else { return }
        do {
            let nodes = try clipboard.readNodes(mode: clipboardMode)
            pushUndoSnapshot(for: doc)
            let target = selectedNode(in: doc) ?? doc.root
            target.children.append(contentsOf: nodes)
            doc.isDirty = true
            document = doc
        } catch {
            presentError(error)
        }
    }

    func deleteSelection() {
        guard var doc = document, let selectedID = selectedNodeID else { return }
        if doc.root.id == selectedID {
            return
        }
        guard let parent = doc.root.findParent(of: selectedID),
              let index = parent.children.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        pushUndoSnapshot(for: doc)
        parent.children.remove(at: index)
        doc.isDirty = true
        document = doc
        selectedNodeID = parent.children.indices.contains(index) ? parent.children[index].id : parent.id
    }

    func moveSelectionUp() {
        moveSelection(by: -1)
    }

    func moveSelectionDown() {
        moveSelection(by: 1)
    }

    func indentSelection() {
        guard var doc = document, let selectedID = selectedNodeID else { return }
        guard let parent = doc.root.findParent(of: selectedID),
              let index = parent.children.firstIndex(where: { $0.id == selectedID }) else { return }
        if index == 0 { return }
        pushUndoSnapshot(for: doc)
        let newParent = parent.children[index - 1]
        let node = parent.children.remove(at: index)
        newParent.children.append(node)
        doc.isDirty = true
        document = doc
    }

    func outdentSelection() {
        guard var doc = document, let selectedID = selectedNodeID else { return }
        guard let parent = doc.root.findParent(of: selectedID),
              let grandParent = doc.root.findParent(of: parent.id),
              let parentIndex = grandParent.children.firstIndex(where: { $0.id == parent.id }) else { return }
        let nodeIndex = parent.children.firstIndex(where: { $0.id == selectedID })
        guard let nodeIndex else { return }
        pushUndoSnapshot(for: doc)
        let node = parent.children.remove(at: nodeIndex)
        grandParent.children.insert(node, at: parentIndex + 1)
        doc.isDirty = true
        document = doc
    }

    func createEmptyDocument() {
        let root = LayerNode(
            elementName: "svg",
            attributes: [
                "xmlns": "http://www.w3.org/2000/svg",
                "width": "100",
                "height": "100",
                "viewBox": "0 0 100 100"
            ]
        )
        document = SVGDocument(root: root)
        selectedNodeID = nil
        lastReferenceNodeID = nil
        resetUndoStack()
    }

    private func moveSelection(by offset: Int) {
        guard var doc = document, let selectedID = selectedNodeID else { return }
        guard let parent = doc.root.findParent(of: selectedID),
              let index = parent.children.firstIndex(where: { $0.id == selectedID }) else { return }
        let newIndex = index + offset
        if newIndex < 0 || newIndex >= parent.children.count { return }
        pushUndoSnapshot(for: doc)
        parent.children.swapAt(index, newIndex)
        doc.isDirty = true
        document = doc
    }

    private func selectedNode(in document: SVGDocument) -> LayerNode? {
        guard let selectedID = selectedNodeID else { return nil }
        return document.root.findNode(by: selectedID)
    }

    private func writeDocument(_ doc: SVGDocument, to url: URL) throws {
        let output = serializer.serialize(document: doc)
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }

    func moveNode(draggedID: UUID, targetID: UUID?) {
        guard var doc = document else { return }
        guard let draggedParent = doc.root.findParent(of: draggedID) else { return }
        guard let draggedIndex = draggedParent.children.firstIndex(where: { $0.id == draggedID }) else { return }
        let draggedNode = draggedParent.children[draggedIndex]

        let targetParent: LayerNode
        var targetIndex: Int

        if let targetID,
           let parent = doc.root.findParent(of: targetID),
           let index = parent.children.firstIndex(where: { $0.id == targetID }) {
            targetParent = parent
            targetIndex = index + 1
        } else {
            targetParent = doc.root
            targetIndex = targetParent.children.count
        }

        if draggedNode.contains(nodeID: targetParent.id) {
            return
        }

        pushUndoSnapshot(for: doc)
        draggedParent.children.remove(at: draggedIndex)
        if draggedParent.id == targetParent.id, targetIndex > draggedIndex {
            targetIndex -= 1
        }

        targetIndex = max(0, min(targetIndex, targetParent.children.count))
        targetParent.children.insert(draggedNode, at: targetIndex)
        doc.isDirty = true
        document = doc
    }

    func confirmCloseIfNeeded() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "You have unsaved changes. Do you want to close without saving?"
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func toggleVisibility(for nodeID: UUID) {
        guard var doc = document, let node = doc.root.findNode(by: nodeID) else { return }
        pushUndoSnapshot(for: doc)
        if node.attributes["display"] == "none" {
            node.attributes["display"] = "inline"
        } else {
            node.attributes["display"] = "none"
        }
        doc.isDirty = true
        document = doc
    }

    struct SVGPreviewPath: Identifiable {
        let id: UUID
        let elementName: String
        let attributes: [String: String]
        let d: String?
        let text: String?
        let fill: String?
        let stroke: String?
        let opacity: Double?
    }

    var previewViewBox: CGRect {
        guard let doc = document else { return CGRect(x: 0, y: 0, width: 100, height: 100) }
        if let viewBoxValue = doc.root.attributes["viewBox"], let rect = parseViewBox(viewBoxValue) {
            return rect
        }
        if let width = doc.root.attributes["width"], let height = doc.root.attributes["height"],
           let w = Double(width), let h = Double(height) {
            return CGRect(x: 0, y: 0, width: w, height: h)
        }
        return CGRect(x: 0, y: 0, width: 100, height: 100)
    }

    var previewPaths: [SVGPreviewPath] {
        guard let doc = document else { return [] }
        var result: [SVGPreviewPath] = []
        collectPreviewPaths(from: doc.root, inheritedHidden: false, into: &result)
        return result
    }

    func isHidden(_ node: LayerNode) -> Bool {
        node.attributes["display"] == "none"
    }

    var hasReferenceSelection: Bool {
        lastReferenceNodeID != nil
    }

    func alignSelectedToCanvas(_ mode: AlignmentMode) {
        alignSelected(to: previewViewBox, mode: mode)
    }

    func alignSelectedToReference(_ mode: AlignmentMode) {
        guard let doc = document, let referenceID = lastReferenceNodeID,
              let referenceNode = doc.root.findNode(by: referenceID),
              let referenceBounds = boundsForNode(referenceNode) else { return }
        alignSelected(to: referenceBounds, mode: mode)
    }

    private func alignSelected(to targetBounds: CGRect, mode: AlignmentMode) {
        guard let doc = document, let selectedID = selectedNodeID,
              let selectedNode = doc.root.findNode(by: selectedID),
              let selectedBounds = boundsForNode(selectedNode) else { return }

        var deltaX: CGFloat = 0
        var deltaY: CGFloat = 0

        switch mode {
        case .left:
            deltaX = targetBounds.minX - selectedBounds.minX
        case .right:
            deltaX = targetBounds.maxX - selectedBounds.maxX
        case .centerX:
            deltaX = targetBounds.midX - selectedBounds.midX
        case .top:
            deltaY = targetBounds.minY - selectedBounds.minY
        case .bottom:
            deltaY = targetBounds.maxY - selectedBounds.maxY
        case .centerY:
            deltaY = targetBounds.midY - selectedBounds.midY
        }

        if deltaX == 0 && deltaY == 0 { return }
        let transform = CGAffineTransform(translationX: deltaX, y: deltaY)
        transformElement(nodeID: selectedID, transform: transform)
    }

    enum AlignmentMode {
        case left
        case right
        case centerX
        case top
        case bottom
        case centerY
    }
}

extension SVGLayerEditorViewModel {
    private func loadRecentFiles() {
        let urls = UserDefaults.standard.array(forKey: recentKey) as? [String] ?? []
        recentFiles = urls.compactMap { URL(fileURLWithPath: $0) }
    }

    func addRecentFile(_ url: URL) {
        var paths = recentFiles.map { $0.path }
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > maxRecentCount {
            paths = Array(paths.prefix(maxRecentCount))
        }
        recentFiles = paths.map { URL(fileURLWithPath: $0) }
        UserDefaults.standard.set(paths, forKey: recentKey)
    }

    func syncSelectedNodeText() {
        guard let xml = selectedNodeXML else {
            if !selectedNodeXMLText.isEmpty || selectedNodeXMLError != nil {
                selectedNodeXMLText = ""
                selectedNodeXMLError = nil
            }
            return
        }
        if selectedNodeXMLText == xml && selectedNodeXMLError == nil {
            return
        }
        isApplyingEditorUpdate = true
        DispatchQueue.main.async {
            self.selectedNodeXMLText = xml
            self.selectedNodeXMLError = nil
            self.isApplyingEditorUpdate = false
        }
    }

    func syncDocumentText() {
        guard let doc = document else {
            if !documentXMLText.isEmpty || documentXMLError != nil {
                documentXMLText = ""
                documentXMLError = nil
            }
            return
        }
        let xml = serializer.serialize(document: doc)
        if documentXMLText == xml && documentXMLError == nil {
            return
        }
        isApplyingDocumentUpdate = true
        DispatchQueue.main.async {
            self.documentXMLText = xml
            self.documentXMLError = nil
            self.isApplyingDocumentUpdate = false
        }
    }

    func parseNode(from text: String) -> Result<LayerNode, Error> {
        if let nodes = try? SVGParser.parseFragment(from: text), nodes.count == 1 {
            return .success(nodes[0])
        }
        do {
            let doc = try SVGParser.parseDocument(from: text)
            if doc.root.elementName != "svg" {
                return .success(doc.root)
            }
            if doc.root.children.count == 1, let child = doc.root.children.first {
                return .success(child)
            }
            return .failure(SVGParseError.invalidFragment)
        } catch {
            return .failure(error)
        }
    }

    func parseViewBox(_ value: String) -> CGRect? {
        let parts = value.split { $0 == " " || $0 == "," }.map(String.init)
        guard parts.count == 4,
              let x = Double(parts[0]), let y = Double(parts[1]),
              let w = Double(parts[2]), let h = Double(parts[3]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func addRectangle() {
        addShape(elementName: "rect", attributes: defaultRectAttributes())
    }

    func addCircle() {
        addShape(elementName: "circle", attributes: defaultCircleAttributes())
    }

    func addEllipse() {
        addShape(elementName: "ellipse", attributes: defaultEllipseAttributes())
    }

    func addLine() {
        addShape(elementName: "line", attributes: defaultLineAttributes())
    }

    func addPolygon() {
        addShape(elementName: "polygon", attributes: defaultPolygonAttributes())
    }

    func addPolyline() {
        addShape(elementName: "polyline", attributes: defaultPolylineAttributes())
    }

    func addText() {
        addShape(elementName: "text", attributes: defaultTextAttributes(), text: "Text")
    }

    func addGroup() {
        addShape(elementName: "g", attributes: [:])
    }

    func setFillColor(_ color: Color) {
        lastFillHex = color.hexString
        updateSelectedAttributes { $0["fill"] = color.hexString }
    }

    func setStrokeColor(_ color: Color) {
        lastStrokeHex = color.hexString
        updateSelectedAttributes { $0["stroke"] = color.hexString }
    }

    private func addShape(elementName: String, attributes: [String: String], text: String? = nil) {
        guard var doc = document else { return }
        pushUndoSnapshot(for: doc)
        let node = LayerNode(elementName: elementName, attributes: attributes, text: text)
        let target = selectedNode(in: doc) ?? doc.root
        target.children.append(node)
        doc.isDirty = true
        document = doc
        selectedNodeID = node.id
    }

    private func updateSelectedAttributes(_ mutate: (inout [String: String]) -> Void) {
        guard var doc = document, let selectedID = selectedNodeID,
              let node = doc.root.findNode(by: selectedID) else { return }
        pushUndoSnapshot(for: doc)
        mutate(&node.attributes)
        doc.isDirty = true
        document = doc
    }

    private func defaultRectAttributes() -> [String: String] {
        let box = previewViewBox
        let w = max(box.width * 0.25, 10)
        let h = max(box.height * 0.25, 10)
        let x = box.midX - w / 2
        let y = box.midY - h / 2
        return [
            "x": format(x),
            "y": format(y),
            "width": format(w),
            "height": format(h),
            "rx": "0",
            "ry": "0",
            "fill": lastFillHex,
            "stroke": lastStrokeHex
        ]
    }

    private func defaultCircleAttributes() -> [String: String] {
        let box = previewViewBox
        let r = max(min(box.width, box.height) * 0.15, 8)
        return [
            "cx": format(box.midX),
            "cy": format(box.midY),
            "r": format(r),
            "fill": lastFillHex,
            "stroke": lastStrokeHex
        ]
    }

    private func defaultEllipseAttributes() -> [String: String] {
        let box = previewViewBox
        let rx = max(box.width * 0.18, 8)
        let ry = max(box.height * 0.12, 8)
        return [
            "cx": format(box.midX),
            "cy": format(box.midY),
            "rx": format(rx),
            "ry": format(ry),
            "fill": lastFillHex,
            "stroke": lastStrokeHex
        ]
    }

    private func defaultLineAttributes() -> [String: String] {
        let box = previewViewBox
        return [
            "x1": format(box.midX - box.width * 0.15),
            "y1": format(box.midY),
            "x2": format(box.midX + box.width * 0.15),
            "y2": format(box.midY),
            "stroke": lastStrokeHex,
            "stroke-width": "2",
            "fill": "none"
        ]
    }

    private func defaultPolygonAttributes() -> [String: String] {
        let box = previewViewBox
        let w = max(box.width * 0.18, 10)
        let h = max(box.height * 0.18, 10)
        let cx = box.midX
        let cy = box.midY
        let p1 = "\(format(cx)) \(format(cy - h))"
        let p2 = "\(format(cx + w)) \(format(cy + h))"
        let p3 = "\(format(cx - w)) \(format(cy + h))"
        return [
            "points": "\(p1) \(p2) \(p3)",
            "fill": lastFillHex,
            "stroke": lastStrokeHex
        ]
    }

    private func defaultPolylineAttributes() -> [String: String] {
        let box = previewViewBox
        let w = max(box.width * 0.2, 12)
        let h = max(box.height * 0.12, 12)
        let cx = box.midX
        let cy = box.midY
        let p1 = "\(format(cx - w)) \(format(cy - h))"
        let p2 = "\(format(cx)) \(format(cy + h))"
        let p3 = "\(format(cx + w)) \(format(cy - h))"
        return [
            "points": "\(p1) \(p2) \(p3)",
            "stroke": lastStrokeHex,
            "stroke-width": "2",
            "fill": "none"
        ]
    }

    private func defaultTextAttributes() -> [String: String] {
        let box = previewViewBox
        return [
            "x": format(box.midX),
            "y": format(box.midY),
            "font-size": "18",
            "fill": lastFillHex
        ]
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }
}

private extension Color {
    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    init?(svg value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("#") {
            self.init(hex: trimmed)
            return
        }
        if trimmed.hasPrefix("rgb(") && trimmed.hasSuffix(")") {
            let inner = trimmed.dropFirst(4).dropLast()
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3,
                  let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
            self = Color(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: 1.0)
            return
        }
        switch trimmed {
        case "black": self = .black
        case "white": self = .white
        case "red": self = .red
        case "green": self = .green
        case "blue": self = .blue
        case "gray", "grey": self = .gray
        case "yellow": self = .yellow
        case "cyan": self = .cyan
        case "magenta": self = Color(.sRGB, red: 1.0, green: 0.0, blue: 1.0, opacity: 1.0)
        case "orange": self = Color(.sRGB, red: 1.0, green: 0.55, blue: 0.0, opacity: 1.0)
        default: return nil
        }
    }

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        let length = value.count
        guard length == 6 || length == 8 else { return nil }

        var hexNumber: UInt64 = 0
        let scanner = Scanner(string: value)
        guard scanner.scanHexInt64(&hexNumber) else { return nil }

        let r, g, b, a: Double
        if length == 6 {
            r = Double((hexNumber & 0xFF0000) >> 16) / 255.0
            g = Double((hexNumber & 0x00FF00) >> 8) / 255.0
            b = Double(hexNumber & 0x0000FF) / 255.0
            a = 1.0
        } else {
            r = Double((hexNumber & 0xFF000000) >> 24) / 255.0
            g = Double((hexNumber & 0x00FF0000) >> 16) / 255.0
            b = Double((hexNumber & 0x0000FF00) >> 8) / 255.0
            a = Double(hexNumber & 0x000000FF) / 255.0
        }

        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

private enum SVGValidationError: LocalizedError {
    case invalidRoot
    case missingDimension(name: String)
    case invalidDimension(name: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "Root element must be <svg>."
        case .missingDimension(let name):
            return "Missing SVG \(name)."
        case .invalidDimension(let name, let value):
            return "Invalid SVG \(name): \(value)."
        }
    }
}

extension SVGLayerEditorViewModel {
    private func collectPreviewPaths(from node: LayerNode, inheritedHidden: Bool, into result: inout [SVGPreviewPath]) {
        let isNodeHidden = inheritedHidden || isHidden(node)
        let drawable = ["path", "rect", "circle", "ellipse", "line", "polygon", "polyline", "text"]
        if drawable.contains(node.elementName), !isNodeHidden {
            let opacityValue = Double(node.attributes["opacity"] ?? "") ?? Double(node.attributes["fill-opacity"] ?? "")
            result.append(SVGPreviewPath(
                id: node.id,
                elementName: node.elementName,
                attributes: node.attributes,
                d: node.attributes["d"],
                text: node.text,
                fill: node.attributes["fill"],
                stroke: node.attributes["stroke"],
                opacity: opacityValue
            ))
        }
        for child in node.children {
            collectPreviewPaths(from: child, inheritedHidden: isNodeHidden, into: &result)
        }
    }

    func transformPath(nodeID: UUID, transform: CGAffineTransform) {
        guard var doc = document, let node = doc.root.findNode(by: nodeID) else { return }
        guard let d = node.attributes["d"], let path = SVGPathParser.toPath(d) else { return }
        pushUndoSnapshot(for: doc)
        var mutableTransform = transform
        let transformed = path.copy(using: &mutableTransform) ?? path
        let newD = SVGPathParser.serialize(path: transformed)
        node.attributes["d"] = newD
        doc.isDirty = true
        document = doc
    }

    func transformElement(nodeID: UUID, transform: CGAffineTransform) {
        guard var doc = document, let node = doc.root.findNode(by: nodeID) else { return }
        pushUndoSnapshot(for: doc)
        switch node.elementName {
        case "path":
            guard let d = node.attributes["d"], let path = SVGPathParser.toPath(d) else { return }
            var mutableTransform = transform
            let transformed = path.copy(using: &mutableTransform) ?? path
            node.attributes["d"] = SVGPathParser.serialize(path: transformed)
        case "rect":
            guard let rect = readRect(from: node.attributes) else { return }
            let newRect = transformRect(rect, by: transform)
            node.attributes["x"] = format(newRect.origin.x)
            node.attributes["y"] = format(newRect.origin.y)
            node.attributes["width"] = format(newRect.width)
            node.attributes["height"] = format(newRect.height)
        case "circle":
            guard let cx = number(node.attributes["cx"]),
                  let cy = number(node.attributes["cy"]),
                  let r = number(node.attributes["r"]) else { return }
            let center = CGPoint(x: cx, y: cy).applying(transform)
            let sx = abs(transform.a)
            let sy = abs(transform.d)
            let scale = max(sx, sy)
            node.attributes["cx"] = format(center.x)
            node.attributes["cy"] = format(center.y)
            node.attributes["r"] = format(r * scale)
        case "ellipse":
            guard let cx = number(node.attributes["cx"]),
                  let cy = number(node.attributes["cy"]),
                  let rx = number(node.attributes["rx"]),
                  let ry = number(node.attributes["ry"]) else { return }
            let center = CGPoint(x: cx, y: cy).applying(transform)
            let sx = abs(transform.a)
            let sy = abs(transform.d)
            node.attributes["cx"] = format(center.x)
            node.attributes["cy"] = format(center.y)
            node.attributes["rx"] = format(rx * sx)
            node.attributes["ry"] = format(ry * sy)
        case "line":
            guard let x1 = number(node.attributes["x1"]),
                  let y1 = number(node.attributes["y1"]),
                  let x2 = number(node.attributes["x2"]),
                  let y2 = number(node.attributes["y2"]) else { return }
            let p1 = CGPoint(x: x1, y: y1).applying(transform)
            let p2 = CGPoint(x: x2, y: y2).applying(transform)
            node.attributes["x1"] = format(p1.x)
            node.attributes["y1"] = format(p1.y)
            node.attributes["x2"] = format(p2.x)
            node.attributes["y2"] = format(p2.y)
        case "polygon", "polyline":
            guard let points = node.attributes["points"], let list = parsePoints(points) else { return }
            let transformed = list.map { $0.applying(transform) }
            node.attributes["points"] = serializePoints(transformed)
        case "text":
            guard let x = number(node.attributes["x"]),
                  let y = number(node.attributes["y"]) else { return }
            let p = CGPoint(x: x, y: y).applying(transform)
            node.attributes["x"] = format(p.x)
            node.attributes["y"] = format(p.y)
        default:
            return
        }
        doc.isDirty = true
        document = doc
    }

    private func number(_ value: String?) -> CGFloat? {
        guard let value, let d = Double(value) else { return nil }
        return CGFloat(d)
    }

    private func readRect(from attrs: [String: String]) -> CGRect? {
        guard let x = number(attrs["x"]),
              let y = number(attrs["y"]),
              let w = number(attrs["width"]),
              let h = number(attrs["height"]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func transformRect(_ rect: CGRect, by transform: CGAffineTransform) -> CGRect {
        let p1 = CGPoint(x: rect.minX, y: rect.minY).applying(transform)
        let p2 = CGPoint(x: rect.maxX, y: rect.maxY).applying(transform)
        let minX = min(p1.x, p2.x)
        let minY = min(p1.y, p2.y)
        let maxX = max(p1.x, p2.x)
        let maxY = max(p1.y, p2.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func parsePoints(_ value: String) -> [CGPoint]? {
        let parts = value
            .split { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }
            .map(String.init)
        if parts.count < 2 { return nil }
        var points: [CGPoint] = []
        var index = 0
        while index + 1 < parts.count {
            if let x = Double(parts[index]), let y = Double(parts[index + 1]) {
                points.append(CGPoint(x: x, y: y))
            }
            index += 2
        }
        return points.isEmpty ? nil : points
    }

    func serializePoints(_ points: [CGPoint]) -> String {
        points.map { "\(format($0.x)) \(format($0.y))" }.joined(separator: " ")
    }

    func rotateSelected(by degrees: CGFloat) {
        guard let doc = document, let selectedID = selectedNodeID,
              let node = doc.root.findNode(by: selectedID),
              let bounds = boundsForNode(node) else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radians = degrees * .pi / 180.0
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)
        transformElement(nodeID: selectedID, transform: transform)
    }

    private func boundsForNode(_ node: LayerNode) -> CGRect? {
        switch node.elementName {
        case "path":
            guard let d = node.attributes["d"], let path = SVGPathParser.toPath(d) else { return nil }
            return path.boundingBoxOfPath
        case "rect":
            return readRect(from: node.attributes)
        case "circle":
            guard let cx = number(node.attributes["cx"]),
                  let cy = number(node.attributes["cy"]),
                  let r = number(node.attributes["r"]) else { return nil }
            return CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        case "ellipse":
            guard let cx = number(node.attributes["cx"]),
                  let cy = number(node.attributes["cy"]),
                  let rx = number(node.attributes["rx"]),
                  let ry = number(node.attributes["ry"]) else { return nil }
            return CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        case "line":
            guard let x1 = number(node.attributes["x1"]),
                  let y1 = number(node.attributes["y1"]),
                  let x2 = number(node.attributes["x2"]),
                  let y2 = number(node.attributes["y2"]) else { return nil }
            return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        case "polygon", "polyline":
            guard let points = node.attributes["points"], let list = parsePoints(points), !list.isEmpty else { return nil }
            var bounds = CGRect.null
            for point in list {
                bounds = bounds.isNull ? CGRect(origin: point, size: .zero) : bounds.union(CGRect(origin: point, size: .zero))
            }
            return bounds
        case "text":
            guard let x = number(node.attributes["x"]),
                  let y = number(node.attributes["y"]) else { return nil }
            return CGRect(x: x, y: y, width: 1, height: 1)
        default:
            return nil
        }
    }

    func rootAttribute(_ key: String) -> String {
        document?.root.attributes[key] ?? ""
    }

    func setRootAttribute(_ key: String, value: String) {
        guard var doc = document else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        pushUndoSnapshot(for: doc)
        if trimmed.isEmpty {
            doc.root.attributes.removeValue(forKey: key)
        } else {
            doc.root.attributes[key] = trimmed
        }
        doc.isDirty = true
        document = doc
    }

    func nodePath(for nodeID: UUID, in document: SVGDocument) -> [Int]? {
        if document.root.id == nodeID {
            return []
        }
        return nodePath(for: nodeID, in: document.root)
    }

    func nodeID(for path: [Int], in document: SVGDocument) -> UUID? {
        if path.isEmpty {
            return document.root.id
        }
        var node = document.root
        for index in path {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node.id
    }

    private func nodePath(for nodeID: UUID, in node: LayerNode) -> [Int]? {
        for (index, child) in node.children.enumerated() {
            if child.id == nodeID {
                return [index]
            }
            if let childPath = nodePath(for: nodeID, in: child) {
                return [index] + childPath
            }
        }
        return nil
    }
}
