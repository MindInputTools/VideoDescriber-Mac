import Foundation
import CoreImage
import CoreGraphics

/// Detects the video content area within a window screenshot.
///
/// Strategy: Find the video's right edge and bottom edge (the two most
/// detectable boundaries on a typical YouTube/streaming page), then derive
/// the rectangle by fitting a standard aspect ratio.
/// The video is assumed to start near the left edge of the window.
class SmartBorderDetector: VideoAreaDetecting {

    // MARK: - Configuration

    /// Standard video aspect ratios (width / height) with preference weight
    private let standardAspectRatios: [(name: String, ratio: CGFloat, preference: CGFloat)] = [
        ("16:9",  16.0 / 9.0,  0.20),
        ("4:3",   4.0 / 3.0,   0.05),
        ("21:9",  21.0 / 9.0,  0.0),
        ("1:1",   1.0,         0.0),
    ]

    /// Aspect ratio tolerance
    private let aspectRatioTolerance: CGFloat = 0.05

    /// Working resolution
    private let workingMaxDimension: CGFloat = 960

    /// Diagnostic info from the last detection run
    private(set) var lastDiagnostics: String = ""

    // MARK: - VideoAreaDetecting

    func detectVideoArea(in frames: [CGImage]) -> CGRect {
        guard let frame = frames.first else { return .zero }
        return detect(in: frame)
    }

    // MARK: - Detection

    private func detect(in image: CGImage) -> CGRect {
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let ciImage = CIImage(cgImage: image)

        let gray = grayscale(ciImage)
        let (downsampled, scale) = downsample(gray, maxDimension: workingMaxDimension)

        guard let cg = ciContext.createCGImage(downsampled, from: downsampled.extent),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return .zero
        }

        let W = cg.width
        let H = cg.height
        let bpp = cg.bitsPerPixel / 8
        let bpr = cg.bytesPerRow
        guard W > 60 && H > 60 else { return .zero }

        func lum(_ x: Int, _ y: Int) -> CGFloat {
            CGFloat(ptr[y * bpr + x * bpp]) / 255.0
        }

        // --- Step 1: Find the bottom edge of the video ---
        // For each row, compute a boundary score: how different is the content
        // above vs below this row? Use both mean-luminance contrast and edge density.

        // Row means (full width)
        var rowMeans = [CGFloat](repeating: 0, count: H)
        for y in 0..<H {
            var s: CGFloat = 0
            for x in 0..<W { s += lum(x, y) }
            rowMeans[y] = s / CGFloat(W)
        }

        // Row edge density: fraction of pixels with a strong vertical gradient
        var rowEdge = [CGFloat](repeating: 0, count: H)
        for y in 1..<(H - 1) {
            var count: CGFloat = 0
            for x in 0..<W {
                if abs(lum(x, y - 1) - lum(x, y + 1)) > 0.06 { count += 1 }
            }
            rowEdge[y] = count / CGFloat(W)
        }

        // Compute row boundary score using a sliding window contrast
        let band = max(4, H / 80)
        var rowBoundary = [CGFloat](repeating: 0, count: H)
        for y in band..<(H - band) {
            // Mean luminance contrast above vs below
            var aboveSum: CGFloat = 0, belowSum: CGFloat = 0
            for dy in 1...band {
                aboveSum += rowMeans[y - dy]
                belowSum += rowMeans[y + dy]
            }
            let contrast = abs(aboveSum - belowSum) / CGFloat(band)

            // Combined score
            rowBoundary[y] = contrast * 2.0 + rowEdge[y]
        }

        // --- Step 2: Find the right edge of the video ---
        // Use only the top portion of the image (where the video is) for column analysis.
        // First pass: use the top 60% of the image.
        let colScanH = Int(CGFloat(H) * 0.6)

        var colEdge = [CGFloat](repeating: 0, count: W)
        for x in 1..<(W - 1) {
            var count: CGFloat = 0
            for y in 0..<colScanH {
                if abs(lum(x - 1, y) - lum(x + 1, y)) > 0.06 { count += 1 }
            }
            colEdge[x] = count / CGFloat(colScanH)
        }

        // Column mean within the scan region
        var colMeans = [CGFloat](repeating: 0, count: W)
        for x in 0..<W {
            var s: CGFloat = 0
            for y in 0..<colScanH { s += lum(x, y) }
            colMeans[x] = s / CGFloat(colScanH)
        }

        let colBand = max(4, W / 80)
        var colBoundary = [CGFloat](repeating: 0, count: W)
        for x in colBand..<(W - colBand) {
            var leftSum: CGFloat = 0, rightSum: CGFloat = 0
            for dx in 1...colBand {
                leftSum += colMeans[x - dx]
                rightSum += colMeans[x + dx]
            }
            let contrast = abs(leftSum - rightSum) / CGFloat(colBand)
            colBoundary[x] = contrast * 2.0 + colEdge[x]
        }

        // --- Step 3: Find peaks in boundary scores ---
        let peakWindow = max(8, min(W, H) / 40)

        // Bottom edge candidates: search rows from 30% to 85% of height
        var bottomCandidates: [(pos: Int, score: CGFloat)] = []
        let bStart = Int(CGFloat(H) * 0.3)
        let bEnd = Int(CGFloat(H) * 0.85)
        for y in bStart..<bEnd {
            let val = rowBoundary[y]
            guard val > 0.04 else { continue }
            let maxDy = min(peakWindow, min(y - bStart, bEnd - 1 - y))
            guard maxDy >= 1 else {
                bottomCandidates.append((pos: y, score: val))
                continue
            }
            var isPeak = true
            for dy in 1...maxDy {
                if rowBoundary[y - dy] > val || rowBoundary[y + dy] > val {
                    isPeak = false; break
                }
            }
            if isPeak { bottomCandidates.append((pos: y, score: val)) }
        }

