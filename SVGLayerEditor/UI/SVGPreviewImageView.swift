import SwiftUI
import AppKit

struct SVGPreviewImageView: View {
    let viewBox: CGRect
    let scene: SVGRenderScene
    let scale: CGFloat
    let selectedID: UUID?
    let moveSensitivity: CGFloat
    let resizeSensitivity: CGFloat
    let gridSpacing: CGFloat
    let gridColor: Color
    let borderColor: Color
    let onSelect: (UUID?) -> Void
    /// Transform in canvas (viewBox) coordinates for the given element.
    let onTransform: (UUID, CGAffineTransform) -> Void
    let onTransformEnded: () -> Void

    @State private var dragMode: DragMode?

    var body: some View {
        GeometryReader { geo in
            let effective = effectiveViewBox()
            let transform = viewBoxTransform(viewBox: effective, size: geo.size, scale: scale)
            let fit = transform.a
            let inverse = transform.inverted()
            let selectedBoundsSVG = selectedID.flatMap { scene.boundsByID[$0] }
            let selectedBoundsView = selectedBoundsSVG.map { $0.applying(transform) }

            ZStack {
                Canvas { context, _ in
                    context.concatenate(transform)
                    drawGrid(in: context, viewBox: effective, lineWidth: 0.5 / fit)

                    for item in scene.items {
                        draw(item, in: context)
                    }

                    if let selectedID, let item = scene.items.first(where: { $0.id == selectedID }) {
                        var highlight = context
                        highlight.concatenate(item.transform)
                        let unit = 1 / max(fit * Self.scaleFactor(of: item.transform), 0.0001)
                        highlight.stroke(
                            Path(item.path),
                            with: .color(.accentColor),
                            style: StrokeStyle(lineWidth: 2 * unit, dash: [6 * unit, 3 * unit])
                        )
                    }

                    drawBorder(in: context, viewBox: effective, lineWidth: 1 / fit)
                }

                if let bounds = selectedBoundsView {
                    Path { path in
                        path.addRect(bounds)
                    }
                    .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))

                    ForEach(Handle.allCases, id: \.self) { handle in
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
                            .frame(width: 10, height: 10)
                            .position(handle.point(in: bounds))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let viewPoint = value.location
                        let svgPoint = viewPoint.applying(inverse)

                        if dragMode == nil {
                            dragMode = beginDrag(viewPoint: viewPoint, svgPoint: svgPoint, fit: fit,
                                                 selectedBoundsSVG: selectedBoundsSVG, selectedBoundsView: selectedBoundsView)
                        }

                        let modifiers = NSEvent.modifierFlags
                        let keepAspect = modifiers.contains(.shift)
                        let centerScale = modifiers.contains(.option)

                        switch dragMode {
                        case .move(let id, let lastPoint):
                            let delta = CGPoint(x: (svgPoint.x - lastPoint.x) * moveSensitivity,
                                                y: (svgPoint.y - lastPoint.y) * moveSensitivity)
                            guard delta != .zero else { return }
                            onTransform(id, CGAffineTransform(translationX: delta.x, y: delta.y))
                            dragMode = .move(id: id, lastPoint: CGPoint(x: lastPoint.x + delta.x, y: lastPoint.y + delta.y))
                        case .resize(let id, let handle, let startBounds, let startPoint, let currentBounds):
                            let adjustedPoint = CGPoint(x: startPoint.x + (svgPoint.x - startPoint.x) * resizeSensitivity,
                                                        y: startPoint.y + (svgPoint.y - startPoint.y) * resizeSensitivity)
                            let newBounds = resizedBounds(from: startBounds, to: adjustedPoint, handle: handle,
                                                          keepAspect: keepAspect, centerScale: centerScale)
                            guard newBounds != currentBounds else { return }
                            // Each event applies only the change since the previous event.
                            onTransform(id, rectTransform(from: currentBounds, to: newBounds))
                            dragMode = .resize(id: id, handle: handle, startBounds: startBounds,
                                               startPoint: startPoint, currentBounds: newBounds)
                        case .idle?, nil:
                            break
                        }
                    }
                    .onEnded { _ in
                        switch dragMode {
                        case .move?, .resize?:
                            onTransformEnded()
                        case .idle?, nil:
                            break
                        }
                        dragMode = nil
                    }
            )
        }
    }

    private func beginDrag(viewPoint: CGPoint, svgPoint: CGPoint, fit: CGFloat,
                           selectedBoundsSVG: CGRect?, selectedBoundsView: CGRect?) -> DragMode {
        if let selectedID, let boundsView = selectedBoundsView, let boundsSVG = selectedBoundsSVG,
           let handle = hitHandle(at: viewPoint, in: boundsView) {
            return .resize(id: selectedID, handle: handle, startBounds: boundsSVG, startPoint: svgPoint, currentBounds: boundsSVG)
        }
        guard let hit = hitTest(canvasPoint: svgPoint, fit: fit) else {
            onSelect(nil)
            return .idle
        }
        // Keep a selected group (from the layer list) when clicking its content, so it can be dragged as a whole.
        if let selectedID, hit.id == selectedID || (hit.ancestorIDs.contains(selectedID) && hit.ancestorIDs.first != selectedID) {
            return .move(id: selectedID, lastPoint: svgPoint)
        }
        onSelect(hit.id)
        return .move(id: hit.id, lastPoint: svgPoint)
    }

    // MARK: Drawing

    private func draw(_ item: SVGRenderItem, in base: GraphicsContext) {
        var context = base
        for clip in item.clipPaths {
            context.clip(to: Path(clip))
        }
        context.concatenate(item.transform)
        context.opacity = item.opacity

        if let text = item.text {
            guard !item.fill.isNone, !text.string.isEmpty else { return }
            let font = SVGTextMetrics.font(properties: text.properties)
            let color: Color
            switch item.fill {
            case .color(var value):
                value.alpha *= item.fillOpacity
                color = value.swiftUIColor
            case .gradient(let gradient):
                color = gradient.stops.first?.color.swiftUIColor ?? .black
            case .none:
                return
            }
            context.draw(Text(text.string).font(Font(font as CTFont)).foregroundStyle(color), at: text.origin, anchor: .topLeading)
            return
        }

        let bounds = item.path.boundingBoxOfPath
        fill(item.path, paint: item.fill, opacity: item.fillOpacity, evenOdd: item.evenOdd, objectBounds: bounds, in: context)
        if !item.stroke.isNone, let outline = item.strokeOutline() {
            fill(outline, paint: item.stroke, opacity: item.strokeOpacity, evenOdd: false, objectBounds: bounds, in: context)
        }
    }

    private func fill(_ path: CGPath, paint: SVGPaint, opacity: Double, evenOdd: Bool,
                      objectBounds: CGRect, in base: GraphicsContext) {
        let style = FillStyle(eoFill: evenOdd)
        switch paint {
        case .none:
            return
        case .color(var color):
            color.alpha *= opacity
            base.fill(Path(path), with: .color(color.swiftUIColor), style: style)
        case .gradient(let gradient):
            var space = gradient.transform
            if gradient.usesObjectBoundingBox {
                guard objectBounds.width > 0, objectBounds.height > 0 else {
                    if var first = gradient.stops.first?.color {
                        first.alpha *= opacity
                        base.fill(Path(path), with: .color(first.swiftUIColor), style: style)
                    }
                    return
                }
                space = space.concatenating(CGAffineTransform(
                    a: objectBounds.width, b: 0, c: 0, d: objectBounds.height,
                    tx: objectBounds.minX, ty: objectBounds.minY
                ))
            }
            guard abs(space.a * space.d - space.b * space.c) > 1e-12 else { return }
            var context = base
            context.clip(to: Path(path), style: style)
            context.concatenate(space)
            let area = path.boundingBoxOfPath.applying(space.inverted()).insetBy(dx: -1, dy: -1)
            let stops = gradient.stops.map { stop -> Gradient.Stop in
                var color = stop.color
                color.alpha *= opacity
                return Gradient.Stop(color: color.swiftUIColor, location: stop.offset)
            }
            let shading: GraphicsContext.Shading
            switch gradient.kind {
            case .linear(let start, let end):
                shading = .linearGradient(Gradient(stops: stops), startPoint: start, endPoint: end)
            case .radial(let center, let radius):
                shading = .radialGradient(Gradient(stops: stops), center: center, startRadius: 0, endRadius: radius)
            }
            context.fill(Path(area), with: shading)
        }
    }

    private func drawGrid(in context: GraphicsContext, viewBox: CGRect, lineWidth: CGFloat) {
        guard gridSpacing > 0 else { return }
        var path = Path()
        var x = (viewBox.minX / gridSpacing).rounded(.up) * gridSpacing
        while x <= viewBox.maxX {
            path.move(to: CGPoint(x: x, y: viewBox.minY))
            path.addLine(to: CGPoint(x: x, y: viewBox.maxY))
            x += gridSpacing
        }
        var y = (viewBox.minY / gridSpacing).rounded(.up) * gridSpacing
        while y <= viewBox.maxY {
            path.move(to: CGPoint(x: viewBox.minX, y: y))
            path.addLine(to: CGPoint(x: viewBox.maxX, y: y))
            y += gridSpacing
        }
        context.stroke(path, with: .color(gridColor), lineWidth: lineWidth)
    }

    private func drawBorder(in context: GraphicsContext, viewBox: CGRect, lineWidth: CGFloat) {
        context.stroke(Path(viewBox), with: .color(borderColor), lineWidth: lineWidth)
    }

    // MARK: Geometry

    private func effectiveViewBox() -> CGRect {
        let defaultBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        guard viewBox == defaultBox else { return viewBox }
        let content = scene.items.reduce(CGRect.null) { $0.union($1.canvasBounds) }
        return content.isNull || content.isEmpty ? viewBox : content
    }

    private func viewBoxTransform(viewBox: CGRect, size: CGSize, scale: CGFloat) -> CGAffineTransform {
        let sx = size.width / max(viewBox.width, 1)
        let sy = size.height / max(viewBox.height, 1)
        let fit = max(min(sx, sy) * scale, 0.0001)
        let tx = (size.width - viewBox.width * fit) / 2.0 - viewBox.minX * fit
        let ty = (size.height - viewBox.height * fit) / 2.0 - viewBox.minY * fit
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: fit, y: fit)
    }

    private static func scaleFactor(of transform: CGAffineTransform) -> CGFloat {
        sqrt(abs(transform.a * transform.d - transform.b * transform.c))
    }

    private func hitTest(canvasPoint: CGPoint, fit: CGFloat) -> SVGRenderItem? {
        for item in scene.items.reversed() {
            let scale = Self.scaleFactor(of: item.transform)
            guard scale > 1e-9, !item.isClipped(canvasPoint: canvasPoint) else { continue }
            let local = canvasPoint.applying(item.transform.inverted())
            if item.text != nil || !item.fill.isNone,
               item.path.contains(local, using: item.evenOdd ? .evenOdd : .winding) {
                return item
            }
            if !item.stroke.isNone || item.fill.isNone {
                let tolerance = 8 / max(fit * scale, 0.0001)
                if let outline = item.strokeOutline(minimumWidth: tolerance), outline.contains(local) {
                    return item
                }
            }
        }
        return nil
    }

    private func hitHandle(at point: CGPoint, in bounds: CGRect) -> Handle? {
        let handleSize: CGFloat = 12
        for handle in Handle.allCases {
            let hp = handle.point(in: bounds)
            let rect = CGRect(x: hp.x - handleSize / 2, y: hp.y - handleSize / 2, width: handleSize, height: handleSize)
            if rect.contains(point) { return handle }
        }
        return nil
    }

    private func resizedBounds(from start: CGRect, to point: CGPoint, handle: Handle, keepAspect: Bool, centerScale: Bool) -> CGRect {
        let aspect = start.width / max(start.height, 1)
        let minSize: CGFloat = 4

        if centerScale {
            let center = CGPoint(x: start.midX, y: start.midY)
            var width = max(abs(point.x - center.x) * 2, minSize)
            var height = max(abs(point.y - center.y) * 2, minSize)

            if keepAspect {
                let scale = max(width / max(start.width, 1), height / max(start.height, 1))
                width = max(start.width * scale, minSize)
                height = max(start.height * scale, minSize)
            }

            return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        }

        var proposed = handle.resizedBounds(from: start, to: point)
        proposed.size.width = max(proposed.width, minSize)
        proposed.size.height = max(proposed.height, minSize)

        let anchor = handle.anchorPoint(in: start)
        if keepAspect {
            let widthBasedHeight = proposed.width / aspect
            let heightBasedWidth = proposed.height * aspect

            if abs(widthBasedHeight - proposed.height) < abs(heightBasedWidth - proposed.width) {
                proposed.size.height = max(widthBasedHeight, minSize)
            } else {
                proposed.size.width = max(heightBasedWidth, minSize)
            }
        }

        // Keep the opposite corner fixed.
        switch handle {
        case .topLeft:
            proposed.origin = CGPoint(x: anchor.x - proposed.width, y: anchor.y - proposed.height)
        case .topRight:
            proposed.origin = CGPoint(x: anchor.x, y: anchor.y - proposed.height)
        case .bottomLeft:
            proposed.origin = CGPoint(x: anchor.x - proposed.width, y: anchor.y)
        case .bottomRight:
            proposed.origin = anchor
        }
        return proposed
    }

    /// Maps one rectangle onto another (scale + translation).
    private func rectTransform(from source: CGRect, to target: CGRect) -> CGAffineTransform {
        let sx = target.width / max(source.width, 0.0001)
        let sy = target.height / max(source.height, 0.0001)
        return CGAffineTransform(translationX: target.minX, y: target.minY)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: -source.minX, y: -source.minY)
    }
}

private enum DragMode {
    /// The gesture hit nothing; it selects nothing and moves nothing.
    case idle
    case move(id: UUID, lastPoint: CGPoint)
    case resize(id: UUID, handle: Handle, startBounds: CGRect, startPoint: CGPoint, currentBounds: CGRect)
}

private enum Handle: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func anchorPoint(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    func resizedBounds(from rect: CGRect, to point: CGPoint) -> CGRect {
        switch self {
        case .topLeft:
            return CGRect(x: point.x, y: point.y, width: rect.maxX - point.x, height: rect.maxY - point.y)
        case .topRight:
            return CGRect(x: rect.minX, y: point.y, width: point.x - rect.minX, height: rect.maxY - point.y)
        case .bottomLeft:
            return CGRect(x: point.x, y: rect.minY, width: rect.maxX - point.x, height: point.y - rect.minY)
        case .bottomRight:
            return CGRect(x: rect.minX, y: rect.minY, width: point.x - rect.minX, height: point.y - rect.minY)
        }
    }
}
