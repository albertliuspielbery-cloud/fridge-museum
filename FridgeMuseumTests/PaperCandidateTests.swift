import CoreGraphics
import Foundation
import Testing
@testable import FridgeMuseum

/// 1.2.2: combining Vision's document / rectangle outlines with the prototype detector (pure scoring with synthetic
/// quads; Vision itself is only exercised where it may return nothing, like the AutoOrientation text tests).
struct PaperCandidateScoringTests {
    /// 4:3 photo, A4 landscape sheet: 0.5 × 0.47 of the frame (2/3 : 0.47 in real proportions ≈ √2).
    let aspect = 4.0 / 3.0
    let a4 = Quad(topLeft: .init(x: 0.25, y: 0.2), topRight: .init(x: 0.75, y: 0.2),
                  bottomRight: .init(x: 0.75, y: 0.67), bottomLeft: .init(x: 0.25, y: 0.67))

    func shifted(_ q: Quad, _ dx: Double, _ dy: Double) -> Quad {
        Quad(topLeft: .init(x: q.topLeft.x + dx, y: q.topLeft.y + dy), topRight: .init(x: q.topRight.x + dx, y: q.topRight.y + dy),
             bottomRight: .init(x: q.bottomRight.x + dx, y: q.bottomRight.y + dy),
             bottomLeft: .init(x: q.bottomLeft.x + dx, y: q.bottomLeft.y + dy))
    }

    @Test func aspectPrefersRealSheets() {
        #expect(abs(PaperCandidateScoring.sheetAspect(a4, imageAspect: aspect) - 2.0.squareRoot()) < 0.03)
        #expect(PaperCandidateScoring.aspectScore(2.0.squareRoot()) > 0.99)
        #expect(PaperCandidateScoring.aspectScore(1.294) > 0.99)          // Letter
        #expect(PaperCandidateScoring.aspectScore(1) > 0.99)              // origami square
        #expect(PaperCandidateScoring.aspectScore(1.8) < 0.65)
        #expect(PaperCandidateScoring.aspectScore(3) == 0.3)
    }

    @Test func shapeRejectsBadQuads() {
        let bowtie = Quad(topLeft: a4.topLeft, topRight: a4.bottomRight, bottomRight: a4.topRight, bottomLeft: a4.bottomLeft)
        #expect(PaperCandidateScoring.shapeScore(bowtie, imageAspect: aspect) == 0)
        #expect(PaperCandidateScoring.shapeScore(.inset(0.45), imageAspect: aspect) < 0.01)      // 1 % of the frame
        #expect(PaperCandidateScoring.shapeScore(.full, imageAspect: aspect) < 0.5)              // the whole frame
        #expect(PaperCandidateScoring.shapeScore(a4, imageAspect: aspect) > 0.95)
    }

    @Test func edgeGateIsMonotone() {
        #expect(PaperCandidateScoring.edgeGate(0) == 0.2)
        #expect(PaperCandidateScoring.edgeGate(-1) == 0.3)
        #expect(PaperCandidateScoring.edgeGate(7) == 1)
        #expect(PaperCandidateScoring.edgeGate(3) < PaperCandidateScoring.edgeGate(5))
    }

    /// The owner's case: Vision sees the sheet on white marble in dim light, but the edge under it is faint (4.5;
    /// 1.2.1 required ≥ 5 and fell back to the whole photo).
    @Test func confidentVisionOutlineWithFaintEdgeWins() throws {
        let doc = PaperCandidate(quad: a4, source: .document, confidence: 0.85, edgeSupport: 4.5)
        let pick = try #require(PaperCandidateScoring.pick([doc], imageAspect: aspect))
        #expect(pick.isConfident)
        #expect(pick.quad == a4)
        #expect(pick.source == .document)
    }

    /// A Vision outline on a featureless surface (no edge at all) is only a suggestion.
    @Test func visionOutlineWithoutAnyEdgeIsOnlyASuggestion() throws {
        let doc = PaperCandidate(quad: a4, source: .document, confidence: 0.9, edgeSupport: 0.5)
        let pick = try #require(PaperCandidateScoring.pick([doc], imageAspect: aspect))
        #expect(!pick.isConfident)
        #expect(pick.quad == a4)
    }

