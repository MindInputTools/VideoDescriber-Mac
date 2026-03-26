import AppIntents
import AppKit

/// App Intent that triggers the same "describe current video" action as the § hotkey.
/// Usable via Siri ("Hey Siri, describe video with VideoDescriber") or from the Shortcuts app.
struct DescribeVideoIntent: AppIntent {
    static var title: LocalizedStringResource = "Beskriv video"
    static var description = IntentDescription("Tar en skärmbild av den aktiva videon och beskriver scenen med AI.")

    /// The app needs to be running (but can stay in the background).
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let vm = MainViewModel.shared else {
            return .result(dialog: "VideoDescriber är inte redo ännu. Öppna appen först.")
        }

        // Capture frontmost app and window list before we do anything,
        // same as the hotkey handler does.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let cgWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] ?? []

        await vm.hotkeyTriggered(frontmostApp: frontApp, cgWindows: cgWindows)

        let response = vm.aiResponse
        if response.isEmpty {
            return .result(dialog: "Kunde inte beskriva videon.")
        }
        return .result(dialog: "\(response)")
    }
}

/// Provides the App Shortcut so it's available in Siri and the Shortcuts app
/// without any user configuration.
struct VideoDescriberShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DescribeVideoIntent(),
            phrases: [
                "Beskriv video med \(.applicationName)",
                "Describe video with \(.applicationName)",
                "Beskriv scenen med \(.applicationName)"
            ],
            shortTitle: "Beskriv video",
            systemImageName: "eye"
        )
    }
}
