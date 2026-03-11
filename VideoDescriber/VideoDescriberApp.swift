import SwiftUI

@main
struct VideoDescriberApp: App {
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
