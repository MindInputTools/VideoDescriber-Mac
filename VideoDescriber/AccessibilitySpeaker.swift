import AppKit

/// Routes speech output through VoiceOver if it is running,
/// otherwise falls back to NSSpeechSynthesizer.
///
/// Supports both single-utterance and streaming modes. In streaming mode,
/// sentence-level chunks are queued and spoken sequentially, allowing speech
/// to begin before the full text is available.
@MainActor
class AccessibilitySpeaker: NSObject, NSSpeechSynthesizerDelegate {

    static let shared = AccessibilitySpeaker()

    // MARK: - Private
    private let synthesizer = NSSpeechSynthesizer()
    private(set) var isSpeaking: Bool = false
    private(set) var isUsingVoiceOver: Bool = false
    private var onFinished: (() -> Void)?

    // Streaming state
    private var speechQueue: [String] = []
    private var isStreamingMode: Bool = false
    private var isStreamingDone: Bool = false
    private var isSynthesizerChunkActive: Bool = false

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API (single utterance)

    /// Speak `text`. When `viaVoiceOver` is true and VoiceOver is running, routes
    /// through VoiceOver; otherwise uses NSSpeechSynthesizer.
    /// Calling this while already speaking will interrupt the current output first.
    /// The optional `onFinished` callback is called when speech ends.
    func speak(_ text: String, viaVoiceOver: Bool = false, onFinished: (() -> Void)? = nil) {
        stop(notifyFinished: false)
        self.onFinished = onFinished

        if viaVoiceOver && isVoiceOverRunning() {
            isUsingVoiceOver = true
            announceViaVoiceOver(text)
        } else {
            isUsingVoiceOver = false
            announceViaSynthesizer(text)
        }
    }

    // MARK: - Public API (streaming)

    /// Begin a streaming speech session. Chunks enqueued via `enqueueSpeechChunk`
    /// are spoken sequentially. Call `endStreaming` when all chunks have been enqueued.
    /// For VoiceOver, chunks are accumulated and spoken as one utterance at `endStreaming`.
    func beginStreaming(viaVoiceOver: Bool = false, onFinished: (() -> Void)? = nil) {
        stop(notifyFinished: false)
        self.onFinished = onFinished
        isStreamingMode = true
        isStreamingDone = false
        speechQueue.removeAll()

        if viaVoiceOver && isVoiceOverRunning() {
            isUsingVoiceOver = true
        } else {
            isUsingVoiceOver = false
            applyVoiceSettings()
            isSpeaking = true
        }
    }

    /// Add a chunk of text to be spoken. If the synthesizer is idle, speech starts immediately.
    func enqueueSpeechChunk(_ text: String) {
        guard isStreamingMode, !text.isEmpty else { return }

        speechQueue.append(text)

        if !isUsingVoiceOver && !isSynthesizerChunkActive {
            speakNextChunk()
        }
    }

    /// Signal that no more chunks will arrive. Triggers VoiceOver playback or
    /// completes the session once the last queued chunk finishes.
    func endStreaming() {
        guard isStreamingMode else { return }
        isStreamingDone = true

        if isUsingVoiceOver {
            let fullText = speechQueue.joined(separator: " ")
            speechQueue.removeAll()
            if !fullText.isEmpty {
                announceViaVoiceOver(fullText)
            } else {
                completeStreaming()
            }
        } else if !isSynthesizerChunkActive && speechQueue.isEmpty {
            completeStreaming()
        }
    }

    /// Stop any ongoing speech immediately.
    func stop() {
        stop(notifyFinished: true)
    }

    private func stop(notifyFinished: Bool) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
        speechQueue.removeAll()
        isStreamingMode = false
        isStreamingDone = false
        isSynthesizerChunkActive = false
        isSpeaking = false
        if notifyFinished {
            onFinished?()
        }
        onFinished = nil
    }

    // MARK: - Private (streaming)

    private func completeStreaming() {
        isStreamingMode = false
        isSynthesizerChunkActive = false
        isSpeaking = false
        onFinished?()
        onFinished = nil
    }

    private func speakNextChunk() {
        guard !speechQueue.isEmpty else {
            if isStreamingDone {
                completeStreaming()
            }
            return
        }

        let chunk = speechQueue.removeFirst()
        isSynthesizerChunkActive = true
        if !synthesizer.startSpeaking(chunk) {
            isSynthesizerChunkActive = false
            speakNextChunk()
        }
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
                if self.isStreamingMode {
                    self.completeStreaming()
                } else {
                    self.isSpeaking = false
                    self.onFinished?()
                    self.onFinished = nil
                }
            }
        }
    }

    // MARK: - NSSpeechSynthesizer fallback

    private func applyVoiceSettings() {
        let voiceID = UserDefaults.standard.string(forKey: "selectedVoice") ?? ""
        if voiceID.isEmpty {
            synthesizer.setVoice(nil)
        } else {
            synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voiceID))
        }
        let rate = UserDefaults.standard.double(forKey: "speechRate")
        synthesizer.rate = Float(rate > 0 ? rate : 175)
    }

    private func announceViaSynthesizer(_ text: String) {
        applyVoiceSettings()
        isSpeaking = true
        synthesizer.startSpeaking(text)
    }

    // MARK: - NSSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            if self.isStreamingMode {
                self.isSynthesizerChunkActive = false
                self.speakNextChunk()
            } else {
                self.isSpeaking = false
                self.onFinished?()
                self.onFinished = nil
            }
        }
    }
}
