import AppKit
import Combine
import SwiftUI

final class AppSettings: ObservableObject {
    @Published var moveSensitivity: Double {
        didSet { defaults.set(moveSensitivity, forKey: Keys.moveSensitivity) }
    }

    @Published var resizeSensitivity: Double {
        didSet { defaults.set(resizeSensitivity, forKey: Keys.resizeSensitivity) }
    }

    @Published var gridSpacing: Double {
        didSet { defaults.set(gridSpacing, forKey: Keys.gridSpacing) }
    }

    @Published var gridColorHex: String {
        didSet { defaults.set(gridColorHex, forKey: Keys.gridColorHex) }
    }

    @Published var borderColorHex: String {
        didSet { defaults.set(borderColorHex, forKey: Keys.borderColorHex) }
    }

    @Published var editorFontDesignRawValue: String {
        didSet { defaults.set(editorFontDesignRawValue, forKey: Keys.editorFontDesign) }
    }

    @Published var editorFontSize: Double {
        didSet { defaults.set(editorFontSize, forKey: Keys.editorFontSize) }
    }

    @Published var editorWrapLines: Bool {
        didSet { defaults.set(editorWrapLines, forKey: Keys.editorWrapLines) }
    }

    @Published var editorSpellChecking: Bool {
        didSet { defaults.set(editorSpellChecking, forKey: Keys.editorSpellChecking) }
    }

    @Published var editorSmartSubstitutions: Bool {
        didSet { defaults.set(editorSmartSubstitutions, forKey: Keys.editorSmartSubstitutions) }
    }

    @Published var editorTextCompletion: Bool {
        didSet { defaults.set(editorTextCompletion, forKey: Keys.editorTextCompletion) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.moveSensitivity = defaults.object(forKey: Keys.moveSensitivity) as? Double ?? 0.1
        self.resizeSensitivity = defaults.object(forKey: Keys.resizeSensitivity) as? Double ?? 0.1
        self.gridSpacing = defaults.object(forKey: Keys.gridSpacing) as? Double ?? 50
        self.gridColorHex = defaults.string(forKey: Keys.gridColorHex) ?? "#80808040"
        self.borderColorHex = defaults.string(forKey: Keys.borderColorHex) ?? "#80808080"
        self.editorFontDesignRawValue = defaults.string(forKey: Keys.editorFontDesign) ?? PlainTextEditorFontDesign.monospaced.rawValue
        self.editorFontSize = defaults.object(forKey: Keys.editorFontSize) as? Double ?? Double(NSFont.smallSystemFontSize)
        self.editorWrapLines = defaults.object(forKey: Keys.editorWrapLines) as? Bool ?? true
        self.editorSpellChecking = defaults.object(forKey: Keys.editorSpellChecking) as? Bool ?? false
        self.editorSmartSubstitutions = defaults.object(forKey: Keys.editorSmartSubstitutions) as? Bool ?? false
        self.editorTextCompletion = defaults.object(forKey: Keys.editorTextCompletion) as? Bool ?? false
    }

    var moveSensitivityValue: CGFloat { CGFloat(moveSensitivity) }
    var resizeSensitivityValue: CGFloat { CGFloat(resizeSensitivity) }
    var gridSpacingValue: CGFloat { CGFloat(gridSpacing) }

    var gridColor: Color {
        get { StoredColor.decode(gridColorHex) ?? Color.gray.opacity(0.25) }
        set { gridColorHex = StoredColor.encode(newValue) }
    }

    var borderColor: Color {
        get { StoredColor.decode(borderColorHex) ?? Color.gray.opacity(0.5) }
        set { borderColorHex = StoredColor.encode(newValue) }
    }

    var editorFontDesign: PlainTextEditorFontDesign {
        get { PlainTextEditorFontDesign(rawValue: editorFontDesignRawValue) ?? .monospaced }
        set { editorFontDesignRawValue = newValue.rawValue }
    }

    var plainTextEditorConfiguration: PlainTextEditorConfiguration {
        PlainTextEditorConfiguration(
            fontDesign: editorFontDesign,
            fontSize: CGFloat(editorFontSize),
            wrapLines: editorWrapLines,
            spellChecking: editorSpellChecking,
            smartSubstitutions: editorSmartSubstitutions,
            textCompletion: editorTextCompletion
        )
    }

    func resetPreviewSettings() {
        moveSensitivity = 0.1
        resizeSensitivity = 0.1
        gridSpacing = 50
        gridColorHex = "#80808040"
        borderColorHex = "#80808080"
    }

    func resetEditorSettings() {
        editorFontDesign = .monospaced
        editorFontSize = Double(NSFont.smallSystemFontSize)
        editorWrapLines = true
        editorSpellChecking = false
        editorSmartSubstitutions = false
        editorTextCompletion = false
    }
}

private enum Keys {
    static let moveSensitivity = "settings.preview.moveSensitivity"
    static let resizeSensitivity = "settings.preview.resizeSensitivity"
    static let gridSpacing = "settings.preview.gridSpacing"
    static let gridColorHex = "settings.preview.gridColorHex"
    static let borderColorHex = "settings.preview.borderColorHex"
    static let editorFontDesign = "settings.editor.fontDesign"
    static let editorFontSize = "settings.editor.fontSize"
    static let editorWrapLines = "settings.editor.wrapLines"
    static let editorSpellChecking = "settings.editor.spellChecking"
    static let editorSmartSubstitutions = "settings.editor.smartSubstitutions"
    static let editorTextCompletion = "settings.editor.textCompletion"
}

private enum StoredColor {
    static func encode(_ color: Color) -> String {
        let resolved = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        let r = Int(round(resolved.redComponent * 255))
        let g = Int(round(resolved.greenComponent * 255))
        let b = Int(round(resolved.blueComponent * 255))
        let a = Int(round(resolved.alphaComponent * 255))
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    static func decode(_ value: String) -> Color? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        guard hex.count == 6 || hex.count == 8 else { return nil }

        var raw: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&raw) else { return nil }

        let r, g, b, a: Double
        if hex.count == 6 {
            r = Double((raw & 0xFF0000) >> 16) / 255.0
            g = Double((raw & 0x00FF00) >> 8) / 255.0
            b = Double(raw & 0x0000FF) / 255.0
            a = 1.0
        } else {
            r = Double((raw & 0xFF000000) >> 24) / 255.0
            g = Double((raw & 0x00FF0000) >> 16) / 255.0
            b = Double((raw & 0x0000FF00) >> 8) / 255.0
            a = Double(raw & 0x000000FF) / 255.0
        }

        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
