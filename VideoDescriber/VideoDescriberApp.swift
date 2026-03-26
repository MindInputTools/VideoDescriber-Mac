import SwiftUI
import AppIntents

@main
struct VideoDescriberApp: App {
    init() {
        // Register App Shortcuts so they're available in Siri and the Shortcuts app.
        VideoDescriberShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 480, minHeight: 320)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}
