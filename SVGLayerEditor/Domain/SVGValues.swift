import CoreGraphics
import Foundation

// MARK: - Number scanning

/// Scans SVG number lists ("10,20 30-40 .5.5 1e3") as used by `d`, `points`,
/// `viewBox` and `transform`. Separators are whitespace and commas; a sign or a
/// second decimal point also starts a new number, as required by the SVG grammar.
struct SVGNumberScanner {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ string: String) {
        scalars = Array(string.unicodeScalars)
    }

    var isAtEnd: Bool {
        var i = index
        skipSeparators(&i)
        return i >= scalars.count
    }

    /// The next non-separator character without consuming it.
    func peek() -> Unicode.Scalar? {
        var i = index
        skipSeparators(&i)
        return i < scalars.count ? scalars[i] : nil
    }

    /// Consumes the character returned by `peek()`.
    mutating func consumePeeked() {
        skipSeparators(&index)
        if index < scalars.count { index += 1 }
    }

    func peekIsNumberStart() -> Bool {
        guard let c = peek() else { return false }
        return c == "+" || c == "-" || c == "." || Self.isDigit(c)
    }

    mutating func nextNumber() -> CGFloat? {
        var i = index
        skipSeparators(&i)
        let start = i
        if i < scalars.count, scalars[i] == "+" || scalars[i] == "-" { i += 1 }
        var hasDigits = false
        while i < scalars.count, Self.isDigit(scalars[i]) { i += 1; hasDigits = true }
        if i < scalars.count, scalars[i] == "." {
            i += 1
            while i < scalars.count, Self.isDigit(scalars[i]) { i += 1; hasDigits = true }
        }
        guard hasDigits else { return nil }
        if i < scalars.count, scalars[i] == "e" || scalars[i] == "E" {
            var j = i + 1
            if j < scalars.count, scalars[j] == "+" || scalars[j] == "-" { j += 1 }
            var hasExponentDigits = false
            while j < scalars.count, Self.isDigit(scalars[j]) { j += 1; hasExponentDigits = true }
            if hasExponentDigits { i = j }
        }
        var text = String(String.UnicodeScalarView(scalars[start..<i]))
        if text.hasSuffix(".") { text.removeLast() }
        if text.hasPrefix(".") || text.hasPrefix("-.") || text.hasPrefix("+.") {
            text = text.replacingOccurrences(of: ".", with: "0.", options: [], range: text.range(of: "."))
        }
        guard let value = Double(text), value.isFinite else { return nil }
        index = i
        return CGFloat(value)
    }

    /// Arc flags are single characters and may be written without separators ("a1 1 0 00 5 5").
    mutating func nextFlag() -> Bool? {
        var i = index
        skipSeparators(&i)
        guard i < scalars.count else { return nil }
        switch scalars[i] {
        case "0": index = i + 1; return false
        case "1": index = i + 1; return true
        default: return nil
        }
    }

    static func numbers(in string: String) -> [CGFloat] {
        var scanner = SVGNumberScanner(string)
        var result: [CGFloat] = []
        while let value = scanner.nextNumber() {
            result.append(value)
        }
        return result
    }

    private func skipSeparators(_ i: inout Int) {
        while i < scalars.count, Self.isSeparator(scalars[i]) { i += 1 }
    }

    static func isSeparator(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" || c == "\u{0C}"
    }

    static func isDigit(_ c: Unicode.Scalar) -> Bool {
        c.value >= 48 && c.value <= 57
    }
}

// MARK: - Formatting

enum SVGFormat {
    /// Compact number output: rounded, without trailing zeros ("550" instead of "550.00").
    static func number(_ value: CGFloat, fractionDigits: Int = 2) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.\(fractionDigits)f", Double(value))
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return text
    }

    static func numbers(_ values: [CGFloat], fractionDigits: Int = 2) -> String {
        values.map { number($0, fractionDigits: fractionDigits) }.joined(separator: " ")
    }
}

// MARK: - Lengths, points, viewBox

