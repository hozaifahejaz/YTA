import AppKit
import DesignSystem
import SwiftUI

@main
struct YTAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("YTA", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)
                .task { model.start() }
        }
        .defaultSize(width: 1320, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Channel…") { model.showNewChannel = true }
                    .keyboardShortcut("n")
                Button("Import Channel…") { model.showImportChannel = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Steps") {
                ForEach(1...9, id: \.self) { number in
                    Button("Go to Step \(number)") { model.selectNode(at: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                        .disabled(model.setupRow == nil)
                }
                Divider()
                Button("Stop Run") {}
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(true)
            }
            CommandGroup(after: .appSettings) {
                Button("Health Check…") { model.showHealthCheck = true }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.light)
        }

        // Runs keep going when the window is closed. The menu bar item says what is running (section 5.2).
        MenuBarExtra("YTA", systemImage: "play.rectangle") {
            MenuBarContent()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Light mode only (section 6.2).
        NSApp.appearance = NSAppearance(named: .aqua)
        // Also lets an unbundled `swift run` build show a normal window and Dock icon.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Nothing is running")
        Divider()
        Button("Open YTA") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Health Check…") {
            openWindow(id: "main")
            model.showHealthCheck = true
            NSApp.activate()
        }
        Divider()
        Button("Quit YTA") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
