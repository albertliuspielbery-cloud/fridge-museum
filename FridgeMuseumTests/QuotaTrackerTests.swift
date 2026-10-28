import Foundation
import Testing
@testable import FridgeMuseum

@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(hours: Double) { now = now.addingTimeInterval(hours * 3600) }
}

@MainActor
struct QuotaTrackerTests {
    let taipei: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    func taipeiTime(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        taipei.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func freshDefaults() -> UserDefaults {
        let name = "QuotaTrackerTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func makeTracker(clock: TestClock, defaults: UserDefaults?, unlocked: @escaping @MainActor () -> Bool = { false }) -> QuotaTracker {
        QuotaTracker(isUnlocked: unlocked, defaults: defaults, now: { clock.now }, calendar: taipei)
    }

    @Test func constantsMatchWebPrototype() {
        #expect(QuotaTracker.freeFlatPerDay == 3)
        #expect(QuotaTracker.craftFreeTrial == 3)
    }

    @Test func threeFlatPerDayThenBlocked() {
        let clock = TestClock(taipeiTime(2026, 10, 28, 10))
        let q = makeTracker(clock: clock, defaults: freshDefaults())
        #expect(q.remainingFlatToday == 3)
        for _ in 0..<3 {
            let id = UUID()
            #expect(q.canKeep(kind: .flat, artworkID: id))
            q.recordKeep(kind: .flat, artworkID: id)
        }
        #expect(q.remainingFlatToday == 0)
        #expect(!q.canKeep(kind: .flat, artworkID: UUID()))
        // Crafts have their own trial.
        #expect(q.canKeep(kind: .craft, artworkID: UUID()))
    }

    @Test func flatResetsAtLocalMidnight() {
        let clock = TestClock(taipeiTime(2026, 10, 28, 23, 58))
        let q = makeTracker(clock: clock, defaults: freshDefaults())
        for _ in 0..<3 { q.recordKeep(kind: .flat, artworkID: UUID()) }
        #expect(q.remainingFlatToday == 0)
        clock.now = taipeiTime(2026, 10, 28, 23, 59)
        #expect(q.remainingFlatToday == 0)
        clock.now = taipeiTime(2026, 10, 29, 0, 1)
        #expect(q.remainingFlatToday == 3)
        #expect(q.canKeep(kind: .flat, artworkID: UUID()))
        q.recordKeep(kind: .flat, artworkID: UUID())
        #expect(q.remainingFlatToday == 2)
    }

    @Test func refreshRollsOverStoredDay() {
        let defaults = freshDefaults()
        let clock = TestClock(taipeiTime(2026, 10, 28, 12))
        let q = makeTracker(clock: clock, defaults: defaults)
        q.recordKeep(kind: .flat, artworkID: UUID())
        clock.advance(hours: 24)
        q.refresh()
        #expect(q.remainingFlatToday == 3)
        #expect(defaults.integer(forKey: QuotaTracker.Keys.flatCount) == 0)
        #expect(defaults.string(forKey: QuotaTracker.Keys.flatDay) == "2026-10-29")
    }

    @Test func craftTrialIsLifetime() {
        let clock = TestClock(taipeiTime(2026, 10, 28, 9))
        let q = makeTracker(clock: clock, defaults: freshDefaults())
        for _ in 0..<3 { q.recordKeep(kind: .craft, artworkID: UUID()) }
        #expect(q.remainingCraftTrial == 0)
        clock.advance(hours: 24 * 30)
        q.refresh()
        #expect(q.remainingCraftTrial == 0)
        #expect(!q.canKeep(kind: .craft, artworkID: UUID()))
        #expect(q.canKeep(kind: .flat, artworkID: UUID()))
    }

    @Test func recordKeepIsIdempotentPerArtwork() {
        let clock = TestClock(taipeiTime(2026, 10, 28, 9))
        let q = makeTracker(clock: clock, defaults: freshDefaults())
        let id = UUID()
        q.recordKeep(kind: .flat, artworkID: id)   // hang it up
        q.recordKeep(kind: .flat, artworkID: id)   // then save to Photos
        q.recordKeep(kind: .flat, artworkID: id)   // re-save after re-edit
        #expect(q.remainingFlatToday == 2)
        #expect(q.hasCounted(artworkID: id))
    }

    @Test func alreadyCountedArtworkCanAlwaysBeKeptAgain() {
        let clock = TestClock(taipeiTime(2026, 10, 28, 9))
        let q = makeTracker(clock: clock, defaults: freshDefaults())
        let first = UUID()
        q.recordKeep(kind: .flat, artworkID: first)
        for _ in 0..<2 { q.recordKeep(kind: .flat, artworkID: UUID()) }
        #expect(!q.canKeep(kind: .flat, artworkID: UUID()))
        #expect(q.canKeep(kind: .flat, artworkID: first))
        // Even on a later day it doesn't count again.
        clock.advance(hours: 24)
        q.recordKeep(kind: .flat, artworkID: first)
        #expect(q.remainingFlatToday == 3)
    }

    @Test func samplesNeverCount() {
        let clock = TestClock(taipeiTime(2026, 10, 28, 9))
        let q = makeTracker(clock: clock, defaults: freshDefaults())
        for _ in 0..<3 { q.recordKeep(kind: .flat, artworkID: UUID()) }
        let sample = UUID()
        #expect(q.canKeep(kind: .flat, artworkID: sample, isSample: true))
        q.recordKeep(kind: .craft, artworkID: sample, isSample: true)
        #expect(q.remainingCraftTrial == 3)
        #expect(!q.hasCounted(artworkID: sample))
    }

    @Test func unlockedBypassesQuota() {
        let clock = TestClock(taipeiTime(2026, 10, 28, 9))
        var unlocked = false
        let q = makeTracker(clock: clock, defaults: freshDefaults(), unlocked: { unlocked })
        for _ in 0..<3 { q.recordKeep(kind: .flat, artworkID: UUID()) }
        for _ in 0..<3 { q.recordKeep(kind: .craft, artworkID: UUID()) }
        #expect(!q.canKeep(kind: .flat, artworkID: UUID()))
        unlocked = true
        #expect(q.isTracking == false)
        #expect(q.canKeep(kind: .flat, artworkID: UUID()))
        #expect(q.canKeep(kind: .craft, artworkID: UUID()))
        // Keeps while unlocked don't use up counters.
        let keptWhileUnlocked = UUID()
        q.recordKeep(kind: .flat, artworkID: keptWhileUnlocked)
        unlocked = false   // refund / revocation re-locks
        #expect(q.remainingFlatToday == 0)
        #expect(q.canKeep(kind: .flat, artworkID: keptWhileUnlocked))
        #expect(!q.canKeep(kind: .flat, artworkID: UUID()))
    }

    @Test func storageUnavailableNeverBlocks() {
        let clock = TestClock(taipeiTime(2026, 10, 28, 9))
        let q = makeTracker(clock: clock, defaults: nil)
        for _ in 0..<10 {
            let id = UUID()
            #expect(q.canKeep(kind: .craft, artworkID: id))
            q.recordKeep(kind: .craft, artworkID: id)
        }
        #expect(q.isTracking == false)
    }

    @Test func persistsAcrossLaunches() {
        let defaults = freshDefaults()
        let clock = TestClock(taipeiTime(2026, 10, 28, 9))
        let id = UUID()
        do {
            let q = makeTracker(clock: clock, defaults: defaults)
            q.recordKeep(kind: .flat, artworkID: id)
            q.recordKeep(kind: .craft, artworkID: UUID())
        }
        let q2 = makeTracker(clock: clock, defaults: defaults)
        #expect(q2.remainingFlatToday == 2)
        #expect(q2.remainingCraftTrial == 2)
        #expect(q2.hasCounted(artworkID: id))
        q2.recordKeep(kind: .flat, artworkID: id)
        #expect(q2.remainingFlatToday == 2)
    }

    @Test func dayKeyUsesTheGivenCalendar() {
        // 2026-10-28 17:30 UTC is already 2026-10-29 in Taipei (UTC+8).
        let date = utc.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 17, minute: 30))!
        #expect(QuotaTracker.dayKey(for: date, calendar: utc) == "2026-10-28")
        #expect(QuotaTracker.dayKey(for: date, calendar: taipei) == "2026-10-29")
    }
}