enum SVGLength {
    /// Parses an SVG length in user units. Absolute units are converted (96 dpi);
    /// percentages and font-relative units return nil because they need a context.
    static func parse(_ value: String?) -> CGFloat? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let units: [(String, CGFloat)] = [
            ("px", 1), ("pt", 4.0 / 3.0), ("pc", 16), ("mm", 96 / 25.4), ("cm", 96 / 2.54), ("in", 96)
        ]
        var factor: CGFloat = 1
        for (unit, unitFactor) in units where text.lowercased().hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            factor = unitFactor
            break
        }
        guard let number = Double(text), number.isFinite else { return nil }
        return CGFloat(number) * factor
    }

    static func number(_ attributes: [String: String], _ key: String) -> CGFloat? {
        parse(attributes[key])
    }
}

enum SVGPoints {
    static func parse(_ value: String?) -> [CGPoint]? {
        guard let value else { return nil }
        let numbers = SVGNumberScanner.numbers(in: value)
        guard numbers.count >= 2 else { return nil }
        return stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
    }

    static func serialize(_ points: [CGPoint]) -> String {
        points.map { "\(SVGFormat.number($0.x)),\(SVGFormat.number($0.y))" }.joined(separator: " ")
    }
}

enum SVGViewBox {
    static func parse(_ value: String?) -> CGRect? {
        guard let value else { return nil }
        let numbers = SVGNumberScanner.numbers(in: value)
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    static func serialize(_ rect: CGRect) -> String {
        SVGFormat.numbers([rect.minX, rect.minY, rect.width, rect.height])
    }

    /// The user-space rectangle of an `<svg>` element: its viewBox, or 0 0 width height.
    static func canvas(of attributes: [String: String]) -> CGRect? {
        if let box = parse(attributes["viewBox"]) {
            return box
        }
        if let width = SVGLength.number(attributes, "width"), let height = SVGLength.number(attributes, "height"),
           width > 0, height > 0 {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        return nil
    }

    /// Transform from the viewBox of a nested `<svg>` into its parent's user space
    /// (preserveAspectRatio "xMidYMid meet").
    static func viewportTransform(of attributes: [String: String]) -> CGAffineTransform {
        let x = SVGLength.number(attributes, "x") ?? 0
        let y = SVGLength.number(attributes, "y") ?? 0
        guard let box = parse(attributes["viewBox"]) else {
            return CGAffineTransform(translationX: x, y: y)
        }
        let width = SVGLength.number(attributes, "width") ?? box.width
        let height = SVGLength.number(attributes, "height") ?? box.height
        let scale = min(width / box.width, height / box.height)
        let tx = x + (width - box.width * scale) / 2 - box.minX * scale
        let ty = y + (height - box.height * scale) / 2 - box.minY * scale
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }
}

// MARK: - Transforms

enum SVGTransform {
    /// Parses a `transform` attribute. Returns nil when the value is malformed so
    /// callers never rewrite geometry based on a misread transform.
    static func parse(_ value: String?) -> CGAffineTransform? {
        guard let value else { return .identity }
        var result = CGAffineTransform.identity
        var rest = Substring(value)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "," }
            if rest.isEmpty { break }
            guard let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") else { return nil }
            let name = rest[..<open].trimmingCharacters(in: .whitespaces)
            let args = SVGNumberScanner.numbers(in: String(rest[rest.index(after: open)..<close]))
            guard let item = transform(named: name, arguments: args) else { return nil }
            // "A B" applies B first, then A.
            result = item.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    private static func transform(named name: String, arguments a: [CGFloat]) -> CGAffineTransform? {
        switch (name, a.count) {
        case ("matrix", 6):
            return CGAffineTransform(a: a[0], b: a[1], c: a[2], d: a[3], tx: a[4], ty: a[5])
        case ("translate", 1):
            return CGAffineTransform(translationX: a[0], y: 0)
        case ("translate", 2):
            return CGAffineTransform(translationX: a[0], y: a[1])
        case ("scale", 1):
            return CGAffineTransform(scaleX: a[0], y: a[0])
        case ("scale", 2):
            return CGAffineTransform(scaleX: a[0], y: a[1])
        case ("rotate", 1):
            return CGAffineTransform(rotationAngle: a[0] * .pi / 180)
        case ("rotate", 3):
            return CGAffineTransform(translationX: a[1], y: a[2])
                .rotated(by: a[0] * .pi / 180)
                .translatedBy(x: -a[1], y: -a[2])
        case ("skewX", 1):
            return CGAffineTransform(a: 1, b: 0, c: tan(a[0] * .pi / 180), d: 1, tx: 0, ty: 0)
        case ("skewY", 1):
            return CGAffineTransform(a: 1, b: tan(a[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
        default:
            return nil
        }
    }

    /// Formats a transform in its most readable SVG form, or nil for the identity.
    static func format(_ t: CGAffineTransform) -> String? {
        let eps: CGFloat = 1e-6
        func zero(_ v: CGFloat) -> Bool { abs(v) < eps }
        func n(_ v: CGFloat) -> String { SVGFormat.number(v) }
        func f(_ v: CGFloat) -> String { SVGFormat.number(v, fractionDigits: 5) }

        if zero(t.b) && zero(t.c) {
            let isTranslation = zero(t.tx) && zero(t.ty)
            if zero(t.a - 1) && zero(t.d - 1) {
                return isTranslation ? nil : "translate(\(n(t.tx)) \(n(t.ty)))"
            }
            let scale = zero(t.a - t.d) ? "scale(\(f(t.a)))" : "scale(\(f(t.a)) \(f(t.d)))"
            return isTranslation ? scale : "translate(\(n(t.tx)) \(n(t.ty))) \(scale)"
        }

        let isRotation = zero(t.a - t.d) && zero(t.b + t.c) && abs(t.a * t.a + t.b * t.b - 1) < 1e-4
        if isRotation {
            let degrees = atan2(t.b, t.a) * 180 / .pi
            if zero(t.tx) && zero(t.ty) {
                return "rotate(\(n(degrees)))"
            }
            let det = (1 - t.a) * (1 - t.d) - t.b * t.c
            if abs(det) > eps {
                let cx = (t.tx * (1 - t.d) + t.c * t.ty) / det
                let cy = ((1 - t.a) * t.ty + t.b * t.tx) / det
                return "rotate(\(n(degrees)) \(n(cx)) \(n(cy)))"
            }
        }
        return "matrix(\(f(t.a)) \(f(t.b)) \(f(t.c)) \(f(t.d)) \(n(t.tx)) \(n(t.ty)))"
    }

    static func isAxisAligned(_ t: CGAffineTransform) -> Bool {
        abs(t.b) < 1e-9 && abs(t.c) < 1e-9
    }
}

// MARK: - Style attribute

enum SVGStyle {
    /// Parses a `style` attribute ("fill: red; stroke-width: 2") into declarations.
    static func declarations(_ style: String?) -> [String: String] {
        guard let style else { return [:] }
        var result: [String: String] = [:]
        for declaration in style.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix("!important") {
                value = String(value.dropLast("!important".count)).trimmingCharacters(in: .whitespaces)
            }
            if !name.isEmpty { result[name] = value }
        }
        return result
    }

    /// Presentation attributes and style declarations merged; `style` wins, as in CSS.
    static func properties(of attributes: [String: String]) -> [String: String] {
        var result = attributes
        result.removeValue(forKey: "style")
        for (name, value) in declarations(attributes["style"]) {
            result[name] = value
        }
        return result
    }

    static func value(_ name: String, in attributes: [String: String]) -> String? {
        declarations(attributes["style"])[name] ?? attributes[name]
    }

    /// Sets a presentation property where it currently lives: inside `style` if it is
    /// declared there (otherwise the style would override the attribute), else as attribute.
    static func set(_ name: String, to value: String?, in attributes: inout [String: String]) {
        var styleDeclarations = declarations(attributes["style"])
        if styleDeclarations[name] != nil {
            styleDeclarations[name] = value
            let style = styleDeclarations.keys.sorted()
                .compactMap { key in styleDeclarations[key].map { "\(key): \($0)" } }
                .joined(separator: "; ")
            attributes["style"] = style.isEmpty ? nil : style
            attributes.removeValue(forKey: name)
        } else {
            attributes[name] = value
        }
    }
}
