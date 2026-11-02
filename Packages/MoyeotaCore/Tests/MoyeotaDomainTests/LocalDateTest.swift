import Foundation
import Testing
@testable import MoyeotaDomain

@Suite struct LocalDateTest {
    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> LocalDate {
        try LocalDate.of(year, month, day)
    }

    @Test("없는 날짜는 값이 되지 못한다")
    func invalidDatesThrow() {
        for (year, month, day) in [(2025, 2, 30), (2023, 2, 29), (2024, 13, 1), (2024, 0, 1), (2024, 1, 0), (2024, 4, 31), (1900, 2, 29)] {
            #expect(throws: DateTimeException.self) { try LocalDate.of(year, month, day) }
            #expect(LocalDate(year: year, month: month, dayOfMonth: day) == nil)
        }
        #expect(LocalDate(year: 2024, month: 2, dayOfMonth: 29) != nil)
        #expect(LocalDate(year: 2000, month: 2, dayOfMonth: 29) != nil)
    }

    @Test("parse 는 ISO_LOCAL_DATE 만 받고 toString 과 왕복한다")
    func parseRoundTrips() throws {
        for text in ["2000-01-01", "1999-12-31", "2024-02-29", "0000-01-01", "-0001-12-31", "+12345-06-07"] {
            #expect(try LocalDate.parse(text).toString() == text)
        }
        for text in ["", "2025-02-30", "2000-1-1", "20000101", "2000-01-01 ", " 2000-01-01", "+2000-01-01", "12345-01-01", "-0000-01-01", "2000-13-01", "２０００-01-01", "2000/01/01"] {
            #expect(throws: DateTimeException.self, "\(text)") { try LocalDate.parse(text) }
        }
    }

    @Test("BASIC_ISO_DATE 와 ISO_LOCAL_DATE 형식")
    func formats() throws {
        let value = try date(2012, 10, 3)
        #expect(value.format(.basicIsoDate) == "20121003")
        #expect(value.format(.isoLocalDate) == "2012-10-03")
        #expect("\(value)" == "2012-10-03")
    }

    @Test("plusYears 는 윤일을 2월 28일로 맞춘다")
    func plusYearsClampsLeapDay() throws {
        #expect(try date(2008, 2, 29).plusYears(14) == date(2022, 2, 28))
        #expect(try date(2008, 2, 29).plusYears(16) == date(2024, 2, 29))
        #expect(try date(2024, 2, 29).minusYears(1) == date(2023, 2, 28))
    }

    @Test("plusMonths 는 말일로 맞추고 해를 넘긴다")
    func plusMonthsClamps() throws {
        #expect(try date(2023, 1, 31).plusMonths(1) == date(2023, 2, 28))
        #expect(try date(2024, 1, 31).plusMonths(1) == date(2024, 2, 29))
        #expect(try date(2024, 11, 15).plusMonths(3) == date(2025, 2, 15))
        #expect(try date(2024, 1, 15).minusMonths(1) == date(2023, 12, 15))
        #expect(try date(2024, 3, 31).minusMonths(1) == date(2024, 2, 29))
        #expect(try date(2024, 1, 15).minusMonths(25) == date(2021, 12, 15))
    }

    @Test("plusDays 는 달과 해의 경계를 넘는다")
    func plusDaysCrossesBoundaries() throws {
        #expect(try date(2023, 12, 31).plusDays(1) == date(2024, 1, 1))
        #expect(try date(2024, 2, 28).plusDays(1) == date(2024, 2, 29))
        #expect(try date(2024, 3, 1).minusDays(1) == date(2024, 2, 29))
        #expect(try date(2023, 3, 1).minusDays(1) == date(2023, 2, 28))
        #expect(try date(2024, 1, 1).plusWeeks(1) == date(2024, 1, 8))
        #expect(try date(2024, 1, 8).minusWeeks(1) == date(2024, 1, 1))
    }

    @Test("에포크 일수는 Java 와 같다")
    func epochDays() throws {
        #expect(try date(1970, 1, 1).toEpochDay() == 0)
        #expect(try date(1969, 12, 31).toEpochDay() == -1)
        #expect(try date(2000, 3, 1).toEpochDay() == 11_017)
        #expect(try date(1582, 10, 10).toEpochDay() == -141_432) // 역산 그레고리력 — 율리우스력 전환 없음
        #expect(try LocalDate.ofEpochDay(19_782) == date(2024, 2, 29))
        for day in stride(from: -800_000, through: 800_000, by: 997) {
            #expect(LocalDate.ofEpochDay(day).toEpochDay() == day)
        }
    }

    @Test("비교")
    func comparison() throws {
        let earlier = try date(2012, 12, 31)
        let later = try date(2013, 1, 1)
        #expect(earlier < later)
        #expect(earlier.isBefore(later))
        #expect(later.isAfter(earlier))
        #expect(!later.isBefore(later))
        #expect(later.isEqual(later))
        #expect(Set([earlier, earlier, later]).count == 2)
    }

    @Test("시각을 시간대의 날짜로 내린다")
    func ofInstantUsesZone() throws {
        // 2026-10-13T15:30:00Z — 서울은 이미 14일이다.
        let instant = Date(timeIntervalSince1970: 1_791_905_400)
        #expect(try LocalDate.ofInstant(instant, LocalDate.utcZone) == date(2026, 10, 13))
        #expect(try LocalDate.ofInstant(instant, LocalDate.seoulZone) == date(2026, 10, 14))
        // 음의 에포크에서도 내림이다.
        #expect(try LocalDate.ofInstant(Date(timeIntervalSince1970: -1), LocalDate.utcZone) == date(1969, 12, 31))
    }

    /// 원본 `java.time.LocalDate.now()` 는 기기 시간대를 쓴다. 생년월일·만 나이 판정의 「오늘」이 이 값이다.
    ///
    /// 두 시간대를 쓰는 이유: 서울(+9) 기준 20시 전이면 파고파고(-11)가 전날이고, 19시 뒤면 키리티마티(+14)가
    /// 다음 날이라 **언제 돌려도 둘 중 하나는 서울과 날짜가 다르다.** 기기가 서울이어도 서울 고정을 잡아낸다.
    @Test("now 의 기본값은 기기 시간대의 날짜다")
    func nowDefaultsToDeviceZone() throws {
        let saved = getenv("TZ").map { String(cString: $0) }
        defer {
            if let saved { setenv("TZ", saved, 1) } else { unsetenv("TZ") }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }
        for identifier in ["Pacific/Pago_Pago", "Pacific/Kiritimati"] {
            setenv("TZ", identifier, 1)
            tzset()
            NSTimeZone.resetSystemTimeZone()
            let zone = try #require(TimeZone(identifier: identifier))

            let before = Date()
            let today = LocalDate.now()
            let after = Date()

            #expect([LocalDate.ofInstant(before, zone), LocalDate.ofInstant(after, zone)].contains(today), "\(identifier)")
        }
    }

    @Test("atStartOfDay 는 그 시간대의 자정이다")
    func atStartOfDay() throws {
        #expect(try date(2000, 1, 1).atStartOfDay(LocalDate.utcZone).timeIntervalSince1970 == 946_684_800)
        #expect(try date(2000, 1, 1).atStartOfDay(LocalDate.seoulZone).timeIntervalSince1970 == 946_684_800 - 9 * 3600)
    }
}
