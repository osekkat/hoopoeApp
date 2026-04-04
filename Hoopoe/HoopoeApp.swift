import SwiftUI

@main
struct HoopoeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let settings = AppSettings.shared
    @State private var projectDirectory: URL?

    init() {
        _projectDirectory = State(initialValue: AppSettings.shared.lastProjectDirectory)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if projectDirectory != nil {
                    ContentView()
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    ProjectPickerView { url in
                        settings.lastProjectDirectory = url
                        settings.defaultSaveDirectory = planDirectory(for: url)
                        projectDirectory = url
                    }
                    .frame(minWidth: 540, minHeight: 400)
                }
            }
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            HoopoeCommands()

            CommandGroup(after: .newItem) {
                if projectDirectory != nil {
                    Button("Close Project") {
                        settings.lastProjectDirectory = nil
                        projectDirectory = nil
                    }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                }
            }
        }

        Settings {
            SettingsView()
        }
    }

    private func planDirectory(for projectURL: URL) -> URL {
        let dir = projectURL.appendingPathComponent(".hoopoe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enable window restoration
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
