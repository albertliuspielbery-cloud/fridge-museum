import Foundation
import Testing
@testable import FridgeMuseum

/// 自動標籤 (1.4.0): colour tags from the fingerprint's hue histogram.
struct AutoTagsTests {
    private func hues(_ shares: [Int: Float]) -> [UInt8] {
        (0..<ArtFingerprint.hueBins).map { UInt8((shares[$0] ?? 0) * 255) }
    }

    @Test func mainColoursMostUsedFirst() {
        // Lots of blue (bins 6–8), some red (11 + 0), a little yellow.
        let keys = AutoTags.colorKeys(hues: hues([7: 0.20, 6: 0.05, 11: 0.04, 0: 0.04, 2: 0.035]))
        #expect(keys == ["blue", "red", "yellow"])
    }

    @Test func traceColoursAndGreyPagesGetNoTags() {
        #expect(AutoTags.colorKeys(hues: hues([:])).isEmpty)
        #expect(AutoTags.colorKeys(hues: hues([4: 0.02, 9: 0.01])).isEmpty)
    }

    @Test func atMostThreeColours() {
        let keys = AutoTags.colorKeys(hues: hues([0: 0.1, 1: 0.1, 2: 0.1, 4: 0.1, 7: 0.1, 9: 0.1]))
        #expect(keys.count == 3)
    }

    @Test func everyKeyHasAName() {
        for color in AutoTags.colors { #expect(AutoTags.name(for: color.key) != nil) }
        #expect(AutoTags.name(for: "nope") == nil)
    }
}
