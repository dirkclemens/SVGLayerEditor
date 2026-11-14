import AppKit
import SwiftUI

enum PlainTextEditorFontDesign: String, CaseIterable, Identifiable {
    case monospaced
    case system
    case rounded
    case serif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monospaced: return "Monospaced"
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        }
    }

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .system:
            return .systemFont(ofSize: size)
        case .rounded:
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.rounded)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        case .serif:
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        }
    }
}

struct PlainTextEditorConfiguration {
    var fontDesign: PlainTextEditorFontDesign = .monospaced
    var fontSize: CGFloat = NSFont.smallSystemFontSize
    var wrapLines: Bool = true
    var spellChecking: Bool = false
    var smartSubstitutions: Bool = false
    var textCompletion: Bool = false

    var font: NSFont {
        fontDesign.font(size: fontSize)
    }
}

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var configuration = PlainTextEditorConfiguration()

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = text
        textView.delegate = context.coordinator
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticDataDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .grooveBorder
        scrollView.documentView = textView
        applyConfiguration(configuration, to: textView, in: scrollView)
        
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.setTextIfNeeded(text)
        applyConfiguration(configuration, to: textView, in: nsView)
        textView.frame = nsView.contentView.bounds
    }

    private func applyConfiguration(_ configuration: PlainTextEditorConfiguration, to textView: NSTextView, in scrollView: NSScrollView) {
        let textColor = NSColor.textColor
        textView.font = configuration.font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.backgroundColor = .textBackgroundColor
        textView.typingAttributes[.foregroundColor] = textColor
        textView.typingAttributes[.font] = configuration.font
        textView.isAutomaticQuoteSubstitutionEnabled = configuration.smartSubstitutions
        textView.isAutomaticDashSubstitutionEnabled = configuration.smartSubstitutions
        textView.isAutomaticSpellingCorrectionEnabled = configuration.spellChecking
        textView.isContinuousSpellCheckingEnabled = configuration.spellChecking
        textView.isAutomaticTextCompletionEnabled = configuration.textCompletion
        textView.isHorizontallyResizable = !configuration.wrapLines
        textView.textContainer?.widthTracksTextView = configuration.wrapLines
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: configuration.wrapLines ? scrollView.contentSize.width : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        scrollView.hasHorizontalScroller = !configuration.wrapLines
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        private var isProgrammaticUpdate = false
        private var text: Binding<String>
        /// Typing has its own undo history; Cmd+Z in the editor undoes text, not document edits.
        private let textUndoManager = UndoManager()

        init(text: Binding<String>) {
            self.text = text
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            textUndoManager
        }

        func setTextIfNeeded(_ newText: String) {
            guard let textView, textView.string != newText else { return }
            isProgrammaticUpdate = true
            // Keep the cursor where it was as far as possible.
            let selection = textView.selectedRange()
            textView.string = newText
            let length = (newText as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            // The text was replaced from outside; old typing steps no longer apply to it.
            textUndoManager.removeAllActions()
            isProgrammaticUpdate = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if isProgrammaticUpdate { return }
            // Defer binding update to avoid publishing during view updates
            let newValue = textView.string
            if text.wrappedValue != newValue {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.text.wrappedValue != newValue {
                        self.text.wrappedValue = newValue
                    }
                }
            }
        }
    }
}
