import AppKit
import SwiftUI

struct NSColorWellPicker: NSViewRepresentable {
    @Binding var color: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(color: $color)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let colorWell = NSColorWell(style: .minimal)
        colorWell.target = context.coordinator
        colorWell.action = #selector(Coordinator.colorDidChange(_:))
        colorWell.color = resolvedColor(color)
        return colorWell
    }

    func updateNSView(_ nsView: NSColorWell, context: Context) {
        let resolved = resolvedColor(color)
        if !nsView.color.isEqual(resolved) {
            nsView.color = resolved
        }
    }

    static func dismantleNSView(_ nsView: NSColorWell, coordinator: Coordinator) {
        nsView.deactivate()
        nsView.target = nil
        nsView.action = nil
    }

    private func resolvedColor(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.deviceRGB) ?? color
    }

    final class Coordinator: NSObject {
        private var color: Binding<NSColor>

        init(color: Binding<NSColor>) {
            self.color = color
        }

        @objc func colorDidChange(_ sender: NSColorWell) {
            guard sender.window != nil else { return }
            color.wrappedValue = sender.color.usingColorSpace(.deviceRGB) ?? sender.color
        }
    }
}
