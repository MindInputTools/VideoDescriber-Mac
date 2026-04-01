import Foundation
import CoreGraphics

/// The method used to locate the video content area within a captured window.
enum VideoDetectionMethod: String, CaseIterable, Identifiable {
    case smartBorder = "smartBorder"
    case motion = "motion"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smartBorder: return "Smart kantdetektering"
        case .motion: return "Rörelsedetektering"
        }
    }

    var explanation: String {
        switch self {
        case .smartBorder:
            return "Analyserar en enskild bild för att hitta videoområdet via kanter och bildförhållande. Fungerar även med stillbilder."
        case .motion:
            return "Jämför flera bilder under ~2 sekunder för att hitta rörelse. Kräver att videon spelar."
        }
    }
}

/// Protocol that all video area detectors must conform to.
protocol VideoAreaDetecting {
    /// Detect the video content rectangle from an array of frames.
    /// Smart border detection uses only the first frame.
    /// Motion detection uses all frames.
    /// Returns .zero if no area is found.
    func detectVideoArea(in frames: [CGImage]) -> CGRect
}