        // Right edge candidates: search cols from 35% to 90% of width
        var rightCandidates: [(pos: Int, score: CGFloat)] = []
        let rStart = Int(CGFloat(W) * 0.35)
        let rEnd = Int(CGFloat(W) * 0.90)
        for x in rStart..<rEnd {
            let val = colBoundary[x]
            guard val > 0.04 else { continue }
            let maxDx = min(peakWindow, min(x - rStart, rEnd - 1 - x))
            guard maxDx >= 1 else {
                rightCandidates.append((pos: x, score: val))
                continue
            }
            var isPeak = true
            for dx in 1...maxDx {
                if colBoundary[x - dx] > val || colBoundary[x + dx] > val {
                    isPeak = false; break
                }
            }
            if isPeak { rightCandidates.append((pos: x, score: val)) }
        }

        // Sort by score descending
        bottomCandidates.sort { $0.score > $1.score }
        rightCandidates.sort { $0.score > $1.score }

        var diag = "Bild: \(W)×\(H), skala=\(String(format: "%.4f", scale))\n"
        diag += "Underkant: \(bottomCandidates.prefix(8).map { "rad \($0.pos) (\(String(format: "%.3f", $0.score)))" }.joined(separator: ", "))\n"
        diag += "Högerkant: \(rightCandidates.prefix(8).map { "kol \($0.pos) (\(String(format: "%.3f", $0.score)))" }.joined(separator: ", "))\n"

        // --- Step 4: For each (bottom, right) pair, compute the rectangle ---
        // The video starts from the left edge (x≈0) and we derive the top edge
        // from the aspect ratio: top = bottom - width / aspectRatio.
        // Then we verify the derived top position makes sense.

        var bestRect: CGRect = .zero
        var bestScore: CGFloat = -1
        var bestName = ""

        let leftEdge: CGFloat = 0 // video starts at the left of the captured window

        for bottom in bottomCandidates.prefix(8) {
            for right in rightCandidates.prefix(8) {
                let videoWidth = CGFloat(right.pos) - leftEdge
                guard videoWidth > CGFloat(W) * 0.3 else { continue }

                for ar in standardAspectRatios {
                    // Derive height from width and aspect ratio
                    let videoHeight = videoWidth / ar.ratio
                    let derivedTop = CGFloat(bottom.pos) - videoHeight

                    // The derived top should be in a reasonable range (0..30% of image)
                    guard derivedTop >= 0 && derivedTop < CGFloat(H) * 0.3 else { continue }

                    // Check that the area is reasonable
                    let area = videoWidth * videoHeight
                    let imageArea = CGFloat(W * H)
                    guard area / imageArea >= 0.12 else { continue }

                    // Verify the derived top by checking if there's a boundary near it
                    let topBoundaryScore = findBoundaryStrength(
                        near: Int(derivedTop), in: rowBoundary,
                        searchRange: max(8, H / 30)
                    )

                    // Score
                    let edgeScore = (bottom.score + right.score) / 2.0
                    let score = edgeScore * 0.30
                        + ar.preference
                        + topBoundaryScore * 0.15
                        + (area / imageArea) * 0.05

                    if score > bestScore {
                        bestScore = score
                        bestName = ar.name
                        bestRect = CGRect(x: leftEdge, y: derivedTop,
                                          width: videoWidth, height: videoHeight)
                    }
                }
            }
        }

        guard bestRect.width > 10 && bestRect.height > 10 else {
            diag += "Inget videoområde hittades."
            lastDiagnostics = diag
            return .zero
        }

        let r = bestRect.width / bestRect.height
        diag += "Valt: \(bestName) topp=\(String(format: "%.0f", bestRect.minY)) botten=\(String(format: "%.0f", bestRect.maxY)) höger=\(String(format: "%.0f", bestRect.maxX)) \(Int(bestRect.width))×\(Int(bestRect.height)) ratio=\(String(format: "%.3f", r)) poäng=\(String(format: "%.4f", bestScore))"
        lastDiagnostics = diag

        return scaleToOriginal(bestRect, scale: scale,
                               originalWidth: CGFloat(image.width),
                               originalHeight: CGFloat(image.height))
    }

    // MARK: - Helpers

    /// Find the maximum boundary strength within ±searchRange of a given position.
    private func findBoundaryStrength(near pos: Int, in scores: [CGFloat], searchRange: Int) -> CGFloat {
        let lo = max(0, pos - searchRange)
        let hi = min(scores.count - 1, pos + searchRange)
        var best: CGFloat = 0
        for i in lo...hi {
            best = max(best, scores[i])
        }
        return best
    }

    // MARK: - Grayscale

    private func grayscale(_ image: CIImage) -> CIImage {
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1),             forKey: "inputAVector")
        return filter.outputImage ?? image
    }

    // MARK: - Downsample

    private func downsample(_ image: CIImage, maxDimension: CGFloat) -> (CIImage, CGFloat) {
        let extent = image.extent
        let maxDim = max(extent.width, extent.height)
        guard maxDim > maxDimension else { return (image, 1.0) }

        let scale = maxDimension / maxDim
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(Float(scale), forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        let output = filter.outputImage ?? image
        return (output.cropped(to: output.extent), scale)
    }

    // MARK: - Coordinate Scaling

    private func scaleToOriginal(_ rect: CGRect, scale: CGFloat,
                                  originalWidth: CGFloat,
                                  originalHeight: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        let invScale = 1.0 / scale
        return CGRect(
            x: rect.origin.x * invScale,
            y: rect.origin.y * invScale,
            width: rect.width * invScale,
            height: rect.height * invScale
        )
    }
}
