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
    /// Robust colour change across the sides (`PaperDetector.edgeMeasure`): < 0 = unknown (< 2 sides measurable).
    var edgeSupport: Double = -1
    /// Detector only: how well its mask fills the quad (0…1).
    var fit: Double = 0
    /// How many sides `edgeSupport` was measured on (sides on the frame edge are skipped).
    var edgeSides: Int = 4
}

enum PaperCandidateScoring {
    /// At or above: trust it (crop to it). Tuned so the detector alone keeps its old acceptance (score 0.4) and a
    /// Vision document at its old 0.5 confidence with a real edge (≥ 5) still passes (tested).
    static let confidentScore = 0.3
    /// An outline covering more than this much of the frame is at most a suggestion (1.2.1: af > 0.96 → whole photo;
    /// a sheet filling the photo must not be cropped, nor shadow removal / edge fill turned on for it).
    static let nearlyFullArea = 0.95
    static let nearlyFullCap = 0.2
    /// A rectangle that no other source agrees with is at most a suggestion: on a placemat, tray, board or book it
    /// would crop to the outer object.
    static let rectangleAloneCap = 0.25
    /// An inner paper-like outline (detector / document) fully inside the winner is preferred when it scores at
    /// least this fraction of the winner (the sheet on a tray, not the tray).
    static let innerPreference = 0.6
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
        /// Strongest edge support in the winning group (-1 unknown).
        var edgeSupport: Double = -1
        /// The winning group has a Vision document of the kind 1.2.1 considered (confidence ≥ 0.5, area ≥ 0.12).
        var hasStrongDocument = false
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

    /// Area fraction: too small is a label or a phone; (nearly) the whole frame is capped at suggestion level.
    static func areaScore(_ area: Double) -> Double {
        area > nearlyFullArea ? nearlyFullCap : smoothStep(0.04, 0.12, area)
    }

    static func shapeScore(_ q: Quad, imageAspect: Double) -> Double {
        guard q.isConvex else { return 0 }
        return areaScore(q.area) * aspectScore(sheetAspect(q, imageAspect: imageAspect))
    }

    /// An edge strong enough on all four sides to trust even a nearly-full outline (tight framing, 1.2.1 cropped it).
    static let clearEdge = 8.0

    /// Shape of a candidate. The nearly-full cap applies to detector guesses and to outlines whose edge is unknown,
    /// weak (< 8) or not measured on all four sides. The detector's own score already contains its area term, so
    /// for it no other area term applies here (its soft evidence term applies the area itself).
    static func shapeScore(_ c: PaperCandidate, imageAspect: Double) -> Double {
        guard c.quad.isConvex else { return 0 }
        let aspect = aspectScore(sheetAspect(c.quad, imageAspect: imageAspect))
        let nearlyFull = c.quad.area > nearlyFullArea
        if c.source == .detector {
            return (nearlyFull && c.confidence < 0.4 ? nearlyFullCap : 1) * aspect
        }
        guard nearlyFull else { return areaScore(c.quad.area) * aspect }
        let clear = c.edgeSides == 4 && c.edgeSupport >= clearEdge
        return (clear ? 1 : nearlyFullCap) * aspect
    }

    // MARK: Evidence

