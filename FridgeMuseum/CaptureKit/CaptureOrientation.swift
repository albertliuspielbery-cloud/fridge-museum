import CoreMotion
import Foundation

/// Which way the still should be turned, from the phone's physical attitude.
///
/// The UI is portrait-locked, so the photo's orientation has to come from the hardware. `AVCaptureDevice.
/// RotationCoordinator.videoRotationAngleForHorizonLevelCapture` follows the device's coarse orientation, which has no
/// answer while the phone lies face-up / face-down — exactly how parents shoot a drawing lying on a table — so it keeps
/// the angle from before the phone was laid down (usually portrait) and landscape table shots came out sideways.
/// Gravity still has a small in-plane component when the phone is held almost flat (the edge nearest the person is a
/// little lower), and that component points to the bottom of the scene as the person sees it.
enum CaptureOrientation {
    /// In-plane gravity (in g) below this — about 7° from flat — is too flat to tell; the last answer is kept.
    static let flatThreshold = 0.12
    /// Degrees past the 45° boundary before switching away from the previous angle (no flicker at the diagonal).
    static let hysteresis = 12.0

    /// `AVCaptureConnection.videoRotationAngle` (0, 90, 180 or 270) for the back camera, from CoreMotion gravity in
    /// the device frame (x toward the right edge, y toward the top edge, in portrait). nil when the phone is too flat.
    ///   portrait (0, −1) → 90 · landscapeLeft, home button right (−1, 0) → 0
    ///   landscapeRight, home button left (1, 0) → 180 · portraitUpsideDown (0, 1) → 270
    static func rotationAngle(gravityX x: Double, gravityY y: Double, previous: Int?) -> Int? {
        guard x.isFinite, y.isFinite else { return nil }
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude >= flatThreshold else { return nil }
        var degrees = atan2(y, x) * 180 / .pi + 180          // 0...360
        if degrees >= 360 { degrees -= 360 }
        let nearest = (Int((degrees / 90).rounded()) % 4) * 90
        if let previous, previous != nearest, [0, 90, 180, 270].contains(previous) {
            var d = abs(degrees - Double(previous)).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            if d < 45 + hysteresis { return previous }
        }
        return nearest
    }
}

/// Turns raw gravity readings into a steady capture angle.
///
/// The first answer may come from a small tilt (≥ `CaptureOrientation.flatThreshold`, about 7°): a phone held flat
/// over a table still has the edge nearest the person a little lower. Leaving an established angle is much harder —
/// the in-plane gravity must be ≥ `switchMagnitude` (about 17° from flat) and the new angle must hold for
/// `switchDelay` — so a phone held portrait over a table, wobbling a few degrees sideways or forward, stays portrait
/// (1.1.0 behaviour), while a deliberate turn to landscape still switches.
struct CaptureOrientationFilter: Sendable {
    static let switchMagnitude = 0.3
    static let switchDelay: TimeInterval = 0.3

    private(set) var angle: Int?
    private var pendingAngle: Int?
    private var pendingSince: TimeInterval = 0

    init(angle: Int? = nil) {
        self.angle = angle
    }

    /// Feeds one reading (CoreMotion gravity in the device frame, `time` in seconds) and returns the current angle.
    @discardableResult
    mutating func update(gravityX x: Double, gravityY y: Double, time: TimeInterval) -> Int? {
        guard let raw = CaptureOrientation.rotationAngle(gravityX: x, gravityY: y, previous: angle) else {
            pendingAngle = nil          // too flat to tell: keep the last angle
            return angle
        }
        guard let current = angle else {
            angle = raw
            return raw
        }
        guard raw != current, (x * x + y * y).squareRoot() >= Self.switchMagnitude else {
            pendingAngle = nil
            return current
        }
        if pendingAngle == raw {
            if time - pendingSince >= Self.switchDelay {
                angle = raw
                pendingAngle = nil
            }
        } else {
            pendingAngle = raw
            pendingSince = time
        }
        return angle
    }
}

/// Follows gravity while the camera is open and remembers the last confident capture angle (so a phone laid flat
/// keeps the orientation it had while it was still tilted). Device motion needs no permission.
/// Mutable state is guarded by `lock`; CoreMotion calls back on its own serial queue, hence @unchecked Sendable.
final class GravityOrientationTracker: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()
    private var filter = CaptureOrientationFilter()

    deinit {
        manager.stopDeviceMotionUpdates()
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 15
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.update(x: motion.gravity.x, y: motion.gravity.y, time: motion.timestamp)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Last confident angle; nil before the phone was ever held at a readable tilt (or without device motion,
    /// e.g. in the Simulator) — the caller then falls back to the RotationCoordinator.
    var currentAngle: Int? {
        lock.withLock { filter.angle }
    }

    private func update(x: Double, y: Double, time: TimeInterval) {
        lock.withLock {
            _ = filter.update(gravityX: x, gravityY: y, time: time)
        }
    }
}
