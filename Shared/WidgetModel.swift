import Foundation

// 主畫面小工具 (1.3.0): everything the app and the widget extension must agree on — the App Group, the files in it,
// the JSON model, which artworks go in, and when the widget shows which one. Compiled into BOTH targets
// (project.yml: FridgeMuseum + FridgeMuseumWidget), so it uses Foundation only and no app types.
// Pure logic is unit-tested in FridgeMuseumTests/WidgetModelTests.swift.

enum WidgetShared {
    /// Created by hand in the developer portal and enabled on both App IDs (HANDOFF.md「1.3.0 主畫面小工具」).
    static let appGroupID = "group.tw.starlight.fridgemuseum"
    static let manifestFileName = "widget.json"
    static let imagesFolderName = "WidgetImages"
    /// At most this many artworks are copied for the widget.
    static let maxArtworks = 24
    /// Long side of the copied JPEGs (the large widget is ~360 pt wide; the extension has a ~30 MB memory limit).
    static let maxImageEdge = 600
    /// The widget shows another artwork every 3 hours.
    static let rotationHours = 3
    static let urlScheme = "fridgemuseum"

    /// The App Group container, or nil when the build has no App Group entitlement (unsigned simulator builds,
    /// a profile without the group). Callers then skip everything silently.
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// `fridgemuseum://artwork/<uuid>` — opens that artwork in the app.
    static func artworkURL(_ id: UUID) -> URL {
        URL(string: "\(urlScheme)://artwork/\(id.uuidString)")!
    }

    /// The artwork id from a widget link, or nil for any other URL.
    static func artworkID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == urlScheme, url.host?.lowercased() == "artwork" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1 else { return nil }
        return UUID(uuidString: parts[0])
    }
}

/// One artwork as the widget sees it (widget.json).
struct WidgetArtwork: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: UUID
    /// The child's display name; nil = 未分類.
    var childName: String?
    var capturedAt: Date
    /// `ArtworkKind.rawValue` ("flat" / "craft").
    var kind: String
    /// File name inside `WidgetShared.imagesFolderName`.
    var imageFile: String

    /// Image files are keyed by render version, so a re-render writes a new file (and the old one is removed).
    static func imageFileName(id: UUID, renderVersion: Int) -> String {
        "\(id.uuidString)-\(renderVersion).jpg"
    }
}

/// widget.json: the artworks in display order.
struct WidgetManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = WidgetManifest.currentVersion
    var generatedAt: Date
    var artworks: [WidgetArtwork]

    static let empty = WidgetManifest(generatedAt: .distantPast, artworks: [])

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    /// nil for missing, damaged or newer-than-understood files (the widget then shows the empty state).
    static func decode(_ data: Data) -> WidgetManifest? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let m = try? d.decode(WidgetManifest.self, from: data), m.version <= currentVersion else { return nil }
        return m
    }

    /// Image files no longer referenced by this manifest (to delete after the manifest is written).
    func staleFiles(in existing: [String]) -> [String] {
        let keep = Set(artworks.map(\.imageFile))
        return existing.filter { !keep.contains($0) }.sorted()
    }
}

/// Which museum artworks go into the widget.
enum WidgetSelection {
    struct Candidate: Equatable, Sendable {
        var id: UUID
        var childName: String?
        var capturedAt: Date
        var kind: String
        var renderVersion: Int
        var isFavorite: Bool
        /// Kept and not a sample (`Artwork.isInMuseum`).
        var isInMuseum: Bool
    }