    /// How much an edge under the outline is believed: 0.2 on a featureless surface, 1 from contrast 7 up
    /// (marble veins alone ≈ 2.5–4.5). Unknown (fewer than 2 sides measurable) → 0.3.
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
            // 0.5 confidence → 0.56; × the gate at edge 5 (0.72) → 0.4: passes, as in 1.2.1.
            return ((c.confidence - 0.25) / 0.45).clamped(0, 1) * edgeGate(c.edgeSupport)
        case .rectangles:
            // The rectangle detector is easily pleased (a placemat, a table edge, a run of marble veins) and reports
            // high confidence for almost anything it returns: less weight, and it needs an edge clearly above the
            // marble noise (≈ 4.5 at the 90th percentile), measured on at least 3 sides (with 2 sides on the frame edge
            // only the strong inner table edge would be measured).
            let edge = c.edgeSides >= 3 ? c.edgeSupport : -1
            return 0.8 * ((c.confidence - 0.4) / 0.5).clamped(0, 1) * strictEdgeGate(edge)
        case .detector:
            // Its own score already includes edges and mask fit (0.4 = its old acceptance → 0.5). A clean mask with an
            // edge above the marble noise also counts, even when its own (stricter) edge term killed the score.
            let own = ((c.confidence - 0.2) / 0.4).clamped(0, 1)
            let soft = c.edgeSupport >= 0
                ? 0.8 * c.fit * smoothStep(4.5, 12, c.edgeSupport) * smoothStep(0.04, 0.12, c.quad.area) : 0
            return max(own, soft)
        }
    }

    static func score(_ c: PaperCandidate, imageAspect: Double) -> Double {
        shapeScore(c, imageAspect: imageAspect) * evidence(c)
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

    /// Every corner of `inner` lies inside the convex quad `outer`.
    static func contains(_ outer: Quad, _ inner: Quad) -> Bool {
        guard outer.isConvex else { return false }
        let o = outer.points
        func side(_ a: NormPoint, _ b: NormPoint, _ p: NormPoint) -> Double {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        let orientation: Double = side(o[0], o[1], o[2]) > 0 ? 1 : -1
        return inner.points.allSatisfy { p in
            (0..<4).allSatisfy { k in side(o[k], o[(k + 1) % 4], p) * orientation >= 0 }
        }
    }

    /// The best outline, or nil when no candidate reaches `suggestionScore`.
    /// Each candidate's evidence is combined (noisy-or) with that of candidates from *other* sources that agree with
    /// it; the corners of an agreeing group come from its member with the strongest edge support (refined /
    /// edge-snapped corners are the precise ones), the winner's own corners when edges tie. A rectangle nothing
    /// agrees with stays a suggestion. When the winner fully contains a paper-like detector / document outline that
    /// scores at least `innerPreference` of it (and is itself confident when the winner is), the inner one wins —
    /// unless the winner's group has a Vision document with a clear edge (≥ 8) or `innerIsOnATray` says the ring
    /// between the two is not a tray (`PaperDetector.ringLooksLikeTray`; e.g. the margin around a drawn frame).
    /// Agreement only counts from outlines with some evidence of their own (≥ `minAgreeingEvidence`).
    static func pick(_ candidates: [PaperCandidate], imageAspect: Double,
                     innerIsOnATray: ((_ outer: Quad, _ inner: Quad) -> Bool)? = nil) -> Pick? {
        let usable = candidates.filter { $0.quad.isConvex }
        var scored: [Scored] = []
        for (i, c) in usable.enumerated() {
            let shape = shapeScore(c, imageAspect: imageAspect)
            guard shape > 0 else { continue }
            let ownEvidence = evidence(c)
            var miss = 1 - ownEvidence
            var agreeing: Set<PaperCandidate.Source> = [c.source]
            var cornerSource = c
            var clearDocument = c.source == .document && c.edgeSupport >= clearEdge
            var strongDocument = isStrongDocument(c)
            var groupEdge = c.edgeSupport
            // An outline without evidence of its own can neither join nor lead a group (else a zero-evidence detector
            // guess would collect a lone rectangle's evidence and bypass the rectangle cap).
            let canGroup = ownEvidence >= minAgreeingEvidence
            for (j, o) in usable.enumerated() where canGroup && j != i && o.source != c.source && !agreeing.contains(o.source) {
                guard agree(c.quad, o.quad, imageAspect: imageAspect) else { continue }
                let e = evidence(o)
                guard e >= minAgreeingEvidence else { continue }
                miss *= 1 - e
                agreeing.insert(o.source)
                if o.source == .document && o.edgeSupport >= clearEdge { clearDocument = true }
                if isStrongDocument(o) { strongDocument = true }
                groupEdge = max(groupEdge, o.edgeSupport)
                if o.edgeSupport > cornerSource.edgeSupport + 0.5 { cornerSource = o }
            }
            var s = shape * (1 - miss)
            if agreeing == [.rectangles] { s = min(s, rectangleAloneCap) }
            let p = Pick(quad: cornerSource.quad, source: c.source, score: s, isConfident: s >= confidentScore,
                         agreeing: agreeing, edgeSupport: groupEdge, hasStrongDocument: strongDocument)
            scored.append(Scored(pick: p, candidate: c, hasClearDocument: clearDocument))
        }
        // first of equal scores wins (stable)
        var top: Scored?
        for e in scored where top == nil || e.pick.score > top!.pick.score + 1e-9 { top = e }
        guard let outer = top else { return nil }
        var best = outer
        if !outer.hasClearDocument {
            var innerFloor = max(suggestionScore, outer.pick.score * innerPreference)
            if outer.pick.isConfident { innerFloor = max(innerFloor, confidentScore) }   // never trade down to a guess
            var innerScore = -1.0
            for e in scored {
                // a rectangle inside a sheet is usually a drawn frame, not the sheet
                if e.candidate.source == .rectangles { continue }
                if outer.pick.agreeing.contains(e.candidate.source) { continue }
                if e.candidate.quad.area > outer.candidate.quad.area * 0.85 { continue }
                if !contains(outer.candidate.quad, e.candidate.quad) { continue }
                guard e.pick.score >= innerFloor, e.pick.score > innerScore else { continue }
                if let innerIsOnATray, !innerIsOnATray(outer.candidate.quad, e.candidate.quad) { continue }
                innerScore = e.pick.score
                best = e
            }
        }
        guard best.pick.score >= suggestionScore else { return nil }
        return best.pick
    }

    /// The kind of Vision document 1.2.1 looked at (confidence ≥ 0.5, plausible size).
    static func isStrongDocument(_ c: PaperCandidate) -> Bool {
        c.source == .document && c.confidence >= 0.5 && c.quad.area >= 0.12
    }

    /// 1.2.2 rescue — only asked when 1.2.1 would have kept the whole photo (see `PaperDecision`). `pick`, plus
    /// guardrails before anything is cropped: never a nearly-full outline (> 95 %; 1.2.1 already handled the clear
    /// ones), only a sheet-like shape (aspect score ≥ 0.9), an edge at least at the marble-noise level (≥ 4), and a
    /// winning group with a 1.2.1-grade Vision document — otherwise (weak documents 0.3–0.5, small outlines, detector
    /// soft guesses; lone rectangles are capped anyway) only when the edge is in the faint range 4…8 that 1.2.1's
    /// "< 5" rule threw away. Anything else is a suggestion.
    static func rescue(_ candidates: [PaperCandidate], imageAspect: Double,
                       innerIsOnATray: ((_ outer: Quad, _ inner: Quad) -> Bool)? = nil) -> Pick? {
        guard var p = pick(candidates, imageAspect: imageAspect, innerIsOnATray: innerIsOnATray) else { return nil }
        if p.isConfident && !rescueMayCrop(p, imageAspect: imageAspect) { p.isConfident = false }
        return p
    }

    static func rescueMayCrop(_ p: Pick, imageAspect: Double) -> Bool {
        guard p.quad.isConvex, p.quad.area >= 0.04, p.quad.area <= nearlyFullArea else { return false }
        guard aspectScore(sheetAspect(p.quad, imageAspect: imageAspect)) >= 0.9 else { return false }
        guard p.edgeSupport >= 4 else { return false }
        // The detector's own outline was rejected by it (score < 0.4); without a Vision document agreeing it may be a
        // placemat or tray found by the brightness mask.
        if p.agreeing.contains(.detector) && !p.agreeing.contains(.document) { return false }
        return p.hasStrongDocument || p.edgeSupport <= clearEdge
    }

    /// An outline needs at least this much evidence of its own for its agreement to count (a detector guess with
    /// none must not lift a lone rectangle — a placemat in dim light — over the cap).
    static let minAgreeingEvidence = 0.1

    private struct Scored {
        var pick: Pick
        var candidate: PaperCandidate
        var hasClearDocument: Bool
    }

    /// Where the crop tool's corners start when no paper was found: the best weak outline, else an inset frame
    /// (so all four handles are away from the screen edges and easy to grab).
    static func startingCorners(suggestion: Quad?) -> Quad {
        if let s = suggestion, s.isConvex, s.area >= 0.08, s.area <= 0.92 { return s }
        return .inset(0.12)
    }
}

/// The paper decision for a still photo (1.2.2). By construction, whatever 1.2.1 cropped is cropped identically: the
/// exact 1.2.1 rule runs first, and the new scoring is only a rescue for photos 1.2.1 left whole (white on white,
/// dim light). Pure, so a parity test can run both on the same inputs.
enum PaperDecision {
    /// Vision's document outline as 1.2.1 saw it.
    struct VisionDocument: Sendable, Equatable {
        /// Straight from Vision (normalized, top-left origin).
        var original: Quad
        var confidence: Double
        /// After `PaperDetector.refine` on the 360 px image (1.2.1's corners).
        var refined: Quad
        /// `refine`'s raw contrast (1.2.1's value: -1 only when no side could be measured).
        var rawContrast: Double
    }

    /// The glue in ImageProcessor.detectPaperSync: each convex Vision outline refined on the 360 px planes (1.2.1's
    /// `refine`); the document becomes the 1.2.1 input (original quad, refined quad, raw contrast), and every outline
    /// becomes a scoring candidate with its refined corners and known edge support.
    static func prepare(vision: [PaperCandidate], planes: PaperDetector.Planes)
        -> (document: VisionDocument?, candidates: [PaperCandidate]) {
        var document: VisionDocument?
        var out: [PaperCandidate] = []
        for var c in vision where c.quad.isConvex {
            let original = c.quad
            let refined = PaperDetector.refine(original, planes: planes)
            if c.source == .document {
                document = VisionDocument(original: original, confidence: c.confidence, refined: refined.quad,
                                          rawContrast: refined.rawContrast)
            }
            c.quad = refined.quad
            c.edgeSupport = PaperDetector.knownContrast(refined.rawContrast, sides: refined.sides)
            c.edgeSides = refined.sides
            out.append(c)
        }
        return (document, out)
    }

    /// 1.2.1's `detectPaperSync`, verbatim: Vision document (confidence ≥ 0.5, plausible), refined; deferred to the
    /// detector when its contrast is < 5, or < 8 while the detector is sure (> 0.6); else the detector when it is
    /// not a guess. nil = whole photo.
    static func legacy(document: VisionDocument?, detector det: PaperDetector.Result) -> PaperDetection? {
        if let d = document, d.confidence >= 0.5, d.original.isPlausible {
            if d.rawContrast < 5 || (d.rawContrast < 8 && !det.isGuess && det.score > 0.6) {
                return det.isGuess ? nil : PaperDetection(quad: det.quad, isGuess: false, method: .detector)
            }
            return PaperDetection(quad: d.refined, isGuess: false, method: .vision)
        }
        return det.isGuess ? nil : PaperDetection(quad: det.quad, isGuess: false, method: .detector)
    }

    /// 1.2.1 first; when it keeps the whole photo, `PaperCandidateScoring.rescue` over all candidates (a confident
    /// rescue crops; otherwise its outline only becomes the crop tool's suggestion).
    static func decide(document: VisionDocument?, detector: PaperDetector.Result, candidates: [PaperCandidate],
                       imageAspect: Double,
                       innerIsOnATray: ((_ outer: Quad, _ inner: Quad) -> Bool)? = nil) -> PaperDetection {
        if let old = legacy(document: document, detector: detector) { return old }
        guard let pick = PaperCandidateScoring.rescue(candidates, imageAspect: imageAspect,
                                                      innerIsOnATray: innerIsOnATray) else {
            return PaperDetection(quad: .full, isGuess: true, method: .none)
        }
        if pick.isConfident {
            return PaperDetection(quad: pick.quad, isGuess: false, method: pick.source == .detector ? .detector : .vision)
        }
        return PaperDetection(quad: .full, isGuess: true, method: .none, suggestion: pick.quad)
    }
}

/// Live camera overlay (1.2.2):Vision document segmentation every analysed frame, the rectangle detector only when
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
