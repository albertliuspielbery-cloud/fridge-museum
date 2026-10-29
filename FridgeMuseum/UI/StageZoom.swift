import CoreGraphics
import Foundation

/// Zoom & pan of the editor stage while 筆刷 (or 對比) is on. Pure value math so it can be unit-tested.
///
/// - `fit`: where the artwork sits at 1× (`fitRect(output.size, in: stage)`), in stage points.
/// - `viewport`: the stage size; the zoomed artwork never leaves an empty gap inside it.
/// - Image points are normalized to the artwork (0…1, top-left origin) — the output-normalized space the brush
///   already records in before `OutputMapping.toStrokeSpace`, so zooming never changes where a stroke lands.
struct StageZoom: Equatable, Sendable {
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 6
    /// Double-tap zoom level (double-tap again returns to fit).
    static let doubleTapScale: CGFloat = 2.5
    /// Brush radius per slider step, as a fraction of the output's long edge at 1× (unchanged from before zoom).
    static let brushRadiusPerStep = 0.006

    /// 1 = fit.
    var scale: CGFloat = 1
    /// Shift of the zoomed artwork's center from the fit rect's center, in stage points.
    var offset: CGSize = .zero

    var isZoomed: Bool { scale > 1.001 }

    /// Where the artwork is drawn on the stage at this zoom.
    func displayRect(fit: CGRect) -> CGRect {
        let w = fit.width * scale, h = fit.height * scale
        return CGRect(x: fit.midX - w / 2 + offset.width, y: fit.midY - h / 2 + offset.height, width: w, height: h)
    }

    /// Stage point → artwork-normalized point (may fall outside 0…1 when the touch is off the artwork).
    func imagePoint(fromView p: CGPoint, fit: CGRect) -> CGPoint {
        let r = displayRect(fit: fit)
        guard r.width > 0, r.height > 0 else { return .zero }
        return CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }

    /// Artwork-normalized point → stage point.
    func viewPoint(fromImage p: CGPoint, fit: CGRect) -> CGPoint {
        let r = displayRect(fit: fit)
        return CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
    }

    /// The zoom at `newScale` that puts artwork point `image` under stage point `view`, then clamped.
    static func placing(_ image: CGPoint, at view: CGPoint, scale newScale: CGFloat,
                        fit: CGRect, viewport: CGSize) -> StageZoom {
        let s = newScale.clamped(minScale, maxScale)
        let w = fit.width * s, h = fit.height * s
        let minX = view.x - image.x * w, minY = view.y - image.y * h
        let z = StageZoom(scale: s, offset: CGSize(width: minX - (fit.midX - w / 2), height: minY - (fit.midY - h / 2)))
        return z.clamped(fit: fit, viewport: viewport)
    }

    /// Zooms to `newScale` keeping the artwork point under `anchor` where it is.
    func zoomed(to newScale: CGFloat, around anchor: CGPoint, fit: CGRect, viewport: CGSize) -> StageZoom {
        Self.placing(imagePoint(fromView: anchor, fit: fit), at: anchor, scale: newScale, fit: fit, viewport: viewport)
    }

    /// Two-finger pinch + pan in one: `self` is the zoom when the fingers came down. The artwork point that was
    /// under the starting centroid follows the current centroid; the scale follows the finger distance.
    func pinched(startCentroid c0: CGPoint, startDistance d0: CGFloat, centroid c1: CGPoint, distance d1: CGFloat,
                 fit: CGRect, viewport: CGSize) -> StageZoom {
        let ratio = d0 > 1 ? d1 / d0 : 1
        return Self.placing(imagePoint(fromView: c0, fit: fit), at: c1, scale: scale * ratio, fit: fit, viewport: viewport)
    }

    /// Double tap: fit ↔ 2.5× around the tapped point.
    func toggled(at p: CGPoint, fit: CGRect, viewport: CGSize) -> StageZoom {
        isZoomed ? StageZoom() : zoomed(to: Self.doubleTapScale, around: p, fit: fit, viewport: viewport)
    }

    /// Scale within 1…6; at 1× exactly the fit. Along an axis where the zoomed artwork is wider than the stage it
    /// may not pull away from the stage edges; where it is narrower it stays centered in the stage.
    func clamped(fit: CGRect, viewport: CGSize) -> StageZoom {
        let s = scale.clamped(Self.minScale, Self.maxScale)
        guard s > 1.001 else { return StageZoom() }
        func axis(_ off: CGFloat, length: CGFloat, fitMid: CGFloat, viewLength: CGFloat) -> CGFloat {
            let centered = viewLength / 2 - fitMid
            let slack = (length - viewLength) / 2
            return slack <= 0 ? centered : off.clamped(centered - slack, centered + slack)
        }
        return StageZoom(scale: s, offset: CGSize(
            width: axis(offset.width, length: fit.width * s, fitMid: fit.midX, viewLength: viewport.width),
            height: axis(offset.height, length: fit.height * s, fitMid: fit.midY, viewLength: viewport.height)))
    }

    /// Stroke radius in artwork space (fraction of the output's long edge): the slider size divided by the zoom,
    /// so a brush feels the same size on screen at any zoom.
    static func strokeRadius(sliderSize: Double, scale: CGFloat) -> Double {
        sliderSize * brushRadiusPerStep / Double(max(scale, minScale))
    }

    /// On-screen brush radius (stage points) — the same at every zoom.
    static func screenRadius(sliderSize: Double, fit: CGRect) -> CGFloat {
        CGFloat(sliderSize * brushRadiusPerStep) * max(fit.width, fit.height)
    }
}

/// When a second finger lands during a one-finger stroke, the stroke was probably the first finger of a pinch:
/// discard it if it is very young or has barely moved; otherwise keep (commit) what was painted.
enum StageTouchPolicy {
    static let discardWindow: TimeInterval = 0.12
    static let discardTravel: CGFloat = 8
    /// A tap (paints a dot unless a second tap follows) is short and nearly still.
    static let tapDuration: TimeInterval = 0.25
    static let tapSlop: CGFloat = 10
    /// The second tap of a double tap must start within this time and distance of the first.
    static let doubleTapInterval: TimeInterval = 0.3
    static let doubleTapDistance: CGFloat = 44

    static func discardsStroke(age: TimeInterval, travel: CGFloat) -> Bool {
        age < discardWindow || travel < discardTravel
    }

    static func isTap(duration: TimeInterval, travel: CGFloat) -> Bool {
        duration < tapDuration && travel < tapSlop
    }
}
