import AppKit

/// Routes speech output through VoiceOver if it is running,
/// otherwise falls back to NSSpeechSynthesizer.
///
/// VoiceOver announcements are interruptible with the standard VO controls
/// (e.g. Control key to stop). The synthesizer fallback can be stopped
/// by calling `stop()`.
@MainActor
class AccessibilitySpeaker: NSObject, NSSpeechSynthesizerDelegate {

    static let shared = AccessibilitySpeaker()

    // MARK: - Private
    private let synthesizer = NSSpeechSynthesizer()
    private(set) var isSpeaking: Bool = false
    private var onFinished: (() -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self
        // Prefer a Swedish voice if available
        let svVoice = NSSpeechSynthesizer.availableVoices.first {
            $0.rawValue.contains("sv-SE") || $0.rawValue.contains("sv_SE")
        }
        if let svVoice {
            synthesizer.setVoice(svVoice)
        }
    }

    // MARK: - Public API

    /// Speak `text`. Routes through VoiceOver if active, NSSpeechSynthesizer otherwise.
    /// Calling this while already speaking will interrupt the current output first.
    /// The optional `onFinished` callback is called when speech ends.
    func speak(_ text: String, onFinished: (() -> Void)? = nil) {
        stop() // Interrupt any ongoing speech
        self.onFinished = onFinished

        if isVoiceOverRunning() {
            announceViaVoiceOver(text)
        } else {
            announceViaSynthesizer(text)
        }
    }

    /// Stop any ongoing speech immediately.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
        // VoiceOver announcements cannot be programmatically cancelled,
        // but the user can always press Control to silence VO.
        isSpeaking = false
        onFinished?()
        onFinished = nil
    }

    // MARK: - VoiceOver

    private func isVoiceOverRunning() -> Bool {
        if #available(macOS 13.0, *) {
            return NSWorkspace.shared.isVoiceOverEnabled
        }
        let axValue = UserDefaults.standard.bool(forKey: "com.apple.universalaccess.voiceOverOnOffKey")
        return axValue
    }

    private func announceViaVoiceOver(_ text: String) {
        // Use VoiceOver's AppleScript binding for reliable speech output.
        // The user can press Control to silence VoiceOver as usual.
        let sanitized = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"VoiceOver\" to output \"\(sanitized)\""
        
        isSpeaking = true
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
            process.waitUntilExit()
            await MainActor.run {
                self.isSpeaking = false
                self.onFinished?()
                self.onFinished = nil
            }
        }
    }

    // MARK: - NSSpeechSynthesizer fallback

    private func announceViaSynthesizer(_ text: String) {
        isSpeaking = true
        synthesizer.startSpeaking(text)
    }

    // MARK: - NSSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onFinished?()
            self.onFinished = nil
        }
    }
}
