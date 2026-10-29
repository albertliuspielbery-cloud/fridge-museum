import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Which quarter turn makes a flat artwork upright, judged from its content — on device, no generative AI.
/// Conservative on purpose: a wrong automatic turn is worse than none, so anything short of a clear answer
/// leaves the capture orientation alone (`shouldApply == false`).
struct AutoOrientation: Sendable, Hashable {
    enum Basis: String, Sendable {
        /// Recognized writing (a name, a date) reads clearly one way.
        case text
        /// Several weak cues agree (drawn faces, sky / sun on top, ground at the bottom, faint text).
        case cues
        case none
    }

    /// Clockwise quarter turns (0...3) that make the artwork upright, in `ProcessingRecipe.quarterTurns` units.
    var quarterTurns: Int
    /// 0...1; only ≥ `AutoOrienter.applyThreshold` is acted on.
    var confidence: Double
    var basis: Basis

    static let none = AutoOrientation(quarterTurns: 0, confidence: 0, basis: .none)

    /// A non-zero turn the content is sure about.
    var shouldApply: Bool { quarterTurns != 0 && confidence >= AutoOrienter.applyThreshold }
}

/// Content-based upright check (prototype-free; Vision + a colour-layout prior for kids' drawings).
///
/// Every score is computed per candidate turn t = 0...3 (t clockwise quarter turns would make it upright):
/// - text: `VNRecognizeTextRequest` (fast, zh-Hant/en when supported, no language correction) with Vision told the
///   image needs t turns. Children often write their name or the date — upright text reads with high confidence,
///   turned text reads as little or nothing. Decisive when one turn clearly wins.
/// - faces: `VNDetectFaceRectanglesRequest`; drawn faces are sometimes found, upright (small roll) only. Weak.
/// - layout: blue (sky) and yellow (sun) along the top, green (grass) along the bottom. Weak, three separate cues.
/// Weak cues only turn the artwork when at least two agree with one of them not from the colour layout, or all
/// three colour cues agree — and none disagrees.
enum AutoOrienter {
    /// Long edge of the copy the Vision requests see.
    static let visionEdge = 720
    /// Long edge of the colour-layout sample.
    static let layoutEdge = 96
    static let applyThreshold = 0.6

    /// Vision orientation meaning "turn this image `t` quarter turns clockwise to see it upright" (EXIF 1, 6, 3, 8).
    static let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]

    /// Full estimate on an upright-as-captured (perspective-corrected) artwork image. ~4 fast text passes + 4 face
    /// passes on a ≤ 720 px copy and a 96 px colour sample.
    static func estimate(cgImage: CGImage) -> AutoOrientation {
        guard let small = scaled(cgImage, maxEdge: visionEdge) else { return .none }
        let text = textScores(small)
        let faces = (0..<4).map { faceScore(small, turns: $0) }
        let layout = layoutSample(cgImage).map { LayoutCues.votes($0) } ?? []
        return decide(text: text, faces: faces, layoutVotes: layout)
    }

    // MARK: Decision (pure)

    /// Combines the per-turn scores. `text` and `faces` have 4 entries (turns 0...3); `layoutVotes` holds the turn
    /// each colour cue voted for (cues without a clear vote are left out).
    static func decide(text: [Double], faces: [Double], layoutVotes: [Int]) -> AutoOrientation {
        var votes: [Int] = []
        var nonLayoutVote = false
        if let w = winner(text) {
            let (best, score, second) = w
            if score >= 4, score >= 2.5 * second {
                let confidence = min(0.95, 0.7 + score / 60)
                return AutoOrientation(quarterTurns: best, confidence: confidence, basis: .text)
            }
            if score >= 3, score >= 1.5 * second {
                votes.append(best)
                nonLayoutVote = true
            }
        }
        if let w = winner(faces), w.score >= 0.5, w.second <= 0.34 * w.score {
            votes.append(w.best)
            nonLayoutVote = true
        }
        votes += layoutVotes.filter { (0..<4).contains($0) }
        guard let first = votes.first, votes.allSatisfy({ $0 == first }) else { return .none }
        let needed = nonLayoutVote ? 2 : 3
        guard votes.count >= needed else { return .none }
        let confidence = min(0.85, 0.32 + 0.15 * Double(votes.count))     // 2 → 0.62, 3 → 0.77
        return AutoOrientation(quarterTurns: first, confidence: confidence, basis: .cues)
    }

    /// Index of the highest score, the score, and the runner-up score; nil when every score is 0.
    private static func winner(_ scores: [Double]) -> (best: Int, score: Double, second: Double)? {
        guard scores.count == 4, let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else {
            return nil
        }
        let second = scores.indices.filter { $0 != best }.map { scores[$0] }.max() ?? 0
        return (best: best, score: scores[best], second: second)
    }

    // MARK: Vision

    /// Text score per turn (0...3).
    static func textScores(_ image: CGImage) -> [Double] {
        (0..<4).map { textScore(image, turns: $0) }
    }

    private static func textScore(_ image: CGImage, turns: Int) -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        if let supported = try? request.supportedRecognitionLanguages() {
            let wanted = ["zh-Hant", "en-US"].filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientations[turns], options: [:])
        do { try handler.perform([request]) } catch { return 0 }
        var score = 0.0
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.4 else { continue }
            score += stringScore(candidate.string) * Double(candidate.confidence)
        }
        return score
    }

    /// Letters / digits read (capped), plus a bonus for something shaped like a date (2026.3.14, 3/14) — turned
    /// upside down the dots and slashes no longer sit between digits.
    static func stringScore(_ s: String) -> Double {
        let core = s.filter { $0.isLetter || $0.isNumber }
        guard core.count >= 2 else { return 0 }
        var value = Double(min(core.count, 24))
        if s.range(of: #"\d{1,4}[./-]\d{1,2}"#, options: .regularExpression) != nil { value += 4 }
        return value
    }

    private static func faceScore(_ image: CGImage, turns: Int) -> Double {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientations[turns], options: [:])
        do { try handler.perform([request]) } catch { return 0 }
        var score = 0.0
        for face in request.results ?? [] where face.confidence >= 0.5 {
            let roll = face.roll?.doubleValue ?? 0
            if abs(roll) <= 0.6 { score += Double(face.confidence) }
        }
        return score
    }

    // MARK: Pixels

    /// Downscaled copy (long edge ≤ maxEdge), or the image itself when it is small enough.
    private static func scaled(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > maxEdge else { return image }
        let s = Double(maxEdge) / Double(long)
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        return render(image, width: w, height: h)?.makeImage()
    }

    /// Small 8-bit RGBA copy (row 0 = top) for the colour layout.
    static func layoutSample(_ image: CGImage) -> RGBA8Image? {
        let long = max(image.width, image.height, 1)
        let s = min(1, Double(layoutEdge) / Double(long))
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        guard let ctx = render(image, width: w, height: h), let data = ctx.data else { return nil }
        let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        return RGBA8Image(width: w, height: h, pixels: pixels)
    }

    private static func render(_ image: CGImage, width w: Int, height h: Int) -> CGContext? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }
}

