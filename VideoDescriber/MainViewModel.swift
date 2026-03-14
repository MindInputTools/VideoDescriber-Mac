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

    // MARK: - Inställningar (UserDefaults)
    @AppStorage("selectedModel") private var selectedModel = "ministral-3:latest"
    @AppStorage("systemPrompt") private var systemPrompt = SettingsView.defaultSystemPrompt
    @AppStorage("defaultQuestion") private var defaultQuestion =
    SettingsView.defaultDefaultQuestion

    // MARK: - Private State
    private var captureManager: ScreenCaptureManager?
    private var videoDetector = VideoMotionDetector()
    private var ollamaClient = OllamaClient()
    private var videoArea: CGRect = .zero
    private var hotKeyRef: EventHotKeyRef?

    // MARK: - Window Picking
    func pickWindow() async {
        statusMessage = "Väljer fönster..."
        statusColor = .orange

        do {
            let manager = ScreenCaptureManager()
            try await manager.startCapture()
            self.captureManager = manager
            hasCapture = true
            statusMessage = "Fönster valt. Redo att kalibrera."
            statusColor = .green
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

            let manager = ScreenCaptureManager()
            try await manager.startCaptureForWindow(window)
            self.captureManager = manager
            hasCapture = true
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
        statusMessage = "Analyserar rörelse..."
        statusColor = .orange

        do {
            var frames: [CGImage] = []
            for i in 0..<5 {
                if let frame = await manager.captureFrame() {
                    frames.append(frame)
                }
                if i < 4 {
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                }
            }

            let detected = videoDetector.detectMotionArea(in: frames)
            videoArea = detected

            if detected.width > 0 && detected.height > 0 {
                statusMessage = "Video hittad! (\(Int(detected.width))×\(Int(detected.height)) px)"
                statusColor = .green
                hasVideoArea = true
            } else {
                statusMessage = "Ingen video hittad. Prova igen med video igång."
                statusColor = .red
                hasVideoArea = false
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

        guard let fullFrame = await manager.captureFrame() else {
            statusMessage = "Kunde inte ta skärmbild."
            isDescribing = false
            return
        }

        // Crop to video area
        guard let cropped = cropImage(fullFrame, to: videoArea) else {
            statusMessage = "Kunde inte beskära videoarea."
            isDescribing = false
            return
        }

        // Convert to JPEG base64
        guard let base64 = imageToBase64JPEG(cropped) else {
            statusMessage = "Bildkonvertering misslyckades."
            isDescribing = false
            return
        }

        // Send to Ollama
        do {
            ollamaClient.model = selectedModel
//            let prompt = buildPrompt()
            let response = try await ollamaClient.describe(imageBase64: base64, prompt: defaultQuestion, system: systemPrompt)
            aiResponse = response
            statusMessage = "Beskrivning klar."
            statusColor = .green
            // Speak the description — routes through VoiceOver if active,
            // AVSpeechSynthesizer otherwise. Interruptible via Control (VO)
            // or the Stop button in the UI.
            AccessibilitySpeaker.shared.speak(response)
            isSpeaking = true
            // Poll speaker to keep isSpeaking in sync (covers both VO and synth)
            Task {
                while AccessibilitySpeaker.shared.isSpeaking {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                isSpeaking = false
            }
        } catch {
            statusMessage = "AI-fel: \(error.localizedDescription)"
            statusColor = .red
        }

        isDescribing = false
    }

    /// Stop any ongoing speech (called from the UI stop button)
    func stopSpeaking() {
        AccessibilitySpeaker.shared.stop()
        isSpeaking = false
    }

    // MARK: - Auto-Hotkey Flow (Cmd+G equivalent)
    func setupHotKey() {
        // Register Cmd+G as a global hotkey using Carbon
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType("VDSC".fourCharCode)
        hotKeyID.id = 1

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let ctx = userData else { return noErr }
            let vm = Unmanaged<MainViewModel>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in
                await vm.hotkeyTriggered()
            }
            return noErr
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        // Cmd = cmdKey (0x0100), G = kVK_ANSI_G (0x05)
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(cmdKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func hotkeyTriggered() async {
        if captureManager == nil {
            // Auto-capture the frontmost window (excluding our own)
            await autoCaptureFrontWindow()
        }
        if !hasVideoArea {
            await calibrate()
        }
        await describe()
    }

    private func autoCaptureFrontWindow() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ourPID = ProcessInfo.processInfo.processIdentifier

            // Use NSWorkspace to find the actual frontmost app (excluding ourselves)
            let frontmostApp = NSWorkspace.shared.runningApplications
                .filter { $0.isActive || $0.ownsMenuBar }
                .first { $0.processIdentifier != ourPID }
            ?? NSWorkspace.shared.frontmostApplication

            // Match by frontmost app's PID, fall back to largest window from another app
            let targetPID = frontmostApp?.processIdentifier
            let candidateWindows = content.windows.filter {
                $0.owningApplication?.processID != ourPID &&
                $0.frame.width > 100 &&
                $0.frame.height > 100
            }

            let window: SCWindow?
            if let targetPID {
                // Prefer the largest window from the frontmost app
                window = candidateWindows
                    .filter { $0.owningApplication?.processID == targetPID }
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            } else {
                // Fallback: pick the largest candidate window
                window = candidateWindows
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            }

            guard let window else { return }

            let manager = ScreenCaptureManager()
            try await manager.startCaptureForWindow(window)
            self.captureManager = manager
            hasCapture = true
            statusMessage = "Auto-fångad: \(window.owningApplication?.applicationName ?? "Okänt")"
        } catch {
            statusMessage = "Auto-fångning misslyckades: \(error.localizedDescription)"
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
