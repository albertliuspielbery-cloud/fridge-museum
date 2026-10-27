import Foundation
import Testing
@testable import FridgeMuseum

struct ImageOpsTests {
    @Test func otsuSplitsBimodalHistogram() {
        var hist = [Double](repeating: 0, count: 256)
        hist[40] = 500
        hist[200] = 500
        let t = ImageOps.otsu(hist, total: 1000)
        #expect(t >= 40 && t < 200)
    }

    @Test func componentsCountsBlobs() {
        let w = 6, h = 4
        let bin: [UInt8] = [
            1, 1, 0, 0, 0, 1,
            1, 0, 0, 0, 0, 1,
            0, 0, 0, 1, 0, 0,
            0, 0, 0, 1, 0, 0,
        ]
        let cc = ImageOps.components(bin, w, h)
        #expect(cc.count == 3)
        #expect(cc.area.dropFirst().sorted() == [2, 2, 3])
    }

    @Test func fillHolesClosesRing() {
        let w = 5, h = 5
        var bin = [UInt8](repeating: 0, count: w * h)
        for i in 1...3 { bin[1 * w + i] = 1; bin[3 * w + i] = 1; bin[i * w + 1] = 1; bin[i * w + 3] = 1 }
        let filled = ImageOps.fillHoles(bin, w, h)
        #expect(filled[2 * w + 2] == 1)
        #expect(filled[0] == 0)
    }

    @Test func boxBlurPreservesConstant() {
        let a = [Float](repeating: 0.5, count: 30)
        let b = ImageOps.blur3(a, 6, 5, 2)
        #expect(b.allSatisfy { abs($0 - 0.5) < 1e-5 })
    }
}

struct PaperDetectorTests {
    @Test func findsWhitePaperOnBrownTable() {
        var img = RGBA8Image(width: 200, height: 150, fill: (150, 100, 60))
        for y in 30..<120 { for x in 40..<160 { img.set(x, y, (245, 243, 238)) } }
        let q = PaperDetector.detect(img)
        #expect(abs(q.topLeft.x - 0.2) < 0.02 && abs(q.topLeft.y - 0.2) < 0.02)
        #expect(abs(q.bottomRight.x - 0.8) < 0.02 && abs(q.bottomRight.y - 0.8) < 0.02)
        #expect(abs(q.topRight.x - 0.8) < 0.02 && abs(q.bottomLeft.y - 0.8) < 0.02)
    }

    @Test func paperFillingFrameReturnsFull() {
        let img = RGBA8Image(width: 120, height: 90, fill: (240, 240, 235))
        let q = PaperDetector.detect(img)
        // A uniform frame has no contrast: either the whole frame or the safe inset is acceptable.
        #expect(q == .full || q == .inset(0.05))
    }
}

struct SpeckRemoverTests {
    @Test func removesLonelyGrayDot() {
        var img = RGBA8Image(width: 100, height: 100)
        for y in 50..<52 { for x in 50..<52 { img.set(x, y, (100, 100, 100)) } }
        #expect(SpeckRemover.remove(in: &img) == 1)
        #expect(img.pixels[(50 * 100 + 50) * 4] == 255)
    }

    @Test func keepsDotNextToStroke() {
        var img = RGBA8Image(width: 100, height: 100)
        for y in 50..<52 { for x in 50..<52 { img.set(x, y, (100, 100, 100)) } }
        for x in 20..<80 { img.set(x, 54, (30, 30, 30)) }
        #expect(SpeckRemover.remove(in: &img) == 0)
        #expect(img.pixels[(50 * 100 + 50) * 4] == 100)
    }

    @Test func keepsColoredDot() {
        var img = RGBA8Image(width: 100, height: 100)
        for y in 50..<52 { for x in 50..<52 { img.set(x, y, (230, 20, 20)) } }
        #expect(SpeckRemover.remove(in: &img) == 0)
    }
}

struct IlluminationTests {
    @Test func uniformPaperMapsToItself() {
        let w = 16, h = 12
        var rgba = [Float](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) { rgba[i * 4] = 0.8; rgba[i * 4 + 1] = 0.78; rgba[i * 4 + 2] = 0.7 }
        let map = IlluminationEstimator.backgroundMap(rgba: rgba, width: w, height: h)
        for i in 0..<(w * h) {
            #expect(abs(map[i * 4] - 0.8) < 1e-3)
            #expect(abs(map[i * 4 + 2] - 0.7) < 1e-3)
        }
    }

    @Test func followsAShadowGradient() {
        let w = 40, h = 10
        var rgba = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = 0.6 + 0.35 * Float(x) / Float(w - 1)
                let i = (y * w + x) * 4
                rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v
            }
        }
        let map = IlluminationEstimator.backgroundMap(rgba: rgba, width: w, height: h)
        let left = map[(5 * w + 2) * 4], right = map[(5 * w + 37) * 4]
        #expect(left < right)
    }

    @Test func blockSizeMatchesPrototype() {
        #expect(IlluminationEstimator.blockSize(width: 1800, height: 1200) == 15)
        #expect(IlluminationEstimator.blockSize(width: 100, height: 80) == 1)
    }
}

struct AlphaBrushTests {
    @Test func eraseAndRestore() {
        let w = 50, h = 50
        var alpha = [UInt8](repeating: 255, count: w * h)
        AlphaBrush.apply(to: &alpha, width: w, height: h, points: [(x: 25, y: 25)], radius: 5, restore: false)
        #expect(alpha[25 * w + 25] == 0)
        #expect(alpha[0] == 255)
        AlphaBrush.apply(to: &alpha, width: w, height: h, points: [(x: 25, y: 25)], radius: 5, restore: true)
        #expect(alpha[25 * w + 25] == 255)
    }

    @Test func normalizedStrokesAndBoundingBox() {
        let w = 40, h = 20
        var alpha = [UInt8](repeating: 0, count: w * h)
        let stroke = BrushStroke(mode: .restore, radius: 0.05, points: [.init(x: 0.25, y: 0.5), .init(x: 0.75, y: 0.5)])
        AlphaBrush.apply(strokes: [stroke], to: &alpha, width: w, height: h)
        let box = AlphaBrush.boundingBox(alpha, width: w, height: h)
        #expect(box != nil)
        if let box {
            #expect(box.x0 <= 10 && box.x1 >= 30)
            #expect(box.y0 <= 10 && box.y1 >= 10)
        }
        #expect(AlphaBrush.boundingBox([UInt8](repeating: 0, count: 4), width: 2, height: 2) == nil)
    }
}

struct CraftMaskTests {
    @Test func liftsObjectFromPlainTable() {
        var img = RGBA8Image(width: 64, height: 48, fill: (180, 170, 150))
        for y in 14..<34 { for x in 22..<42 { img.set(x, y, (40, 90, 200)) } }
        let m = CraftMaskEstimator.estimate(img, sensitivity: 0.5)
        #expect(m.mask[24 * 64 + 32] > 0.9)   // center of the object
        #expect(m.mask[2 * 64 + 2] < 0.1)     // table corner
        let alpha = CraftMaskEstimator.alpha(full: img, mask: m)
        #expect(alpha[24 * 64 + 32] > 200)
        #expect(alpha[2 * 64 + 2] < 50)
    }
}
