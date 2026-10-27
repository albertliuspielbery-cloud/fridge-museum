import Foundation

struct ChildAge: Hashable, Comparable, Sendable {
    var years: Int
    var months: Int

    var totalMonths: Int { years * 12 + months }

    /// "3歲2個月" / "3歲" / "8個月" / "未滿1個月" (same wording as the prototype).
    var label: String {
        if years > 0 { return months > 0 ? "\(years)歲\(months)個月" : "\(years)歲" }
        return months > 0 ? "\(months)個月" : "未滿1個月"
    }

    /// Section title for grouping by age: "3 歲", or "未滿 1 歲".
    var yearLabel: String { years > 0 ? "\(years) 歲" : "未滿 1 歲" }

    static func < (a: ChildAge, b: ChildAge) -> Bool { a.totalMonths < b.totalMonths }
}

enum AgeCalculator {
    /// Whole years + months between birthday and date (calendar days, time of day ignored).
    /// Returns nil when the date is before the birthday.
    static func age(birthday: Date, at date: Date, calendar: Calendar = .current) -> ChildAge? {
        let b = calendar.startOfDay(for: birthday)
        let d = calendar.startOfDay(for: date)
        guard d >= b else { return nil }
        let c = calendar.dateComponents([.year, .month], from: b, to: d)
        return ChildAge(years: max(0, c.year ?? 0), months: max(0, c.month ?? 0))
    }
}

/// Taiwan school terms. 上學期 = August–January, 下學期 = February–July.
/// The academic year (學年) is numbered in the ROC calendar by the year it starts in (AD − 1911).
struct SchoolTerm: Hashable, Comparable, Sendable {
    enum Half: Int, Sendable { case first = 0, second = 1 }

    var academicYear: Int
    var half: Half

    init(academicYear: Int, half: Half) {
        self.academicYear = academicYear
        self.half = half
    }

    static func of(_ date: Date, calendar: Calendar = .current) -> SchoolTerm {
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)
        switch m {
        case 8...12: return SchoolTerm(academicYear: y - 1911, half: .first)
        case 1: return SchoolTerm(academicYear: y - 1 - 1911, half: .first)
        default: return SchoolTerm(academicYear: y - 1 - 1911, half: .second)
        }
    }

    /// AD year in which this academic year starts (August).
    var startYearAD: Int { academicYear + 1911 }
    var halfLabel: String { half == .first ? "上學期" : "下學期" }
    /// "114學年 上學期"
    var label: String { "\(academicYear)學年 \(halfLabel)" }
    var sortKey: Int { academicYear * 2 + half.rawValue }

    static func < (a: SchoolTerm, b: SchoolTerm) -> Bool { a.sortKey < b.sortKey }

    /// Grade in the Taiwan system for a child with this birthday during this academic year,
    /// using the Sept-1 cutoff (age on Sept 1 of the start year). nil when younger than 2 or older than 15.
    func gradeLabel(birthday: Date, calendar: Calendar = .current) -> String? {
        guard let sep1 = calendar.date(from: DateComponents(year: startYearAD, month: 9, day: 1)),
              let age = AgeCalculator.age(birthday: birthday, at: sep1, calendar: calendar) else { return nil }
        let names = [2: "幼幼班", 3: "小班", 4: "中班", 5: "大班",
                     6: "小一", 7: "小二", 8: "小三", 9: "小四", 10: "小五", 11: "小六",
                     12: "國一", 13: "國二", 14: "國三"]
        return names[age.years]
    }
}
