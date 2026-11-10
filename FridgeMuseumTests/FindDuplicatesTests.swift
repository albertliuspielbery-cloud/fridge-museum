import Foundation
import Testing
@testable import FridgeMuseum

/// 找重複作品 (1.4.0): pairing the whole museum, and what the kept artwork takes over.
struct FindDuplicatesTests {
    private func entry(_ piece: CraftSketch.Piece, degrees: Double = 0, kind: ArtworkKind = .craft) throws -> DuplicateFinder.Entry {
        let fp = try #require(ArtFingerprint.make(CraftSketch.image(piece, on: .white, degrees: degrees)))
        return DuplicateFinder.Entry(id: UUID(), kindRaw: kind.rawValue, fingerprint: fp)
    }

    @Test func findsTheReshootAndNothingElse() throws {
        let cup = try entry(.cup), cupAgain = try entry(.cup, degrees: 4)
        let entries = [cup, try entry(.ball), cupAgain, try entry(.robot)]
        let pairs = DuplicateFinder.pairs(among: entries)
        #expect(pairs == [DuplicateFinder.Pair(cup.id, cupAgain.id)])
    }

    @Test func onlyComparesTheSameKind() throws {
        let cup = try entry(.cup), cupAsDrawing = try entry(.cup, kind: .flat)
        #expect(DuplicateFinder.pairs(among: [cup, cupAsDrawing]).isEmpty)
    }

    @Test func remembersNotADuplicateEitherWayRound() throws {
        let a = try entry(.ball), b = try entry(.ball, degrees: 3)
        let pair = DuplicateFinder.Pair(b.id, a.id)
        #expect(pair == DuplicateFinder.Pair(a.id, b.id))
        #expect(DuplicateFinder.pairs(among: [a, b], ignoring: [pair.key]).isEmpty)
    }

    @Test @MainActor func keptArtworkTakesOverWhatOnlyTheOtherHad() {
        let keep = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data())
        let other = Artwork(kind: .flat, child: nil, capturedAt: Date(), originalImageData: Data())
        keep.title = "我的家"
        keep.tags = ["家人"]
        other.title = "別的名字"
        other.note = "這是爸爸"
        other.tags = ["家人", "生日"]
        other.isFavorite = true
        other.voiceNoteData = Data([1, 2])
        other.voiceTranscript = "爸爸"
        DuplicateMerge.fill(keep, from: other)
        #expect(keep.title == "我的家")
        #expect(keep.note == "這是爸爸")
        #expect(keep.tags == ["家人", "生日"])
        #expect(keep.isFavorite)
        #expect(keep.voiceNoteData == Data([1, 2]) && keep.voiceTranscript == "爸爸")
        #expect(keep.modifiedAt != nil)
    }
}
