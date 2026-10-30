import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import FridgeMuseum

/// 1.2.0 automatic upright turn: capture angle from gravity (pure) and the content check on synthetic sheets.
struct CaptureOrientationTests {
    private func angle(_ x: Double, _ y: Double, previous: Int? = nil) -> Int? {
        CaptureOrientation.rotationAngle(gravityX: x, gravityY: y, previous: previous)
    }

    @Test func uprightPoses() {
        #expect(angle(0, -1) == 90)      // portrait
        #expect(angle(-1, 0) == 0)       // landscapeLeft (home button right) = sensor orientation
        #expect(angle(1, 0) == 180)      // landscapeRight (home button left)
        #expect(angle(0, 1) == 270)      // upside down
    }

    @Test func heldAlmostFlatOverATable() {
        // Face up, near edge a little lower: the small in-plane gravity still tells which edge is "down".
        #expect(angle(0.25, 0.02) == 180)
        #expect(angle(-0.15, -0.05) == 0)
        #expect(angle(0.03, -0.2) == 90)
    }

    @Test func flatKeepsTheLastAnswer() {
        #expect(angle(0.02, -0.03) == nil)
        #expect(angle(0, 0) == nil)
        #expect(angle(.nan, 1) == nil)
        // The tracker keeps its previous value whenever this returns nil.
        var last: Int? = 180
        if let a = angle(0.05, 0.04, previous: last) { last = a }
        #expect(last == 180)
    }

    @Test func hysteresisAtTheDiagonal() {
        // 40° (nearest: 0) — stays portrait (90) until 12° past the diagonal.
        let a40 = -140.0 * .pi / 180, a20 = -160.0 * .pi / 180
        #expect(angle(cos(a40), sin(a40)) == 0)
        #expect(angle(cos(a40), sin(a40), previous: 90) == 90)
        #expect(angle(cos(a20), sin(a20), previous: 90) == 0)
    }

    /// Gravity for a phone tilted `side` degrees toward its right edge and `forward` degrees toward its top edge
    /// from lying face up (small-angle sines; z dominant).
    private func flat(side: Double, forward: Double) -> (x: Double, y: Double) {
        (sin(side * .pi / 180), sin(forward * .pi / 180))
    }

    @Test func portraitOverATableStaysPortrait() {
        var f = CaptureOrientationFilter()
        f.update(gravityX: 0, gravityY: -1, time: 0)                 // lifted in portrait
        #expect(f.angle == 90)
        // Laid over the drawing: 8° to the right and 3° forward (in-plane ≈ 0.15 g, raw angle 166° → 180) …
        let wobble = flat(side: 8, forward: 3)
        for i in 1...20 { f.update(gravityX: wobble.x, gravityY: wobble.y, time: Double(i) * 0.07) }
        #expect(f.angle == 90)
        // … or leaning forward 10° (raw → 270, upside down).
        let lean = flat(side: 0, forward: 10)
        for i in 21...40 { f.update(gravityX: lean.x, gravityY: lean.y, time: Double(i) * 0.07) }
        #expect(f.angle == 90)
    }

    @Test func clearLandscapeTiltSwitchesAfterAMoment() {
        var f = CaptureOrientationFilter(angle: 90)
        let tilt = flat(side: 30, forward: 0)                          // 0.5 g toward the right edge → 180
        f.update(gravityX: tilt.x, gravityY: tilt.y, time: 0)
        f.update(gravityX: tilt.x, gravityY: tilt.y, time: 0.1)
        #expect(f.angle == 90)                                         // not yet: needs to hold 0.3 s
        f.update(gravityX: tilt.x, gravityY: tilt.y, time: 0.35)
        #expect(f.angle == 180)
        // A brief swing that doesn't hold changes nothing.
        let back = flat(side: -30, forward: 0)
        f.update(gravityX: back.x, gravityY: back.y, time: 1.0)
        f.update(gravityX: 0.02, gravityY: 0.01, time: 1.2)            // flat again
        f.update(gravityX: back.x, gravityY: back.y, time: 1.4)
        #expect(f.angle == 180)
    }

    @Test func firstAnswerMayComeFromASmallTilt() {
        var f = CaptureOrientationFilter()
        f.update(gravityX: 0.02, gravityY: 0.01, time: 0)              // flat: no answer yet
        #expect(f.angle == nil)
        let tilt = flat(side: 9, forward: 0)                           // ≈ 0.16 g toward the right edge
        f.update(gravityX: tilt.x, gravityY: tilt.y, time: 0.1)
        #expect(f.angle == 180)
    }
}

struct AutoOrientationTests {
    // MARK: Synthetic sheets

