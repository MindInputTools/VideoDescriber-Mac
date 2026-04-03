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

        // When triggered via Siri, the frontmost app is Siri itself, so we
        // cannot reliably detect the video window. Instead, require that
        // a window and video area have already been set up (via the § key
        // or the app UI).
        guard vm.hasCapture, vm.hasVideoArea else {
            return .result(dialog: "Inget videofönster valt. Använd §-tangenten eller appen för att välja ett fönster först.")
        }

        // Fire off the describe work in a detached task so we can return
        // to Siri immediately. The actual description will be spoken via
        // AccessibilitySpeaker / VoiceOver — we don't need Siri to wait
        // for the (potentially slow) AI response.
        Task { @MainActor in
            await vm.describe()
        }

        return .result(dialog: "Beskriver videon…")
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