/// Colour-layout prior for kids' drawings: sky and sun along the top, grass along the bottom.
enum LayoutCues {
    /// Sides of the image as stored: 0 top, 1 right, 2 bottom, 3 left.
    struct SideFractions: Sendable, Equatable {
        var blue: [Double]
        var yellow: [Double]
        var green: [Double]
    }

    /// The side that ends up on top after `t` clockwise quarter turns (a clockwise turn brings the left side up).
    static func topSide(afterTurns t: Int) -> Int { (4 - ((t % 4) + 4) % 4) % 4 }

    /// Fraction of sky-blue / sun-yellow / grass-green pixels in the outer third along each side.
    static func fractions(_ img: RGBA8Image) -> SideFractions {
        var blue = [Double](repeating: 0, count: 4), yellow = blue, green = blue, count = blue
        let w = img.width, h = img.height
        let bandX = max(1, w / 3), bandY = max(1, h / 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(img.pixels[i]) / 255, g = Double(img.pixels[i + 1]) / 255, b = Double(img.pixels[i + 2]) / 255
                let cls = classify(r, g, b)
                var sides: [Int] = []
                if y < bandY { sides.append(0) }
                if x >= w - bandX { sides.append(1) }
                if y >= h - bandY { sides.append(2) }
                if x < bandX { sides.append(3) }
                for s in sides {
                    count[s] += 1
                    switch cls {
                    case .blue: blue[s] += 1
                    case .yellow: yellow[s] += 1
                    case .green: green[s] += 1
                    case .other: break
                    }
                }
            }
        }
        for s in 0..<4 where count[s] > 0 {
            blue[s] /= count[s]; yellow[s] /= count[s]; green[s] /= count[s]
        }
        return SideFractions(blue: blue, yellow: yellow, green: green)
    }

    enum ColorClass { case blue, yellow, green, other }

    static func classify(_ r: Double, _ g: Double, _ b: Double) -> ColorClass {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard mx > 0, d > 0 else { return .other }
        let s = d / mx
        var hue: Double
        if mx == r { hue = 60 * ((g - b) / d) } else if mx == g { hue = 60 * ((b - r) / d + 2) } else { hue = 60 * ((r - g) / d + 4) }
        if hue < 0 { hue += 360 }
        if hue >= 185, hue <= 255, s >= 0.3, mx >= 0.35 { return .blue }
        if hue >= 38, hue <= 65, s >= 0.45, mx >= 0.6 { return .yellow }
        if hue >= 75, hue <= 165, s >= 0.3, mx >= 0.2 { return .green }
        return .other
    }

    /// The turn each colour cue votes for (at most one vote per cue; cues without a clear winner don't vote).
    static func votes(_ img: RGBA8Image) -> [Int] {
        let f = fractions(img)
        var out: [Int] = []
        if let t = vote(f.blue, onTop: true, minOn: 0.12, minDiff: 0.08) { out.append(t) }
        if let t = vote(f.yellow, onTop: true, minOn: 0.03, minDiff: 0.025) { out.append(t) }
        if let t = vote(f.green, onTop: false, minOn: 0.10, minDiff: 0.07) { out.append(t) }
        return out
    }

    /// For a colour that belongs on top (or at the bottom): the turn putting most of it there, when that side holds
    /// clearly more than the opposite side and the perpendicular pair is clearly less lopsided.
    static func vote(_ frac: [Double], onTop: Bool, minOn: Double, minDiff: Double) -> Int? {
        guard frac.count == 4 else { return nil }
        func lean(_ t: Int) -> Double {
            let top = topSide(afterTurns: t), bottom = (top + 2) % 4
            return onTop ? frac[top] - frac[bottom] : frac[bottom] - frac[top]
        }
        let leans = (0..<4).map(lean)
        guard let best = leans.indices.max(by: { leans[$0] < leans[$1] }) else { return nil }
        let top = topSide(afterTurns: best), bottom = (top + 2) % 4
        let on = onTop ? frac[top] : frac[bottom], off = onTop ? frac[bottom] : frac[top]
        let perpendicular = abs(leans[(best + 1) % 4])
        guard on >= minOn, leans[best] >= minDiff, on >= 2.5 * off, leans[best] >= 1.5 * perpendicular else { return nil }
        return best
    }
}
