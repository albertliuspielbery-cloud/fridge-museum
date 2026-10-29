import CoreGraphics
import Foundation
import Testing
@testable import FridgeMuseum

/// Brush zoom & pan on the editor stage: screen ↔ artwork mapping, clamping, pinch, stroke width.
struct StageZoomTests {
    /// A portrait craft fitted in a phone-sized stage: 200×300 pt, centered in 335×300.
    let viewport = CGSize(width: 335, height: 300)
    var fit: CGRect { fitRect(CGSize(width: 800, height: 1200), in: viewport) }

    private func close(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 1e-6) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }

    @Test func fitIsIdentity() {
        let z = StageZoom()
        #expect(z.displayRect(fit: fit) == fit)
        #expect(!z.isZoomed)
        #expect(close(z.imagePoint(fromView: CGPoint(x: fit.minX, y: fit.minY), fit: fit), .zero))
        #expect(close(z.imagePoint(fromView: CGPoint(x: fit.maxX, y: fit.maxY), fit: fit), CGPoint(x: 1, y: 1)))
        #expect(close(z.imagePoint(fromView: CGPoint(x: fit.midX, y: fit.midY), fit: fit), CGPoint(x: 0.5, y: 0.5)))
    }

    @Test func screenAndImagePointsRoundTripUnderZoomAndPan() {
        let z = StageZoom(scale: 3, offset: CGSize(width: 40, height: -25))
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.8), CGPoint(x: 1, y: 1), CGPoint(x: 0.6, y: 0.1)] {
            let v = z.viewPoint(fromImage: p, fit: fit)
            #expect(close(z.imagePoint(fromView: v, fit: fit), p))
        }
        // The zoomed artwork is 3× the fit, its center shifted by the offset.
        let r = z.displayRect(fit: fit)
        #expect(abs(r.width - fit.width * 3) < 1e-9)
        #expect(abs(r.midX - (fit.midX + 40)) < 1e-9)
        #expect(abs(r.midY - (fit.midY - 25)) < 1e-9)
    }

    @Test func zoomKeepsTheAnchorPointStill() {
        let anchor = CGPoint(x: fit.midX + 30, y: fit.midY + 40)   // inside the artwork, away from the edges
        let before = StageZoom().imagePoint(fromView: anchor, fit: fit)
        let z = StageZoom().zoomed(to: 2, around: anchor, fit: fit, viewport: viewport)
        #expect(z.scale == 2)
        #expect(close(z.imagePoint(fromView: anchor, fit: fit), before, 1e-6))
    }

    @Test func scaleIsClampedToOneToSix() {
        let c = CGPoint(x: fit.midX, y: fit.midY)
        #expect(StageZoom().zoomed(to: 20, around: c, fit: fit, viewport: viewport).scale == StageZoom.maxScale)
        #expect(StageZoom(scale: 3).zoomed(to: 0.3, around: c, fit: fit, viewport: viewport) == StageZoom())
    }

    @Test func panCannotPullTheArtworkAwayFromTheStageEdges() {
        // 4×: 800×1200 pt artwork in a 335×300 stage — it must keep covering the stage.
        let z = StageZoom(scale: 4, offset: CGSize(width: 5000, height: -5000)).clamped(fit: fit, viewport: viewport)
        let r = z.displayRect(fit: fit)
        #expect(abs(r.minX - 0) < 1e-9)                       // pushed right as far as allowed
        #expect(abs(r.maxY - viewport.height) < 1e-9)         // pushed up as far as allowed
        #expect(r.maxX >= viewport.width && r.minY <= 0)
    }

    @Test func narrowAxisStaysCentered() {
        // 1.5×: the portrait craft is 300 pt wide (< 335) — horizontally centered whatever the pan.
        let z = StageZoom(scale: 1.5, offset: CGSize(width: 80, height: 0)).clamped(fit: fit, viewport: viewport)
        #expect(abs(z.displayRect(fit: fit).midX - viewport.width / 2) < 1e-9)
    }

    @Test func pinchFollowsTheFingers() {
        let start = StageZoom(scale: 2, offset: .zero).clamped(fit: fit, viewport: viewport)
        let c0 = CGPoint(x: 160, y: 150), c1 = CGPoint(x: 150, y: 140)
        let under = start.imagePoint(fromView: c0, fit: fit)
        let z = start.pinched(startCentroid: c0, startDistance: 100, centroid: c1, distance: 150, fit: fit, viewport: viewport)
        #expect(abs(z.scale - 3) < 1e-9)
        // The artwork point that was under the fingers is still under them (no clamping needed here).
        #expect(close(z.viewPoint(fromImage: under, fit: fit), c1, 1e-6))
        // Same distance, fingers moved: a pure two-finger pan.
        let pan = start.pinched(startCentroid: c0, startDistance: 100, centroid: CGPoint(x: 170, y: 160), distance: 100,
                                fit: fit, viewport: viewport)
        #expect(pan.scale == start.scale)
        #expect(close(pan.viewPoint(fromImage: under, fit: fit), CGPoint(x: 170, y: 160), 1e-6))
    }

    @Test func doubleTapToggles() {
        let p = CGPoint(x: fit.midX, y: fit.midY + 20)
        let z = StageZoom().toggled(at: p, fit: fit, viewport: viewport)
        #expect(z.scale == StageZoom.doubleTapScale)
        #expect(z.isZoomed)
        #expect(z.toggled(at: p, fit: fit, viewport: viewport) == StageZoom())
    }

    @Test func strokeLandsOnTheSameArtworkPointAtAnyZoom() {
        // The same artwork point, touched at 1× and at 4× (after panning), records the same stroke point.
        let target = CGPoint(x: 0.3, y: 0.7)
        let zoomed = StageZoom(scale: 4, offset: CGSize(width: 120, height: -300)).clamped(fit: fit, viewport: viewport)
        let atFit = StageZoom().viewPoint(fromImage: target, fit: fit)
        let atZoom = zoomed.viewPoint(fromImage: target, fit: fit)
        #expect(close(StageZoom().imagePoint(fromView: atFit, fit: fit), target))
        #expect(close(zoomed.imagePoint(fromView: atZoom, fit: fit), target))
    }

    @Test func strokeWidthScalesWithZoom() {
        // Unchanged at 1× (size × 0.006 of the long edge), divided by the zoom otherwise.
        #expect(abs(StageZoom.strokeRadius(sliderSize: 3, scale: 1) - 0.018) < 1e-12)
        #expect(abs(StageZoom.strokeRadius(sliderSize: 3, scale: 3) - 0.006) < 1e-12)
        #expect(abs(StageZoom.strokeRadius(sliderSize: 10, scale: 0.5) - 0.06) < 1e-12)   // never below 1×
        // On screen the brush is the same size at every zoom.
        for scale in [1.0, 2.5, 6.0] as [CGFloat] {
            let z = StageZoom(scale: scale)
            let r = z.displayRect(fit: fit)
            let onScreen = CGFloat(StageZoom.strokeRadius(sliderSize: 4, scale: scale)) * max(r.width, r.height)
            #expect(abs(onScreen - StageZoom.screenRadius(sliderSize: 4, fit: fit)) < 1e-9)
        }
    }

    @Test func secondFingerDiscardsOnlyAYoungOrStillStroke() {
        #expect(StageTouchPolicy.discardsStroke(age: 0.05, travel: 40))     // pinch began within ~100 ms
        #expect(StageTouchPolicy.discardsStroke(age: 0.5, travel: 3))       // first finger held still
        #expect(!StageTouchPolicy.discardsStroke(age: 0.5, travel: 40))     // a real stroke is kept
        #expect(StageTouchPolicy.isTap(duration: 0.1, travel: 2))
        #expect(!StageTouchPolicy.isTap(duration: 0.1, travel: 30))
        #expect(!StageTouchPolicy.isTap(duration: 0.6, travel: 2))
    }
}
