//
//  SVGLayerEditorApp.swift
//  SVGLayerEditor
//

import AppKit
import SwiftUI
import Combine
import Foundation

/// Asks about unsaved changes before the app quits (Cmd+Q, logout, restart).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shouldTerminate: () -> Bool = { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate() ? .terminateNow : .terminateCancel
    }
}

@main
struct SVGLayerEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = SVGLayerEditorViewModel()
    @StateObject private var settings = AppSettings()

    init() {
        UpdateChecker.checkForUpdate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(settings)
                .onAppear {
                    appDelegate.shouldTerminate = {
                        viewModel.confirmDiscardChangesIfNeeded()
                    }
                    if !viewModel.hasDocument {
                        viewModel.createEmptyDocument(size: settings.newDocumentSizeValue)
                    }
                }
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") {
                    viewModel.newDocument(size: settings.newDocumentSizeValue)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open...") {
                    viewModel.openDocument()
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Save") {
                    viewModel.saveDocument()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!viewModel.hasDocument)
                Button("Save As...") {
                    viewModel.saveDocumentAs()
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(!viewModel.hasDocument)
                Divider()
                Button("Export for Icon Composer...") {
                    viewModel.exportIconComposer()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!viewModel.hasDocument)
            }

            CommandGroup(after: .newItem) {
                Menu("Open Recent") {
                    if viewModel.recentFiles.isEmpty {
                        Text("No Recent Files")
                    } else {
                        ForEach(viewModel.recentFiles, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                viewModel.openRecent(url)
                            }
                        }
                        Divider()
                        Button("Clear Recent") {
                            viewModel.clearRecentFiles()
                        }
                    }
                }
            }

            CommandMenu("Clipboard") {
                Picker("Insert Mode", selection: $viewModel.clipboardMode) {
                    ForEach(ClipboardInsertMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Button("Insert") {
                    viewModel.insertFromClipboard()
                }
                .keyboardShortcut("V", modifiers: [.command, .shift])
                .disabled(!viewModel.hasDocument)
            }

            CommandMenu("Layer") {
                // Cmd+Delete: a plain Delete shortcut would also fire while typing in the XML editors.
                Button("Delete") {
                    viewModel.deleteSelection()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(viewModel.selectedNodeID == nil)
                Divider()
                Button("Move Up") {
                    viewModel.moveSelectionUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(viewModel.selectedNodeID == nil)
                Button("Move Down") {
                    viewModel.moveSelectionDown()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(viewModel.selectedNodeID == nil)
                Button("Indent") {
                    viewModel.indentSelection()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!viewModel.canIndentSelection)
                Button("Outdent") {
                    viewModel.outdentSelection()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(viewModel.selectedNodeID == nil)
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    viewModel.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!viewModel.hasUndo)
                Button("Redo") {
                    viewModel.redo()
                }
                .keyboardShortcut("Z", modifiers: [.command, .shift])
                .disabled(!viewModel.hasRedo)
            }
        }
    }
}