    /// Favourites first, then the newest (by the date the artwork was made), id as the tie-break: always the same order.
    static func prioritized(_ candidates: [Candidate]) -> [Candidate] {
        candidates.filter(\.isInMuseum).sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            if a.capturedAt != b.capturedAt { return a.capturedAt > b.capturedAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// The first `limit` prioritized candidates that have an image. `hasImage` is asked lazily, in priority order,
    /// and only until `limit` are found (the app's check reads image data).
    static func select(_ candidates: [Candidate], limit: Int = WidgetShared.maxArtworks,
                       hasImage: (Candidate) -> Bool) -> [Candidate] {
        guard limit > 0 else { return [] }
        var picked: [Candidate] = []
        for c in prioritized(candidates) where hasImage(c) {
            picked.append(c)
            if picked.count == limit { break }
        }
        return displayOrder(picked)
    }

    /// The order the widget rotates through: newest first, id as the tie-break (favourites only decide who gets in).
    static func displayOrder(_ picked: [Candidate]) -> [Candidate] {
        picked.sorted { a, b in
            if a.capturedAt != b.capturedAt { return a.capturedAt > b.capturedAt }
            return a.id.uuidString < b.id.uuidString
        }
    }
}

/// When the widget shows which artwork: one slot every `rotationHours` (00:00, 03:00, … local time). Slot n of the
/// calendar shows artwork (n mod count), so the pick depends only on the date — the same on every refresh — and
/// walks through the whole list.
enum WidgetSchedule {
    struct Entry: Equatable, Sendable {
        var date: Date
        /// Index into the manifest's artworks; nil = nothing to show (empty state).
        var index: Int?
    }

    static var slotsPerDay: Int { 24 / WidgetShared.rotationHours }

    /// Start of the slot containing `date`.
    static func slotStart(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        let slotHour = hour / WidgetShared.rotationHours * WidgetShared.rotationHours
        return calendar.date(bySettingHour: slotHour, minute: 0, second: 0, of: day) ?? day
    }

    /// Start of the slot after the one starting at `start` (wall clock: 03:00 after 00:00 even across a DST change).
    static func nextSlotStart(after start: Date, calendar: Calendar) -> Date {
        let step = WidgetShared.rotationHours
        let fallback = start.addingTimeInterval(TimeInterval(step * 3600))
        let day = calendar.startOfDay(for: start)
        let nextHour = calendar.component(.hour, from: start) / step * step + step
        let next = nextHour >= 24
            ? calendar.date(byAdding: .day, value: 1, to: day)
            : calendar.date(bySettingHour: nextHour, minute: 0, second: 0, of: day)
        guard let next, next > start else { return fallback }
        return next
    }

    /// Global slot number (days since 2001-01-01 in `calendar` × slots per day + slot of the day). DST-safe: it
    /// counts calendar days and wall-clock hours, not seconds.
    static func slotNumber(for date: Date, calendar: Calendar) -> Int {
        let day = calendar.startOfDay(for: date)
        var refComps = DateComponents()
        refComps.year = 2001; refComps.month = 1; refComps.day = 1
        let ref = calendar.date(from: refComps) ?? Date(timeIntervalSinceReferenceDate: 0)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: ref), to: day).day ?? 0
        let slot = calendar.component(.hour, from: date) / WidgetShared.rotationHours
        return days * slotsPerDay + slot
    }

    static func index(for date: Date, count: Int, calendar: Calendar) -> Int? {
        guard count > 0 else { return nil }
        let n = slotNumber(for: date, calendar: calendar) % count
        return n < 0 ? n + count : n
    }

    /// Timeline entries from `now`: the current slot (dated `now`), then the next `horizon - 1` slot starts.
    /// 0 or 1 artworks → a single entry (nothing to rotate; the app reloads the widget when that changes).
    static func entries(now: Date, count: Int, calendar: Calendar, horizon: Int = slotsPerDay) -> [Entry] {
        guard count > 1, horizon > 1 else { return [Entry(date: now, index: index(for: now, count: count, calendar: calendar))] }
        var result = [Entry(date: now, index: index(for: now, count: count, calendar: calendar))]
        var start = slotStart(for: now, calendar: calendar)
        while result.count < horizon {
            start = nextSlotStart(after: start, calendar: calendar)
            result.append(Entry(date: start, index: index(for: start, count: count, calendar: calendar)))
        }
        return result
    }
}
