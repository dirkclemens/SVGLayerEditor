//
//  SVGLayerEditorApp.swift
//  SVGLayerEditor
//

import AppKit
import SwiftUI
import Combine
import Foundation

/// App-level events: quitting with unsaved changes and files opened from Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shouldTerminate: () -> Bool = { true }

    /// Set once the window is up; files opened before that are queued.
    var openFile: ((URL) -> Void)? {
        didSet {
            guard let openFile else { return }
            let pending = pendingFiles
            pendingFiles = []
            pending.forEach(openFile)
        }
    }
    private var pendingFiles: [URL] = []

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate() ? .terminateNow : .terminateCancel
    }

    /// The app edits one document in one window; closing it ends the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// "Open With", double-click (if chosen as default app) and drops on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        // One document at a time: open the last file.
        guard let url = urls.last else { return }
        if let openFile {
            openFile(url)
        } else {
            pendingFiles = [url]
        }
    }
}

@main
struct SVGLayerEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = SVGLayerEditorViewModel()
    @StateObject private var settings = AppSettings()

    init() {
        // No network calls while the app hosts unit tests.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            UpdateChecker.checkForUpdate()
        }
    }

    var body: some Scene {
        // A single window: all state lives in one view model, so a WindowGroup would show
        // the same document in several windows.
        Window("SVG Layer Editor", id: "main") {
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
                    appDelegate.openFile = { url in
                        viewModel.openDocument(at: url)
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

            // Undo/Redo use the standard Edit menu items: they act on the focused XML editor's
            // typing, or on the document through the window's UndoManager.
        }
    }
}
