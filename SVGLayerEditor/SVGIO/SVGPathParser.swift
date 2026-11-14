import CoreGraphics
import Foundation

/// Parses SVG path data (all commands of SVG 1.1: M L H V C S Q T A Z, absolute and relative).
struct SVGPathParser {
    /// Parses `d`. In lenient mode (rendering) the path is built up to the first error, as
    /// browsers do. In strict mode any error returns nil, so edits never truncate path data.
    func parse(_ d: String, strict: Bool = false) -> CGPath? {
        var scanner = SVGNumberScanner(d)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?        // reflected by S/s
        var lastQuadControl: CGPoint?    // reflected by T/t
        var command: Unicode.Scalar?
        var hasMove = false

        func fail() -> CGPath? {
            strict ? nil : (path.isEmpty ? nil : path)
        }

        while !scanner.isAtEnd {
            if let next = scanner.peek(), Self.commands.contains(next) {
                scanner.consumePeeked()
                command = next
            } else if command == nil || !scanner.peekIsNumberStart() {
                return fail()
            }
            guard let cmd = command else { return fail() }
            let relative = cmd.properties.isLowercase
            let base = relative ? current : .zero

            func point() -> CGPoint? {
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }

            if !hasMove && cmd != "M" && cmd != "m" {
                return fail()
            }

            switch cmd {
            case "M", "m":
                guard let p = point() else { return fail() }
                path.move(to: p)
                current = p
                subpathStart = p
                hasMove = true
                lastControl = nil
                lastQuadControl = nil
                // Further coordinate pairs are implicit line-to commands.
                command = relative ? "l" : "L"
                continue
            case "L", "l":
                guard let p = point() else { return fail() }
                path.addLine(to: p)
                current = p
                lastControl = nil
                lastQuadControl = nil
            case "H", "h":
                guard let x = scanner.nextNumber() else { return fail() }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil
            case "V", "v":
                guard let y = scanner.nextNumber() else { return fail() }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil
            case "C", "c":
                guard let c1 = point(), let c2 = point(), let end = point() else { return fail() }
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastControl = c2
                lastQuadControl = nil
            case "S", "s":
                guard let c2 = point(), let end = point() else { return fail() }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastControl = c2
                lastQuadControl = nil
            case "Q", "q":
                guard let c = point(), let end = point() else { return fail() }
                path.addQuadCurve(to: end, control: c)
                current = end
                lastQuadControl = c
                lastControl = nil
            case "T", "t":
                guard let end = point() else { return fail() }
                let c = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: end, control: c)
                current = end
                lastQuadControl = c
                lastControl = nil
            case "A", "a":
                guard let rx = scanner.nextNumber(), let ry = scanner.nextNumber(),
                      let rotation = scanner.nextNumber(),
                      let largeArc = scanner.nextFlag(), let sweep = scanner.nextFlag(),
                      let end = point() else { return fail() }
                Self.addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                            rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = end
                lastControl = nil
                lastQuadControl = nil
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil
                lastQuadControl = nil
                // Z takes no parameters; a following number is an error.
                command = nil
            default:
                return fail()
            }
        }
        return path.isEmpty ? nil : path
    }

    static func toPath(_ d: String, strict: Bool = false) -> CGPath? {
        SVGPathParser().parse(d, strict: strict)
    }

    static func serialize(path: CGPath) -> String {
        var chunks: [String] = []
        func p(_ point: CGPoint) -> String { "\(SVGFormat.number(point.x)) \(SVGFormat.number(point.y))" }
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                chunks.append("M\(p(points[0]))")
            case .addLineToPoint:
                chunks.append("L\(p(points[0]))")
            case .addQuadCurveToPoint:
                chunks.append("Q\(p(points[0])) \(p(points[1]))")
            case .addCurveToPoint:
                chunks.append("C\(p(points[0])) \(p(points[1])) \(p(points[2]))")
            case .closeSubpath:
                chunks.append("Z")
            @unknown default:
                break
            }
        }
        return chunks.joined(separator: " ")
    }

    private static let commands: Set<Unicode.Scalar> = [
        "M", "m", "L", "l", "H", "h", "V", "v", "C", "c", "S", "s", "Q", "q", "T", "t", "A", "a", "Z", "z"
    ]

    /// Endpoint-to-center arc conversion (SVG 1.1 implementation notes, F.6.5) approximated by cubic Béziers.
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var factor = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if largeArc == sweep { factor = -factor }
        let cxp = factor * rx * y1p / ry
        let cyp = -factor * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let kappa = 4.0 / 3.0 * tan(step / 4)

        func pointOnEllipse(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
                    y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
                    y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }

        var t = theta1
        for index in 0..<segments {
            let t2 = t + step
            let start = pointOnEllipse(t)
            let end = index == segments - 1 ? p1 : pointOnEllipse(t2)
            let d1 = derivative(t)
            let d2 = derivative(t2)
            let c1 = CGPoint(x: start.x + kappa * d1.x, y: start.y + kappa * d1.y)
            let c2 = CGPoint(x: end.x - kappa * d2.x, y: end.y - kappa * d2.y)
            path.addCurve(to: end, control1: c1, control2: c2)
            t = t2
        }
    }
}
