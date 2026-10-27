import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import Vision

/// Vision wrappers.
///
/// The default build uses the classic, synchronous VN* API (iOS 15/17+, well-known signatures) because it
/// is easy to keep inside the ImageProcessor actor and the camera's video queue without sending
/// non-Sendable CGImage / CVPixelBuffer values across concurrency domains under Swift 6.
///
/// The new Swift Vision API (iOS 18: `DetectDocumentSegmentationRequest`) is wired in behind the
/// compilation condition `FM_SWIFT_VISION` (off by default; see project.yml). It takes `Data`, which is
/// Sendable. Its exact signatures were not verified on a Mac — turn it on only after a green CI build.
enum VisionPaths {
    /// Paper corners in an upright CGImage, normalized with TOP-LEFT origin. nil if nothing plausible.
    static func detectDocument(cgImage: CGImage) -> Quad? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first, obs.confidence >= 0.5 else { return nil }
        return quad(fromVision: [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft])
    }

    /// Vision points are normalized with LOWER-left origin; flip and order them.
    static func quad(fromVision pts: [CGPoint]) -> Quad? {
        CornerOrdering.order(pts.map { NormPoint(x: Double($0.x), y: 1 - Double($0.y)) })
    }

    /// Subject-lifting mask (0...255, row 0 = top) at width×height, from VNGenerateForegroundInstanceMaskRequest.
    /// Returns nil when Vision finds no foreground instance or the request is unsupported (e.g. Simulator).
    static func foregroundMask(cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }
        guard let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) else { return nil }
        return PixelBufferReader.grayscale(buffer, width: width, height: height)
    }
}

enum PixelBufferReader {
    /// Reads a one-component (Float32 or UInt8) pixel buffer into 8-bit values, nearest-sampled to width×height.
    static func grayscale(_ pb: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bw = CVPixelBufferGetWidth(pb), bh = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let format = CVPixelBufferGetPixelFormatType(pb)
        guard bw > 0, bh > 0, width > 0, height > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: width * height)
        let isFloat = format == kCVPixelFormatType_OneComponent32Float
        let isByte = format == kCVPixelFormatType_OneComponent8
        guard isFloat || isByte else { return nil }
        for y in 0..<height {
            let sy = min(bh - 1, y * bh / height)
            let row = base.advanced(by: sy * bpr)
            for x in 0..<width {
                let sx = min(bw - 1, x * bw / width)
                if isFloat {
                    let v = row.assumingMemoryBound(to: Float32.self)[sx]
                    out[y * width + x] = UInt8((v * 255).rounded().clamped(0, 255))
                } else {
                    out[y * width + x] = row.assumingMemoryBound(to: UInt8.self)[sx]
                }
            }
        }
        return out
    }
}

enum ImageMetadata {
    /// EXIF orientation of encoded image data (defaults to .up).
    static func orientation(of data: Data) -> CGImagePropertyOrientation {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let raw = props[kCGImagePropertyOrientation as String] as? UInt32,
              let o = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return o
    }

    /// EXIF DateTimeOriginal, if present (used when importing from the photo library).
    static func captureDate(of data: Data) -> Date? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }
}

#if FM_SWIFT_VISION
/// New Swift Vision API path (iOS 18). Unverified signatures — enable with the FM_SWIFT_VISION flag.
/// Expected: `ImageProcessingRequest.perform(on: Data, orientation:) async throws -> Result`,
/// `DetectDocumentSegmentationRequest.Result == DetectedDocumentObservation?`,
/// corners are `NormalizedPoint` (lower-left origin) with `.x` / `.y`.
enum SwiftVisionPaths {
    static func detectDocument(in data: Data) async -> Quad? {
        let request = DetectDocumentSegmentationRequest()
        let orientation = ImageMetadata.orientation(of: data)
        do {
            let observation: DetectedDocumentObservation? = try await request.perform(on: data, orientation: orientation)
            guard let o = observation else { return nil }
            let pts = [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { CGPoint(x: $0.x, y: $0.y) }
            return VisionPaths.quad(fromVision: pts)
        } catch {
            return nil
        }
    }
}
#endif
