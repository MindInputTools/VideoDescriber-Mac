import Foundation
import SwiftUI
import Combine
import ScreenCaptureKit
import CoreImage
import CoreGraphics
import Carbon.HIToolbox
import AppKit

@MainActor
class MainViewModel: ObservableObject {
    /// Shared instance so App Intents (Siri Shortcuts) can trigger actions.
    static var shared: MainViewModel?

    // MARK: - Published State
    @Published var statusMessage: String = "Väntar på fönsterval..."
    @Published var statusColor: Color = .orange
    @Published var isCapturing: Bool = false
    @Published var isCalibrating: Bool = false
    @Published var isDescribing: Bool = false
    @Published var aiResponse: String = ""
    @Published var hasCapture: Bool = false
    @Published var hasVideoArea: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var detectionDiagnostics: String = ""
    @Published var selectedAppName: String?
    @Published var selectedWindowTitle: String?
    @Published var videoAreaDescription: String?

    // MARK: - Inställningar (UserDefaults)
    @AppStorage("selectedModel") private var selectedModel = "ministral-3:latest"
    @AppStorage("systemPrompt") private var systemPrompt = SettingsView.defaultSystemPrompt
    @AppStorage("defaultQuestion") private var defaultQuestion =
    SettingsView.defaultDefaultQuestion
    @AppStorage("useVoiceOver") private var useVoiceOver = false
    @AppStorage("detectionMethod") private var detectionMethodRaw = VideoDetectionMethod.smartBorder.rawValue
    @AppStorage("followFrontmost") private var followFrontmost = false

    // MARK: - Private State
    private var captureManager: ScreenCaptureManager?
    private let smartBorderDetector = SmartBorderDetector()
    private let motionDetector = VideoMotionDetector()
    private var ollamaClient = OllamaClient()

    private var activeDetector: VideoAreaDetecting {
        let method = VideoDetectionMethod(rawValue: detectionMethodRaw) ?? .smartBorder
        switch method {
        case .smartBorder: return smartBorderDetector
        case .motion: return motionDetector
        }
    }

    var calibrationProgressMessage: String {
        let method = VideoDetectionMethod(rawValue: detectionMethodRaw) ?? .smartBorder
        switch method {
        case .smartBorder: return "Analyserar bild..."
        case .motion: return "Analyserar rörelse..."
        }
    }

    private var videoArea: CGRect = .zero
    private var hotKeyRef: EventHotKeyRef?
    private var videoPausedByUs: Bool = false
    private var selectedPID: pid_t?

    // MARK: - Window Picking
    func pickWindow() async {
        statusMessage = "Väljer fönster..."
        statusColor = .orange

        do {
            let manager = ScreenCaptureManager()
            try await manager.requestPermission()
            self.captureManager = manager
            // Permission granted — now let user pick a window
            await pickWindowWithPicker()
        } catch SCStreamError.userDeclined {
            statusMessage = "Skärminspelning nekad. Aktivera i Systeminställningar."
            statusColor = .red
        } catch {
            // Use our custom picker to let user select a window
            await pickWindowWithPicker()
        }
    }

    private func pickWindowWithPicker() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windows = content.windows.filter { $0.frame.width > 100 && $0.frame.height > 100 }

            guard !windows.isEmpty else {
                statusMessage = "Inga fönster hittades."
                statusColor = .red
                return
            }

            // Show window picker
            let picked = await showWindowPicker(windows: windows)
            guard let window = picked else {
                statusMessage = "Inget fönster valdes."
                statusColor = .orange
                return
            }

