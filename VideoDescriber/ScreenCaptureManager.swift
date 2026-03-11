import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreImage

/// Manages screen capture of a specific window using Apple's ScreenCaptureKit.
/// This replaces the Windows.Graphics.Capture + Direct3D11 pipeline.
class ScreenCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private(set) var captureSize: CGSize = .zero

    // Latest captured frame - protected by an actor-style lock
    private var latestFrame: CGImage?
    private let frameLock = NSLock()

    // MARK: - Public API

    /// Request permission and start capturing using system picker (SCShareablePicker if available,
    /// otherwise falls back to programmatic window selection).
    func startCapture() async throws {
        // Check / request screen recording permission
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw SCStreamError(.userDeclined)
        }
        // After permission is granted, caller can call startCaptureForWindow
    }

    /// Begin capturing a specific SCWindow
    func startCaptureForWindow(_ window: SCWindow) async throws {
        // Stop any existing stream
        try? await stream?.stopCapture()

        captureSize = window.frame.size

        let filter = SCContentFilter(desktopIndependentWindow: window)
        self.filter = filter

        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 fps max
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await newStream.startCapture()
        self.stream = newStream
    }

    /// Grab the most recent frame captured from the stream
    func captureFrame() async -> CGImage? {
        // Wait up to 1s for a frame to arrive
        for _ in 0..<20 {
            frameLock.lock()
            let frame = latestFrame
            frameLock.unlock()
            if let frame { return frame }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        return nil
    }

    func stopCapture() async {
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

        frameLock.lock()
        latestFrame = cgImage
        frameLock.unlock()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped: \(error.localizedDescription)")
    }
}