    @Test func detectorAloneKeepsItsOldAcceptance() throws {
        let det = PaperCandidate(quad: a4, source: .detector, confidence: 0.4, edgeSupport: 3, fit: 0.9)
        #expect(PaperCandidateScoring.pick([det], imageAspect: aspect)?.isConfident == true)
        let weak = PaperCandidate(quad: a4, source: .detector, confidence: 0.15, edgeSupport: 3, fit: 0.9)
        #expect(PaperCandidateScoring.pick([weak], imageAspect: aspect)?.isConfident != true)
    }

    /// Two weak, agreeing sources add up; the corners come from the one with the stronger edges (the snapped one).
    @Test func agreeingWeakCandidatesCombineAndTakeTheSharperCorners() throws {
        let nudged = shifted(a4, 0.012, -0.008)
        // alone: 0.24 and 0.13 (< 0.3); together 0.34
        let doc = PaperCandidate(quad: nudged, source: .document, confidence: 0.4, edgeSupport: 5)
        let det = PaperCandidate(quad: a4, source: .detector, confidence: 0.1, edgeSupport: 6.5, fit: 0.9)
        #expect(PaperCandidateScoring.pick([doc], imageAspect: aspect)?.isConfident != true)
        #expect(PaperCandidateScoring.pick([det], imageAspect: aspect)?.isConfident != true)
        let pick = try #require(PaperCandidateScoring.pick([doc, det], imageAspect: aspect))
        #expect(pick.isConfident)
        #expect(pick.quad == a4)
        #expect(pick.agreeing == [.document, .detector])
    }

    @Test func disagreeingCandidatesHighestScoreWins() throws {
        let plate = Quad(topLeft: .init(x: 0.05, y: 0.05), topRight: .init(x: 0.3, y: 0.05),
                         bottomRight: .init(x: 0.3, y: 0.38), bottomLeft: .init(x: 0.05, y: 0.38))
        let rect = PaperCandidate(quad: plate, source: .rectangles, confidence: 1, edgeSupport: 30)
        let doc = PaperCandidate(quad: a4, source: .document, confidence: 0.8, edgeSupport: 8)
        let pick = try #require(PaperCandidateScoring.pick([rect, doc], imageAspect: aspect))
        #expect(pick.quad == a4)
        #expect(pick.agreeing == [.document])
    }

    /// Rectangles alone need an edge clearly above marble-vein noise.
    @Test func rectangleAloneNeedsARealEdge() throws {
        let veins = PaperCandidate(quad: a4, source: .rectangles, confidence: 1, edgeSupport: 4.5)
        #expect(PaperCandidateScoring.pick([veins], imageAspect: aspect)?.isConfident != true)
        // a strong edge alone is still only a suggestion (a placemat, tray or book has one too)
        let sheet = PaperCandidate(quad: a4, source: .rectangles, confidence: 1, edgeSupport: 12)
        let alone = try #require(PaperCandidateScoring.pick([sheet], imageAspect: aspect))
        #expect(!alone.isConfident)
        // with an agreeing document it counts
        let doc = PaperCandidate(quad: a4, source: .document, confidence: 0.4, edgeSupport: 5)
        #expect(PaperCandidateScoring.pick([sheet, doc], imageAspect: aspect)?.isConfident == true)
    }

    /// 1.2.1 passed a Vision document at 0.5 confidence with edge contrast 5; so does 1.2.2.
    @Test func documentAtOldThresholdStillPasses() throws {
        let doc = PaperCandidate(quad: a4, source: .document, confidence: 0.5, edgeSupport: 5)
        #expect(PaperCandidateScoring.pick([doc], imageAspect: aspect)?.isConfident == true)
    }

    /// Paper filling the frame (or a white table caught whole): not a confident crop unless all four edges are clear
    /// (tight framing with a real edge, which 1.2.1 cropped too).
    @Test func nearlyFullFrameNeedsClearEdges() {
        let detectorGuess = PaperCandidate(quad: .inset(0.003), source: .detector, confidence: 0.3, edgeSupport: -1, fit: 0.97)
        let weakDocument = PaperCandidate(quad: .inset(0.01), source: .document, confidence: 1, edgeSupport: 5)
        let threeSides = PaperCandidate(quad: .inset(0.01), source: .document, confidence: 1, edgeSupport: 10, edgeSides: 3)
        let clearDocument = PaperCandidate(quad: .inset(0.01), source: .document, confidence: 1, edgeSupport: 10)
        #expect(PaperCandidateScoring.pick([detectorGuess], imageAspect: aspect)?.isConfident != true)
        #expect(PaperCandidateScoring.pick([weakDocument], imageAspect: aspect)?.isConfident != true)
        #expect(PaperCandidateScoring.pick([threeSides], imageAspect: aspect)?.isConfident != true)
        #expect(PaperCandidateScoring.pick([detectorGuess, weakDocument], imageAspect: aspect)?.isConfident != true)
        #expect(PaperCandidateScoring.pick([clearDocument], imageAspect: aspect)?.isConfident == true)
    }