            let manager = captureManager ?? ScreenCaptureManager()
            manager.selectWindow(window)
            self.captureManager = manager
            hasCapture = true
            selectedAppName = window.owningApplication?.applicationName
            selectedWindowTitle = window.title
            selectedPID = window.owningApplication?.processID
            statusMessage = "Fångstar: \(window.owningApplication?.applicationName ?? "Okänt fönster")"
            statusColor = .green
        } catch {
            statusMessage = "Fel: \(error.localizedDescription)"
            statusColor = .red
        }
    }

    private func showWindowPicker(windows: [SCWindow]) async -> SCWindow? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Välj fönster att fånga"
                alert.addButton(withTitle: "Välj")
                alert.addButton(withTitle: "Avbryt")

                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
                for w in windows {
                    let name = w.owningApplication?.applicationName ?? "Okänt"
                    let title = w.title ?? "Namnlöst fönster"
                    popup.addItem(withTitle: "\(name) — \(title)")
                }
                alert.accessoryView = popup

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    let index = popup.indexOfSelectedItem
                    continuation.resume(returning: windows[index])
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Calibration
    func calibrate() async {
        guard let manager = captureManager else { return }
        isCalibrating = true

        let method = VideoDetectionMethod(rawValue: detectionMethodRaw) ?? .smartBorder

        switch method {
        case .smartBorder:
            statusMessage = "Analyserar bild..."
        case .motion:
            statusMessage = "Analyserar rörelse..."
        }
        statusColor = .orange

        do {
            var frames: [CGImage] = []

            switch method {
            case .smartBorder:
                // Single frame — fast
                if let frame = try? await manager.captureScreenshot() {
                    frames.append(frame)
                }
            case .motion:
                // 5 frames over ~2s (existing behavior)
                for i in 0..<5 {
                    if let frame = try? await manager.captureScreenshot() {
                        frames.append(frame)
                    }
                    if i < 4 {
                        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    }
                }
            }

            let detected = activeDetector.detectVideoArea(in: frames)
            videoArea = detected

            // Capture diagnostics from smart border detector
            if method == .smartBorder {
                detectionDiagnostics = smartBorderDetector.lastDiagnostics
            } else {
                detectionDiagnostics = "Rörelsedetektering: \(detected.width > 0 ? "\(Int(detected.width))×\(Int(detected.height)) px" : "inget hittat")"
            }

            if detected.width > 0 && detected.height > 0 {
                statusMessage = "Video hittad! (\(Int(detected.width))×\(Int(detected.height)) px)"
                statusColor = .green
                hasVideoArea = true
                videoAreaDescription = "\(Int(detected.width))×\(Int(detected.height)) px"
            } else {
                switch method {
                case .smartBorder:
                    // Fallback: use the full window frame rather than failing
                    if let fullSize = captureManager?.captureSize, fullSize.width > 0 {
                        videoArea = CGRect(origin: .zero, size: fullSize)
                        hasVideoArea = true
                        videoAreaDescription = "\(Int(fullSize.width))×\(Int(fullSize.height)) px (hela fönstret)"
                        statusMessage = "Inget videoområde hittades — använder hela fönstret."
                        statusColor = .yellow
                    } else {
                        statusMessage = "Inget videoområde hittades."
                        statusColor = .red
                        hasVideoArea = false
                    }
                case .motion:
                    statusMessage = "Ingen video hittad. Prova igen med video igång."
                    statusColor = .red
                    hasVideoArea = false
                }
            }
        } catch {
            statusMessage = "Kalibrering misslyckades: \(error.localizedDescription)"
            statusColor = .red
        }

        isCalibrating = false
    }

    // MARK: - Describe Scene
    func describe() async {
        guard let manager = captureManager, hasVideoArea else { return }
        isDescribing = true
        aiResponse = ""
        statusMessage = "Analyserar scen med AI..."

        guard let fullFrame = try? await manager.captureScreenshot() else {
            statusMessage = "Kunde inte ta skärmbild."
            isDescribing = false
            return
        }

        // Pause the video *after* the screenshot so we don't capture player UI overlays
        sendMediaPlayPause()
        videoPausedByUs = true

        let willUseVoiceOver = useVoiceOver

        // Crop to video area
        guard let cropped = cropImage(fullFrame, to: videoArea) else {
            statusMessage = "Kunde inte beskära videoarea."
            isDescribing = false
            if videoPausedByUs { sendMediaPlayPause(); videoPausedByUs = false }
            return
        }

        // Convert to JPEG base64
        guard let base64 = imageToBase64JPEG(cropped) else {
            statusMessage = "Bildkonvertering misslyckades."
            isDescribing = false
            if videoPausedByUs { sendMediaPlayPause(); videoPausedByUs = false }
            return
        }

        // Send to Ollama
        do {
            ollamaClient.model = selectedModel
            let response = try await ollamaClient.describe(imageBase64: base64, prompt: defaultQuestion, system: systemPrompt)
            aiResponse = response
            statusMessage = "Beskrivning klar."
            statusColor = .green

            // When using VoiceOver: no auto-resume (user resumes manually).
            // When using system speech: auto-resume when speech finishes,
            // and § key can stop speech early (which also resumes).
            let onSpeechFinished: (() -> Void)? = willUseVoiceOver ? nil : { [weak self] in
                self?.isSpeaking = false
                if self?.videoPausedByUs == true {
                    self?.sendMediaPlayPause()
                    self?.videoPausedByUs = false
                }
            }

            AccessibilitySpeaker.shared.speak(response, viaVoiceOver: willUseVoiceOver, onFinished: onSpeechFinished)
            isSpeaking = !willUseVoiceOver  // Only track speaking state for system speech
            if willUseVoiceOver {
                // VoiceOver: video stays paused, user resumes manually
                videoPausedByUs = false
            }
        } catch {
            statusMessage = "AI-fel: \(error.localizedDescription)"
            statusColor = .red
            if videoPausedByUs { sendMediaPlayPause(); videoPausedByUs = false }
        }

        isDescribing = false
    }

    /// Stop any ongoing speech (called from the UI stop button or § key re-press).
    /// The AccessibilitySpeaker.stop() triggers onFinished, which handles video resume
    /// for system speech. For VoiceOver mode videoPausedByUs is already false.
    func stopSpeaking() {
        AccessibilitySpeaker.shared.stop()
        isSpeaking = false
    }

    /// Resets window selection and video area so the user can pick a new target.
    func resetSelection() {
        stopSpeaking()
        captureManager = nil
        hasCapture = false
        hasVideoArea = false
        videoArea = .zero
        selectedAppName = nil
        selectedWindowTitle = nil
        selectedPID = nil
        videoAreaDescription = nil
        aiResponse = ""
        detectionDiagnostics = ""
        videoPausedByUs = false
        statusMessage = "Väntar på fönsterval..."
        statusColor = .orange
    }

    // MARK: - Auto-Hotkey Flow (§ key)
    func setupHotKey() {
        // Register § as a global hotkey using Carbon
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType("VDSC".fourCharCode)
        hotKeyID.id = 1

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let ctx = userData else { return noErr }
            let vm = Unmanaged<MainViewModel>.fromOpaque(ctx).takeUnretainedValue()
            // Capture the frontmost app synchronously before async dispatch,
            // because once our app processes the hotkey we become frontmost.
            let frontApp = NSWorkspace.shared.frontmostApplication
            // Capture the window list synchronously too — CGWindowListCopyWindowInfo
            // uses internal locks that trigger concurrency warnings in async contexts.
            let cgWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
            Task { @MainActor in
                await vm.hotkeyTriggered(frontmostApp: frontApp, cgWindows: cgWindows)
            }
            return noErr
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        // § = kVK_ISO_Section (0x0A), no modifiers
        RegisterEventHotKey(UInt32(kVK_ISO_Section), 0, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func hotkeyTriggered(frontmostApp: NSRunningApplication?, cgWindows: [[CFString: Any]]) async {
        // If currently speaking (system speech), § stops speech and resumes video
        if isSpeaking {
            stopSpeaking()
            return
        }

        // Clear stale pause state from a previous VoiceOver cycle where
        // the user resumed the video manually.
        videoPausedByUs = false

        // If "follow frontmost" is enabled and the frontmost app changed, reset
        // so we re-acquire the new window and re-calibrate.
        if followFrontmost,
           captureManager != nil,
           let frontPID = frontmostApp?.processIdentifier,
           frontPID != ProcessInfo.processInfo.processIdentifier,
           frontPID != selectedPID {
            resetSelection()
        }

        if captureManager == nil {
            // Auto-capture the frontmost window (excluding our own)
            await autoCaptureFrontWindow(frontmostApp: frontmostApp, cgWindows: cgWindows)
        }
        if !hasVideoArea {
            await calibrate()
        }
        await describe()
    }

    private func autoCaptureFrontWindow(frontmostApp: NSRunningApplication?, cgWindows: [[CFString: Any]]) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ourPID = ProcessInfo.processInfo.processIdentifier

            // Use the frontmost app captured at hotkey time (before our app became active)
            let targetPID: pid_t?
            if let frontmostApp, frontmostApp.processIdentifier != ourPID {
                targetPID = frontmostApp.processIdentifier
            } else {
                targetPID = nil
            }
            // Match the pre-captured CGWindowList (front-to-back order) against
            // SCShareableContent windows by windowID.
            let scWindows = content.windows.filter {
                $0.owningApplication?.processID != ourPID &&
                $0.frame.width > 100 &&
                $0.frame.height > 100
            }
            let scWindowsByID = Dictionary(uniqueKeysWithValues: scWindows.map { ($0.windowID, $0) })

            let window: SCWindow?
            if let targetPID {
                // Find the frontmost on-screen window belonging to the target app
                window = cgWindows.lazy
                    .filter { ($0[kCGWindowOwnerPID] as? pid_t) == targetPID &&
                              ($0[kCGWindowLayer] as? Int) == 0 }
                    .compactMap { scWindowsByID[($0[kCGWindowNumber] as? CGWindowID) ?? 0] }
                    .first
            } else {
                // Fallback: frontmost normal-layer window from any other app
                window = cgWindows.lazy
                    .filter { ($0[kCGWindowOwnerPID] as? pid_t) != ourPID &&
                              ($0[kCGWindowLayer] as? Int) == 0 }
                    .compactMap { scWindowsByID[($0[kCGWindowNumber] as? CGWindowID) ?? 0] }
                    .first
            }

            guard let window else { return }

            let manager = ScreenCaptureManager()
            manager.selectWindow(window)
            self.captureManager = manager
            hasCapture = true
            selectedAppName = window.owningApplication?.applicationName
            selectedWindowTitle = window.title
            selectedPID = window.owningApplication?.processID
            statusMessage = "Auto-fångad: \(window.owningApplication?.applicationName ?? "Okänt")"
        } catch {
            statusMessage = "Auto-fångning misslyckades: \(error.localizedDescription)"
        }
    }

    // MARK: - Media Key Simulation

    /// Sends a system-wide media Play/Pause key event (same as the physical ⏯ key).
    private func sendMediaPlayPause() {
        // NX_KEYTYPE_PLAY = 16
        let keyCode: UInt32 = 16

        // Key down
        if let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,                        // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: Int((keyCode << 16) | (0xa << 8)),  // key down
            data2: -1
        ) {
            keyDown.cgEvent?.post(tap: .cghidEventTap)
        }

        // Key up
        if let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyCode << 16) | (0xb << 8)),  // key up
            data2: -1
        ) {
            keyUp.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Helpers

    /// Bygger fullständig prompt från systemprompt + valfri standardfråga.
    private func buildPrompt() -> String {
        var prompt = systemPrompt
        if !defaultQuestion.isEmpty {
            prompt += "\n\n" + defaultQuestion
        }
        return prompt
    }

    private func cropImage(_ image: CGImage, to rect: CGRect) -> CGImage? {
        // Scale rect to actual image coordinates if needed
        let scaleX = CGFloat(image.width) / (captureManager?.captureSize.width ?? CGFloat(image.width))
        let scaleY = CGFloat(image.height) / (captureManager?.captureSize.height ?? CGFloat(image.height))
        let scaledRect = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        return image.cropping(to: scaledRect)
    }

    private func imageToBase64JPEG(_ image: CGImage) -> String? {
        let nsImage = NSImage(cgImage: image, size: .zero)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        return jpegData.base64EncodedString()
    }
}

// MARK: - FourCharCode helper
extension String {
    var fourCharCode: FourCharCode {
        var result: FourCharCode = 0
        for char in self.utf16.prefix(4) {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
}


