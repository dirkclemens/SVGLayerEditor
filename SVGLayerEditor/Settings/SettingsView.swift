import SwiftUI
import Foundation
import Combine

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            previewTab
                .tabItem {
                    Label("Preview", systemImage: "cursorarrow.motionlines")
                }

            editorTab
                .tabItem {
                    Label("Editor", systemImage: "text.alignleft")
                }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }

    private var previewTab: some View {
        Form {
            LabeledContent("Move Sensitivity") {
                valueSlider(value: $settings.moveSensitivity, range: 0.05...1.0, step: 0.05, fractionDigits: 2)
            }

            LabeledContent("Resize Sensitivity") {
                valueSlider(value: $settings.resizeSensitivity, range: 0.05...1.0, step: 0.05, fractionDigits: 2)
            }

            LabeledContent("Grid Spacing") {
                valueSlider(value: $settings.gridSpacing, range: 0...200, step: 5, fractionDigits: 0)
            }

            LabeledContent("New Document Size") {
                HStack {
                    TextField("Size", value: $settings.newDocumentSize, format: .number.precision(.fractionLength(0)))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("× \(settings.newDocumentSize.formatted(.number.precision(.fractionLength(0))))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Icon Composer (1024)") {
                        settings.newDocumentSize = Double(SVGLayerEditorViewModel.defaultDocumentSize)
                    }
                }
            }

            ColorPicker(
                "Grid Color",
                selection: Binding(
                    get: { settings.gridColor },
                    set: { settings.gridColor = $0 }
                ),
                supportsOpacity: true
            )

            ColorPicker(
                "Border Color",
                selection: Binding(
                    get: { settings.borderColor },
                    set: { settings.borderColor = $0 }
                ),
                supportsOpacity: true
            )

            HStack {
                Spacer()
                Button("Reset Preview Settings") {
                    settings.resetPreviewSettings()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var editorTab: some View {
        Form {
            Picker("Font", selection: Binding(
                get: { settings.editorFontDesign },
                set: { settings.editorFontDesign = $0 }
            )) {
                ForEach(PlainTextEditorFontDesign.allCases) { design in
                    Text(design.title).tag(design)
                }
            }

            LabeledContent("Font Size") {
                valueSlider(value: $settings.editorFontSize, range: 10...24, step: 1, fractionDigits: 0)
            }

            Toggle("Wrap Lines", isOn: $settings.editorWrapLines)
            Toggle("Spell Checking", isOn: $settings.editorSpellChecking)
            Toggle("Smart Quotes and Dashes", isOn: $settings.editorSmartSubstitutions)
            Toggle("Text Completion", isOn: $settings.editorTextCompletion)

            VStack(alignment: .leading, spacing: 8) {
                Text("Sample")
                    .font(.headline)
                Text(sampleText)
                    .font(Font(settings.plainTextEditorConfiguration.font))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("Reset Editor Settings") {
                    settings.resetEditorSettings()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func valueSlider(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int
    ) -> some View {
        HStack {
            Slider(value: value, in: range, step: step)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(fractionDigits))))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private let sampleText = """
<text x="120" y="80" font-size="18" fill="#202020">
    Preview your XML editor style here.
</text>
"""
}