    /// A big rectangle (placemat / tray) around a medium detector outline: the sheet wins.
    @Test func innerSheetBeatsOuterRectangle() throws {
        let mat = PaperCandidate(quad: .inset(0.1), source: .rectangles, confidence: 1, edgeSupport: 30)
        let det = PaperCandidate(quad: a4, source: .detector, confidence: 0.5, edgeSupport: 8, fit: 0.9)
        let pick = try #require(PaperCandidateScoring.pick([mat, det], imageAspect: aspect))
        #expect(pick.quad == a4 && pick.isConfident)
    }

    /// A tray that Vision calls a document (moderate edge), with the detector's sheet inside it: the inner sheet wins.
    /// With a clear document edge (≥ 8) the document is trusted, as in 1.2.1.
    @Test func innerSheetVersusOuterDocument() throws {
        let tray = PaperCandidate(quad: .inset(0.08), source: .document, confidence: 0.9, edgeSupport: 6)
        let det = PaperCandidate(quad: a4, source: .detector, confidence: 0.45, edgeSupport: 8, fit: 0.9)
        let pick = try #require(PaperCandidateScoring.pick([tray, det], imageAspect: aspect))
        #expect(pick.quad == a4 && pick.isConfident)
        let clearTray = PaperCandidate(quad: .inset(0.08), source: .document, confidence: 0.9, edgeSupport: 30)
        let kept = try #require(PaperCandidateScoring.pick([clearTray, det], imageAspect: aspect))
        #expect(kept.quad == .inset(0.08))
        #expect(PaperCandidateScoring.contains(.inset(0.08), a4))
        #expect(!PaperCandidateScoring.contains(a4, .inset(0.08)))
    }

    /// A confident document (the 1.2.1 0.5 / edge-5 case) is not traded for a weak guess inside it.
    @Test func confidentOuterIsNotTradedForAWeakInnerGuess() throws {
        let doc = PaperCandidate(quad: a4, source: .document, confidence: 0.5, edgeSupport: 5)
        let inner = Quad(topLeft: .init(x: 0.35, y: 0.3), topRight: .init(x: 0.65, y: 0.3),
                         bottomRight: .init(x: 0.65, y: 0.57), bottomLeft: .init(x: 0.35, y: 0.57))
        let guess = PaperCandidate(quad: inner, source: .detector, confidence: 0.3, edgeSupport: 3, fit: 0.8)
        let pick = try #require(PaperCandidateScoring.pick([doc, guess], imageAspect: aspect))
        #expect(pick.quad == a4)
        #expect(pick.isConfident)
    }

    /// A detector guess with no evidence of its own agreeing with a lone rectangle doesn't lift the rectangle cap.
    @Test func zeroEvidenceAgreementDoesNotCount() {
        let mat = PaperCandidate(quad: a4, source: .rectangles, confidence: 1, edgeSupport: 12)
        let guess = PaperCandidate(quad: a4, source: .detector, confidence: 0.15, edgeSupport: 3, fit: 0.9)
        #expect(PaperCandidateScoring.pick([mat, guess], imageAspect: aspect)?.isConfident != true)
    }

    // MARK: Drawn frame vs tray (ring check on a synthetic image)

    /// Brown table, white sheet (60…300 × 40…230 of 360 × 270) with a black frame drawn 25 px inside its edge and a
    /// blue scribble inside the frame.
    func sheetWithDrawnFrame() -> RGBA8Image {
        var img = RGBA8Image(width: 360, height: 270, fill: (120, 85, 55))
        for y in 40..<230 { for x in 60..<300 { img.set(x, y, (245, 243, 238)) } }
        for y in 64..<206 {
            for x in 84..<276 where x < 86 || x >= 274 || y < 66 || y >= 204 { img.set(x, y, (20, 20, 20)) }
        }
        for y in 120..<130 { for x in 130..<230 { img.set(x, y, (40, 80, 200)) } }
        return img
    }

