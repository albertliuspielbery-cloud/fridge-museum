import Foundation
import Testing
@testable import FridgeMuseum

/// 主畫面小工具: the shared model (Shared/WidgetModel.swift) — links, widget.json, which artworks get in, rotation.
struct WidgetModelTests {
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012ld", n))!
    }

    static var taipei: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, calendar: Calendar = taipei) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static func candidate(_ n: Int, day: Int, favorite: Bool = false, inMuseum: Bool = true) -> WidgetSelection.Candidate {
        WidgetSelection.Candidate(id: uuid(n), childName: "小明", capturedAt: date(2026, 10, day), kind: "flat",
                                  renderVersion: 1, isFavorite: favorite, isInMuseum: inMuseum)
    }

    // MARK: Links

    @Test func artworkLinkRoundTrips() {
        let id = Self.uuid(42)
        let url = WidgetShared.artworkURL(id)
        #expect(url.absoluteString == "fridgemuseum://artwork/\(id.uuidString)")
        #expect(WidgetShared.artworkID(from: url) == id)
    }

    @Test func otherLinksAreIgnored() {
        let id = Self.uuid(1).uuidString
        let urls = ["https://artwork/\(id)", "fridgemuseum://museum/\(id)", "fridgemuseum://artwork/not-a-uuid",
                    "fridgemuseum://artwork/", "fridgemuseum://artwork/\(id)/extra"]
        for s in urls {
            let url = URL(string: s)!
            #expect(WidgetShared.artworkID(from: url) == nil, "\(s)")
        }
    }

    @Test func linkAcceptsLowercaseUUID() {
        let id = Self.uuid(7)
        let url = URL(string: "fridgemuseum://artwork/\(id.uuidString.lowercased())")!
        #expect(WidgetShared.artworkID(from: url) == id)
    }

    // MARK: widget.json

    @Test func manifestRoundTrips() throws {
        let a = WidgetArtwork(id: Self.uuid(1), childName: "小美", capturedAt: Self.date(2026, 11, 3, 9, 30), kind: "craft",
                              imageFile: WidgetArtwork.imageFileName(id: Self.uuid(1), renderVersion: 3))
        let b = WidgetArtwork(id: Self.uuid(2), childName: nil, capturedAt: Self.date(2026, 1, 1), kind: "flat",
                              imageFile: WidgetArtwork.imageFileName(id: Self.uuid(2), renderVersion: 0))
        let m = WidgetManifest(generatedAt: Self.date(2026, 11, 3, 10), artworks: [a, b])
        let data = try m.encoded()
        let back = WidgetManifest.decode(data)
        #expect(back == m)
        #expect(a.imageFile == "\(Self.uuid(1).uuidString)-3.jpg")
    }

    @Test func damagedOrNewerManifestIsIgnored() throws {
        #expect(WidgetManifest.decode(Data("not json".utf8)) == nil)
        var future = WidgetManifest(generatedAt: Self.date(2026, 11, 3), artworks: [])
        future.version = WidgetManifest.currentVersion + 1
        let data = try future.encoded()
        #expect(WidgetManifest.decode(data) == nil)
    }

    @Test func staleFilesAreTheUnreferencedOnes() {
        let keep = WidgetArtwork(id: Self.uuid(1), childName: nil, capturedAt: Self.date(2026, 1, 1), kind: "flat",
                                 imageFile: "a-2.jpg")
        let m = WidgetManifest(generatedAt: Self.date(2026, 1, 1), artworks: [keep])
        #expect(m.staleFiles(in: ["a-1.jpg", "a-2.jpg", "b-0.jpg"]) == ["a-1.jpg", "b-0.jpg"])
        #expect(WidgetManifest.empty.staleFiles(in: ["x.jpg"]) == ["x.jpg"])
    }

    // MARK: Selection

    @Test func onlyMuseumArtworksWithImagesGetIn() {
        let all = [Self.candidate(1, day: 1), Self.candidate(2, day: 2, inMuseum: false), Self.candidate(3, day: 3)]
        let picked = WidgetSelection.select(all) { $0.id != Self.uuid(3) }
        #expect(picked.map(\.id) == [Self.uuid(1)])
    }

    @Test func atMost24NewestWithFavouritesFirst() {
        var all = (1...40).map { Self.candidate($0, day: min($0, 28)) }
        all.append(Self.candidate(99, day: 1, favorite: true))   // old, but a favourite
        let picked = WidgetSelection.select(all) { _ in true }
        #expect(picked.count == WidgetShared.maxArtworks)
        #expect(picked.contains { $0.id == Self.uuid(99) })
        #expect(!picked.contains { $0.id == Self.uuid(1) })
        // Display order: newest first, the old favourite last.
        #expect(picked.last?.id == Self.uuid(99))
        let dates = picked.map(\.capturedAt)
        #expect(dates == dates.sorted(by: >))
    }

    @Test func imageCheckStopsOnceFull() {
        let all = (1...100).map { Self.candidate($0, day: 1 + $0 % 28) }
        var asked = 0
        let picked = WidgetSelection.select(all, limit: 5) { _ in asked += 1; return true }
        #expect(picked.count == 5)
        #expect(asked == 5)
    }

    @Test func selectionOrderIsStable() {
        let all = (1...10).map { Self.candidate($0, day: 5) }   // same date: id decides
        let a = WidgetSelection.select(all) { _ in true }.map(\.id)
        let b = WidgetSelection.select(all.reversed()) { _ in true }.map(\.id)
        #expect(a == b)
        #expect(a.first == Self.uuid(1))
    }

    // MARK: Rotation

    @Test func slotsStartEveryThreeHours() {
        let cal = Self.taipei
        #expect(WidgetSchedule.slotStart(for: Self.date(2026, 11, 3, 10, 45), calendar: cal) == Self.date(2026, 11, 3, 9))
        #expect(WidgetSchedule.slotStart(for: Self.date(2026, 11, 3, 0, 0), calendar: cal) == Self.date(2026, 11, 3, 0))
        #expect(WidgetSchedule.slotStart(for: Self.date(2026, 11, 3, 23, 59), calendar: cal) == Self.date(2026, 11, 3, 21))
    }

    @Test func pickDependsOnlyOnTheSlot() {
        let cal = Self.taipei
        let a = WidgetSchedule.index(for: Self.date(2026, 11, 3, 9, 1), count: 7, calendar: cal)
        let b = WidgetSchedule.index(for: Self.date(2026, 11, 3, 11, 59), count: 7, calendar: cal)
        let c = WidgetSchedule.index(for: Self.date(2026, 11, 3, 12, 0), count: 7, calendar: cal)
        #expect(a == b)
        #expect(a != c)
        #expect(WidgetSchedule.index(for: Self.date(2026, 11, 3), count: 0, calendar: cal) == nil)
    }

    @Test func aDayWalksThroughTheList() {
        let cal = Self.taipei
        let entries = WidgetSchedule.entries(now: Self.date(2026, 11, 3, 0, 0), count: 24, calendar: cal)
        #expect(entries.count == 8)
        let indices = entries.compactMap(\.index)
        #expect(Set(indices).count == 8)
        // Consecutive slots show consecutive artworks (mod count) — and the next day carries on.
        for (x, y) in zip(indices, indices.dropFirst()) { #expect(y == (x + 1) % 24) }
        let tomorrow = WidgetSchedule.index(for: Self.date(2026, 11, 4, 0, 0), count: 24, calendar: cal)
        #expect(tomorrow == ((indices.last ?? 0) + 1) % 24)
    }

    @Test func entriesStartNowThenOnSlotBoundaries() {
        let cal = Self.taipei
        let now = Self.date(2026, 11, 3, 10, 20)
        let entries = WidgetSchedule.entries(now: now, count: 5, calendar: cal)
        #expect(entries.first?.date == now)
        #expect(entries.first?.index == WidgetSchedule.index(for: now, count: 5, calendar: cal))
        let rest = entries.dropFirst().map(\.date)
        #expect(rest.first == Self.date(2026, 11, 3, 12))
        #expect(rest.last == Self.date(2026, 11, 4, 6))
        for (x, y) in zip(rest, rest.dropFirst()) { #expect(y.timeIntervalSince(x) == 3 * 3600) }
    }

    @Test func zeroOrOneArtworkIsASingleEntry() {
        let cal = Self.taipei
        let now = Self.date(2026, 11, 3, 10)
        let none = WidgetSchedule.entries(now: now, count: 0, calendar: cal)
        #expect(none == [WidgetSchedule.Entry(date: now, index: nil)])
        let one = WidgetSchedule.entries(now: now, count: 1, calendar: cal)
        #expect(one == [WidgetSchedule.Entry(date: now, index: 0)])
    }

    @Test func daylightSavingKeepsWallClockSlots() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08: clocks jump 02:00 → 03:00. 2026-11-01: 02:00 → 01:00.
        for day in [Self.date(2026, 3, 8, calendar: cal), Self.date(2026, 11, 1, calendar: cal)] {
            let entries = WidgetSchedule.entries(now: day, count: 9, calendar: cal)
            let hours = entries.map { cal.component(.hour, from: $0.date) }
            #expect(hours == [0, 3, 6, 9, 12, 15, 18, 21])
            let indices = entries.compactMap(\.index)
            #expect(Set(indices).count == 8)
        }
    }
}
