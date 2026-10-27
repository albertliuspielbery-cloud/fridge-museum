import Foundation
import Testing
@testable import FridgeMuseum

struct GeometryTests {
    let quad = Quad(topLeft: .init(x: 0.12, y: 0.1), topRight: .init(x: 0.9, y: 0.15),
                    bottomRight: .init(x: 0.85, y: 0.92), bottomLeft: .init(x: 0.08, y: 0.85))

    @Test func orderingRecoversCornersFromAnyPermutation() throws {
        let pts = quad.points
        let perms = [[2, 0, 3, 1], [3, 2, 1, 0], [1, 3, 0, 2], [0, 1, 2, 3]]
        for p in perms {
            let ordered = try #require(CornerOrdering.order(p.map { pts[$0] }))
            #expect(ordered == quad)
        }
    }

    @Test func orderingNeedsFourPoints() {
        #expect(CornerOrdering.order([.init(x: 0, y: 0)]) == nil)
    }

    @Test func homographyMapsCorners() throws {
        let square = Quad.full.points
        let h = try #require(Homography(from: square, to: quad.points))
        for (a, b) in zip(square, quad.points) {
            let m = h.apply(a)
            #expect(abs(m.x - b.x) < 1e-9)
            #expect(abs(m.y - b.y) < 1e-9)
        }
        // Center of the square maps inside the quad.
        let c = h.apply(.init(x: 0.5, y: 0.5))
        #expect(c.x > 0.3 && c.x < 0.7 && c.y > 0.3 && c.y < 0.7)
    }

    @Test func homographyInverseRoundTrips() throws {
        let fwd = try #require(Homography(from: Quad.full.points, to: quad.points))
        let inv = try #require(Homography(from: quad.points, to: Quad.full.points))
        let p = NormPoint(x: 0.3, y: 0.7)
        let back = inv.apply(fwd.apply(p))
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
    }

    @Test func degenerateHomographyIsNil() {
        let line = [NormPoint(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 1, y: 0), .init(x: 0.2, y: 0)]
        #expect(Homography(from: Quad.full.points, to: line) == nil || Homography(from: line, to: Quad.full.points) == nil)
    }

    @Test func plausibility() {
        #expect(quad.isConvex)
        #expect(quad.isPlausible)
        #expect(Quad.full.area == 1)
        #expect(!Quad.inset(0.4).isPlausible)   // 0.2 × 0.2 = 4% of the frame
        let bowtie = Quad(topLeft: .init(x: 0, y: 0), topRight: .init(x: 1, y: 1),
                          bottomRight: .init(x: 1, y: 0), bottomLeft: .init(x: 0, y: 1))
        #expect(!bowtie.isConvex)
    }

    @Test func outputSizeCapsLongEdge() {
        let s = Quad.full.outputSize(imageWidth: 4000, imageHeight: 3000, maxEdge: 1600)
        #expect(s.width == 1600 && s.height == 1200)
        let small = Quad.full.outputSize(imageWidth: 800, imageHeight: 600, maxEdge: 1600)
        #expect(small.width == 800 && small.height == 600)
    }

    @Test func normRectMapsToParent() {
        let r = NormRect(x: 0.2, y: 0.1, width: 0.5, height: 0.4)
        #expect(r.toParent(.init(x: 0.5, y: 0.5)) == NormPoint(x: 0.45, y: 0.3))
    }

    @Test func subscriptSetsCorner() {
        var q = Quad.full
        q[2] = .init(x: 0.7, y: 0.8)
        #expect(q.bottomRight == NormPoint(x: 0.7, y: 0.8))
        #expect(q[2] == q.bottomRight)
    }
}