    /// Dark tray (40…320 × 25…245) with a white sheet (100…260 × 70…200) on it.
    func sheetOnTray() -> RGBA8Image {
        var img = RGBA8Image(width: 360, height: 270, fill: (190, 185, 175))
        for y in 25..<245 { for x in 40..<320 { img.set(x, y, (80, 70, 60)) } }
        for y in 70..<200 { for x in 100..<260 { img.set(x, y, (245, 243, 238)) } }
        return img
    }

    func px(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Quad {
        Quad(topLeft: .init(x: x0 / 360, y: y0 / 270), topRight: .init(x: x1 / 360, y: y0 / 270),
             bottomRight: .init(x: x1 / 360, y: y1 / 270), bottomLeft: .init(x: x0 / 360, y: y1 / 270))
    }

    @Test func ringCheckTellsDrawnFrameFromTray() {
        let drawn = sheetWithDrawnFrame()
        #expect(PaperDetector.ringLooksLikePaper(outer: px(60, 40, 300, 230), inner: px(85, 65, 275, 205), in: drawn))
        let tray = sheetOnTray()
        #expect(!PaperDetector.ringLooksLikePaper(outer: px(40, 25, 320, 245), inner: px(100, 70, 260, 200), in: tray))
    }

    /// The detector traces the drawn frame; the document has the sheet: the sheet stays.
    @Test func drawnFrameDoesNotBeatTheSheet() throws {
        let img = sheetWithDrawnFrame()
        let imageAspect = 360.0 / 270.0
        let sheet = px(60, 40, 300, 230), frame = px(85, 65, 275, 205)
        let doc = PaperCandidate(quad: sheet, source: .document, confidence: 0.9, edgeSupport: 7.5)
        let det = PaperCandidate(quad: frame, source: .detector, confidence: 0.45, edgeSupport: 40, fit: 0.9)
        let picked = PaperCandidateScoring.pick([doc, det], imageAspect: imageAspect, ringLooksLikePaper: { outer, inner in
            PaperDetector.ringLooksLikePaper(outer: outer, inner: inner, in: img)
        })
        let pick = try #require(picked)
        #expect(pick.quad == sheet)
        // without the ring check the inner frame would have won
        #expect(PaperCandidateScoring.pick([doc, det], imageAspect: imageAspect)?.quad == frame)
    }

    @Test func agreementUsesTheLongEdge() {
        #expect(PaperCandidateScoring.agree(a4, shifted(a4, 0.03, 0), imageAspect: aspect))
        #expect(!PaperCandidateScoring.agree(a4, shifted(a4, 0.06, 0), imageAspect: aspect))
        // portrait photo: y spans the long edge
        #expect(PaperCandidateScoring.agree(a4, shifted(a4, 0, 0.03), imageAspect: 0.75))
        #expect(!PaperCandidateScoring.agree(a4, shifted(a4, 0, 0.06), imageAspect: 0.75))
    }

    @Test func nothingUsableGivesNil() {
        #expect(PaperCandidateScoring.pick([], imageAspect: aspect) == nil)
        let tiny = PaperCandidate(quad: .inset(0.47), source: .document, confidence: 1, edgeSupport: 30)
        #expect(PaperCandidateScoring.pick([tiny], imageAspect: aspect) == nil)
    }

    @Test func cropStartsAtSuggestionElseInset() {
        #expect(PaperCandidateScoring.startingCorners(suggestion: nil) == .inset(0.12))
        #expect(PaperCandidateScoring.startingCorners(suggestion: a4) == a4)
        #expect(PaperCandidateScoring.startingCorners(suggestion: .inset(0.4)) == .inset(0.12))   // too small
        #expect(PaperCandidateScoring.startingCorners(suggestion: .full) == .inset(0.12))         // the whole photo
    }

    // MARK: Measured on a synthetic white-on-white image (no Vision)

    /// Light warm "marble" with thin grey veins, a sheet only 3 levels brighter and without veins (dim, no shadow).
    func marbleWithSheet() -> RGBA8Image {
        var img = RGBA8Image(width: 360, height: 270, fill: (205, 200, 192))
        for y in 0..<270 {
            for x in 0..<360 {
                let onSheet = x >= 90 && x < 270 && y >= 72 && y < 199
                if onSheet {
                    img.set(x, y, (208, 203, 195))
                } else if (x + Int(Double(y) * 0.6)) % 37 < 3 {
                    img.set(x, y, (183, 179, 174))
                }
            }
        }
        return img
    }

    @Test func faintSheetEdgeBeatsMarbleVeins() throws {
        let img = marbleWithSheet()
        let planes = PaperDetector.Planes(img)
        let truth = Quad(topLeft: .init(x: 90.0 / 360, y: 72.0 / 270), topRight: .init(x: 270.0 / 360, y: 72.0 / 270),
                         bottomRight: .init(x: 270.0 / 360, y: 199.0 / 270), bottomLeft: .init(x: 90.0 / 360, y: 199.0 / 270))
        let onSheet = PaperDetector.edgeContrast(truth, planes: planes)
        let c = SIMD2(0.5, 135.5 / 270)
        let grown = Quad(topLeft: .init(x: c.x + (truth.topLeft.x - c.x) * 1.12, y: c.y + (truth.topLeft.y - c.y) * 1.12),
                         topRight: .init(x: c.x + (truth.topRight.x - c.x) * 1.12, y: c.y + (truth.topRight.y - c.y) * 1.12),
                         bottomRight: .init(x: c.x + (truth.bottomRight.x - c.x) * 1.12, y: c.y + (truth.bottomRight.y - c.y) * 1.12),
                         bottomLeft: .init(x: c.x + (truth.bottomLeft.x - c.x) * 1.12, y: c.y + (truth.bottomLeft.y - c.y) * 1.12))
        let onMarble = PaperDetector.edgeContrast(grown, planes: planes)
        #expect(onSheet > 4, "sheet edge \(onSheet)")
        #expect(onMarble < onSheet / 2, "marble \(onMarble) vs sheet \(onSheet)")

        let imageAspect = 360.0 / 270.0
        let right = PaperCandidate(quad: truth, source: .document, confidence: 0.7, edgeSupport: onSheet)
        let wrong = PaperCandidate(quad: grown, source: .document, confidence: 0.7, edgeSupport: onMarble)
        #expect(PaperCandidateScoring.pick([right], imageAspect: imageAspect)?.isConfident == true)
        #expect(PaperCandidateScoring.pick([wrong], imageAspect: imageAspect)?.isConfident != true)
        // refine keeps (or snaps back to) the true outline
        // a sheet running off a frame corner: 2 sides measured (still known); only 1 side: unknown
        let corner = Quad(topLeft: .init(x: 0, y: 0), topRight: .init(x: 0.5, y: 0),
                          bottomRight: .init(x: 0.5, y: 0.5), bottomLeft: .init(x: 0, y: 0.5))
        let cornerEdge = PaperDetector.edgeMeasure(corner, planes: planes)
        #expect(cornerEdge.sides == 2 && cornerEdge.contrast >= 0)
        let half = Quad(topLeft: .init(x: 0, y: 0), topRight: .init(x: 0.5, y: 0),
                        bottomRight: .init(x: 0.5, y: 1), bottomLeft: .init(x: 0, y: 1))
        #expect(PaperDetector.edgeContrast(half, planes: planes) == -1)
        let refined = PaperDetector.refine(truth, planes: planes)
        #expect(PaperCandidateScoring.agree(refined.quad, truth, imageAspect: imageAspect, tolerance: 0.015))
    }

    /// A guess rejected for a (nearly) whole-frame mask never becomes a candidate, even though the 0.994 shrink can
    /// bring its outline just under 95 %.
    @Test func wholeFrameGuessOffersNoCandidate() {
        let white = PaperDetector.detectFull(RGBA8Image(width: 240, height: 180, fill: (246, 244, 240)))
        #expect(white.isGuess)
        #expect(!white.offersCandidate)
        let shrunk = PaperDetector.Result(quad: .full, isGuess: true, score: 0.7, candidate: .inset(0.0013), fit: 0.99,
                                          areaFraction: 0.955)
        #expect(!shrunk.offersCandidate)
    }

    @Test func detectorExposesItsBestOutline() {
        var img = RGBA8Image(width: 240, height: 180, fill: (120, 80, 50))
        for y in 40..<140 { for x in 50..<190 { img.set(x, y, (240, 238, 232)) } }
        let r = PaperDetector.detectFull(img)
        #expect(!r.isGuess)
        #expect(r.candidate == r.quad)
        #expect(r.fit > 0.8)
        let empty = PaperDetector.detectFull(RGBA8Image(width: 200, height: 150, fill: (120, 80, 50)))
        #expect(empty.isGuess && empty.quad == .full)
    }
}

struct LivePaperPickerTests {
    let aspect = 4.0 / 3.0
    let sheet = Quad(topLeft: .init(x: 0.25, y: 0.2), topRight: .init(x: 0.75, y: 0.2),
                     bottomRight: .init(x: 0.75, y: 0.67), bottomLeft: .init(x: 0.25, y: 0.67))
    var nudged: Quad {
        Quad(topLeft: .init(x: 0.26, y: 0.21), topRight: .init(x: 0.76, y: 0.2),
             bottomRight: .init(x: 0.75, y: 0.68), bottomLeft: .init(x: 0.25, y: 0.66))
    }