    private func render(width: Int = 900, height: Int = 640, _ draw: (CGContext) -> Void) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(ctx.cgContext)          // UIKit coordinates: origin top-left
        }
        return try #require(image.cgImage)
    }

    /// A child's name and the date, as written on a drawing.
    private func textSheet() throws -> CGImage {
        try render { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 84), .foregroundColor: UIColor.black]
            NSAttributedString(string: "小明 2026.3.14", attributes: attrs).draw(at: CGPoint(x: 50, y: 140))
            NSAttributedString(string: "Ming's rainbow cat", attributes: attrs).draw(at: CGPoint(x: 50, y: 360))
        }
    }

    /// Sky along the top, a sun in it, grass along the bottom.
    private func landscapeSheet() throws -> CGImage {
        try render { ctx in
            ctx.setFillColor(UIColor(red: 0.35, green: 0.65, blue: 0.95, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 150))
            ctx.setFillColor(UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: 380, y: 5, width: 140, height: 140))
            ctx.setFillColor(UIColor(red: 0.3, green: 0.7, blue: 0.25, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 520, width: 900, height: 120))
            ctx.setFillColor(UIColor(red: 0.8, green: 0.3, blue: 0.3, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 380, y: 330, width: 140, height: 190))   // a house
        }
    }

    private func pixels(_ image: CGImage) throws -> (width: Int, height: Int, data: [UInt8]) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        try data.withUnsafeMutableBytes { raw in
            let ctx = try #require(CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                             bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, data)
    }

    private func image(width w: Int, height h: Int, data: [UInt8]) throws -> CGImage {
        // The context owns its memory, so the image never points at a buffer that goes away.
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let dest = try #require(ctx.data)
        data.withUnsafeBytes { src in
            if let base = src.baseAddress { dest.copyMemory(from: base, byteCount: min(src.count, w * h * 4)) }
        }
        return try #require(ctx.makeImage())
    }

    /// Turns the image `turns` quarter turns clockwise, pixel by pixel (independent of the code under test):
    /// source (x, y) lands at (h − 1 − y, x).
    private func rotatedClockwise(_ img: CGImage, turns: Int) throws -> CGImage {
        var current = img
        for _ in 0..<(turns % 4) {
            let (w, h, src) = try pixels(current)
            var dst = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let s = (y * w + x) * 4, d = (x * h + (h - 1 - y)) * 4
                    dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
                }
            }
            current = try image(width: h, height: w, data: dst)
        }
        return current
    }

    @Test func testRotationHelperTurnsClockwise() throws {
        // [red, blue] turned clockwise → red on top, blue below.
        let row = try image(width: 2, height: 1, data: [255, 0, 0, 255, 0, 0, 255, 255])
        let (w, h, px) = try pixels(try rotatedClockwise(row, turns: 1))
        #expect(w == 1 && h == 2)
        #expect(px[0] == 255 && px[2] == 0)
        #expect(px[4] == 0 && px[6] == 255)
    }

    // MARK: Content check

    @Test func writtenNameAndDateFindTheUprightTurn() throws {
        let sheet = try textSheet()
        // Vision text recognition should run in the Simulator; if this environment reads nothing at all, there is
        // nothing to compare.
        guard !AutoOrienter.textAnalysis(sheet).reads.isEmpty else { return }
        for k in 0..<4 {
            let turned = try rotatedClockwise(sheet, turns: k)
            let result = AutoOrienter.estimate(cgImage: turned)
            // What Vision saw, per pass (F = fast, A = accurate; pass = turns Vision was told; a = line angle,
            // r = line aspect, → = turns the line votes for), so a CI failure says why.
            let seen = AutoOrienter.textDiagnostics(turned)
            // Content turned k clockwise needs (4 − k) more clockwise turns to stand upright.
            #expect(result.quarterTurns == (4 - k) % 4, "turned \(k): got \(result); \(seen)")
            #expect(result.basis == .text, "turned \(k): got \(result); \(seen)")
            #expect(result.shouldApply == (k != 0), "turned \(k): got \(result); \(seen)")
        }
    }

    @Test func blankSheetStaysAsCaptured() throws {
        let blank = try render { _ in }
        let result = AutoOrienter.estimate(cgImage: blank)
        #expect(result.quarterTurns == 0)
        #expect(!result.shouldApply)
    }

    @Test func skySunAndGrassAgree() throws {
        let sheet = try landscapeSheet()
        for k in 0..<4 {
            let turned = try rotatedClockwise(sheet, turns: k)
            let sample = try #require(AutoOrienter.layoutSample(turned))
            let want = (4 - k) % 4
            #expect(LayoutCues.votes(sample) == [want, want, want], "turned \(k)")
            let result = AutoOrienter.estimate(cgImage: turned)
            #expect(result.quarterTurns == want, "turned \(k): got \(result)")
            #expect(result.shouldApply == (k != 0))
        }
    }

    @Test func topSideMapping() {
        // A clockwise turn brings the left side (3) to the top.
        #expect(LayoutCues.topSide(afterTurns: 0) == 0)
        #expect(LayoutCues.topSide(afterTurns: 1) == 3)
        #expect(LayoutCues.topSide(afterTurns: 2) == 2)
        #expect(LayoutCues.topSide(afterTurns: 3) == 1)
    }

    @Test func decisionIsConservative() {
        func decide(_ text: [Double] = [0, 0, 0, 0], lines: [Int] = [0, 0, 0, 0], chars: [Int] = [0, 0, 0, 0],
                    faces: [Double] = [0, 0, 0, 0], layout: [Int] = []) -> AutoOrientation {
            AutoOrienter.decide(text: text, textLines: lines, textChars: chars, faces: faces, layoutVotes: layout)
        }
        // Clear text from two lines wins on its own.
        let text = decide([0, 0, 11, 1], lines: [0, 0, 2, 0], chars: [0, 0, 14, 1])
        #expect(text.quarterTurns == 2 && text.basis == .text && text.shouldApply)
        // One long line (≥ 6 characters) is enough too.
        #expect(decide([0, 9, 0, 0], lines: [0, 1, 0, 0], chars: [0, 8, 0, 0]).quarterTurns == 1)
        // A short name along the side edge (one line, < 6 characters) is not decisive.
        #expect(!decide([0, 5, 0, 0], lines: [0, 1, 0, 0], chars: [0, 4, 0, 0]).shouldApply)
        // Colour cues against the text verdict: keep the capture orientation.
        #expect(!decide([0, 0, 11, 1], lines: [0, 0, 2, 0], chars: [0, 0, 14, 1], layout: [1]).shouldApply)
        // Colour cues agreeing with the text are fine.
        #expect(decide([0, 0, 11, 1], lines: [0, 0, 2, 0], chars: [0, 0, 14, 1], layout: [2]).quarterTurns == 2)
        // Two colour cues alone are not enough; all three are.
        #expect(!decide(layout: [3, 3]).shouldApply)
        #expect(decide(layout: [3, 3, 3]).quarterTurns == 3)
        // A drawn face plus one colour cue agreeing is enough.
        let face = decide(faces: [0, 0.9, 0, 0], layout: [1])
        #expect(face.quarterTurns == 1 && face.shouldApply)
        // Any disagreement → keep the capture orientation.
        #expect(!decide(faces: [0, 0.9, 0, 0], layout: [1, 3]).shouldApply)
        // Faces found in every turn say nothing.
        #expect(!decide(faces: [0.9, 0.9, 0.9, 0.9], layout: [1]).shouldApply)
        // Text that only slightly prefers one turn is a weak cue.
        #expect(!decide([0, 5, 3.5, 0], lines: [0, 2, 1, 0], chars: [0, 8, 6, 0]).shouldApply)
    }

    @Test func dateShapedTextScoresHigher() {
        #expect(AutoOrienter.stringScore("2026.3.14") > AutoOrienter.stringScore("9202'E'hl"))
        #expect(AutoOrienter.stringScore("l") == 0)
    }

    // MARK: Recipe

    @Test func recipeAppliesTheTurnOnce() throws {
        let sure = AutoOrientation(quarterTurns: 1, confidence: 0.9, basis: .text)
        var r = ProcessingRecipe(kind: .flat).applyingAutoOrientation(sure)
        #expect(r.quarterTurns == 1 && r.autoTurns == 1 && r.isAutoTurned)
        // Already checked: a later estimate changes nothing (re-renders stay stable).
        #expect(r.applyingAutoOrientation(AutoOrientation(quarterTurns: 3, confidence: 0.9, basis: .text)) == r)
        // A manual turn wins and the hint goes away.
        r.rotateClockwise()
        #expect(r.quarterTurns == 2 && !r.isAutoTurned)
        // Stored and read back.
        let back = try ProcessingRecipe.decode(try r.encoded())
        #expect(back == r && back.autoTurns == 1)
    }

    @Test func recipeKeepsCaptureWhenUnsureTurnedOrCraft() throws {
        let unsure = AutoOrientation(quarterTurns: 2, confidence: 0.4, basis: .cues)
        let a = ProcessingRecipe(kind: .flat).applyingAutoOrientation(unsure)
        #expect(a.quarterTurns == 0 && a.autoTurns == 0 && !a.isAutoTurned)

        let sure = AutoOrientation(quarterTurns: 2, confidence: 0.9, basis: .text)
        var turned = ProcessingRecipe(kind: .flat)
        turned.rotateCounterClockwise()
        let b = turned.applyingAutoOrientation(sure)
        #expect(b.quarterTurns == 3 && b.autoTurns == 0)

        let c = ProcessingRecipe(kind: .craft).applyingAutoOrientation(sure)
        #expect(c.quarterTurns == 0 && c.autoTurns == 0)

        // Recipes from before 1.2.0 have not been checked.
        #expect(try ProcessingRecipe.decode(Data(#"{"kind":"flat","quarterTurns":1}"#.utf8)).autoTurns == nil)
    }
}
