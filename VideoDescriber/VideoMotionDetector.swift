import Foundation
import CoreImage
import CoreGraphics

/// Detects the region of the screen where video motion occurs.
/// Replaces VideoAutoDetector.cs which used OpenCV — here we use CoreImage filters instead.
class VideoMotionDetector {

    /// Given a sequence of frames, returns the CGRect bounding box of the area with significant motion.
    /// Returns .zero if no motion area large enough is found.
    func detectMotionArea(in frames: [CGImage]) -> CGRect {
        guard frames.count >= 2 else { return .zero }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        // Convert all frames to grayscale CIImages
        let grayFrames: [CIImage] = frames.compactMap { cgImage in
            let ci = CIImage(cgImage: cgImage)
            return applyGaussianBlur(grayscale(ci))
        }

        guard let first = grayFrames.first else { return .zero }
        let imageSize = first.extent

        // Accumulate absolute differences between first frame and all subsequent frames
        var accumulatedDiff: CIImage = CIImage(color: CIColor.black).cropped(to: imageSize)

        for i in 1..<grayFrames.count {
            let diff = absoluteDifference(grayFrames[i], first)
            let thresholded = threshold(diff, value: 0.18) // ~46/255 ≈ the OpenCV value of 50
            accumulatedDiff = maximumOf(accumulatedDiff, thresholded)
        }

        // Dilate / expand motion blobs so nearby regions merge
        let dilated = dilate(accumulatedDiff, radius: 15)

        // Render to a bitmap we can scan
        let bounds = dilated.extent
        guard let cgDilated = ciContext.createCGImage(dilated, from: bounds) else { return .zero }

        // Find bounding box of bright (motion) pixels
        return findMotionBoundingBox(in: cgDilated, originalSize: imageSize.size)
    }

    // MARK: - CoreImage helpers

    private func grayscale(_ image: CIImage) -> CIImage {
        // CIColorMatrix: set R=G=B to luminance
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1),             forKey: "inputAVector")
        return filter.outputImage ?? image
    }

    private func applyGaussianBlur(_ image: CIImage) -> CIImage {
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(3.0, forKey: kCIInputRadiusKey) // Comparable to OpenCV's 5x5 kernel
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    private func absoluteDifference(_ a: CIImage, _ b: CIImage) -> CIImage {
        // CIColorAbsoluteDifference gives |a - b| per channel
        let filter = CIFilter(name: "CIColorAbsoluteDifference")!
        filter.setValue(a, forKey: kCIInputImageKey)
        filter.setValue(b, forKey: "inputImage2")
        return filter.outputImage ?? a
    }

    private func threshold(_ image: CIImage, value: CGFloat) -> CIImage {
        // Use CIColorThreshold (available macOS 10.15+) to binarize
        if let filter = CIFilter(name: "CIColorThreshold") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(value, forKey: "inputThreshold")
            if let output = filter.outputImage { return output }
        }
        // Fallback: use a ColorMatrix to amplify and clip
        let multiply = CIFilter(name: "CIColorClamp")!
        multiply.setValue(image, forKey: kCIInputImageKey)
        multiply.setValue(CIVector(x: value, y: value, z: value, w: 0), forKey: "inputMinComponents")
        multiply.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
        return multiply.outputImage ?? image
    }

    private func maximumOf(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter(name: "CIMaximumCompositing")!
        filter.setValue(a, forKey: kCIInputImageKey)
        filter.setValue(b, forKey: kCIInputBackgroundImageKey)
        return (filter.outputImage ?? a).cropped(to: a.extent)
    }

    private func dilate(_ image: CIImage, radius: Int) -> CIImage {
        // Repeated box-blur approximates dilation well
        var result = image
        let filter = CIFilter(name: "CIMorphologyMaximum")
        if let f = filter {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(CGFloat(radius), forKey: kCIInputRadiusKey)
            result = (f.outputImage ?? image).cropped(to: image.extent)
        } else {
            // Fallback: use a large gaussian blur and re-threshold
            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.setValue(image, forKey: kCIInputImageKey)
            blur.setValue(CGFloat(radius), forKey: kCIInputRadiusKey)
            result = (blur.outputImage ?? image).cropped(to: image.extent)
            result = threshold(result, value: 0.05)
        }
        return result
    }

    // MARK: - Pixel scanning

    private func findMotionBoundingBox(in image: CGImage, originalSize: CGSize) -> CGRect {
        let width = image.width
        let height = image.height

        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return .zero }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow

        var minX = width, minY = height, maxX = 0, maxY = 0
        var foundMotion = false

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                // Check if pixel is bright (motion)
                // For BGRA: B at offset, G at offset+1, R at offset+2
                let brightness = Int(ptr[offset]) + Int(ptr[offset + 1]) + Int(ptr[offset + 2])
                if brightness > 100 { // threshold: ~33 per channel
                    minX = Swift.min(minX, x)
                    minY = Swift.min(minY, y)
                    maxX = Swift.max(maxX, x)
                    maxY = Swift.max(maxY, y)
                    foundMotion = true
                }
            }
        }

        guard foundMotion else { return .zero }

        let motionRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Filter: require a minimum area (matches OpenCV's 150x100 filter)
        guard motionRect.width > 150 && motionRect.height > 100 else { return .zero }

        // Scale back to original capture coordinates
        let scaleX = originalSize.width / CGFloat(width)
        let scaleY = originalSize.height / CGFloat(height)
        return CGRect(
            x: motionRect.origin.x * scaleX,
            y: motionRect.origin.y * scaleY,
            width: motionRect.width * scaleX,
            height: motionRect.height * scaleY
        )
    }
}
