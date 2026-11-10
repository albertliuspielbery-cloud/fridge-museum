import Foundation
import Testing
@testable import FridgeMuseum

/// 最近刪除 (1.4.0): days left and the 30-day purge.
struct TrashPolicyTests {
    private let deleted = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    @Test func notDeletedHasNoDaysAndNeverExpires() {
        #expect(TrashPolicy.daysLeft(deletedAt: nil, now: deleted) == nil)
        #expect(!TrashPolicy.isExpired(deletedAt: nil, now: deleted.addingTimeInterval(400 * day)))
    }

    @Test func countsDownFromThirtyLikePhotos() {
        #expect(TrashPolicy.daysLeft(deletedAt: deleted, now: deleted) == 30)
        #expect(TrashPolicy.daysLeft(deletedAt: deleted, now: deleted.addingTimeInterval(1)) == 30)
        #expect(TrashPolicy.daysLeft(deletedAt: deleted, now: deleted.addingTimeInterval(day)) == 29)
        #expect(TrashPolicy.daysLeft(deletedAt: deleted, now: deleted.addingTimeInterval(29.5 * day)) == 1)
        #expect(TrashPolicy.daysLeft(deletedAt: deleted, now: deleted.addingTimeInterval(31 * day)) == 0)
    }

    @Test func expiresAfterThirtyDays() {
        #expect(!TrashPolicy.isExpired(deletedAt: deleted, now: deleted.addingTimeInterval(30 * day - 1)))
        #expect(TrashPolicy.isExpired(deletedAt: deleted, now: deleted.addingTimeInterval(30 * day)))
    }

    @Test @MainActor func trashedArtworkLeavesTheMuseum() {
        let a = Artwork(kind: .flat, child: nil, capturedAt: deleted, originalImageData: Data())
        a.isKept = true
        #expect(a.isInMuseum && !a.isTrashed)
        a.deletedAt = deleted
        #expect(!a.isInMuseum && a.isTrashed)
        a.isSample = true
        #expect(!a.isInMuseum && !a.isTrashed)
    }

    @Test @MainActor func familyFieldsCarryDeletionAndAutoTags() {
        let a = Artwork(kind: .flat, child: nil, capturedAt: deleted, originalImageData: Data())
        a.deletedAt = deleted
        a.autoTags = ["動物", "紅色"]
        let fields = FamilyArtworkFields(a)
        #expect(fields.deletedAt == deleted)
        #expect(fields.autoTags == ["動物", "紅色"])
        let b = Artwork(kind: .flat, child: nil, capturedAt: deleted, originalImageData: Data())
        fields.apply(to: b, child: nil)
        #expect(b.deletedAt == deleted)
        #expect(b.autoTags == ["動物", "紅色"])
    }
}