    @Test func confidentDocumentAlone() {
        #expect(LivePaperPicker.pick(document: (sheet, 0.7), rectangles: [], previousRectangle: nil, imageAspect: aspect) == sheet)
    }

    @Test func weakDocumentNeedsAnAgreeingRectangle() {
        #expect(LivePaperPicker.pick(document: (nudged, 0.4), rectangles: [], previousRectangle: nil, imageAspect: aspect) == nil)
        #expect(LivePaperPicker.pick(document: (nudged, 0.4), rectangles: [(sheet, 0.6)], previousRectangle: nil,
                                     imageAspect: aspect) == sheet)
    }

    @Test func rectangleAloneMustRepeat() {
        #expect(LivePaperPicker.pick(document: nil, rectangles: [(sheet, 0.9)], previousRectangle: nil, imageAspect: aspect) == nil)
        #expect(LivePaperPicker.pick(document: nil, rectangles: [(sheet, 0.9)], previousRectangle: nudged,
                                     imageAspect: aspect) == sheet)
        #expect(LivePaperPicker.pick(document: nil, rectangles: [(sheet, 0.5)], previousRectangle: nudged,
                                     imageAspect: aspect) == nil)       // not confident enough alone
    }

    @Test func stripsAreNotSheets() {
        let strip = Quad(topLeft: .init(x: 0.05, y: 0.4), topRight: .init(x: 0.95, y: 0.4),
                         bottomRight: .init(x: 0.95, y: 0.62), bottomLeft: .init(x: 0.05, y: 0.62))
        #expect(LivePaperPicker.pick(document: nil, rectangles: [(strip, 1)], previousRectangle: strip, imageAspect: aspect) == nil)
    }

    @Test func rectanglesOnlyWhenUnsureAndThrottled() {
        #expect(!LivePaperPicker.wantsRectangles(documentConfidence: 0.7, now: 10, lastRectangles: 0))
        #expect(LivePaperPicker.wantsRectangles(documentConfidence: nil, now: 10, lastRectangles: 0))
        #expect(LivePaperPicker.wantsRectangles(documentConfidence: 0.4, now: 10, lastRectangles: 9.6))
        #expect(!LivePaperPicker.wantsRectangles(documentConfidence: nil, now: 10, lastRectangles: 9.8))
    }
}

