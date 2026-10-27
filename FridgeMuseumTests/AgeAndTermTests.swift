import Foundation
import Testing
@testable import FridgeMuseum

struct AgeCalculatorTests {
    let birthday = day(2020, 3, 15)

    @Test func yearsAndMonths() {
        let age = AgeCalculator.age(birthday: birthday, at: day(2023, 5, 15), calendar: utc)
        #expect(age == ChildAge(years: 3, months: 2))
        #expect(age?.label == "3歲2個月")
    }

    @Test func dayBeforeMonthBoundaryDoesNotCount() {
        let age = AgeCalculator.age(birthday: birthday, at: day(2023, 5, 14), calendar: utc)
        #expect(age == ChildAge(years: 3, months: 1))
    }

    @Test func exactBirthdayHasNoMonths() {
        #expect(AgeCalculator.age(birthday: birthday, at: day(2024, 3, 15), calendar: utc)?.label == "4歲")
    }

    @Test func babyLabels() {
        #expect(AgeCalculator.age(birthday: birthday, at: day(2020, 11, 15), calendar: utc)?.label == "8個月")
        #expect(AgeCalculator.age(birthday: birthday, at: day(2020, 3, 20), calendar: utc)?.label == "未滿1個月")
    }

    @Test func beforeBirthIsNil() {
        #expect(AgeCalculator.age(birthday: birthday, at: day(2019, 12, 1), calendar: utc) == nil)
    }

    @Test func yearLabelAndOrdering() {
        #expect(ChildAge(years: 0, months: 5).yearLabel == "未滿 1 歲")
        #expect(ChildAge(years: 5, months: 0).yearLabel == "5 歲")
        #expect(ChildAge(years: 2, months: 11) < ChildAge(years: 3, months: 0))
    }
}

struct SchoolTermTests {
    @Test(arguments: [
        (day(2025, 8, 1), 114, SchoolTerm.Half.first),
        (day(2025, 12, 31), 114, SchoolTerm.Half.first),
        (day(2026, 1, 31), 114, SchoolTerm.Half.first),
        (day(2026, 2, 1), 114, SchoolTerm.Half.second),
        (day(2026, 7, 31), 114, SchoolTerm.Half.second),
        (day(2026, 8, 1), 115, SchoolTerm.Half.first),
    ])
    func termFromDate(date: Date, year: Int, half: SchoolTerm.Half) {
        let t = SchoolTerm.of(date, calendar: utc)
        #expect(t.academicYear == year)
        #expect(t.half == half)
    }

    @Test func labels() {
        #expect(SchoolTerm(academicYear: 114, half: .first).label == "114學年 上學期")
        #expect(SchoolTerm(academicYear: 114, half: .second).label == "114學年 下學期")
        #expect(SchoolTerm(academicYear: 114, half: .second) > SchoolTerm(academicYear: 114, half: .first))
        #expect(SchoolTerm(academicYear: 113, half: .second) < SchoolTerm(academicYear: 114, half: .first))
    }

    @Test func gradeUsesSeptemberFirstCutoff() {
        let term = SchoolTerm(academicYear: 114, half: .first)   // starts Aug 2025
        #expect(term.gradeLabel(birthday: day(2019, 9, 1), calendar: utc) == "小一")
        #expect(term.gradeLabel(birthday: day(2019, 9, 2), calendar: utc) == "大班")
        #expect(term.gradeLabel(birthday: day(2023, 3, 1), calendar: utc) == "幼幼班")
        #expect(term.gradeLabel(birthday: day(2022, 3, 1), calendar: utc) == "小班")
        #expect(term.gradeLabel(birthday: day(2024, 3, 1), calendar: utc) == nil)
    }
}

struct TagTests {
    @Test func normalize() {
        #expect(TagSuggestions.normalize("  #母親節 ") == "母親節")
        #expect(TagSuggestions.normalize("＃ 家人") == "家人")
        #expect(TagSuggestions.normalize("海邊   旅行") == "海邊 旅行")
        #expect(TagSuggestions.normalize("   ") == nil)
        #expect(TagSuggestions.common.contains("動物"))
    }
}
