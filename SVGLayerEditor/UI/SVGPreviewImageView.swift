import SwiftUI
import AppKit

struct SVGPreviewImageView: View {
    let viewBox: CGRect
    let paths: [SVGLayerEditorViewModel.SVGPreviewPath]
    let scale: CGFloat
    let selectedID: UUID?
    let onSelect: (UUID?) -> Void
    let onTransform: (UUID, CGAffineTransform) -> Void

    private let parser = SVGPathParser()
    @State private var dragMode: DragMode?

    private let moveSensitivity: CGFloat = 0.35
    private let resizeSensitivity: CGFloat = 0.35

    private let gridSpacing: CGFloat = 50
    private let gridColor = Color.gray.opacity(0.25)
    private let borderColor = Color.gray.opacity(0.6)

    var body: some View {
        GeometryReader { geo in
            let parsed: [(SVGLayerEditorViewModel.SVGPreviewPath, CGPath?)] = paths.map { item in
                (item, buildPath(for: item))
            }
            let effective = effectiveViewBox(fallback: viewBox, paths: parsed.compactMap { $0.1 })
            let transform = viewBoxTransform(viewBox: effective, size: geo.size, scale: scale)
            let inverse = transform.inverted()
            let selectedPath = parsed.first { $0.0.id == selectedID }
            let selectedBoundsSVG = selectedPath?.1?.boundingBoxOfPath
            let selectedBoundsView = selectedBoundsSVG.map { $0.applying(transform) }

            ZStack {
                Canvas { context, _ in
                    context.concatenate(transform)

                    drawGrid(in: context, viewBox: effective)

                    for (pathElement, cgPath) in parsed {
                        context.opacity = pathElement.opacity ?? 1.0

                        if pathElement.elementName == "text",
                           let textValue = pathElement.text,
                           let x = number(pathElement.attributes["x"]),
                           let y = number(pathElement.attributes["y"]) {
                            let fontSize = number(pathElement.attributes["font-size"]) ?? 16
                            let textColor = Color(svg: pathElement.fill ?? "black") ?? .black
                            let text = Text(textValue).font(.system(size: fontSize))
                            context.draw(text.foregroundStyle(textColor), at: CGPoint(x: x, y: y), anchor: .topLeading)
                            continue
                        }

                        guard let cgPath else { continue }

                        if let fill = pathElement.fill, fill.lowercased() != "none", let color = Color(svg: fill) {
                            context.fill(Path(cgPath), with: .color(color))
                        }

                        if let stroke = pathElement.stroke, stroke.lowercased() != "none", let color = Color(svg: stroke) {
                            let strokeWidth = number(pathElement.attributes["stroke-width"]) ?? 1
                            let strokeStyle = StrokeStyle(lineWidth: strokeWidth)
                            context.stroke(Path(cgPath), with: .color(color), style: strokeStyle)
                        }

                        if pathElement.id == selectedID {
                            let highlight = StrokeStyle(lineWidth: 2, dash: [6, 3])
                            context.stroke(Path(cgPath), with: .color(.accentColor), style: highlight)
                        }
                    }

                    drawBorder(in: context, viewBox: effective)
                }

                if let bounds = selectedBoundsView {
                    Path { path in
                        path.addRect(bounds)
                    }
                    .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))

                    ForEach(Handle.allCases, id: \.self) { handle in
                        let handlePoint = handle.point(in: bounds)
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1))
                            .frame(width: 10, height: 10)
                            .position(handlePoint)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let selectedID else { return }
                        let viewPoint = value.location
                        let svgPoint = viewPoint.applying(inverse)

                        if dragMode == nil {
                            if let boundsView = selectedBoundsView, let handle = hitHandle(at: viewPoint, in: boundsView) {
                                dragMode = .resize(handle: handle, startBounds: selectedBoundsSVG ?? .zero, startPoint: svgPoint)
                            } else if let hit = hitTest(svgPoint: svgPoint, paths: parsed) {
                                onSelect(hit)
                                dragMode = .move(startPoint: svgPoint)
                            } else {
                                onSelect(nil)
                            }
                        }

                        let modifiers = NSEvent.modifierFlags
                        let keepAspect = modifiers.contains(.shift)
                        let centerScale = modifiers.contains(.option)

                        switch dragMode {
                        case .move(let startPoint):
                            let rawDelta = CGPoint(x: svgPoint.x - startPoint.x, y: svgPoint.y - startPoint.y)
                            let delta = CGPoint(x: rawDelta.x * moveSensitivity, y: rawDelta.y * moveSensitivity)
                            let transform = CGAffineTransform(translationX: delta.x, y: delta.y)
                            onTransform(selectedID, transform)
                            let nextPoint = CGPoint(x: startPoint.x + delta.x, y: startPoint.y + delta.y)
                            dragMode = .move(startPoint: nextPoint)
                        case .resize(let handle, let startBounds, let startPoint):
                            let rawDelta = CGPoint(x: svgPoint.x - startPoint.x, y: svgPoint.y - startPoint.y)
                            let adjustedPoint = CGPoint(x: startPoint.x + rawDelta.x * resizeSensitivity, y: startPoint.y + rawDelta.y * resizeSensitivity)
                            let newBounds = resizedBounds(from: startBounds, to: adjustedPoint, handle: handle, keepAspect: keepAspect, centerScale: centerScale)
                            if let transform = resizeTransform(from: startBounds, to: newBounds, handle: handle, centerScale: centerScale) {
                                onTransform(selectedID, transform)
                            }
                        case .none:
                            break
                        }
                    }
                    .onEnded { _ in
                        dragMode = nil
                    }
            )
        }
    }

    private func buildPath(for item: SVGLayerEditorViewModel.SVGPreviewPath) -> CGPath? {
        switch item.elementName {
        case "path":
            guard let d = item.d else { return nil }
            return parser.parse(d)
        case "rect":
            guard let x = number(item.attributes["x"]),
                  let y = number(item.attributes["y"]),
                  let w = number(item.attributes["width"]),
                  let h = number(item.attributes["height"]) else { return nil }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            let rx = number(item.attributes["rx"]) ?? 0
            let ry = number(item.attributes["ry"]) ?? 0
            if rx > 0 || ry > 0 {
                let cornerWidth = min(rx, w / 2)
                let cornerHeight = min(ry, h / 2)
                return CGPath(roundedRect: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: nil)
            }
            return CGPath(rect: rect, transform: nil)
        case "circle":
            guard let cx = number(item.attributes["cx"]),
                  let cy = number(item.attributes["cy"]),
                  let r = number(item.attributes["r"]) else { return nil }
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            return CGPath(ellipseIn: rect, transform: nil)
        case "ellipse":
            guard let cx = number(item.attributes["cx"]),
                  let cy = number(item.attributes["cy"]),
                  let rx = number(item.attributes["rx"]),
                  let ry = number(item.attributes["ry"]) else { return nil }
            let rect = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
            return CGPath(ellipseIn: rect, transform: nil)
        case "line":
            guard let x1 = number(item.attributes["x1"]),
                  let y1 = number(item.attributes["y1"]),
                  let x2 = number(item.attributes["x2"]),
                  let y2 = number(item.attributes["y2"]) else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
            return path
        case "polygon":
            guard let points = item.attributes["points"], let list = parsePoints(points), !list.isEmpty else { return nil }
            let path = CGMutablePath()
            path.move(to: list[0])
            for point in list.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            return path
        case "polyline":
            guard let points = item.attributes["points"], let list = parsePoints(points), !list.isEmpty else { return nil }
            let path = CGMutablePath()
            path.move(to: list[0])
            for point in list.dropFirst() { path.addLine(to: point) }
            return path
        case "text":
            return nil
        default:
            return nil
        }
    }

    private func parsePoints(_ value: String) -> [CGPoint]? {
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

    private func number(_ value: String?) -> CGFloat? {
        guard let value else { return nil }
        return CGFloat(Double(value) ?? .nan).isNaN ? nil : CGFloat(Double(value) ?? 0)
    }

    private func hitTest(svgPoint: CGPoint, paths: [(SVGLayerEditorViewModel.SVGPreviewPath, CGPath?)]) -> UUID? {
        for (item, path) in paths.reversed() {
            if let path, path.contains(svgPoint) {
                return item.id
            }
            if item.elementName == "line", let path {
                let width = number(item.attributes["stroke-width"]) ?? 6
                let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
                if stroked.contains(svgPoint) {
                    return item.id
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

        if keepAspect {
            let widthBasedHeight = proposed.width / aspect
            let heightBasedWidth = proposed.height * aspect

            if abs(widthBasedHeight - proposed.height) < abs(heightBasedWidth - proposed.width) {
                proposed.size.height = max(widthBasedHeight, minSize)
            } else {
                proposed.size.width = max(heightBasedWidth, minSize)
            }

            let anchor = handle.anchorPoint(in: start)
            switch handle {
            case .topLeft:
                proposed.origin = CGPoint(x: anchor.x - proposed.width, y: anchor.y - proposed.height)
            case .topRight:
                proposed.origin = CGPoint(x: anchor.x, y: anchor.y - proposed.height)
            case .bottomLeft:
                proposed.origin = CGPoint(x: anchor.x - proposed.width, y: anchor.y)
            case .bottomRight:
                proposed.origin = CGPoint(x: anchor.x, y: anchor.y)
            }
        }

        return proposed
    }

    private func resizeTransform(from start: CGRect, to end: CGRect, handle: Handle, centerScale: Bool) -> CGAffineTransform? {
        let startWidth = max(start.width, 1)
        let startHeight = max(start.height, 1)
        let endWidth = max(end.width, 1)
        let endHeight = max(end.height, 1)
        let sx = endWidth / startWidth
        let sy = endHeight / startHeight

        let anchor: CGPoint
        if centerScale {
            anchor = CGPoint(x: start.midX, y: start.midY)
        } else {
            anchor = handle.anchorPoint(in: start)
        }

        var transform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
        transform = transform.scaledBy(x: sx, y: sy)
        transform = transform.translatedBy(x: -anchor.x, y: -anchor.y)
        return transform
    }

    private func viewBoxTransform(viewBox: CGRect, size: CGSize, scale: CGFloat) -> CGAffineTransform {
        let sx = size.width / max(viewBox.width, 1)
        let sy = size.height / max(viewBox.height, 1)
        let fit = min(sx, sy) * scale
        let tx = (size.width - viewBox.width * fit) / 2.0 - viewBox.minX * fit
        let ty = (size.height - viewBox.height * fit) / 2.0 - viewBox.minY * fit
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: fit, y: fit)
    }

    private func effectiveViewBox(fallback: CGRect, paths: [CGPath]) -> CGRect {
        let defaultBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        var bounds: CGRect = .null
        for path in paths {
            let b = path.boundingBoxOfPath
            bounds = bounds.isNull ? b : bounds.union(b)
        }
        if bounds.isNull {
            return fallback
        }
        if fallback == defaultBox {
            return bounds
        }
        return fallback
    }

    private func drawGrid(in context: GraphicsContext, viewBox: CGRect) {
        guard gridSpacing > 0 else { return }
        var path = Path()
        let startX = floor(viewBox.minX / gridSpacing) * gridSpacing
        let endX = ceil(viewBox.maxX / gridSpacing) * gridSpacing
        let startY = floor(viewBox.minY / gridSpacing) * gridSpacing
        let endY = ceil(viewBox.maxY / gridSpacing) * gridSpacing

        var x = startX
        while x <= endX {
            path.move(to: CGPoint(x: x, y: viewBox.minY))
            path.addLine(to: CGPoint(x: x, y: viewBox.maxY))
            x += gridSpacing
        }

        var y = startY
        while y <= endY {
            path.move(to: CGPoint(x: viewBox.minX, y: y))
            path.addLine(to: CGPoint(x: viewBox.maxX, y: y))
            y += gridSpacing
        }

        context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
    }

    private func drawBorder(in context: GraphicsContext, viewBox: CGRect) {
        let rectPath = Path(viewBox)
        context.stroke(rectPath, with: .color(borderColor), lineWidth: 1)
    }
}

private extension Color {
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
        if let named = Color.named(trimmed) {
            self = named
            return
        }
        return nil
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

    static func named(_ name: String) -> Color? {
        switch name {
        case "black": return .black
        case "white": return .white
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "gray", "grey": return .gray
        case "yellow": return .yellow
        case "cyan": return .cyan
        case "magenta": return Color(.sRGB, red: 1.0, green: 0.0, blue: 1.0, opacity: 1.0)
        case "orange": return Color(.sRGB, red: 1.0, green: 0.55, blue: 0.0, opacity: 1.0)
        default: return nil
        }
    }
}

private enum DragMode {
    case move(startPoint: CGPoint)
    case resize(handle: Handle, startBounds: CGRect, startPoint: CGPoint)
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
