import AVFoundation
import CoreGraphics
import Vision

/// Live paper outline in *capture-device* coordinates: (0,0) top-left, (1,1) bottom-right of the
/// unrotated sensor frame. AVCaptureVideoPreviewLayer converts these to view points.
struct LiveQuad: Sendable, Equatable {
    var points: [CGPoint]
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
    private var detectionEnabled = true

    // sessionQueue only
    private var isConfigured = false
    // videoQueue only
    private var lastDetection: CFAbsoluteTime = 0
    private var smoothed: [CGPoint]?
    private var misses = 0

    /// Set once configured; read on the main actor afterwards.
    private(set) var device: AVCaptureDevice?

    func setQuadHandler(_ handler: @escaping @Sendable (LiveQuad?) -> Void) {
        lock.withLock { quadHandler = handler }
    }

    func setDetectionEnabled(_ on: Bool) {
        lock.withLock { detectionEnabled = on }
    }

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
            if self.session.isRunning { self.session.stopRunning() }
        }
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
        isConfigured = true
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDetection > 0.12 else { return }   // ~8 detections per second is plenty
        lastDetection = now
        let (enabled, handler) = lock.withLock { (detectionEnabled, quadHandler) }
        guard enabled, let handler, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Classic VN API on purpose: synchronous on this queue, no Sendable hops for the pixel buffer.
        let request = VNDetectDocumentSegmentationRequest()
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? requestHandler.perform([request])

        var found: [CGPoint]?
        if let obs = request.results?.first, obs.confidence >= 0.6 {
            // Vision: normalized, lower-left origin, in buffer (= sensor) orientation → device points (top-left origin).
            let pts = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
            if let q = CornerOrdering.order(pts.map { NormPoint(x: Double($0.x), y: Double($0.y)) }), q.isPlausible {
                found = q.points.map { CGPoint(x: $0.x, y: $0.y) }
            }
        }
        if let found {
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