struct EntitlementPolicyTests {
    let id = PurchaseStore.fullProductID
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ownPurchaseUnlocks() {
        #expect(EntitlementPolicy.grantsFull(EntitlementFacts(productID: id, revocationDate: nil, expirationDate: nil, isFamilyShared: false), now: now))
    }

    @Test func familySharedUnlocks() {
        #expect(EntitlementPolicy.grantsFull(EntitlementFacts(productID: id, revocationDate: nil, expirationDate: nil, isFamilyShared: true), now: now))
    }

    @Test func refundedOrRevokedRelocks() {
        let revoked = EntitlementFacts(productID: id, revocationDate: now.addingTimeInterval(-60), expirationDate: nil, isFamilyShared: false)
        #expect(!EntitlementPolicy.grantsFull(revoked, now: now))
        let sharedRevoked = EntitlementFacts(productID: id, revocationDate: now, expirationDate: nil, isFamilyShared: true)
        #expect(!EntitlementPolicy.grantsFull(sharedRevoked, now: now))
    }

    @Test func otherProductOrExpiredDoesNotUnlock() {
        #expect(!EntitlementPolicy.grantsFull(EntitlementFacts(productID: "other", revocationDate: nil, expirationDate: nil, isFamilyShared: false), now: now))
        #expect(!EntitlementPolicy.grantsFull(EntitlementFacts(productID: id, revocationDate: nil, expirationDate: now.addingTimeInterval(-1), isFamilyShared: false), now: now))
    }

    @Test func productIDMatchesAppStoreConnect() {
        #expect(PurchaseStore.fullProductID == "tw.starlight.fridgemuseum.full")
    }
}
