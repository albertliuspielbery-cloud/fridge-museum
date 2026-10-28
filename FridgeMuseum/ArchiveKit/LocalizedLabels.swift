import Foundation

/// The UI language the app is actually running in (zh-Hant is the development language; en is the other one).
enum AppLanguage {
    static var isChinese: Bool {
        (Bundle.main.preferredLocalizations.first ?? "zh-Hant").hasPrefix("zh")
    }

    /// Short dates on placards: zh 2026/03/14, en Mar 14, 2026.
    static func placardDate(_ date: Date) -> String {
        if isChinese {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "zh_Hant_TW")
            f.dateFormat = "yyyy/MM/dd"
            return f.string(from: date)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year().locale(Locale(identifier: "en_US")))
    }
}

extension ChildAge {
    /// Placard / caption form — zh 「5歲3個月」, en “5 yrs 3 mos” (reviewed copy: ageY / ageM / ageYM).
    var localizedLabel: String {
        let y = String(localized: "\(years)歲")
        let m = String(localized: "\(months)個月")
        if years > 0 && months > 0 { return String(localized: "\(y) \(m)") }
        if years > 0 { return y }
        if months > 0 { return m }
        return String(localized: "未滿1個月")
    }

    /// Section title when grouping by age.
    var localizedYearLabel: String {
        years > 0 ? String(localized: "\(years) 歲") : String(localized: "未滿 1 歲")
    }
}

extension SchoolTerm {
    /// zh 「114學年 上學期」; en “Fall 2025” / “Spring 2026” (US terms for the same Aug–Jan / Feb–Jul halves).
    var localizedLabel: String {
        if AppLanguage.isChinese { return label }
        return half == .first ? "Fall \(startYearAD)" : "Spring \(startYearAD + 1)"
    }

    /// zh 「上學期」; en “Fall”.
    var localizedHalf: String {
        if AppLanguage.isChinese { return halfLabel }
        return half == .first ? "Fall" : "Spring"
    }

    /// zh 「114學年」; en “2025–26 school year”.
    var localizedYear: String {
        if AppLanguage.isChinese { return "\(academicYear)學年" }
        return "\(startYearAD)–\(String(format: "%02d", (startYearAD + 1) % 100)) school year"
    }

    func localizedGrade(birthday: Date, calendar: Calendar = .current) -> String? {
        guard let zh = gradeLabel(birthday: birthday, calendar: calendar) else { return nil }
        if AppLanguage.isChinese { return zh }
        let en = ["幼幼班": "Toddler Class", "小班": "Preschool (3s)", "中班": "Preschool (4s)", "大班": "Kindergarten",
                  "小一": "1st Grade", "小二": "2nd Grade", "小三": "3rd Grade", "小四": "4th Grade", "小五": "5th Grade",
                  "小六": "6th Grade", "國一": "7th Grade", "國二": "8th Grade", "國三": "9th Grade"]
        return en[zh] ?? zh
    }
}

extension ArtworkKind {
    /// 畫作 / Drawing, 勞作 / Craft.
    var title: String { self == .flat ? String(localized: "畫作") : String(localized: "勞作") }
    /// 平面畫作 / Drawing, 立體勞作 / Craft (dock mode switch).
    var longTitle: String { self == .flat ? String(localized: "平面畫作") : String(localized: "立體勞作") }
    /// Placard default medium: 紙上作品 / Work on paper, 立體勞作 / Mixed media.
    var defaultMedium: String { self == .flat ? String(localized: "紙上作品") : String(localized: "mediumCraft") }
}

extension CraftBackground {
    var title: String {
        switch self {
        case .white: String(localized: "純白")
        case .warm: String(localized: "暖白")
        case .gray: String(localized: "淺灰")
        case .gradient: String(localized: "柔光漸層")
        }
    }
}

extension Artwork {
    /// Placard title: the artwork's name, or 無題 / Untitled.
    var placardTitle: String { title.isEmpty ? String(localized: "無題") : title }

    /// “小明 · 5歲3個月” / “Mia · 5 yrs 3 mos”; 小畫家 / Little Artist when nobody is set.
    var placardArtist: String {
        let name = child.map(\.displayName) ?? String(localized: "小畫家")
        if let age = ageAtCreation { return "\(name) · \(age.localizedLabel)" }
        return name
    }

    /// “蠟筆、紙 · 2026/03/14”.
    var placardMedium: String {
        let m = medium.isEmpty ? kind.defaultMedium : medium
        return "\(m) · \(AppLanguage.placardDate(capturedAt))"
    }

    /// “114學年 下學期 · 大班” / “Spring 2026 · Kindergarten”.
    var placardTerm: String {
        var s = schoolTerm.localizedLabel
        if let b = child?.birthday, let g = schoolTerm.localizedGrade(birthday: b) { s += " · \(g)" }
        return s
    }

}
