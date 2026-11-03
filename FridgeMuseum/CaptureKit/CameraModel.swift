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
    /// 1.2.2 low-light assist: the scene is dim (from the analysed frames).
    var isDim = false
    /// The flashlight is on (as the device reports it).
    var torchOn = false
    /// This camera has a flashlight (false in the Simulator, so DemoMode / screenshots never show the button).
    var hasTorch = false

    let controller = CameraController()

    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    /// Gravity-based capture angle; also right when the phone is held (almost) flat over a table.
    @ObservationIgnored private let gravity = GravityOrientationTracker()
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var torch = TorchState()

    /// Show the flashlight hint / highlight: dim, flashlight off, and there is one.
    var suggestsTorch: Bool { hasTorch && isDim && !torchOn }

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
        controller.setLightHandler { status in
            Task { @MainActor in self.updateLight(status) }
        }
        do {
            try await controller.start()
            state = .running
            hasTorch = controller.hasTorch
            setUpRotation()
        } catch {
            state = .unavailable
        }
    }

    func stop() {
        _ = torch.leave(now: Self.now)
        torchOn = false
        isDim = false
        controller.stop()        // also switches the flashlight off
        gravity.stop()
        liveQuad = nil
    }

    /// The flashlight button.
    func toggleTorch() {
        guard state == .running, hasTorch else { return }
        let want = torch.toggle(available: true, now: Self.now)
        torchOn = want          // answer the tap at once; corrected below if the device refuses
        Task {
            let on = await controller.setTorch(want)
            torch.applied(on, now: Self.now)
            torchOn = on
        }
    }

    /// Leaving the app (background): flashlight off; it stays off when the user comes back.
    func turnTorchOff() {
        guard torch.leave(now: Self.now) || torchOn else { return }
        torchOn = false
        Task { _ = await controller.setTorch(false) }
    }

    private func updateLight(_ status: CameraLightStatus) {
        if isDim != status.isDim { isDim = status.isDim }
        // The system switched it off (overheating, another app, an interruption): accept it, don't turn it back on.
        if torch.deviceReported(active: status.torchActive, available: status.torchAvailable, now: Self.now) {
            torchOn = false
            // keep the device's mode in step with the button (no-op if it is already off)
            Task { _ = await controller.setTorch(false) }
        }
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

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
        // Gravity only from moments the phone was clearly tilted (≥ 30°) in this session; otherwise the coordinator
        // (1.1.0), otherwise portrait. A near-flat reading never decides (see CaptureOrientation).
        let angle = captureRotationAngle(gravityAngle: gravity.currentAngle,
                                         coordinatorAngle: rotationCoordinator?.videoRotationAngleForHorizonLevelCapture)
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
