import SwiftUI
import UIKit

/// What the stage touch surface reports (points in the surface = the stage's inner area).
enum StageTouchEvent {
    /// One-finger drawing (筆刷) or dragging (對比 split line).
    case strokeBegan(CGPoint)
    case strokeMoved(CGPoint)
    /// Keep what was drawn.
    case strokeEnded
    /// Throw away what was drawn (it turned into a pinch, a double tap, or the system cancelled the touch).
    case strokeCancelled
    /// Two fingers: centroid and finger distance.
    case transformBegan(centroid: CGPoint, distance: CGFloat)
    case transformChanged(centroid: CGPoint, distance: CGFloat)
    case transformEnded
    case doubleTap(CGPoint)
}

/// Transparent multi-touch view over the stage: one finger draws, two fingers pinch / pan, double tap zooms.
/// Raw touches (not gesture recognizers) so a stroke that becomes a pinch can be discarded after the fact.
struct StageTouchSurface: UIViewRepresentable {
    let onEvent: @MainActor (StageTouchEvent) -> Void

    func makeUIView(context: Context) -> StageTouchView {
        let view = StageTouchView(frame: .zero)
        view.onEvent = onEvent
        return view
    }

    func updateUIView(_ uiView: StageTouchView, context: Context) {
        uiView.onEvent = onEvent
    }
}

final class StageTouchView: UIView {
    var onEvent: (@MainActor (StageTouchEvent) -> Void)?

    private enum Phase {
        case idle
        case stroke(UITouch, start: TimeInterval, origin: CGPoint, travel: CGFloat)
        /// A touch that may be the second tap of a double tap (the first tap's dot is still pending).
        case secondTap(UITouch, start: TimeInterval, origin: CGPoint)
        case transform(UITouch, UITouch)
        /// After a pinch or a cancelled stroke: ignore the remaining fingers until all are up.
        case finishing
    }

    private var phase: Phase = .idle
    private var active: Set<UITouch> = []
    /// A tap's dot waits a moment before it is kept, in case a second tap makes it a double tap.
    private var pendingTap: (point: CGPoint, time: TimeInterval)?
    private var pendingTapTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func send(_ event: StageTouchEvent) { onEvent?(event) }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            active.insert(touch)
            began(touch)
        }
    }

    private func began(_ touch: UITouch) {
        let p = touch.location(in: self)
        switch phase {
        case .idle:
            if active.count >= 2, let other = active.first(where: { $0 !== touch }) {
                keepPendingTap()
                beginTransform(other, touch)
            } else if let tap = pendingTap,
                      distance(p, tap.point) < StageTouchPolicy.doubleTapDistance,
                      touch.timestamp - tap.time < StageTouchPolicy.doubleTapInterval {
                pendingTapTask?.cancel()
                phase = .secondTap(touch, start: touch.timestamp, origin: p)
            } else {
                keepPendingTap()
                phase = .stroke(touch, start: touch.timestamp, origin: p, travel: 0)
                send(.strokeBegan(p))
            }
        case let .stroke(first, start, _, travel):
            send(StageTouchPolicy.discardsStroke(age: touch.timestamp - start, travel: travel) ? .strokeCancelled : .strokeEnded)
            beginTransform(first, touch)
        case let .secondTap(first, _, _):
            keepPendingTap()
            beginTransform(first, touch)
        case .transform, .finishing:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        switch phase {
        case let .stroke(touch, start, origin, travel):
            guard touches.contains(touch) else { return }
            let p = touch.location(in: self)
            phase = .stroke(touch, start: start, origin: origin, travel: max(travel, distance(p, origin)))
            send(.strokeMoved(p))
        case let .secondTap(touch, start, origin):
            guard touches.contains(touch) else { return }
            let p = touch.location(in: self)
            guard distance(p, origin) > StageTouchPolicy.tapSlop else { return }
            // Not a double tap after all: keep the first dot, and this touch becomes an ordinary stroke.
            keepPendingTap()
            phase = .stroke(touch, start: start, origin: origin, travel: distance(p, origin))
            send(.strokeBegan(origin))
            send(.strokeMoved(p))
        case let .transform(a, b):
            guard touches.contains(a) || touches.contains(b) else { return }
            send(.transformChanged(centroid: centroid(a, b), distance: distance(a.location(in: self), b.location(in: self))))
        case .idle, .finishing:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        ended(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        ended(touches, cancelled: true)
    }

    private func ended(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches { active.remove(touch) }
        switch phase {
        case let .stroke(touch, start, origin, travel) where touches.contains(touch):
            if cancelled {
                send(.strokeCancelled)
            } else if StageTouchPolicy.isTap(duration: touch.timestamp - start, travel: travel) {
                holdTap(at: origin, time: touch.timestamp)
            } else {
                send(.strokeEnded)
            }
            phase = active.isEmpty ? .idle : .finishing
        case let .secondTap(touch, start, _) where touches.contains(touch):
            if !cancelled, touch.timestamp - start < StageTouchPolicy.tapDuration, let tap = pendingTap {
                pendingTapTask?.cancel()
                pendingTap = nil
                send(.strokeCancelled)          // the first tap's dot
                send(.doubleTap(tap.point))
            } else {
                keepPendingTap()
            }
            phase = active.isEmpty ? .idle : .finishing
        case let .transform(a, b) where touches.contains(a) || touches.contains(b):
            send(.transformEnded)
            phase = active.isEmpty ? .idle : .finishing
        default:
            if active.isEmpty { phase = .idle }
        }
    }

    // MARK: Helpers

    private func beginTransform(_ a: UITouch, _ b: UITouch) {
        phase = .transform(a, b)
        send(.transformBegan(centroid: centroid(a, b), distance: distance(a.location(in: self), b.location(in: self))))
    }

    /// The tap's dot stays drawn but is only kept after the double-tap window passes.
    private func holdTap(at point: CGPoint, time: TimeInterval) {
        pendingTap = (point: point, time: time)
        pendingTapTask?.cancel()
        pendingTapTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(StageTouchPolicy.doubleTapInterval))
            guard !Task.isCancelled else { return }
            self?.keepPendingTap()
        }
    }

    private func keepPendingTap() {
        pendingTapTask?.cancel()
        pendingTapTask = nil
        guard pendingTap != nil else { return }
        pendingTap = nil
        send(.strokeEnded)
    }

    private func centroid(_ a: UITouch, _ b: UITouch) -> CGPoint {
        let p = a.location(in: self), q = b.location(in: self)
        return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
    }

    private func distance(_ p: CGPoint, _ q: CGPoint) -> CGFloat {
        hypot(p.x - q.x, p.y - q.y)
    }
}
