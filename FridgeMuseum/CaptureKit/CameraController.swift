import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import Vision

/// Live paper outline in *capture-device* coordinates: (0,0) top-left, (1,1) bottom-right of the
/// unrotated sensor frame. AVCaptureVideoPreviewLayer converts these to view points.
struct LiveQuad: Sendable, Equatable {
    var points: [CGPoint]
}

/// 1.2.2: light and flashlight as seen on the analysed frames (sent only when something changed).
struct CameraLightStatus: Sendable, Equatable {
    var isDim = false
    var torchActive = false
    var torchAvailable = false
}

enum CameraError: Error {
    case unavailable
    case cannotAddInput
    case noPhotoData
}

/// Owns the AVCaptureSession. All session work happens on `sessionQueue`, frame analysis on `videoQueue`.
/// Mutable state is confined to those queues (or guarded by `lock`), hence @unchecked Sendable.
final class CameraController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "fridgemuseum.camera.session")
    private let videoQueue = DispatchQueue(label: "fridgemuseum.camera.video", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    private let lock = NSLock()
    private var pendingPhotos: [Int64: CheckedContinuation<Data, Error>] = [:]
    private var quadHandler: (@Sendable (LiveQuad?) -> Void)?
    private var lightHandler: (@Sendable (CameraLightStatus) -> Void)?
    private var detectionEnabled = true
    /// The active format's maximum ISO, set when configured (0 = unknown). Guarded by `lock`.
    private var maxISO: Double = 0

    // sessionQueue only
    private var isConfigured = false
    // videoQueue only
    private var lastDetection: CFAbsoluteTime = 0
    private var smoothed: [CGPoint]?
    private var misses = 0
    private var lastRectangles: CFAbsoluteTime = 0
    /// Best sheet-like rectangle of the previous rectangle pass (device coordinates).
    private var previousRectangle: Quad?
    private var lowLight = LowLightClassifier()
    private var lastLight: CameraLightStatus?

    /// Set once configured; read on the main actor afterwards.
    private(set) var device: AVCaptureDevice?

    func setQuadHandler(_ handler: @escaping @Sendable (LiveQuad?) -> Void) {
        lock.withLock { quadHandler = handler }
    }

    func setLightHandler(_ handler: @escaping @Sendable (CameraLightStatus) -> Void) {
        lock.withLock { lightHandler = handler }
    }

    func setDetectionEnabled(_ on: Bool) {
        lock.withLock { detectionEnabled = on }
    }

    /// Whether this camera has a flashlight (after `start()`).
    var hasTorch: Bool { device?.hasTorch ?? false }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            self.applyTorch(false)
            if self.session.isRunning { self.session.stopRunning() }
        }
        videoQueue.async {
            self.lowLight.reset()
            self.lastLight = nil
            self.previousRectangle = nil
        }
    }

    /// 1.2.2: turns the flashlight on or off; returns whether it is on afterwards. When the device refuses
    /// (overheated, in use), it simply stays off. The photo flash itself stays off (AVCapturePhotoSettings default).
    func setTorch(_ on: Bool) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            sessionQueue.async {
                cont.resume(returning: self.applyTorch(on))
            }
        }
    }

    /// sessionQueue only.
    @discardableResult
    private func applyTorch(_ on: Bool) -> Bool {
        guard let device, device.hasTorch else { return false }
        if on && !device.isTorchAvailable { return false }
        if !on && device.torchMode == .off { return false }
        do {
            try device.lockForConfiguration()
        } catch {
            return device.torchMode == .on
        }
        if on {
            // A little under full power: plenty for a sheet 30 cm away, less heat.
            try? device.setTorchModeOn(level: 0.8)
        } else if device.isTorchModeSupported(.off) {
            device.torchMode = .off
        }
        device.unlockForConfiguration()
        return device.torchMode == .on
    }

    /// Captures a still. `rotationAngle` comes from AVCaptureDevice.RotationCoordinator (horizon-level capture).
    func capturePhoto(rotationAngle: CGFloat) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            sessionQueue.async {
                guard self.isConfigured, self.session.isRunning else {
                    cont.resume(throwing: CameraError.unavailable)
                    return
                }
                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.photoQualityPrioritization = .balanced
                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                self.lock.withLock { self.pendingPhotos[settings.uniqueID] = cont }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        // Virtual multi-camera devices switch to the ultra-wide (macro) automatically when close to the paper.
        let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        self.device = device
        let iso = Double(device.activeFormat.maxISO)
        lock.withLock { maxISO = iso }
        isConfigured = true
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDetection > 0.12 else { return }   // ~8 analyses per second is plenty
        lastDetection = now
        let (enabled, handler, light, isoMax) = lock.withLock { (detectionEnabled, quadHandler, lightHandler, maxISO) }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 1.2.2 low light (drawings and crafts; cheap: frame metadata + a sparse luma sample).
        if let light {
            let sample = lowLightSample(sampleBuffer, pixelBuffer: pixelBuffer, maxISO: isoMax)
            var status = CameraLightStatus(isDim: lowLight.update(sample, now: now))
            if let device, device.hasTorch {
                status.torchActive = device.isTorchActive
                status.torchAvailable = device.isTorchAvailable
            }
            if status != lastLight {
                lastLight = status
                light(status)
            }
        }

        guard enabled, let handler else { return }
        let width = Double(CVPixelBufferGetWidth(pixelBuffer)), height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let aspect = height > 0 ? width / height : 4.0 / 3.0

        // Classic VN API on purpose: synchronous on this queue, no Sendable hops for the pixel buffer.
        let request = VNDetectDocumentSegmentationRequest()
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? requestHandler.perform([request])

        var document: (quad: Quad, confidence: Double)?
        if let obs = request.results?.first, let q = Self.deviceQuad(obs) {
            document = (q, Double(obs.confidence))
        }
        // 1.2.2: the rectangle detector only when the document detector is unsure (dim light, white on white), and
        // at most every 0.3 s (heat).
        var rectangles: [(quad: Quad, confidence: Double)] = []
        let runRectangles = LivePaperPicker.wantsRectangles(documentConfidence: document?.confidence, now: now,
                                                           lastRectangles: lastRectangles)
        if runRectangles {
            lastRectangles = now
            let rect = VisionPaths.sheetRectanglesRequest()
            try? requestHandler.perform([rect])
            for o in rect.results ?? [] {
                if let q = Self.deviceQuad(o) { rectangles.append((quad: q, confidence: Double(o.confidence))) }
            }
        }
        let picked = LivePaperPicker.pick(document: document, rectangles: rectangles,
                                          previousRectangle: previousRectangle, imageAspect: aspect)
        if runRectangles {
            previousRectangle = rectangles.filter { $0.quad.isPlausible }.max { $0.confidence < $1.confidence }?.quad
        }
        // Between rectangle passes a rectangle-only outline is held by the smoothing below (3 misses ≈ 0.36 s).
        if let picked {
            let found = picked.points.map { CGPoint(x: $0.x, y: $0.y) }
            misses = 0
            if let prev = smoothed, prev.count == 4 {
                smoothed = zip(prev, found).map { p, n in CGPoint(x: p.x * 0.5 + n.x * 0.5, y: p.y * 0.5 + n.y * 0.5) }
            } else {
                smoothed = found
            }
        } else {
            misses += 1
            if misses >= 3 { smoothed = nil }
        }
        handler(smoothed.map { LiveQuad(points: $0) })
    }

    /// Vision: normalized, lower-left origin, in buffer (= sensor) orientation → device points (top-left origin).
    private static func deviceQuad(_ o: VNRectangleObservation) -> Quad? {
        let pts = [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { NormPoint(x: Double($0.x), y: 1 - Double($0.y)) }
        return CornerOrdering.order(pts)
    }

    /// Frame metadata (EXIF BrightnessValue / ISO / exposure), the device's ISO range, and a sparse mean luma.
    private func lowLightSample(_ sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer, maxISO: Double) -> LowLightSample {
        var s = LowLightSample()
        if let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil) as? [String: Any] {
            s.brightnessValue = (exif[kCGImagePropertyExifBrightnessValue as String] as? NSNumber)?.doubleValue
            s.exposureSeconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
            s.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        }
        if s.iso == nil, let device {
            s.iso = Double(device.iso)
            let t = device.exposureDuration.seconds
            if t.isFinite, t > 0 { s.exposureSeconds = t }
        }
        if let iso = s.iso, maxISO > 0 { s.isoRatio = iso / maxISO }
        s.meanLuma = LumaSampler.mean(pixelBuffer)
        return s
    }
}