struct LowLightTests {
    @Test func brightnessFromExifOrExposure() throws {
        #expect(LowLightClassifier.brightness(LowLightSample(brightnessValue: 2.5)) == 2.5)
        // ISO 1000, 1/30 s: a dim restaurant
        let est = try #require(LowLightClassifier.brightness(LowLightSample(iso: 1000, exposureSeconds: 1.0 / 30)))
        #expect(est < -1.5 && est > -2.5)
        // ISO 100, 1/60 s: a bright room
        #expect((LowLightClassifier.brightness(LowLightSample(iso: 100, exposureSeconds: 1.0 / 60)) ?? -99) > 1.5)
        #expect(LowLightClassifier.brightness(LowLightSample()) == nil)
    }

    @Test func verdicts() {
        #expect(LowLightClassifier.verdict(LowLightSample(brightnessValue: -1)) == true)
        #expect(LowLightClassifier.verdict(LowLightSample(brightnessValue: 3)) == false)
        #expect(LowLightClassifier.verdict(LowLightSample(brightnessValue: 0.5)) == nil)      // in between: keep
        #expect(LowLightClassifier.verdict(LowLightSample(brightnessValue: 3, meanLuma: 30)) == true)
        #expect(LowLightClassifier.verdict(LowLightSample(brightnessValue: 3, isoRatio: 0.9)) == true)
        #expect(LowLightClassifier.verdict(LowLightSample()) == nil)
    }

