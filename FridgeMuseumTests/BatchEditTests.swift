import Foundation
import SwiftData
import Testing
@testable import FridgeMuseum

/// 美術館「選取」: one change applied to several artworks at once (AppModel+Batch).
@MainActor
struct BatchEditTests {
    private func makeArtworks(_ n: Int, in context: ModelContext) -> [Artwork] {
        (0..<n).map { _ in
            let a = Artwork(kind: .flat, child: nil, capturedAt: day(2026, 10, 28), originalImageData: Data([0, 1, 2]))
            context.insert(a)
            return a
        }
    }

    @Test func assignsAChildAndSkipsDeletedArtworks() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let mia = Child(name: "Mia")
        context.insert(mia)
        let list = makeArtworks(3, in: context)
        try context.save()
        app.delete(list[1], context: context)

        #expect(app.assignChild(mia, to: list, context: context) == 2)
        #expect(list[0].child?.id == mia.id)
        #expect(list[2].child?.id == mia.id)

        #expect(app.assignChild(nil, to: list, context: context) == 2)
        #expect(list[0].child == nil)
        #expect(list[2].child == nil)
    }

    @Test func addsTagsWithoutDuplicatesAndKeepsExistingOnes() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let list = makeArtworks(2, in: context)
        list[0].tags = ["家人"]
        try context.save()

        #expect(app.addTags(["#動物", " 家人 ", "動物"], to: list, context: context) == 2)
        #expect(list[0].tags == ["家人", "動物"])
        #expect(list[1].tags == ["動物", "家人"])
        #expect(app.addTags(["  ", "#"], to: list, context: context) == 0)
    }

    @Test func setsTheDateWhichMovesTheSemester() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let list = makeArtworks(2, in: context)
        try context.save()
        let before = list[0].schoolTerm
        let march = day(2026, 3, 10)

        #expect(app.setCapturedAt(march, for: list, context: context) == 2)
        let allMoved = list.allSatisfy { $0.capturedAt == march }
        #expect(allMoved)
        #expect(list[0].schoolTerm == SchoolTerm.of(march))
        #expect(list[0].schoolTerm != before)
    }

    @Test func togglesFavoritesOnAndOff() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let list = makeArtworks(3, in: context)
        try context.save()

        #expect(app.setFavorite(true, for: list, context: context) == 3)
        let allFavorite = list.allSatisfy { $0.isFavorite }
        #expect(allFavorite)
        #expect(app.setFavorite(false, for: Array(list.prefix(2)), context: context) == 2)
        #expect(!list[0].isFavorite && !list[1].isFavorite && list[2].isFavorite)
    }

    @Test func deletesAllOnceAndForgetsThemFromThisVisit() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let list = makeArtworks(3, in: context)
        try context.save()
        let keepID = list[2].id
        app.sessionArtworkIDs = list.map(\.id)

        #expect(app.deleteAll(Array(list.prefix(2)), context: context) == 2)
        #expect(!AppModel.isAlive(list[0]) && !AppModel.isAlive(list[1]))
        #expect(app.sessionArtworkIDs == [keepID])
        let left = try context.fetch(FetchDescriptor<Artwork>())
        let leftIDs = left.map { $0.id }
        #expect(leftIDs == [keepID])
        // Already gone: nothing to delete.
        #expect(app.deleteAll(Array(list.prefix(2)), context: context) == 0)
    }

    @Test func nothingAliveMeansNoChange() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let list = makeArtworks(1, in: context)
        try context.save()
        app.delete(list[0], context: context)

        #expect(app.setFavorite(true, for: list, context: context) == 0)
        #expect(app.assignChild(nil, to: [], context: context) == 0)
    }

    // MARK: 轉向

    /// A quarter turn for each selected artwork, the automatic check settled, edit time bumped, and the re-render
    /// queued (held while an editor is open — the drain then runs them one at a time).
    @Test func rotatesSelectedArtworksAndQueuesTheirRenders() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let list = makeArtworks(3, in: context)
        for a in list {
            a.renderedImageData = Data([9])
            a.processingState = .done
            a.modifiedAt = day(2026, 1, 1)
        }
        try context.save()
        app.delete(list[2], context: context)
        app.beginEditing(UUID())                                   // hold the queue so we can look at it

        #expect(app.rotateAll(list, clockwise: true, context: context) == 2)
        for a in list.prefix(2) {
            #expect(a.recipe.quarterTurns == 1)
            #expect(a.recipe.autoTurns == 0)
            #expect(!AppModel.owesOrientationCheck(a))
            #expect((a.modifiedAt ?? .distantPast) > day(2026, 1, 1))
            #expect(a.processingState == .pending)                  // owed a re-render, not started yet
            #expect(app.isQueuedForRender(a.id))                    // the museum shows its spinner
        }
        #expect(app.rotateAll(list, clockwise: false, context: context) == 2)
        #expect(app.rotateAll(list, clockwise: false, context: context) == 2)
        #expect(list[0].recipe.quarterTurns == 3)
        #expect(app.rotateAll([], clockwise: true, context: context) == 0)
    }

    /// Once the editor closes, the queued turns render one at a time and the spinners go away. (The test data
    /// isn't a real image, so each render ends as `.failed` — that's how we see it ran.)
    @Test func queuedTurnsRenderAfterTheEditorCloses() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let list = makeArtworks(2, in: context)
        for a in list {
            a.renderedImageData = Data([9])
            a.processingState = .done
        }
        try context.save()
        let editor = UUID()
        app.beginEditing(editor)
        #expect(app.rotateAll(list, clockwise: true, context: context) == 2)
        app.endEditing(editor, context: context)
        for _ in 0..<600 where list.contains(where: { $0.processingState != .failed }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(list.allSatisfy { $0.processingState == .failed })
        #expect(list.allSatisfy { !app.isQueuedForRender($0.id) })
    }

    @Test func turningKeepsAnEarlierAutomaticResult() {
        var r = ProcessingRecipe(kind: .flat)
        r.quarterTurns = 1
        r.autoTurns = 1
        let t = AppModel.turned(r, clockwise: true)
        #expect(t.quarterTurns == 2 && t.autoTurns == 1 && !t.isAutoTurned)
        let fresh = AppModel.turned(ProcessingRecipe(kind: .craft), clockwise: false)
        #expect(fresh.quarterTurns == 3 && fresh.autoTurns == 0)
    }
}
