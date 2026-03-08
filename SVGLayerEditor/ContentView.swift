//
//  ContentView.swift
//  SVGLayerEditor
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject private var viewModel: SVGLayerEditorViewModel
    @State private var previewZoom: CGFloat = 1.0
    @State private var expandedNodes: Set<UUID> = []
    @State private var lastDocument: SVGDocument?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                layerList
            }
            .padding()
        } detail: {
            detailPanel
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { viewModel.openDocument() } label: {
                    Image(systemName: "folder")
                }
                .help("Open")
                
                Button { viewModel.saveDocument() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save")
                .disabled(!viewModel.hasDocument)
                
                Button { viewModel.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Undo")
                .disabled(!viewModel.hasUndo)
                
                Button { viewModel.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .help("Redo")
                .disabled(!viewModel.hasRedo)
            }
            
            ToolbarItemGroup(placement: .automatic) {
                Button { viewModel.addGroup() } label: {
                    Image(systemName: "folder")
                }
                .help("Add Group")
                .disabled(!viewModel.hasDocument)
            }
//                ToolbarSpacer()
                
            ToolbarItemGroup(placement: .automatic) {
                Button { viewModel.addRectangle() } label: {
                    Image(systemName: "rectangle")
                }
                .help("Add Rectangle")
                .disabled(!viewModel.hasDocument)

                Button { viewModel.addCircle() } label: {
                    Image(systemName: "circle")
                }
                .help("Add Circle")
                .disabled(!viewModel.hasDocument)

                Button { viewModel.addEllipse() } label: {
                    Image(systemName: "oval")
                }
                .help("Add Ellipse")
                .disabled(!viewModel.hasDocument)

                Button { viewModel.addLine() } label: {
                    Image(systemName: "line.diagonal")
                }
                .help("Add Line")
                .disabled(!viewModel.hasDocument)

                Button { viewModel.addPolygon() } label: {
                    Image(systemName: "triangle")
                }
                .help("Add Polygon")
                .disabled(!viewModel.hasDocument)

                Button { viewModel.addPolyline() } label: {
                    Image(systemName: "scribble.variable")
                }
                .help("Add Polyline")
                .disabled(!viewModel.hasDocument)

                Button { viewModel.addText() } label: {
                    Image(systemName: "textformat")
                }
                .help("Add Text")
                .disabled(!viewModel.hasDocument)
            }

            ToolbarItemGroup(placement: .automatic) {
                if viewModel.selectedNodeID != nil {
                    ColorPicker("Fill", selection: Binding(
                        get: { viewModel.selectedFillColor ?? .black },
                        set: { viewModel.setFillColor($0) }
                    ))
                    .labelsHidden()
                    .help("Fill Color")

                    ColorPicker("Stroke", selection: Binding(
                        get: { viewModel.selectedStrokeColor ?? .black },
                        set: { viewModel.setStrokeColor($0) }
                    ))
                    .labelsHidden()
                    .help("Stroke Color")
                }
            }

            ToolbarItemGroup(placement: .automatic) {
                Button { viewModel.rotateSelected(by: -15) } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Rotate Left 15°")
                .disabled(viewModel.selectedNodeID == nil)

                Button { viewModel.rotateSelected(by: 15) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rotate Right 15°")
                .disabled(viewModel.selectedNodeID == nil)
            }

            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    Button("Center Horizontally") {
                        viewModel.alignSelectedToCanvas(.centerX)
                    }
                    .disabled(viewModel.selectedNodeID == nil)

                    Button("Center Vertically") {
                        viewModel.alignSelectedToCanvas(.centerY)
                    }
                    .disabled(viewModel.selectedNodeID == nil)

                    Divider()

                    Button("Align Left to Reference") {
                        viewModel.alignSelectedToReference(.left)
                    }
                    .disabled(viewModel.selectedNodeID == nil || !viewModel.hasReferenceSelection)

                    Button("Align Center X to Reference") {
                        viewModel.alignSelectedToReference(.centerX)
                    }
                    .disabled(viewModel.selectedNodeID == nil || !viewModel.hasReferenceSelection)

                    Button("Align Right to Reference") {
                        viewModel.alignSelectedToReference(.right)
                    }
                    .disabled(viewModel.selectedNodeID == nil || !viewModel.hasReferenceSelection)

                    Divider()

                    Button("Align Top to Reference") {
                        viewModel.alignSelectedToReference(.top)
                    }
                    .disabled(viewModel.selectedNodeID == nil || !viewModel.hasReferenceSelection)

                    Button("Align Center Y to Reference") {
                        viewModel.alignSelectedToReference(.centerY)
                    }
                    .disabled(viewModel.selectedNodeID == nil || !viewModel.hasReferenceSelection)

                    Button("Align Bottom to Reference") {
                        viewModel.alignSelectedToReference(.bottom)
                    }
                    .disabled(viewModel.selectedNodeID == nil || !viewModel.hasReferenceSelection)
                } label: {
                    Image(systemName: "align.vertical.center")
                }
                .help("Align")
            }
        }
        .background(WindowCloseHandler(isDirty: viewModel.isDirty, shouldClose: viewModel.confirmCloseIfNeeded))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
        .alert("Error", isPresented: $viewModel.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .onReceive(viewModel.$document) { newDoc in
            guard let newDoc else {
                expandedNodes = []
                lastDocument = nil
                return
            }
            if let oldDoc = lastDocument {
                let paths = expandedNodes.compactMap { viewModel.nodePath(for: $0, in: oldDoc) }
                let newExpanded = paths.compactMap { viewModel.nodeID(for: $0, in: newDoc) }
                expandedNodes = Set(newExpanded)
            }
            lastDocument = newDoc
        }
    }

    private var layerList: some View {
        Group {
            if let root = viewModel.document?.root {
                VStack(spacing: 8) {
                    layerToolbar
                    List(selection: $viewModel.selectedNodeID) {
                        Section(header: Text("Document")) {
                            layerRow(for: root)
                                .tag(root.id)
                        }
                        ForEach(root.children) { node in
                            layerTree(node)
                        }
                    }
                    .onDrop(of: [.plainText], delegate: LayerDropDelegate(targetID: nil, viewModel: viewModel))
                }
            } else {
                Text("No SVG loaded")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            documentEditor
            Divider()
            detailInfo
            Divider()
            previewControls
            previewPanel
        }
        .padding()
    }

    private var documentEditor: some View {
        Group {
            if viewModel.document != nil {
                HStack {
                    Text("Document XML")
                    Spacer()
                    Button("Apply") {
                        viewModel.applyDocumentXMLFromEditor()
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    PlainTextEditor(text: $viewModel.documentXMLText)
                        .frame(minHeight: 120)

                    if let error = viewModel.documentXMLError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(8)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(6)
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                }
            }
        }
    }

    private var detailInfo: some View {
        Group {
            if let document = viewModel.document,
               let selectedID = viewModel.selectedNodeID,
               let node = document.root.findNode(by: selectedID) {
                HStack() {
                    Text("Element: \(node.elementName)")
                    Text("Name: \(node.displayName)")
                    Text("Attributes: \(node.attributes.count)")
                    Text("Children: \(node.children.count)")
                }

                if node.elementName == "svg" {
                    HStack(spacing: 8) {
                        Text("Width")
                        TextField("", text: Binding(
                            get: { viewModel.rootAttribute("width") },
                            set: { viewModel.setRootAttribute("width", value: $0) }
                        ))
                        .frame(width: 80)

                        Text("Height")
                        TextField("", text: Binding(
                            get: { viewModel.rootAttribute("height") },
                            set: { viewModel.setRootAttribute("height", value: $0) }
                        ))
                        .frame(width: 80)

                        Text("ViewBox")
                        TextField("", text: Binding(
                            get: { viewModel.rootAttribute("viewBox") },
                            set: { viewModel.setRootAttribute("viewBox", value: $0) }
                        ))
                        .frame(minWidth: 200)
                    }
                }

                if let text = node.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Text: \(text)")
                }
                Divider()
                Text("Raw XML")
                HStack(alignment: .top, spacing: 12) {
                    PlainTextEditor(text: $viewModel.selectedNodeXMLText)
                        .frame(minHeight: 40)

                    if let error = viewModel.selectedNodeXMLError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(8)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(6)
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                }
            } else {
                Text("Select a layer")
            }
        }
    }

    private var layerToolbar: some View {
        let hasSelection = viewModel.selectedNodeID != nil
        return HStack(spacing: 10) {
            Button {
                viewModel.deleteSelection()
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete layer")
            .disabled(!hasSelection)

            Button {
                viewModel.moveSelectionUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("Move up")
            .disabled(!hasSelection)

            Button {
                viewModel.moveSelectionDown()
            } label: {
                Image(systemName: "arrow.down")
            }
            .help("Move down")
            .disabled(!hasSelection)

            Button {
                viewModel.indentSelection()
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .help("Indent")
            .disabled(!hasSelection)

            Button {
                viewModel.outdentSelection()
            } label: {
                Image(systemName: "arrow.left.to.line")
            }
            .help("Outdent")
            .disabled(!hasSelection)

            Spacer()
        }
        .buttonStyle(.borderless)
    }

    private var previewControls: some View {
        HStack {
            Text("Zoom")
            Slider(value: $previewZoom, in: 0.25...4.0, step: 0.05)
                .frame(maxWidth: 200)
            Text(String(format: "%.0f%%", previewZoom * 100))
                .frame(width: 60, alignment: .trailing)
            Button("Fit") {
                previewZoom = 1.0
            }
        }
    }

    private var previewPanel: some View {
        Group {
            let paths = viewModel.previewPaths
            if !paths.isEmpty {
                SVGPreviewImageView(
                    viewBox: viewModel.previewViewBox,
                    paths: paths,
                    scale: previewZoom,
                    selectedID: viewModel.selectedNodeID,
                    onSelect: { viewModel.selectedNodeID = $0 },
                    onTransform: { id, transform in
                        viewModel.transformElement(nodeID: id, transform: transform)
                    }
                )
                .frame(minHeight: 240)
            } else if let data = viewModel.previewSVGData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(minHeight: 240)
            } else {
                Text("No preview")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }
}

private extension ContentView {
    func layerRow(for node: LayerNode) -> some View {
        HStack(spacing: 8) {
            if node.elementName == "svg" {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    viewModel.toggleVisibility(for: node.id)
                } label: {
                    Image(systemName: viewModel.isHidden(node) ? "eye.slash" : "eye")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.displayName)
                    if node.elementName == "svg" {
                        Text("SVG Root")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                if let detail = pathDetail(for: node) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    func pathDetail(for node: LayerNode) -> String? {
        guard node.elementName == "path", let d = node.attributes["d"] else { return nil }
        return "d=\"\(truncate(d, max: 80))\""
    }

    func truncate(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        let index = text.index(text.startIndex, offsetBy: max)
        return String(text[..<index]) + "..."
    }

    func dragItemProvider(for node: LayerNode) -> NSItemProvider {
        NSItemProvider(object: node.id.uuidString as NSString)
    }

    func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                viewModel.openDocument(at: url)
            }
        }
        return true
    }
}

private struct LayerDropDelegate: DropDelegate {
    let targetID: UUID?
    let viewModel: SVGLayerEditorViewModel

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let idString = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                viewModel.moveNode(draggedID: uuid, targetID: targetID)
            }
        }
        return true
    }
}

private extension ContentView {
    func layerTree(_ node: LayerNode) -> AnyView {
        if node.children.isEmpty {
            return AnyView(
                layerRow(for: node)
                    .onDrag { dragItemProvider(for: node) }
                    .onDrop(of: [.plainText], delegate: LayerDropDelegate(targetID: node.id, viewModel: viewModel))
            )
        }
        return AnyView(
            DisclosureGroup(isExpanded: isExpandedBinding(for: node)) {
                ForEach(node.children) { child in
                    layerTree(child)
                }
            } label: {
                layerRow(for: node)
            }
            .onDrag { dragItemProvider(for: node) }
            .onDrop(of: [.plainText], delegate: LayerDropDelegate(targetID: node.id, viewModel: viewModel))
        )
    }

    func isExpandedBinding(for node: LayerNode) -> Binding<Bool> {
        Binding(
            get: { expandedNodes.contains(node.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedNodes.insert(node.id)
                } else {
                    expandedNodes.remove(node.id)
                }
            }
        )
    }
}
