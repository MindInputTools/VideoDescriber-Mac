import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage
import os

/// Manages screen capture of a specific window using Apple's ScreenCaptureKit.
///
/// Supports three capture modes:
/// 1. **On-demand screenshots** (default) — `captureScreenshot()` takes a single frame when called.
///    Battery-friendly since no continuous work is done between calls.
/// 2. **Periodic capture** — `startPeriodicCapture(interval:)` takes screenshots at a fixed
///    interval (e.g. 1/sec) and keeps `latestFrame` fresh. Useful when you need polling.
/// 3. **Continuous stream** — `startStreamForWindow(_:)` runs a full SCStream at up to 30fps.
///    Most resource-intensive; kept for cases that need real-time frames.
class ScreenCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private(set) var captureSize: CGSize = .zero

    /// Whether a window has been selected (via `selectWindow` or stream start).
    var hasWindow: Bool { filter != nil }

    // Latest captured frame - protected by an unfair lock (safe from async contexts)
    private let frameStorage = OSAllocatedUnfairLock<CGImage?>(initialState: nil)

    // Periodic capture task
    private var periodicTask: Task<Void, Never>?

    // Stored window reference for stream start
    private var selectedWindow: SCWindow?

    // Dedicated serial queue for stream output
    private let streamOutputQueue = DispatchQueue(label: "com.videodescriber.streamOutput")

    // MARK: - Permission

    /// Request screen recording permission. Call before any capture.
    func requestPermission() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw SCStreamError(.userDeclined)
        }
    }

    // MARK: - Window Selection (no stream)

    /// Select a window for capture without starting a stream.
    /// After calling this, use `captureScreenshot()` to grab frames on demand.
    func selectWindow(_ window: SCWindow) {
        captureSize = window.frame.size
        filter = SCContentFilter(desktopIndependentWindow: window)
        selectedWindow = window
    }

    // MARK: - On-Demand Screenshot

    /// Take a single screenshot of the selected window.
    /// This is the primary, battery-friendly capture method.
    func captureScreenshot() async throws -> CGImage {
        guard let filter else {
            throw SCStreamError(.attemptToStartStreamState)
        }

        let config = SCStreamConfiguration()
        config.width = Int(captureSize.width)
        config.height = Int(captureSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Periodic Capture

    /// Start capturing screenshots at a fixed interval, storing each in `latestFrame`.
    /// Call `stopPeriodicCapture()` to stop. Does not start a stream.
    func startPeriodicCapture(interval: TimeInterval) {
        stopPeriodicCapture()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let image = try? await self.captureScreenshot() {
                    self.frameStorage.withLockUnchecked { $0 = image }
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Stop periodic capture.
    func stopPeriodicCapture() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    // MARK: - Continuous Stream

    /// Start a continuous stream for the currently selected window.
    /// Use `captureStreamFrame()` to read frames, and `stopStream()` when done.
    func startStream() async throws {
        guard let selectedWindow else {
            throw SCStreamError(.attemptToStartStreamState)
        }
        try await startStreamForWindow(selectedWindow)
    }

    /// Begin a continuous SCStream for a window. Use `captureStreamFrame()` to read frames.
    /// This is resource-intensive — prefer `captureScreenshot()` for most use cases.
    func startStreamForWindow(_ window: SCWindow) async throws {
        try? await stream?.stopCapture()

        captureSize = window.frame.size

        let filter = SCContentFilter(desktopIndependentWindow: window)
        self.filter = filter
        self.selectedWindow = window

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2) // 2 fps — enough for motion detection
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamOutputQueue)
        try await newStream.startCapture()
        self.stream = newStream
    }

    /// Grab a new frame from the running stream.
    /// Clears the current frame and waits for the stream to deliver a fresh one.
    func captureStreamFrame() async -> CGImage? {
        // Clear so we wait for a genuinely new frame
        frameStorage.withLockUnchecked { $0 = nil }

        for _ in 0..<40 {
            if let frame = frameStorage.withLockUnchecked({ $0 }) { return frame }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        return nil
    }

    /// Stop the continuous stream.
    func stopStream() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        frameStorage.withLockUnchecked { $0 = cgImage }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped: \(error.localizedDescription)")
    }
}
