import Foundation
import Testing
@testable import FridgeMuseum

struct RecipeCodableTests {
    @Test func roundTrip() throws {
        var r = ProcessingRecipe(kind: .craft)
        r.corners = Quad(topLeft: .init(x: 0.1, y: 0.12), topRight: .init(x: 0.9, y: 0.1),
                         bottomRight: .init(x: 0.88, y: 0.95), bottomLeft: .init(x: 0.12, y: 0.9))
        r.strength = 0.3
        r.protect = 0.5
        r.vivid = 0.7
        r.removeSpecks = false
        r.sensitivity = 0.8
        r.background = .gradient
        r.shadow = false
        r.caption = true
        r.strokes = [
            BrushStroke(mode: .erase, radius: 0.018, points: [.init(x: 0.2, y: 0.3), .init(x: 0.25, y: 0.35)]),
            BrushStroke(mode: .restore, radius: 0.01, points: [.init(x: 0.5, y: 0.5)]),
        ]
        let data = try r.encoded()
        let back = try ProcessingRecipe.decode(data)
        #expect(back == r)
    }

    @Test func missingKeysUseDefaults() throws {
        let r = try ProcessingRecipe.decode(Data(#"{"kind":"craft"}"#.utf8))
        #expect(r.kind == .craft)
        #expect(r.strength == 0.6)
        #expect(r.protect == 0.85)
        #expect(r.vivid == 0.15)
        #expect(r.removeSpecks)
        #expect(r.shadow)
        #expect(r.background == .white)
        #expect(r.corners == nil)
        #expect(r.strokes.isEmpty)
        #expect(r.version == ProcessingRecipe.currentVersion)
    }

    @Test func emptyObjectIsDefaultFlat() throws {
        #expect(try ProcessingRecipe.decode(Data("{}".utf8)) == ProcessingRecipe.default(for: .flat))
    }

    @Test func unknownBackgroundFallsBackToWhite() throws {
        let r = try ProcessingRecipe.decode(Data(#"{"background":"sparkles"}"#.utf8))
        #expect(r.background == .white)
    }

    @Test func activeStrokesDependOnKind() {
        var r = ProcessingRecipe(kind: .flat)
        r.strokes = [
            BrushStroke(mode: .paintWhite, radius: 0.01, points: [.init(x: 0, y: 0)]),
            BrushStroke(mode: .erase, radius: 0.01, points: [.init(x: 0, y: 0)]),
        ]
        #expect(r.activeStrokes.map(\.mode) == [.paintWhite])
        r.kind = .craft
        #expect(r.activeStrokes.map(\.mode) == [.erase])
    }

    @Test func colorHex() {
        let c = RGBColor(hex: "#2F5BFF")
        #expect(c?.hex == "#2F5BFF")
        #expect(RGBColor(hex: "nope") == nil)
    }
}