/// Mean luma of a camera frame from a sparse 24 × 18 grid (bi-planar YUV: the Y plane; BGRA: weighted RGB).
enum LumaSampler {
    static func mean(_ pb: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pb)
        let planar = CVPixelBufferIsPlanar(pb)
        let isBGRA = !planar && format == kCVPixelFormatType_32BGRA
        guard planar || isBGRA else { return nil }
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, 0) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb)
        let bpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        let rawBase = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb)
        guard w > 0, h > 0, let rawBase else { return nil }
        let bytes = rawBase.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, n = 0
        for gy in 0..<18 {
            let y = (gy * 2 + 1) * h / 36
            for gx in 0..<24 {
                let x = (gx * 2 + 1) * w / 48
                if planar {
                    sum += Double(bytes[y * bpr + x])
                } else {
                    let i = y * bpr + x * 4
                    sum += 0.114 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.299 * Double(bytes[i + 2])
                }
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / Double(n)
        // Video-range YUV: 16…235 → 0…255.
        if planar && format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            return ((mean - 16) * 255 / 219).clamped(0, 255)
        }
        return mean
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let cont = lock.withLock { pendingPhotos.removeValue(forKey: id) }
        if let error {
            cont?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            cont?.resume(returning: data)
        } else {
            cont?.resume(throwing: CameraError.noPhotoData)
        }
    }
}
