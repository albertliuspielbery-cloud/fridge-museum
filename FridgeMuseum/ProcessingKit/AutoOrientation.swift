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
/// - text: `VNRecognizeTextRequest` (zh-Hant/en when supported, no language correction); each line read votes by its
///   own geometry (see `textScores`). Children often write their name or the date. Decisive when one turn clearly
///   wins.
/// - faces: `VNDetectFaceRectanglesRequest`; drawn faces are sometimes found, upright (small roll) only. Weak.
/// - layout: blue (sky) and yellow (sun) along the top, green (grass) along the bottom. Weak, three separate cues.
/// Weak cues only turn the artwork when at least two agree with one of them not from the colour layout, or all
/// three colour cues agree — and none disagrees. Text decides alone only with ≥ 2 lines or ≥ 6 characters behind it
/// and no colour cue against it.
enum AutoOrienter {
    /// Long edge of the copy the Vision requests see.
    static let visionEdge = 720
    /// Long edge of the colour-layout sample.
    static let layoutEdge = 96
    static let applyThreshold = 0.6

    /// Vision orientation meaning "turn this image `t` quarter turns clockwise to see it upright" (EXIF 1, 6, 3, 8).
    static let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]

    /// Full estimate on an upright-as-captured (perspective-corrected) artwork image. 4 fast text passes (+ 2 accurate
    /// ones only when text was found but the fast passes don't agree) and 4 face passes on a ≤ 720 px copy, plus a
    /// 96 px colour sample.
    static func estimate(cgImage: CGImage) -> AutoOrientation {
        guard let small = scaled(cgImage, maxEdge: visionEdge) else { return .none }
        let text = textAnalysis(small)
        let faces = (0..<4).map { faceScore(small, turns: $0) }
        let layout = layoutSample(cgImage).map { LayoutCues.votes($0) } ?? []
        return decide(text: text.scores, textLines: text.lines, textChars: text.chars, faces: faces, layoutVotes: layout)
    }

    // MARK: Decision (pure)

    /// Combines the per-turn scores. `text`, `textLines` (text lines voting for each turn), `textChars` (letters /
    /// digits in them) and `faces` have 4 entries (turns 0...3); `layoutVotes` holds the turn each colour cue voted
    /// for (cues without a clear vote are left out).
    ///
    /// Text decides alone only with a clear winner backed by ≥ 2 separate lines or ≥ 6 characters (one short name
    /// written along the side edge must not turn a landscape drawing), and never against a colour cue.
    static func decide(text: [Double], textLines: [Int], textChars: [Int], faces: [Double],
                       layoutVotes: [Int]) -> AutoOrientation {
        var votes: [Int] = []
        var nonLayoutVote = false
        let colourVotes = layoutVotes.filter { (0..<4).contains($0) }
        if let w = winner(text) {
            let (best, score, second) = w
            let lines = textLines.count == 4 ? textLines[best] : 0
            let chars = textChars.count == 4 ? textChars[best] : 0
            if score >= 4, score >= 2.5 * second, lines >= 2 || chars >= 6 {
                // Colour cues disagree with a turn the text wants: keep the capture orientation.
                if best != 0, colourVotes.contains(where: { $0 != best }) { return .none }
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
        votes += colourVotes
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

    /// One line of text Vision read in one pass.
    struct TextRead: Sendable, CustomStringConvertible {
        var pass: Int
        var accurate: Bool
        var string: String
        var confidence: Double
        /// Direction of the text line (bottom-left → bottom-right corner) in the pass's upright frame, degrees,
        /// y up: 0 = reads left to right, 90 = runs upward, ±180 = upside down.
        var angle: Double
        /// Line length ÷ line height in pixels (a real text line is wide and short).
        var aspect: Double
        /// Clockwise quarter turns this line says the image needs: the pass's turn plus the line's own angle.
        var impliedTurns: Int
        var weight: Double
        /// Letters / digits read.
        var chars: Int

        var description: String {
            let level = accurate ? "A" : "F"
            let c = String(format: "%.2f", confidence), a = String(format: "%.0f", angle)
            let r = String(format: "%.1f", aspect), w = String(format: "%.1f", weight)
            return "\(level)\(pass) \"\(string)\" c\(c) a\(a) r\(r)→\(impliedTurns) w\(w)"
        }
    }

    /// Text score per turn (0...3).
    ///
    /// Why not just "how much text each pass reads": Vision also reads text that is turned relative to the
    /// orientation it was given (it may re-orient internally), and fast mode reads upside-down Latin as confident
    /// junk — so plain per-pass totals come out level. Instead each line votes with its own geometry: the line's
    /// direction in the pass's frame (a line running upward means one more clockwise turn), and lines that are not
    /// wide-and-short (a vertical column read as a tall box) don't vote. Fast passes in all four turns pick the
    /// winner; when that is not clear, two accurate passes on the winning axis break the 0°/180° tie (the
    /// accurate recognizer reads upside-down text at low confidence or recognizes it as turned).
    static func textScores(_ image: CGImage) -> [Double] {
        textAnalysis(image).scores
    }

    /// Per-turn text evidence plus every line read (diagnostics).
    struct TextEvidence: Sendable {
        var scores: [Double]
        /// Lines (with a vote) supporting each turn.
        var lines: [Int]
        /// Letters / digits in those lines.
        var chars: [Int]
        var reads: [TextRead]
    }

    static func textAnalysis(_ image: CGImage) -> TextEvidence {
        let fastReads = (0..<4).flatMap { readText(image, turns: $0, accurate: false) }
        let fast = tally(fastReads)
        guard fast.reduce(0, +) > 0 else { return evidence(fast, used: fastReads, all: fastReads) }
        if let w = winner(fast), w.score >= 4, w.score >= 2.5 * w.second {
            return evidence(fast, used: fastReads, all: fastReads)
        }
        let axis = fast[0] + fast[2] >= fast[1] + fast[3] ? 0 : 1
        let precise = [axis, axis + 2].flatMap { readText(image, turns: $0, accurate: true) }
        var scores = tally(precise)
        // The other axis keeps half its fast evidence, so a wrong axis guess can still lose cleanly.
        let others = [(axis + 1) % 4, (axis + 3) % 4]
        for t in others { scores[t] = fast[t] * 0.5 }
        let used = precise + fastReads.filter { others.contains($0.impliedTurns) }
        return evidence(scores, used: used, all: fastReads + precise)
    }

    private static func evidence(_ scores: [Double], used: [TextRead], all: [TextRead]) -> TextEvidence {
        var lines = [Int](repeating: 0, count: 4), chars = lines
        for r in used where r.weight > 0 {
            lines[r.impliedTurns] += 1
            chars[r.impliedTurns] += r.chars
        }
        return TextEvidence(scores: scores, lines: lines, chars: chars, reads: all)
    }

    /// Human-readable list of what Vision read (test failure messages).
    static func textDiagnostics(_ image: CGImage) -> String {
        let a = textAnalysis(image)
        let scores = a.scores.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        return "text scores [\(scores)] lines \(a.lines) chars \(a.chars) reads: " + a.reads.map(\.description).joined(separator: " | ")
    }

    private static func tally(_ reads: [TextRead]) -> [Double] {
        var scores = [Double](repeating: 0, count: 4)
        for r in reads { scores[r.impliedTurns] += r.weight }
        return scores
    }

    private static func readText(_ image: CGImage, turns: Int, accurate: Bool) -> [TextRead] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = false
        if let supported = try? request.supportedRecognitionLanguages() {
            let wanted = ["zh-Hant", "en-US"].filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientations[turns], options: [:])
        do { try handler.perform([request]) } catch { return [] }
        // Pixel size of the frame Vision's normalized coordinates refer to (the image turned `turns` times).
        let w = Double(turns % 2 == 0 ? image.width : image.height)
        let h = Double(turns % 2 == 0 ? image.height : image.width)
        var out: [TextRead] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { continue }
            let base = stringScore(candidate.string)
            guard base > 0 else { continue }
            let bl = observation.bottomLeft, br = observation.bottomRight, tl = observation.topLeft
            let dx = Double(br.x - bl.x) * w, dy = Double(br.y - bl.y) * h
            let ux = Double(tl.x - bl.x) * w, uy = Double(tl.y - bl.y) * h
            let length = (dx * dx + dy * dy).squareRoot(), height = (ux * ux + uy * uy).squareRoot()
            let aspect = length / max(height, 1e-6)
            let angle = atan2(dy, dx) * 180 / .pi
            let own = ((Int((angle / 90).rounded()) % 4) + 4) % 4
            let chars = candidate.string.filter { $0.isLetter || $0.isNumber }.count
            // A line of several characters must be wider than tall; otherwise it is a turned column read as a box.
            let usable = chars < 3 || aspect >= 1.0
            let weight = usable ? base * Double(candidate.confidence) : 0
            out.append(TextRead(pass: turns, accurate: accurate, string: candidate.string,
                                confidence: Double(candidate.confidence), angle: angle, aspect: aspect,
                                impliedTurns: (turns + own) % 4, weight: weight, chars: chars))
        }
        return out
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
