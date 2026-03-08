import CoreGraphics
import Foundation

struct SVGPathParser {
    enum Command: Character {
        case moveAbs = "M"
        case moveRel = "m"
        case lineAbs = "L"
        case lineRel = "l"
        case horizAbs = "H"
        case horizRel = "h"
        case vertAbs = "V"
        case vertRel = "v"
        case cubicAbs = "C"
        case cubicRel = "c"
        case closeAbs = "Z"
        case closeRel = "z"
    }

    func parse(_ d: String) -> CGPath? {
        var scanner = PathScanner(d)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var startPoint = CGPoint.zero
        var lastCommand: Command?

        while true {
            let nextCommand = scanner.nextCommand()
            let command: Command
            if let nextCommand {
                command = nextCommand
                lastCommand = command
            } else if let lastCommand, scanner.peekNumberAvailable() {
                command = lastCommand
            } else {
                break
            }
            switch command {
            case .moveAbs:
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                current = CGPoint(x: x, y: y)
                startPoint = current
                path.move(to: current)
                while let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber() {
                    current = CGPoint(x: x2, y: y2)
                    path.addLine(to: current)
                }
            case .moveRel:
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return path }
                current = CGPoint(x: current.x + x, y: current.y + y)
                startPoint = current
                path.move(to: current)
                while let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber() {
                    current = CGPoint(x: current.x + x2, y: current.y + y2)
                    path.addLine(to: current)
                }
            case .lineAbs:
                while let x = scanner.nextNumber(), let y = scanner.nextNumber() {
                    current = CGPoint(x: x, y: y)
                    path.addLine(to: current)
                }
            case .lineRel:
                while let x = scanner.nextNumber(), let y = scanner.nextNumber() {
                    current = CGPoint(x: current.x + x, y: current.y + y)
                    path.addLine(to: current)
                }
            case .horizAbs:
                while let x = scanner.nextNumber() {
                    current = CGPoint(x: x, y: current.y)
                    path.addLine(to: current)
                }
            case .horizRel:
                while let x = scanner.nextNumber() {
                    current = CGPoint(x: current.x + x, y: current.y)
                    path.addLine(to: current)
                }
            case .vertAbs:
                while let y = scanner.nextNumber() {
                    current = CGPoint(x: current.x, y: y)
                    path.addLine(to: current)
                }
            case .vertRel:
                while let y = scanner.nextNumber() {
                    current = CGPoint(x: current.x, y: current.y + y)
                    path.addLine(to: current)
                }
            case .cubicAbs:
                while let x1 = scanner.nextNumber(), let y1 = scanner.nextNumber(),
                      let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() {
                    let c1 = CGPoint(x: x1, y: y1)
                    let c2 = CGPoint(x: x2, y: y2)
                    let end = CGPoint(x: x, y: y)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end
                }
            case .cubicRel:
                while let x1 = scanner.nextNumber(), let y1 = scanner.nextNumber(),
                      let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() {
                    let c1 = CGPoint(x: current.x + x1, y: current.y + y1)
                    let c2 = CGPoint(x: current.x + x2, y: current.y + y2)
                    let end = CGPoint(x: current.x + x, y: current.y + y)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end
                }
            case .closeAbs, .closeRel:
                path.closeSubpath()
                current = startPoint
            }
        }

        return path
    }

    static func toPath(_ d: String) -> CGPath? {
        SVGPathParser().parse(d)
    }

    static func serialize(path: CGPath) -> String {
        var chunks: [String] = []
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                chunks.append("M \(format(points[0].x)) \(format(points[0].y))")
            case .addLineToPoint:
                chunks.append("L \(format(points[0].x)) \(format(points[0].y))")
            case .addQuadCurveToPoint:
                chunks.append("Q \(format(points[0].x)) \(format(points[0].y)) \(format(points[1].x)) \(format(points[1].y))")
            case .addCurveToPoint:
                chunks.append("C \(format(points[0].x)) \(format(points[0].y)) \(format(points[1].x)) \(format(points[1].y)) \(format(points[2].x)) \(format(points[2].y))")
            case .closeSubpath:
                chunks.append("Z")
            @unknown default:
                break
            }
        }
        return chunks.joined(separator: " ")
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }
}

private struct PathScanner {
    private let scalars: [UnicodeScalar]
    private var index: Int = 0

    init(_ d: String) {
        self.scalars = Array(d.unicodeScalars)
    }

    mutating func nextCommand() -> SVGPathParser.Command? {
        skipSeparators()
        guard index < scalars.count else { return nil }
        let scalar = scalars[index]
        if let command = SVGPathParser.Command(rawValue: Character(scalar)) {
            index += 1
            return command
        }
        return nil
    }

    func peekNumberAvailable() -> Bool {
        var idx = index
        skipSeparators(&idx)
        guard idx < scalars.count else { return false }
        let c = scalars[idx]
        if c == "+" || c == "-" || c == "." { return true }
        return c.properties.numericType != nil
    }

    mutating func nextNumber() -> CGFloat? {
        skipSeparators()
        guard index < scalars.count else { return nil }
        let start = index
        var hasSign = false
        var hasDot = false
        var hasDigit = false
        var hasExp = false

        while index < scalars.count {
            let c = scalars[index]
            if c == "+" || c == "-" {
                if hasDigit || hasSign || hasDot || hasExp { break }
                hasSign = true
                index += 1
            } else if c == "." {
                if hasDot || hasExp { break }
                hasDot = true
                index += 1
            } else if c == "e" || c == "E" {
                if hasExp || !hasDigit { break }
                hasExp = true
                hasSign = false
                hasDot = false
                index += 1
            } else if c.properties.numericType != nil {
                hasDigit = true
                index += 1
            } else {
                break
            }
        }

        if !hasDigit { return nil }
        let numberString = String(String.UnicodeScalarView(scalars[start..<index]))
        return CGFloat(Double(numberString) ?? 0)
    }

    mutating func skipSeparators() {
        Self.skipSeparators(&index, scalars: scalars)
    }

    private func skipSeparators(_ idx: inout Int) {
        Self.skipSeparators(&idx, scalars: scalars)
    }

    private static func skipSeparators(_ idx: inout Int, scalars: [UnicodeScalar]) {
        while idx < scalars.count {
            let c = scalars[idx]
            if c == " " || c == "\n" || c == "\t" || c == "," {
                idx += 1
            } else {
                break
            }
        }
    }
}
