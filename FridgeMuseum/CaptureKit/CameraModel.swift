import AVFoundation
import Observation

@MainActor
@Observable
final class CameraModel {
    enum State: Equatable {
        case idle
        case running
        case denied
        case unavailable
    }

    var state: State = .idle
    var liveQuad: LiveQuad?
    var isCapturing = false
    /// Increments on every shutter press (drives the flash animation).
    var shutterCount = 0

    let controller = CameraController()

    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// Gravity-based capture angle; also right when the phone is held (almost) flat over a table.
    @ObservationIgnored private let gravity = GravityOrientationTracker()
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?

    var paperFound: Bool { liveQuad != nil }

    func start() async {
        var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard authorized else {
            state = .denied
            return
        }
        gravity.start()
        controller.setQuadHandler { quad in
            Task { @MainActor in self.updateQuad(quad) }
        }
        do {
            try await controller.start()
            state = .running
            setUpRotation()
        } catch {
            state = .unavailable
        }
    }

    func stop() {
        controller.stop()
        gravity.stop()
        liveQuad = nil
    }

    func setDetectionEnabled(_ on: Bool) {
        controller.setDetectionEnabled(on)
        if !on { liveQuad = nil }
    }

    func attach(previewLayer layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        setUpRotation()
    }

    /// Takes a photo; returns encoded HEIC/JPEG data with orientation metadata (EXIF set from the capture angle).
    func capture() async -> Data? {
        guard state == .running, !isCapturing else { return nil }
        isCapturing = true
        shutterCount += 1
        defer { isCapturing = false }
        // Gravity first: the coordinator's horizon-level angle does not follow the phone while it lies flat
        // (table shots), so it kept portrait and landscape drawings arrived sideways.
        let angle: CGFloat = gravity.currentAngle.map { CGFloat($0) }
            ?? rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        return try? await controller.capturePhoto(rotationAngle: angle)
    }

    private func updateQuad(_ quad: LiveQuad?) {
        if liveQuad != quad { liveQuad = quad }
    }

    private func setUpRotation() {
        guard rotationCoordinator == nil, let device = controller.device, let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        if let connection = layer.connection {
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}
