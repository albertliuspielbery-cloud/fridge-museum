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
}
