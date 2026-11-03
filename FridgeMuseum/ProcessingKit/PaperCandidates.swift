import Foundation

/// 1.2.2: several detectors propose a paper outline; one scoring decides.
///
/// Sources: Vision document segmentation (an ML document detector), Vision rectangle detection (tuned for sheets),
/// and the ported prototype detector (`PaperDetector`). Each candidate is scored the same way — shape (area,
/// convexity, how close the perspective-corrected aspect is to a real sheet) × evidence (the detector's own
/// confidence, gated by how much the colour changes across the quad's sides, measured on the same small image for
/// every candidate). When two different sources agree, their evidence adds up and the corners come from the one with
/// the stronger edges (the edge-snapped one). Everything here is pure, so it is unit-tested with synthetic quads;
/// Vision itself may return nothing in the Simulator.
///
/// Why: white paper on a white marble table in dim warm light has almost no brightness / colour contrast, so the
/// prototype detector (brightness − saturation masks) finds nothing, and the old rule "Vision's outline needs an edge
/// contrast ≥ 5 under it" threw away correct Vision outlines (marble alone measures ≈ 2.5–4.5, a shadowless sheet
/// edge ≈ 5–9, a sheet with a thin shadow ≈ 20–40; measured on a real dim marble photo with a pasted sheet).
struct PaperCandidate: Sendable, Equatable {
    enum Source: String, Sendable {
        /// VNDetectDocumentSegmentationRequest
        case document
        /// VNDetectRectanglesRequest
        case rectangles
        /// PaperDetector (the prototype port)
        case detector
    }

    /// Normalized, top-left origin, TL → TR → BR → BL.
    var quad: Quad
    var source: Source
    /// Vision observation confidence (0…1), or the detector's own score (0…1).
    var confidence: Double
    /// Robust colour change across the sides (`PaperDetector.edgeContrast`): < 0 = unknown (all sides on the frame).
    var edgeSupport: Double = -1
    /// Detector only: how well its mask fills the quad (0…1).
    var fit: Double = 0
}

enum PaperCandidateScoring {
    /// At or above: trust it (crop to it). Tuned so the detector alone keeps its old acceptance (score 0.4) and a
    /// Vision document at its old 0.5 confidence with a real edge (≥ 5) still passes.
    static let confidentScore = 0.3
    /// At or above (but not confident): offered as the crop tool's starting corners, not used for the render.
    static let suggestionScore = 0.1
    /// Two quads "agree" when no corner is further apart than this (fraction of the image's long edge).
    static let agreeTolerance = 0.04

    struct Pick: Sendable, Equatable {
        var quad: Quad
        var source: PaperCandidate.Source
        var score: Double
        var isConfident: Bool
        /// Sources that agreed with the winner (the winner's included).
        var agreeing: Set<PaperCandidate.Source>
    }

    // MARK: Shape

    /// Real sheet aspect (long / short ≥ 1) of a quad, corrected for perspective (PaperAspect, no snapping).
    static func sheetAspect(_ q: Quad, imageAspect: Double) -> Double {
        let w = max(imageAspect, 1e-6), h = 1.0
        let px = q.points.map { NormPoint(x: $0.x * w, y: $0.y * h) }
        let r = PaperAspect.estimate(px, imageWidth: w, imageHeight: h, snap: false)
        return r >= 1 ? r : 1 / r
    }

    /// 1 near a known sheet (A4, Letter, 4:3, square, 八開, 四開), down to 0.6 for an odd one, 0.3 for a strip.
    static func aspectScore(_ r: Double) -> Double {
        guard r.isFinite, r > 0 else { return 0.3 }
        let lr = r >= 1 ? r : 1 / r
        if lr > 2.3 { return 0.3 }
        let d = PaperAspect.sheetRatios.map { abs(log(lr / $0)) }.min() ?? 1
        return 0.6 + 0.4 * exp(-(d / 0.08) * (d / 0.08))
    }

    /// Area fraction: too small is a label or a phone, almost the whole frame is probably not an outline at all.
    static func areaScore(_ area: Double) -> Double {
        let s = smoothStep(0.04, 0.12, area)
        return area > 0.95 ? s * 0.4 : s
    }

    static func shapeScore(_ q: Quad, imageAspect: Double) -> Double {
        guard q.isConvex else { return 0 }
        return areaScore(q.area) * aspectScore(sheetAspect(q, imageAspect: imageAspect))
    }

    // MARK: Evidence

    /// How much an edge under the outline is believed: 0.2 on a featureless surface, 1 from contrast 7 up
    /// (marble veins alone ≈ 2.5–4.5). Unknown (all sides on the frame edge) → 0.3.
    static func edgeGate(_ contrast: Double) -> Double {
        guard contrast >= 0 else { return 0.3 }
        return 0.2 + 0.8 * smoothStep(2, 7, contrast)
    }

    /// Rectangles: 0.1 below contrast 4, 1 from 10 up (a shadowless sheet edge ≈ 7 → ≈ 0.5).
    static func strictEdgeGate(_ contrast: Double) -> Double {
        guard contrast >= 0 else { return 0.1 }
        return 0.1 + 0.9 * smoothStep(4, 10, contrast)
    }

