import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SVGLayerEditorViewModel: ObservableObject {
    @Published var document: SVGDocument? {
        didSet {
            documentVersion &+= 1
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
    @Published var alertTitle = "Error"
    @Published var errorMessage: String?
    @Published var isShowingError = false
    @Published private(set) var recentFiles: [URL] = []
    @Published var selectedNodeXMLText: String = ""
    @Published var selectedNodeXMLError: String?
    @Published var documentXMLText: String = ""
    @Published var documentXMLError: String?

    /// Canvas size of new documents. 1024 × 1024 is the Icon Composer canvas.
    nonisolated static let defaultDocumentSize: CGFloat = 1024

    private var lastFillHex: String = "#4F8CFF"
    private var lastStrokeHex: String = "#1C1C1C"

    private struct UndoSnapshot {
        let document: SVGDocument
        let selectedNodeID: UUID?
    }

    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    private let maxUndoCount = 100
    /// Continuous edits (dragging, color panel) with the same key form one undo step.
    private var undoCoalescingKey: String?
    private var undoCoalescingDate = Date.distantPast

    private let clipboard = ClipboardService()
    private let serializer = SVGSerializer()
    private var isApplyingEditorUpdate = false
    private var isApplyingDocumentUpdate = false
    private var isEditorSyncScheduled = false
    /// The user already answered the unsaved-changes prompt when closing the window.
    private var changesDiscardedForClose = false

    private var lastReferenceNodeID: UUID?

    /// Bumped on every document assignment; keys the render scene caches.
    private var documentVersion = 0
    private var previewSceneCache: (version: Int, scene: SVGRenderScene)?
    private var geometrySceneCache: (version: Int, scene: SVGRenderScene)?

    private struct RecentEntry {
        let url: URL
        let bookmark: Data?
    }

    private let recentKey = "recentSVGDocuments"
    private let legacyRecentKey = "recentSVGFiles"
    private let maxRecentCount = 10
    private var recentEntries: [RecentEntry] = [] {
        didSet { recentFiles = recentEntries.map(\.url) }
    }
    /// Security-scoped URL of the open document (recent files in the sandbox).
    private var securityScopedURL: URL?

    init() {
        loadRecentFiles()
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
        var filteredDoc = doc
        filteredDoc.root = filteredRoot
        let svg = serializer.serialize(document: filteredDoc)
        return svg.data(using: String.Encoding.utf8)
    }

    private func makeFilteredNode(from node: LayerNode) -> LayerNode {
        let filteredChildren = node.children.compactMap { child -> LayerNode? in
            if isHidden(child) { return nil }
            return makeFilteredNode(from: child)
        }
        return node.withChildren(filteredChildren)
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
        resolvedPaintColor(fill: true)
    }

    var selectedStrokeColor: Color? {
        resolvedPaintColor(fill: false)
    }

    private func resolvedPaintColor(fill: Bool) -> Color? {
        guard let selectedID = selectedNodeID,
              let item = geometryScene?.items.first(where: { $0.id == selectedID }) else { return nil }
        guard case .color(var color) = fill ? item.fill : item.stroke else { return nil }
        color.alpha *= fill ? item.fillOpacity : item.strokeOpacity
        return color.swiftUIColor
    }

    // MARK: Undo
    //
    // Snapshots live in undoStack/redoStack. Every step is mirrored into the window's
    // UndoManager, so the standard Edit menu, the responder chain and the XML text views
    // (which have their own UndoManager for typing) all behave like in other Mac apps.

    /// The window's undo manager (set by ContentView).
    weak var undoManager: UndoManager? {
        didSet {
            guard oldValue !== undoManager else { return }
            oldValue?.removeAllActions(withTarget: self)
            undoManager?.levelsOfUndo = maxUndoCount
            // Steps recorded before the manager was known cannot be mirrored.
            resetUndoStack()
        }
    }

    func undo() {
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
        } else {
            performUndo()
        }
    }

    func redo() {
        if let undoManager, undoManager.canRedo {
            undoManager.redo()
        } else {
            performRedo()
        }
    }

    private func performUndo() {
        guard let snapshot = undoStack.popLast() else { return }
        undoCoalescingKey = nil
        if let doc = document {
            redoStack.append(UndoSnapshot(document: doc.deepCopy(), selectedNodeID: selectedNodeID))
            if redoStack.count > maxUndoCount {
                redoStack.removeFirst()
            }
            // Registered while undoing, so the UndoManager records it as the redo step.
            undoManager?.registerUndo(withTarget: self) { viewModel in
                viewModel.performRedo()
            }
        }
        document = snapshot.document
        selectedNodeID = snapshot.selectedNodeID
    }

    private func performRedo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoCoalescingKey = nil
        if let doc = document {
            undoStack.append(UndoSnapshot(document: doc.deepCopy(), selectedNodeID: selectedNodeID))
            if undoStack.count > maxUndoCount {
                undoStack.removeFirst()
            }
            undoManager?.registerUndo(withTarget: self) { viewModel in
                viewModel.performUndo()
            }
        }
        document = snapshot.document
        selectedNodeID = snapshot.selectedNodeID
    }

    private func pushUndoSnapshot(for doc: SVGDocument, coalescingKey: String? = nil) {
        let now = Date()
        if let coalescingKey, coalescingKey == undoCoalescingKey, now.timeIntervalSince(undoCoalescingDate) < 2 {
            undoCoalescingDate = now
            return
        }
        undoCoalescingKey = coalescingKey
        undoCoalescingDate = now

        undoStack.append(UndoSnapshot(document: doc.deepCopy(), selectedNodeID: selectedNodeID))
        if undoStack.count > maxUndoCount {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        undoManager?.registerUndo(withTarget: self) { viewModel in
            viewModel.performUndo()
        }
    }

    /// Ends a continuous edit (e.g. a drag), so the next one gets its own undo step.
    func endInteractiveChange() {
        undoCoalescingKey = nil
        flushEditorSync()
    }

    private var isInteractiveChange: Bool {
        undoCoalescingKey != nil && Date().timeIntervalSince(undoCoalescingDate) < 2
    }

    private func resetUndoStack() {
        undoStack = []
        redoStack = []
        undoCoalescingKey = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: XML editors

    func applySelectedNodeXMLText(_ text: String) {
        guard !isApplyingEditorUpdate else { return }
        guard var doc = document, let selectedID = selectedNodeID,
              let existingNode = doc.root.findNode(by: selectedID) else { return }

        if existingNode === doc.root {
            // The root's raw XML is the whole document.
            do {
                let parsed = try SVGParser.parseDocument(from: text)
                if serializer.serialize(node: parsed.root) == serializer.serialize(node: doc.root) {
                    selectedNodeXMLError = nil
                    return
                }
                pushUndoSnapshot(for: doc)
                doc.root = parsed.root.withID(selectedID)
                selectedNodeXMLError = nil
                doc.isDirty = true
                document = doc
                syncSelectedNodeText()
            } catch {
                selectedNodeXMLError = error.localizedDescription
            }
            return
        }

        guard let parent = doc.root.findParent(of: selectedID),
              let index = parent.children.firstIndex(where: { $0.id == selectedID }) else { return }

        switch parseNode(from: text) {
        case .failure(let error):
            selectedNodeXMLError = error.localizedDescription
        case .success(let parsedNode):
            if serializer.serialize(node: existingNode) == serializer.serialize(node: parsedNode) {
                selectedNodeXMLError = nil
                return
            }

            pushUndoSnapshot(for: doc)
            let newNode = parsedNode.withID(selectedID)
            selectedNodeXMLError = nil
            parent.children[index] = newNode
            doc.isDirty = true
            document = doc
            syncSelectedNodeText()
        }
    }

    func applyDocumentXMLText(_ text: String) {
        guard !isApplyingDocumentUpdate else { return }
        guard let currentDoc = document else { return }
        let selectionPath = selectedNodeID.flatMap { nodePath(for: $0, in: currentDoc) }
        do {
            var parsed = try SVGParser.parseDocument(from: text)
            if serializer.serialize(document: parsed) == serializer.serialize(document: currentDoc) {
                documentXMLError = nil
                return
            }
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
        // A pending refresh means the editor shows an outdated document; applying it would revert changes.
        guard !isEditorSyncScheduled else { flushEditorSync(); return }
        applyDocumentXMLText(documentXMLText)
    }

    func applySelectedNodeXMLFromEditor() {
        guard !isEditorSyncScheduled else { flushEditorSync(); return }
        applySelectedNodeXMLText(selectedNodeXMLText)
    }

    // MARK: Files

    /// Asks before unsaved changes would be lost. Returns false if the user cancels.
    func confirmDiscardChangesIfNeeded() -> Bool {
        guard isDirty, !changesDiscardedForClose else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to \u{201C}\(documentDisplayName)\u{201D}?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDocument()
            return !isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Window close. Closing the window quits the app, so the answer also covers termination.
    func confirmCloseIfNeeded() -> Bool {
        guard confirmDiscardChangesIfNeeded() else { return false }
        changesDiscardedForClose = true
        return true
    }

    private var documentDisplayName: String {
        document?.sourceURL?.lastPathComponent ?? "Untitled"
    }

    func newDocument(size: CGFloat = defaultDocumentSize) {
        guard confirmDiscardChangesIfNeeded() else { return }
        createEmptyDocument(size: size)
    }

    func openDocument() {
        guard confirmDiscardChangesIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            loadDocument(at: url, securityScoped: false)
        }
    }

    /// Opens a file (drag & drop), asking first if there are unsaved changes.
    func openDocument(at url: URL) {
        guard confirmDiscardChangesIfNeeded() else { return }
        loadDocument(at: url, securityScoped: false)
    }

    func openRecent(_ url: URL) {
        guard confirmDiscardChangesIfNeeded() else { return }
        guard let entry = recentEntries.first(where: { $0.url == url }), let bookmark = entry.bookmark else {
            loadDocument(at: url, securityScoped: false)
            return
        }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            loadDocument(at: url, securityScoped: false)
            return
        }
        let didStartAccess = resolved.startAccessingSecurityScopedResource()
        loadDocument(at: resolved, securityScoped: didStartAccess)
    }

    private func loadDocument(at url: URL, securityScoped: Bool) {
        do {
            let data = try Data(contentsOf: url)
            var doc = try SVGParser.parseDocument(from: data)
            doc.sourceURL = url
            doc.isDirty = false
            replaceSecurityScope(with: securityScoped ? url : nil)
            document = doc
            lastReferenceNodeID = nil
            selectedNodeID = doc.root.id
            resetUndoStack()
            addRecentFile(url)
        } catch {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            presentError(error)
        }
    }

    private func replaceSecurityScope(with url: URL?) {
        if let current = securityScopedURL, current != url {
            current.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = url
    }

    func clearRecentFiles() {
        recentEntries = []
        UserDefaults.standard.removeObject(forKey: recentKey)
        UserDefaults.standard.removeObject(forKey: legacyRecentKey)
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
        guard let doc = document else { return }
        do {
            try validateDocument(doc)
        } catch {
            presentError(error)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = doc.sourceURL?.lastPathComponent ?? "Untitled.svg"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try writeDocument(doc, to: url)
                var updated = doc
                updated.sourceURL = url
                updated.isDirty = false
                replaceSecurityScope(with: nil)
                document = updated
                addRecentFile(url)
            } catch {
                presentError(error)
            }
        }
    }

    /// Writes the document as an Icon Composer `.icon` bundle (one SVG per layer + icon.json).
    func exportIconComposer() {
        guard let doc = document else { return }
        do {
            try validateDocument(doc)
            let export = try IconComposerExport(document: doc, isHidden: isHidden)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "icon", conformingTo: .package) ?? .package]
            panel.nameFieldStringValue = (doc.sourceURL?.deletingPathExtension().lastPathComponent ?? "AppIcon") + ".icon"
            panel.message = "Top-level groups become Icon Composer groups; their children become layers."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try export.write(to: url)
            if export.groups.count > IconComposerExport.recommendedMaxGroups {
                presentMessage(
                    title: "Exported \(export.groups.count) Groups",
                    message: "Icon Composer works best with up to \(IconComposerExport.recommendedMaxGroups) groups. "
                        + "Combine top-level elements into <g> groups to reduce the number of groups."
                )
            }
        } catch {
            presentError(error)
        }
    }

    private func validateDocument(_ doc: SVGDocument) throws {
        guard doc.root.elementName == "svg" else {
            throw SVGValidationError.invalidRoot
        }
        let attributes = doc.root.attributes
        for name in ["width", "height"] {
            if let value = attributes[name], !Self.isValidLength(value) {
                throw SVGValidationError.invalidDimension(name: name, value: value)
            }
        }
        if let viewBox = attributes["viewBox"] {
            guard SVGViewBox.parse(viewBox) != nil else {
                throw SVGValidationError.invalidViewBox(value: viewBox)
            }
        } else if SVGViewBox.canvas(of: attributes) == nil {
            // Apple's icon assets only carry a viewBox; width/height alone are fine too.
            throw SVGValidationError.missingCanvas
        }
    }

    private static func isValidLength(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            return Double(trimmed.dropLast()) != nil
        }
        return SVGLength.parse(trimmed) != nil
    }

    // MARK: Structure

    func insertFromClipboard() {
        guard var doc = document else { return }
        do {
            let nodes = try clipboard.readNodes(mode: clipboardMode)
            pushUndoSnapshot(for: doc)
            let (target, index) = insertionPoint(in: doc)
            target.children.insert(contentsOf: nodes, at: index)
            doc.isDirty = true
            document = doc
            if let first = nodes.first {
                selectedNodeID = first.id
            }
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

    var canIndentSelection: Bool {
        guard let doc = document, let selectedID = selectedNodeID,
              let parent = doc.root.findParent(of: selectedID),
              let index = parent.children.firstIndex(where: { $0.id == selectedID }), index > 0 else { return false }
        return SVGShapeGeometry.containerElements.contains(parent.children[index - 1].elementName)
    }

    /// Moves the selection into the preceding sibling group.
    func indentSelection() {
        guard canIndentSelection, var doc = document, let selectedID = selectedNodeID,
              let parent = doc.root.findParent(of: selectedID),
              let index = parent.children.firstIndex(where: { $0.id == selectedID }) else { return }
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
              let parentIndex = grandParent.children.firstIndex(where: { $0.id == parent.id }),
              let nodeIndex = parent.children.firstIndex(where: { $0.id == selectedID }) else { return }
        pushUndoSnapshot(for: doc)
        let node = parent.children.remove(at: nodeIndex)
        grandParent.children.insert(node, at: parentIndex + 1)
        doc.isDirty = true
        document = doc
    }

    func createEmptyDocument(size: CGFloat = defaultDocumentSize) {
        let side = SVGFormat.number(max(size, 1))
        let root = LayerNode(
            elementName: "svg",
            attributes: [
                "xmlns": SVGSerializer.svgNamespace,
                "width": side,
                "height": side,
                "viewBox": "0 0 \(side) \(side)"
            ]
        )
        replaceSecurityScope(with: nil)
        document = SVGDocument(root: root)
        lastReferenceNodeID = nil
        selectedNodeID = root.id
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

    /// New content goes into the selected group, or right after the selected element.
    private func insertionPoint(in doc: SVGDocument) -> (parent: LayerNode, index: Int) {
        if let selected = selectedNode(in: doc) {
            if SVGShapeGeometry.containerElements.contains(selected.elementName) {
                return (selected, selected.children.count)
            }
            if let parent = doc.root.findParent(of: selected.id),
               let index = parent.children.firstIndex(where: { $0.id == selected.id }) {
                return (parent, index + 1)
            }
        }
        return (doc.root, doc.root.children.count)
    }

    private func writeDocument(_ doc: SVGDocument, to url: URL) throws {
        let output = serializer.serialize(document: doc)
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private func presentError(_ error: Error) {
        presentMessage(title: "Error", message: error.localizedDescription)
    }

    private func presentMessage(title: String, message: String) {
        alertTitle = title
        errorMessage = message
        isShowingError = true
    }

    func moveNode(draggedID: UUID, targetID: UUID?) {
        guard var doc = document, draggedID != targetID else { return }
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

    func toggleVisibility(for nodeID: UUID) {
        guard var doc = document, let node = doc.root.findNode(by: nodeID) else { return }
        pushUndoSnapshot(for: doc)
        if isHidden(node) {
            // Remove instead of writing display="inline", which only adds noise to the file.
            SVGStyle.set("display", to: nil, in: &node.attributes)
            node.attributes.removeValue(forKey: "display")
        } else {
            SVGStyle.set("display", to: "none", in: &node.attributes)
        }
        doc.isDirty = true
        document = doc
    }

    // MARK: Preview

    var previewViewBox: CGRect {
        guard let doc = document else { return CGRect(x: 0, y: 0, width: 100, height: 100) }
        return SVGViewBox.canvas(of: doc.root.attributes) ?? CGRect(x: 0, y: 0, width: 100, height: 100)
    }

    /// Paint-ready content of the visible layers.
    var previewScene: SVGRenderScene? {
        guard let doc = document else { return nil }
        if let cache = previewSceneCache, cache.version == documentVersion {
            return cache.scene
        }
        let scene = SVGRenderScene(root: doc.root, canvas: previewViewBox, isHidden: isHidden)
        previewSceneCache = (documentVersion, scene)
        return scene
    }

    /// Like `previewScene`, but including hidden layers (bounds for align/rotate).
    private var geometryScene: SVGRenderScene? {
        guard let doc = document else { return nil }
        if let cache = geometrySceneCache, cache.version == documentVersion {
            return cache.scene
        }
        let scene = SVGRenderScene(root: doc.root, canvas: previewViewBox, isHidden: { _ in false })
        geometrySceneCache = (documentVersion, scene)
        return scene
    }

    func isHidden(_ node: LayerNode) -> Bool {
        SVGStyle.value("display", in: node.attributes)?.trimmingCharacters(in: .whitespaces) == "none"
    }

    var hasReferenceSelection: Bool {
        guard let referenceID = lastReferenceNodeID else { return false }
        return document?.root.findNode(by: referenceID) != nil
    }

    func alignSelectedToCanvas(_ mode: AlignmentMode) {
        alignSelected(to: previewViewBox, mode: mode)
    }

    func alignSelectedToReference(_ mode: AlignmentMode) {
        guard let referenceID = lastReferenceNodeID,
              let referenceBounds = canvasBounds(of: referenceID) else { return }
        alignSelected(to: referenceBounds, mode: mode)
    }

    private func alignSelected(to targetBounds: CGRect, mode: AlignmentMode) {
        guard let selectedID = selectedNodeID,
              let selectedBounds = canvasBounds(of: selectedID) else { return }

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

        if abs(deltaX) < 1e-9 && abs(deltaY) < 1e-9 { return }
        transformElement(nodeID: selectedID, transform: CGAffineTransform(translationX: deltaX, y: deltaY))
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

// MARK: - Recent files, editor sync, parsing helpers

extension SVGLayerEditorViewModel {
    private func loadRecentFiles() {
        let defaults = UserDefaults.standard
        if let stored = defaults.array(forKey: recentKey) as? [[String: Any]] {
            recentEntries = stored.compactMap { entry in
                guard let path = entry["path"] as? String else { return nil }
                return RecentEntry(url: URL(fileURLWithPath: path), bookmark: entry["bookmark"] as? Data)
            }
        } else {
            // Paths stored by version 1.0.x. Without a bookmark they can only be reopened outside the sandbox.
            let paths = defaults.array(forKey: legacyRecentKey) as? [String] ?? []
            recentEntries = paths.map { RecentEntry(url: URL(fileURLWithPath: $0), bookmark: nil) }
        }
    }

    func addRecentFile(_ url: URL) {
        // A security-scoped bookmark lets the sandboxed app reopen the file after relaunch.
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var entries = recentEntries.filter { $0.url.standardizedFileURL.path != url.standardizedFileURL.path }
        entries.insert(RecentEntry(url: url, bookmark: bookmark), at: 0)
        recentEntries = Array(entries.prefix(maxRecentCount))
        let stored: [[String: Any]] = recentEntries.map { entry in
            var value: [String: Any] = ["path": entry.url.path]
            if let bookmark = entry.bookmark { value["bookmark"] = bookmark }
            return value
        }
        UserDefaults.standard.set(stored, forKey: recentKey)
    }

    func syncSelectedNodeText() {
        if scheduleEditorSyncIfInteractive() { return }
        performSelectedNodeTextSync()
    }

    func syncDocumentText() {
        if scheduleEditorSyncIfInteractive() { return }
        performDocumentTextSync()
    }

    /// During drags and color-panel changes the document changes many times per second.
    /// Re-serializing it into the editors each time is expensive for large files, so the
    /// editors are refreshed at most every 0.25 s and once more when the change ends.
    private func scheduleEditorSyncIfInteractive() -> Bool {
        guard isInteractiveChange else { return false }
        if !isEditorSyncScheduled {
            isEditorSyncScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.isEditorSyncScheduled else { return }
                self.flushEditorSync()
            }
        }
        return true
    }

    /// Brings both XML editors up to date immediately if a refresh is pending.
    func flushEditorSync() {
        guard isEditorSyncScheduled else { return }
        isEditorSyncScheduled = false
        performDocumentTextSync()
        performSelectedNodeTextSync()
    }

    private func performSelectedNodeTextSync() {
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

    private func performDocumentTextSync() {
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

// MARK: - Shapes and colors

extension SVGLayerEditorViewModel {
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
        setPaint("fill", color: color)
    }

    func setStrokeColor(_ color: Color) {
        setPaint("stroke", color: color)
    }

    private func setPaint(_ property: String, color: Color) {
        guard let selectedID = selectedNodeID, let svgColor = SVGColor(color) else { return }
        let hex = svgColor.hexString
        if property == "fill" { lastFillHex = hex } else { lastStrokeHex = hex }
        updateSelectedAttributes(coalescingKey: "\(property):\(selectedID)") { attributes in
            SVGStyle.set(property, to: hex, in: &attributes)
            let opacity = svgColor.alpha < 0.999 ? SVGFormat.number(CGFloat(svgColor.alpha), fractionDigits: 3) : nil
            SVGStyle.set("\(property)-opacity", to: opacity, in: &attributes)
        }
    }

    private func addShape(elementName: String, attributes: [String: String], text: String? = nil) {
        guard var doc = document else { return }
        pushUndoSnapshot(for: doc)
        let (target, index) = insertionPoint(in: doc)
        var attributes = attributes
        // Default positions are canvas coordinates; compensate a transformed target group.
        if let parentCTM = SVGShapeGeometry.parentTransform(of: target.id, in: doc.root) {
            let targetCTM = SVGShapeGeometry.localTransform(of: target, isDocumentRoot: target === doc.root)
                .concatenating(parentCTM)
            if !targetCTM.isIdentity, let transform = SVGTransform.format(targetCTM.inverted()) {
                attributes["transform"] = transform
            }
        }
        let node = LayerNode(elementName: elementName, attributes: attributes, text: text)
        target.children.insert(node, at: index)
        doc.isDirty = true
        document = doc
        selectedNodeID = node.id
    }

    private func updateSelectedAttributes(coalescingKey: String? = nil, _ mutate: (inout [String: String]) -> Void) {
        guard var doc = document, let selectedID = selectedNodeID,
              let node = doc.root.findNode(by: selectedID) else { return }
        var attributes = node.attributes
        mutate(&attributes)
        guard attributes != node.attributes else { return }
        pushUndoSnapshot(for: doc, coalescingKey: coalescingKey)
        node.attributes = attributes
        doc.isDirty = true
        document = doc
    }

    private func defaultRectAttributes() -> [String: String] {
        let box = previewViewBox
        let w = max(box.width * 0.25, 10)
        let h = max(box.height * 0.25, 10)
        return [
            "x": format(box.midX - w / 2),
            "y": format(box.midY - h / 2),
            "width": format(w),
            "height": format(h),
            "fill": lastFillHex,
            "stroke": lastStrokeHex,
            "stroke-width": format(strokeWidth(for: box))
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
            "stroke": lastStrokeHex,
            "stroke-width": format(strokeWidth(for: box))
        ]
    }

    private func defaultEllipseAttributes() -> [String: String] {
        let box = previewViewBox
        return [
            "cx": format(box.midX),
            "cy": format(box.midY),
            "rx": format(max(box.width * 0.18, 8)),
            "ry": format(max(box.height * 0.12, 8)),
            "fill": lastFillHex,
            "stroke": lastStrokeHex,
            "stroke-width": format(strokeWidth(for: box))
        ]
    }

    private func defaultLineAttributes() -> [String: String] {
        let box = previewViewBox
        return [
            "x1": format(box.midX - box.width * 0.15),
            "y1": format(box.midY),
            "x2": format(box.midX + box.width * 0.15),
            "y2": format(box.midY),
            "fill": "none",
            "stroke": lastStrokeHex,
            "stroke-width": format(strokeWidth(for: box))
        ]
    }

    private func defaultPolygonAttributes() -> [String: String] {
        let box = previewViewBox
        let w = max(box.width * 0.18, 10)
        let h = max(box.height * 0.18, 10)
        let points = [
            CGPoint(x: box.midX, y: box.midY - h),
            CGPoint(x: box.midX + w, y: box.midY + h),
            CGPoint(x: box.midX - w, y: box.midY + h)
        ]
        return [
            "points": SVGPoints.serialize(points),
            "fill": lastFillHex,
            "stroke": lastStrokeHex,
            "stroke-width": format(strokeWidth(for: box))
        ]
    }

    private func defaultPolylineAttributes() -> [String: String] {
        let box = previewViewBox
        let w = max(box.width * 0.2, 12)
        let h = max(box.height * 0.12, 12)
        let points = [
            CGPoint(x: box.midX - w, y: box.midY - h),
            CGPoint(x: box.midX, y: box.midY + h),
            CGPoint(x: box.midX + w, y: box.midY - h)
        ]
        return [
            "points": SVGPoints.serialize(points),
            "fill": "none",
            "stroke": lastStrokeHex,
            "stroke-width": format(strokeWidth(for: box))
        ]
    }

    private func defaultTextAttributes() -> [String: String] {
        let box = previewViewBox
        let fontSize = max((min(box.width, box.height) * 0.12).rounded(), 12)
        return [
            "x": format(box.midX),
            "y": format(box.midY + fontSize / 3),
            // An explicit family keeps preview, browsers and Icon Composer (CoreSVG) consistent.
            "font-family": "Helvetica, Arial, sans-serif",
            "font-size": format(fontSize),
            "text-anchor": "middle",
            "fill": lastFillHex
        ]
    }

    /// Stroke width that stays visible on both 100 and 1024 unit canvases.
    private func strokeWidth(for box: CGRect) -> CGFloat {
        max((min(box.width, box.height) / 100).rounded(), 1)
    }

    private func format(_ value: CGFloat) -> String {
        SVGFormat.number(value)
    }
}

// MARK: - Transforms

extension SVGLayerEditorViewModel {
    /// Canvas-space bounds of a node (union of its painted content for groups).
    func canvasBounds(of nodeID: UUID) -> CGRect? {
        geometryScene?.boundsByID[nodeID]
    }

    func rotateSelected(by degrees: CGFloat) {
        guard let selectedID = selectedNodeID,
              let bounds = canvasBounds(of: selectedID) else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        transformElement(nodeID: selectedID, transform: transform)
    }

    /// Applies `transform`, given in canvas (viewBox) coordinates, to an element.
    ///
    /// Geometry attributes are rewritten when the element can represent the result exactly
    /// (paths, polygons, lines; axis-aligned changes of rects, ellipses, text). Otherwise —
    /// e.g. rotating a rect, moving a group — the element's `transform` attribute is updated,
    /// so shapes never get distorted.
    func transformElement(nodeID: UUID, transform: CGAffineTransform, coalescingKey: String? = nil) {
        guard var doc = document,
              let node = doc.root.findNode(by: nodeID), node !== doc.root,
              let parentCTM = SVGShapeGeometry.parentTransform(of: nodeID, in: doc.root),
              Self.isInvertible(parentCTM) else { return }

        let newAttributes: [String: String]?
        if node.elementName == "svg" {
            // Nested <svg>: x/y/width/height live in the parent's user space; no transform attribute in SVG 1.1.
            let local = parentCTM.concatenating(transform).concatenating(parentCTM.inverted())
            newAttributes = Self.viewportAttributes(of: node, applying: local)
        } else {
            // A malformed transform attribute is left alone rather than guessed.
            guard let own = SVGTransform.parse(node.attributes["transform"]) else { return }
            let geometrySpace = own.concatenating(parentCTM)
            if Self.isInvertible(geometrySpace) {
                let local = geometrySpace.concatenating(transform).concatenating(geometrySpace.inverted())
                newAttributes = Self.geometryAttributes(of: node, applying: local)
                    ?? Self.transformAttributes(of: node, own: own, parentCTM: parentCTM, canvasTransform: transform)
            } else {
                newAttributes = nil
            }
        }

        guard let newAttributes, newAttributes != node.attributes else { return }
        pushUndoSnapshot(for: doc, coalescingKey: coalescingKey)
        node.attributes = newAttributes
        doc.isDirty = true
        document = doc
    }

    private static func isInvertible(_ t: CGAffineTransform) -> Bool {
        abs(t.a * t.d - t.b * t.c) > 1e-12
    }

    private static func transformAttributes(of node: LayerNode, own: CGAffineTransform, parentCTM: CGAffineTransform,
                                            canvasTransform: CGAffineTransform) -> [String: String] {
        let parentLocal = parentCTM.concatenating(canvasTransform).concatenating(parentCTM.inverted())
        var attributes = node.attributes
        attributes["transform"] = SVGTransform.format(own.concatenating(parentLocal))
        return attributes
    }

    /// Rewrites geometry in the element's own user space, or nil if the element cannot represent `t`.
    private static func geometryAttributes(of node: LayerNode, applying t: CGAffineTransform) -> [String: String]? {
        var a = node.attributes
        func n(_ key: String) -> CGFloat? { SVGLength.number(a, key) }
        func f(_ value: CGFloat) -> String { SVGFormat.number(value) }
        let axisAligned = SVGTransform.isAxisAligned(t)

        switch node.elementName {
        case "path":
            guard let d = a["d"], let path = SVGPathParser.toPath(d, strict: true) else { return nil }
            var transform = t
            guard let transformed = path.copy(using: &transform) else { return nil }
            a["d"] = SVGPathParser.serialize(path: transformed)
        case "line":
            let p1 = CGPoint(x: n("x1") ?? 0, y: n("y1") ?? 0).applying(t)
            let p2 = CGPoint(x: n("x2") ?? 0, y: n("y2") ?? 0).applying(t)
            a["x1"] = f(p1.x); a["y1"] = f(p1.y); a["x2"] = f(p2.x); a["y2"] = f(p2.y)
        case "polygon", "polyline":
            guard let points = SVGPoints.parse(a["points"]) else { return nil }
            a["points"] = SVGPoints.serialize(points.map { $0.applying(t) })
        case "rect", "image":
            guard axisAligned, let w = n("width"), let h = n("height") else { return nil }
            let rect = CGRect(x: n("x") ?? 0, y: n("y") ?? 0, width: w, height: h).applying(t)
            a["x"] = f(rect.minX); a["y"] = f(rect.minY); a["width"] = f(rect.width); a["height"] = f(rect.height)
            if let rx = n("rx") { a["rx"] = f(rx * abs(t.a)) }
            if let ry = n("ry") { a["ry"] = f(ry * abs(t.d)) }
        case "use":
            guard axisAligned, abs(t.a - 1) < 1e-9, abs(t.d - 1) < 1e-9 else { return nil }
            a["x"] = f((n("x") ?? 0) + t.tx); a["y"] = f((n("y") ?? 0) + t.ty)
        case "circle":
            // Circles survive similarity transforms (move, uniform scale, rotation, mirroring).
            let isSimilarity = abs(t.a * t.c + t.b * t.d) < 1e-9
                && abs((t.a * t.a + t.b * t.b) - (t.c * t.c + t.d * t.d)) < 1e-9
            guard isSimilarity, let r = n("r") else { return nil }
            let center = CGPoint(x: n("cx") ?? 0, y: n("cy") ?? 0).applying(t)
            a["cx"] = f(center.x); a["cy"] = f(center.y)
            a["r"] = f(r * sqrt(t.a * t.a + t.b * t.b))
        case "ellipse":
            guard axisAligned, let rx = n("rx"), let ry = n("ry") else { return nil }
            let center = CGPoint(x: n("cx") ?? 0, y: n("cy") ?? 0).applying(t)
            a["cx"] = f(center.x); a["cy"] = f(center.y)
            a["rx"] = f(rx * abs(t.a)); a["ry"] = f(ry * abs(t.d))
        case "text":
            // The anchor point moves with the transform; glyphs scale with font-size (uniform scale only).
            guard axisAligned, t.a > 0, abs(t.a - t.d) < 1e-9,
                  let x = SVGLength.parse(a["x"] ?? "0"), let y = SVGLength.parse(a["y"] ?? "0") else { return nil }
            let anchor = CGPoint(x: x, y: y).applying(t)
            a["x"] = f(anchor.x); a["y"] = f(anchor.y)
            if abs(t.a - 1) > 1e-9 {
                let size = SVGTextMetrics.resolvedFontSize(attributes: a) * t.a
                SVGStyle.set("font-size", to: f(size), in: &a)
            }
        default:
            return nil
        }
        return a
    }

    private static func viewportAttributes(of node: LayerNode, applying t: CGAffineTransform) -> [String: String]? {
        guard SVGTransform.isAxisAligned(t) else { return nil }
        var a = node.attributes
        let origin = CGPoint(x: SVGLength.number(a, "x") ?? 0, y: SVGLength.number(a, "y") ?? 0)
        if let w = SVGLength.number(a, "width"), let h = SVGLength.number(a, "height") {
            let rect = CGRect(origin: origin, size: CGSize(width: w, height: h)).applying(t)
            a["x"] = SVGFormat.number(rect.minX); a["y"] = SVGFormat.number(rect.minY)
            a["width"] = SVGFormat.number(rect.width); a["height"] = SVGFormat.number(rect.height)
        } else {
            guard abs(t.a - 1) < 1e-9, abs(t.d - 1) < 1e-9 else { return nil }
            a["x"] = SVGFormat.number(origin.x + t.tx); a["y"] = SVGFormat.number(origin.y + t.ty)
        }
        return a
    }
}

private enum SVGValidationError: LocalizedError {
    case invalidRoot
    case missingCanvas
    case invalidDimension(name: String, value: String)
    case invalidViewBox(value: String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "Root element must be <svg>."
        case .missingCanvas:
            return "The <svg> root needs a viewBox or width and height."
        case .invalidDimension(let name, let value):
            return "Invalid SVG \(name): \(value)."
        case .invalidViewBox(let value):
            return "Invalid viewBox: \(value). Expected four numbers: min-x min-y width height."
        }
    }
}
