import AppKit
import SwiftUI

/// Asks before closing a window with unsaved changes and mirrors the dirty state
/// into the window's close button.
///
/// SwiftUI installs its own window delegate. Replacing it outright breaks SwiftUI's
/// window handling, so the coordinator forwards every other delegate call to it.
struct WindowCloseHandler: NSViewRepresentable {
    let isDirty: Bool
    let shouldClose: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldClose: shouldClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window, isDirty: isDirty)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.attach(to: nsView.window, isDirty: isDirty)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool
        private weak var window: NSWindow?
        private weak var forwardedDelegate: NSWindowDelegate?

        init(shouldClose: @escaping () -> Bool) {
            self.shouldClose = shouldClose
        }

        func attach(to window: NSWindow?, isDirty: Bool) {
            guard let window else { return }
            window.isDocumentEdited = isDirty
            guard window.delegate !== self else { return }
            forwardedDelegate = window.delegate
            self.window = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forwardedDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let forwardedDelegate, forwardedDelegate.responds(to: aSelector) {
                return forwardedDelegate
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
