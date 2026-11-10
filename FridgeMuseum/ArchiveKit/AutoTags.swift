import Foundation

/// 自動標籤 (1.4.0): the main crayon colours of an artwork, read from its fingerprint's hue histogram (no extra image
/// work, nothing leaves the device). Stored as language-neutral keys in `Artwork.autoTags` and shown in the device
/// language. Subject tags (人物、動物…) wait for on-device testing: Apple's classifier only returns placeholder labels
/// in the Simulator, so their accuracy on children's drawings couldn't be checked in CI.
enum AutoTags {
    /// Keys in display order. Hue bins are 30° wide, centred on 15°, 45°, … 345° (ArtFingerprint step 5).
    static let colors: [(key: String, bins: [Int])] = [
        ("red", [11, 0]), ("orange", [1]), ("yellow", [2]), ("green", [3, 4, 5]),
        ("blue", [6, 7, 8]), ("purple", [9]), ("pink", [10]),
    ]

    /// Share of the sheet a colour must cover (soft-binned cells) to count as one of the artwork's colours.
    static let minimumCoverage: Float = 0.03
    static let maximumColors = 3

    /// The artwork's main colours, most-used first (at most three).
    static func colorKeys(hues: [UInt8]) -> [String] {
        guard hues.count == ArtFingerprint.hueBins else { return [] }
        let amounts = colors.map { color in
            (color.key, color.bins.reduce(Float(0)) { $0 + Float(hues[$1]) / 255 })
        }
        return amounts.filter { $0.1 >= minimumCoverage }
            .sorted { $0.1 > $1.1 }
            .prefix(maximumColors)
            .map(\.0)
    }

    static func keys(fingerprintData: Data?) -> [String] {
        guard let fp = ArtFingerprint(data: fingerprintData) else { return [] }
        return colorKeys(hues: fp.hues)
    }

    /// The tag as the parent sees it (#紅色 / #Red).
    static func name(for key: String) -> String? {
        switch key {
        case "red": String(localized: "紅色")
        case "orange": String(localized: "橘色")
        case "yellow": String(localized: "黃色")
        case "green": String(localized: "綠色")
        case "blue": String(localized: "藍色")
        case "purple": String(localized: "紫色")
        case "pink": String(localized: "粉紅色")
        default: nil
        }
    }

    static let settingKey = "showAutoTags"
}

extension Artwork {
    /// 自動標籤 in the device language.
    var autoTagNames: [String] { autoTags.compactMap(AutoTags.name(for:)) }

    /// Sets the colour tags from the current fingerprint; only writes when they change (no needless saves or syncs).
    func refreshAutoTags() {
        let keys = AutoTags.keys(fingerprintData: fingerprintData)
        if keys != autoTags { autoTags = keys }
    }
}
