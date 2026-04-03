import SwiftUI

struct HoopoeCommands: Commands {
    var body: some Commands {
        // File menu additions
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open Plan...") {
                // Placeholder — plan import comes in br-2bf.20
            }
            .keyboardShortcut("o")
        }

        // View menu
        CommandMenu("View") {
            Button("Toggle Sidebar") {
                NSApp.keyWindow?.firstResponder?.tryToPerform(
                    #selector(NSSplitViewController.toggleSidebar(_:)),
                    with: nil
                )
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }

        // Help menu override
        CommandGroup(replacing: .help) {
            Button("Hoopoe Help") {
                // Placeholder — help system
            }
        }
    }
}
