import CoreMotion
import Foundation
import UIKit

/// Which way the still should be turned, from the phone's physical attitude.
///
/// The UI is portrait-locked, so the photo's orientation has to come from the hardware. Gravity is only trusted while
/// the phone is clearly tilted (in-plane gravity ≥ `tiltThreshold`, about 30° from flat). Nearly flat — the usual
/// pose over a drawing on a table — the in-plane direction is mostly noise (1.2.0 took its first answer from a 7°
/// roll and turned flat portrait shots sideways), so the tracker keeps the angle from the last moment the phone was
/// clearly tilted in this camera session, and without one the caller uses the RotationCoordinator (1.1.0) or portrait.
enum CaptureOrientation {
    /// In-plane gravity (in g) needed to trust its direction: about 30° from flat.
    static let tiltThreshold = 0.5
    /// Degrees past the 45° boundary before switching away from the previous angle (no flicker at the diagonal).
    static let hysteresis = 12.0

    /// Apple's convention for `AVCaptureConnection.videoRotationAngle` with the back camera (the values the
    /// RotationCoordinator reports for these device orientations); nil for faceUp / faceDown / unknown.
    static func videoRotationAngle(for orientation: UIDeviceOrientation) -> Int? {
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0          // home button / bottom edge on the right = the sensor's own orientation
        case .landscapeRight: return 180       // home button / bottom edge on the left
        default: return nil
        }
    }

    /// The mapping itself, with no thresholds: CoreMotion gravity in the device frame (x toward the right edge,
    /// y toward the top edge, as held in portrait; units of g) → nearest videoRotationAngle.
    ///   portrait (0, −1) → 90 · landscapeLeft (−1, 0) → 0 · landscapeRight (1, 0) → 180 · upside down (0, 1) → 270
    static func nearestAngle(gravityX x: Double, gravityY y: Double) -> Int {
        (Int((degrees(x, y) / 90).rounded()) % 4) * 90
    }

    /// Gravity's in-plane direction as a videoRotationAngle in degrees, 0..<360.
    private static func degrees(_ x: Double, _ y: Double) -> Double {
        var d = atan2(y, x) * 180 / .pi + 180
        if d >= 360 { d -= 360 }
        return d
    }

    /// The angle gravity points to when the phone is clearly tilted, with hysteresis around `previous`;
    /// nil when it is flatter than `tiltThreshold` (then the direction says nothing).
    static func rotationAngle(gravityX x: Double, gravityY y: Double, previous: Int?) -> Int? {
        guard x.isFinite, y.isFinite else { return nil }
        guard (x * x + y * y).squareRoot() >= tiltThreshold else { return nil }
        let nearest = nearestAngle(gravityX: x, gravityY: y)
        if let previous, previous != nearest, [0, 90, 180, 270].contains(previous) {
            var d = abs(degrees(x, y) - Double(previous)).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            if d < 45 + hysteresis { return previous }
        }
        return nearest
    }
}

/// Turns raw gravity readings into a steady capture angle.
///
/// Only clearly tilted readings (≥ `CaptureOrientation.tiltThreshold`) count — never a first answer from a
/// near-flat phone. The first clear reading sets the angle; a different angle must then hold for `switchDelay`
/// before it replaces it. Flat readings keep whatever was last decided (nil until the phone was clearly tilted once).
struct CaptureOrientationFilter: Sendable {
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
            pendingAngle = nil          // not clearly tilted: keep the last angle
            return angle
        }
        guard let current = angle else {
            angle = raw
            return raw
        }
        guard raw != current else {
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

/// The still's rotation: the gravity tracker's angle when the phone was clearly tilted at some point in this camera
/// session, else the RotationCoordinator's horizon-level angle (1.1.0 behaviour), else portrait.
func captureRotationAngle(gravityAngle: Int?, coordinatorAngle: CGFloat?) -> CGFloat {
    if let gravityAngle { return CGFloat(gravityAngle) }
    return coordinatorAngle ?? 90
}

/// Follows gravity while the camera is open and remembers the angle from the last time the phone was clearly tilted
/// (so a phone laid flat keeps the orientation it had). Device motion needs no permission.
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

    /// Angle from the last time the phone was clearly tilted in this session; nil before that (or without device
    /// motion, e.g. in the Simulator) — the caller then falls back to the RotationCoordinator.
    var currentAngle: Int? {
        lock.withLock { filter.angle }
    }

    private func update(x: Double, y: Double, time: TimeInterval) {
        lock.withLock {
            _ = filter.update(gravityX: x, gravityY: y, time: time)
        }
    }
}