    static func evidence(_ c: PaperCandidate) -> Double {
        switch c.source {
        case .document:
            return ((c.confidence - 0.3) / 0.5).clamped(0, 1) * edgeGate(c.edgeSupport)
        case .rectangles:
            // The rectangle detector is easily pleased (a placemat, a table edge, a run of marble veins) and reports
            // high confidence for almost anything it returns: less weight, and it needs an edge clearly above the
            // marble noise (≈ 4.5 at the 90th percentile) to count on its own.
            return 0.8 * ((c.confidence - 0.4) / 0.5).clamped(0, 1) * strictEdgeGate(c.edgeSupport)
        case .detector:
            // Its own score already includes edges and mask fit (0.4 = its old acceptance → 0.5). A clean mask with an
            // edge above the marble noise also counts, even when its own (stricter) edge term killed the score.
            let own = ((c.confidence - 0.2) / 0.4).clamped(0, 1)
            let soft = c.edgeSupport >= 0 ? 0.8 * c.fit * smoothStep(4.5, 12, c.edgeSupport) : 0
            return max(own, soft)
        }
    }

    static func score(_ c: PaperCandidate, imageAspect: Double) -> Double {
        shapeScore(c.quad, imageAspect: imageAspect) * evidence(c)
    }

    // MARK: Agreement / pick

    /// Largest corner distance in units of the image's long edge.
    static func cornerDistance(_ a: Quad, _ b: Quad, imageAspect: Double) -> Double {
        let sx = imageAspect >= 1 ? 1 : imageAspect, sy = imageAspect >= 1 ? 1 / imageAspect : 1
        return zip(a.points, b.points).map { p, q in
            let dx = (p.x - q.x) * sx, dy = (p.y - q.y) * sy
            return (dx * dx + dy * dy).squareRoot()
        }.max() ?? 1
    }

    static func agree(_ a: Quad, _ b: Quad, imageAspect: Double, tolerance: Double = agreeTolerance) -> Bool {
        cornerDistance(a, b, imageAspect: imageAspect) <= tolerance
    }

    /// The best outline, or nil when no candidate reaches `suggestionScore`.
    /// Each candidate's evidence is combined (noisy-or) with that of candidates from *other* sources that agree with
    /// it; the corners of an agreeing group come from its member with the strongest edge support (refined /
    /// edge-snapped corners are the precise ones), the winner's own corners when edges tie.
    static func pick(_ candidates: [PaperCandidate], imageAspect: Double) -> Pick? {
        let usable = candidates.filter { $0.quad.isConvex }
        guard !usable.isEmpty else { return nil }
        var best: Pick?
        for (i, c) in usable.enumerated() {
            let shape = shapeScore(c.quad, imageAspect: imageAspect)
            guard shape > 0 else { continue }
            var miss = 1 - evidence(c)
            var agreeing: Set<PaperCandidate.Source> = [c.source]
            var cornerSource = c
            for (j, o) in usable.enumerated() where j != i && o.source != c.source && !agreeing.contains(o.source) {
                guard agree(c.quad, o.quad, imageAspect: imageAspect) else { continue }
                miss *= 1 - evidence(o)
                agreeing.insert(o.source)
                if o.edgeSupport > cornerSource.edgeSupport + 0.5 { cornerSource = o }
            }
            let s = shape * (1 - miss)
            if best == nil || s > best!.score + 1e-9 {
                best = Pick(quad: cornerSource.quad, source: c.source, score: s,
                            isConfident: s >= confidentScore, agreeing: agreeing)
            }
        }
        guard let b = best, b.score >= suggestionScore else { return nil }
        return b
    }

    /// Where the crop tool's corners start when no paper was found: the best weak outline, else an inset frame
    /// (so all four handles are away from the screen edges and easy to grab).
    static func startingCorners(suggestion: Quad?) -> Quad {
        if let s = suggestion, s.isConvex, s.area >= 0.08, s.area <= 0.92 { return s }
        return .inset(0.12)
    }
}

/// Live camera overlay (1.2.2): Vision document segmentation every analysed frame, the rectangle detector only when
/// the document detector is unsure, and at most ~3×/s (heat). Pure decision, unit-tested.
enum LivePaperPicker {
    /// Document outline accepted alone (unchanged from 1.2.1).
    static let documentAlone = 0.6
    /// Weak document outline accepted when a rectangle agrees with it.
    static let documentWithRectangle = 0.3
    /// A rectangle alone needs this confidence, a sheet-like shape, and to have been seen in the previous rectangle
    /// pass too (marble veins and glare flicker; a sheet stays put).
    static let rectangleAlone = 0.75
    /// Seconds between rectangle passes.
    static let rectangleInterval = 0.3

    /// Should the (more expensive) rectangle pass run on this frame?
    static func wantsRectangles(documentConfidence: Double?, now: Double, lastRectangles: Double) -> Bool {
        guard now - lastRectangles >= rectangleInterval else { return false }
        return (documentConfidence ?? 0) < documentAlone
    }

    /// `imageAspect`: width / height of the analysed buffer. Returns the outline to show, or nil.
    static func pick(document: (quad: Quad, confidence: Double)?, rectangles: [(quad: Quad, confidence: Double)],
                     previousRectangle: Quad?, imageAspect: Double) -> Quad? {
        if let d = document, d.confidence >= documentAlone, d.quad.isPlausible { return d.quad }
        let sheets = rectangles.filter {
            $0.quad.isPlausible && PaperCandidateScoring.aspectScore(
                PaperCandidateScoring.sheetAspect($0.quad, imageAspect: imageAspect)) >= 0.75
        }
        if let d = document, d.confidence >= documentWithRectangle, d.quad.isPlausible,
           let r = sheets.first(where: { PaperCandidateScoring.agree($0.quad, d.quad, imageAspect: imageAspect, tolerance: 0.06) }) {
            return r.quad     // the rectangle hugs the edges; the document mask outline is coarser
        }
        if let prev = previousRectangle,
           let r = sheets.filter({ $0.confidence >= rectangleAlone })
               .first(where: { PaperCandidateScoring.agree($0.quad, prev, imageAspect: imageAspect, tolerance: 0.05) }) {
            return r.quad
        }
        return nil
    }
}
