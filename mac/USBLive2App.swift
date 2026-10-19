// USBLive2App.swift - app entry point, window and menus.
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        CaptureModel.shared.shutdown()
    }
}

@main
struct USBLive2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = CaptureModel.shared
    @ObservedObject private var editor = EditorModel.shared

    var body: some Scene {
        Window("USB-Live2", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                EditorMenuButton()
            }
            // Undo / Redo act on the editor's cuts and trims
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Edit") { editor.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!editor.canUndo)
                Button("Redo Edit") { editor.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!editor.canRedo)
            }
            CommandMenu("Capture") {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                    model.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.connection != .running)

                Button("Take Snapshot") { model.takeSnapshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.connection != .running)

                Divider()

                Button("Composite Input") { model.input = 0 }
                    .keyboardShortcut("1", modifiers: .command)
                Button("S-Video Input") { model.input = 1 }
                    .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button(model.muted ? "Unmute" : "Mute") { model.muted.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }

        Window("Edit Recording", id: "editor") {
            EditorView()
        }
        .defaultSize(width: 1100, height: 780)
    }
}

/// File > Edit a Recording… (a view, so it can use openWindow)
struct EditorMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Edit a Recording…") { openWindow(id: "editor") }
            .keyboardShortcut("e", modifiers: [.command, .shift])
    }
}