    @Test func holdsBeforeFlippingWithHysteresis() {
        var c = LowLightClassifier()
        let dark = LowLightSample(brightnessValue: -1), mid = LowLightSample(brightnessValue: 0.5)
        let bright = LowLightSample(brightnessValue: 2)
        let r1 = c.update(dark, now: 0)
        #expect(!r1)
        let r2 = c.update(dark, now: 0.5)
        #expect(!r2)
        let r3 = c.update(dark, now: 1.1)
        #expect(r3)          // held ≥ 1 s
        let r4 = c.update(mid, now: 2)
        #expect(r4)             // in between: stays dim
        let r5 = c.update(bright, now: 3)
        #expect(r5)
        let r6 = c.update(bright, now: 4)
        #expect(r6)          // 1.0 s < 1.5 s
        let r7 = c.update(bright, now: 4.6)
        #expect(!r7)
        // a single dark frame doesn't flip it back
        let r8 = c.update(dark, now: 5)
        #expect(!r8)
        let r9 = c.update(bright, now: 5.2)
        #expect(!r9)
        let r10 = c.update(dark, now: 6.0)
        #expect(!r10)
        c.reset()
        #expect(!c.isDim)
    }
}

struct TorchStateTests {
    @Test func userTogglesAndDeviceRefusal() {
        var t = TorchState()
        let r11 = t.toggle(available: true, now: 0)
        #expect(r11)
        t.applied(false, now: 0.1)                 // overheated: the device said no
        #expect(!t.wanted)
        let r12 = t.toggle(available: true, now: 1)
        #expect(r12)
        let r13 = t.toggle(available: true, now: 2)
        #expect(!r13)
        let r14 = t.toggle(available: false, now: 3)
        #expect(!r14)
    }

    @Test func systemTurningItOffIsAcceptedAfterSettling() {
        var t = TorchState()
        _ = t.toggle(available: true, now: 0)
        t.applied(true, now: 0.05)
        let r15 = t.deviceReported(active: false, available: true, now: 0.5)
        #expect(!r15)   // hardware lag right after the change
        #expect(t.wanted)
        let r16 = t.deviceReported(active: true, available: true, now: 2)
        #expect(!r16)
        let r17 = t.deviceReported(active: true, available: false, now: 3)
        #expect(r17)      // thermal: torch unavailable
        #expect(!t.wanted)
        let r18 = t.deviceReported(active: false, available: false, now: 5)
        #expect(!r18)    // already off: nothing to do
    }

    @Test func leavingTurnsItOff() {
        var t = TorchState()
        let r19 = t.leave(now: 0)
        #expect(!r19)
        _ = t.toggle(available: true, now: 1)
        let r20 = t.leave(now: 2)
        #expect(r20)
        #expect(!t.wanted)
    }
}

/// Vision on a synthetic photo: runs where Vision works; returns early where it gives nothing (some Simulators).
struct PaperVisionSmokeTests {
    @Test func visionCandidatesFindAPlainSheet() throws {
        let w = 1200, h = 900
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.42, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 300, y: 238, width: 600, height: 424))
        let image = try #require(ctx.makeImage())
        let found = VisionPaths.paperCandidates(cgImage: image)
        guard !found.isEmpty else { return }
        let truth = Quad(topLeft: .init(x: 0.25, y: 238.0 / 900), topRight: .init(x: 0.75, y: 238.0 / 900),
                         bottomRight: .init(x: 0.75, y: 662.0 / 900), bottomLeft: .init(x: 0.25, y: 662.0 / 900))
        let best = found.map { PaperCandidateScoring.cornerDistance($0.quad, truth, imageAspect: 4.0 / 3.0) }.min() ?? 1
        #expect(best < 0.05, "\(found)")
        #expect(found.allSatisfy { $0.confidence >= 0.3 && $0.confidence <= 1 })
    }

    /// An all-white frame (a sheet filling the photo): the whole photo, marked as not found, as in 1.2.1.
    @Test func allWhiteFrameIsAGuess() async throws {
        let ctx = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let image = try #require(ctx.makeImage())
        let data = try #require(ImageEncoding.jpegData(image, quality: 0.9))
        let det = await ImageProcessor().detectPaper(id: UUID(), originalData: data)
        #expect(det.isGuess)
        #expect(det.quad == .full)
    }
}
