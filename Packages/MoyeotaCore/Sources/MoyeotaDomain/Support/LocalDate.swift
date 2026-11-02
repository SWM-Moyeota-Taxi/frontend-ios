import Foundation

/// `java.time.LocalDate` 의 자리 — 시간대 없는 달력 날짜(ISO-8601, 역산 그레고리력).
///
/// `Foundation.Calendar` 를 쓰지 않고 직접 계산한다. `Calendar(identifier: .gregorian)` 은 1582년 이전을
/// 율리우스력으로 계산하고 기기 설정에 흔들릴 수 있는데, 이 타입은 생년월일 판정(법적 나이)에 쓰이므로
/// 어느 기기에서든 Java 와 같은 답을 내야 한다.
///
/// 존재하지 않는 날짜는 이 타입의 값이 될 수 없다(`AuthPolicy.isOldEnough` 가 기대는 성질이다).
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let monthValue: Int
    public let dayOfMonth: Int

    /// 서비스 지역의 시간대.
    public static let seoulZone = TimeZone(identifier: "Asia/Seoul") ?? TimeZone(secondsFromGMT: 9 * 3600)!

    /// Java `ZoneOffset.UTC`.
    public static let utcZone = TimeZone(secondsFromGMT: 0)!

    private static let yearRange = -999_999_999...999_999_999

    private init(unchecked year: Int, _ monthValue: Int, _ dayOfMonth: Int) {
        self.year = year
        self.monthValue = monthValue
        self.dayOfMonth = dayOfMonth
    }

    /// 없는 날짜면 nil. 원본의 `runCatching { LocalDate.of(…) }.getOrNull()` 자리다.
    public init?(year: Int, month: Int, dayOfMonth: Int) {
        guard Self.yearRange.contains(year),
              (1...12).contains(month),
              (1...Self.lengthOfMonth(year: year, month: month)).contains(dayOfMonth)
        else { return nil }
        self.init(unchecked: year, month, dayOfMonth)
    }

    /// Java `LocalDate.of(year, month, dayOfMonth)`. 없는 날짜면 `DateTimeException` 을 던진다.
    public static func of(_ year: Int, _ month: Int, _ dayOfMonth: Int) throws -> LocalDate {
        guard let date = LocalDate(year: year, month: month, dayOfMonth: dayOfMonth) else {
            throw DateTimeException("Invalid date: \(year)-\(month)-\(dayOfMonth)")
        }
        return date
    }

    /// Java `LocalDate.ofEpochDay` — 1970-01-01 로부터의 일수.
    public static func ofEpochDay(_ epochDay: Int) -> LocalDate {
        let shifted = epochDay + 719_468
        let era = floorDiv(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return LocalDate(unchecked: year, month, day)
    }

    /// Java `LocalDate.ofInstant` / 원본의 `instant.atZone(zone).toLocalDate()`.
    public static func ofInstant(_ instant: Date, _ zone: TimeZone) -> LocalDate {
        let seconds = Int(instant.timeIntervalSince1970.rounded(.down)) + zone.secondsFromGMT(for: instant)
        return ofEpochDay(floorDiv(seconds, 86_400))
    }

    /// 지금 `zone` 의 오늘. 기본값은 원본 `LocalDate.now()` 와 같이 **기기 시간대**다 —
    /// 생년월일·만 나이 판정의 「오늘」은 사용자가 사는 지역의 날짜다(`AuthPolicy.isOldEnough`).
    public static func now(_ zone: TimeZone = .autoupdatingCurrent) -> LocalDate {
        ofInstant(Date(), zone)
    }

    /// Java `LocalDate.parse(text)` — ISO_LOCAL_DATE(`uuuu-MM-dd`), STRICT.
    ///
    /// 연도는 네 자리 이상이고, 네 자리를 넘으면 `+` 가 있어야 하며, 네 자리 이하에는 `+` 를 붙일 수 없다.
    /// `-0000` 은 거절한다. 월·일은 정확히 두 자리. 없는 날짜(`2025-02-30`)는 거절한다.
    public static func parse(_ text: String) throws -> LocalDate {
        let failure = DateTimeException("Text '\(text)' could not be parsed")
        var rest = Array(text.utf8)[...]

        var sign: UInt8?
        if let first = rest.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            sign = first
            rest = rest.dropFirst()
        }
        let yearDigits = rest.prefix(while: isASCIIDigit)
        rest = rest.dropFirst(yearDigits.count)
        guard (4...10).contains(yearDigits.count) else { throw failure }
        switch sign {
        case UInt8(ascii: "+"):
            guard yearDigits.count > 4 else { throw failure }
        case nil:
            guard yearDigits.count == 4 else { throw failure }
        default:
            break
        }
        let magnitude = yearDigits.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        if sign == UInt8(ascii: "-"), magnitude == 0 { throw failure }

        guard rest.count == 6,
              rest[rest.startIndex] == UInt8(ascii: "-"),
              rest[rest.startIndex + 3] == UInt8(ascii: "-"),
              let month = twoDigits(rest[(rest.startIndex + 1)...(rest.startIndex + 2)]),
              let day = twoDigits(rest[(rest.startIndex + 4)...(rest.startIndex + 5)]),
              let date = LocalDate(year: sign == UInt8(ascii: "-") ? -magnitude : magnitude, month: month, dayOfMonth: day)
        else { throw failure }
        return date
    }

    // MARK: 달력

    public var isLeapYear: Bool { Self.isLeap(year) }

    public func lengthOfMonth() -> Int { Self.lengthOfMonth(year: year, month: monthValue) }

    /// Java `toEpochDay` — 1970-01-01 로부터의 일수.
    public func toEpochDay() -> Int {
        let shiftedYear = monthValue <= 2 ? year - 1 : year
        let era = Self.floorDiv(shiftedYear, 400)
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (monthValue + (monthValue > 2 ? -3 : 9)) + 2) / 5 + dayOfMonth - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Java `atStartOfDay(zone).toInstant()`. 원본은 UTC 자정만 쓴다(`toBirthDateInstant`).
    public func atStartOfDay(_ zone: TimeZone) -> Date {
        let localSeconds = toEpochDay() * 86_400
        let guess = Date(timeIntervalSince1970: TimeInterval(localSeconds))
        let adjusted = Date(timeIntervalSince1970: TimeInterval(localSeconds - zone.secondsFromGMT(for: guess)))
        return Date(timeIntervalSince1970: TimeInterval(localSeconds - zone.secondsFromGMT(for: adjusted)))
    }

    // MARK: 더하기·빼기

    public func plusDays(_ days: Int) -> LocalDate {
        days == 0 ? self : Self.ofEpochDay(toEpochDay() + days)
    }

    public func minusDays(_ days: Int) -> LocalDate { plusDays(-days) }

    public func plusWeeks(_ weeks: Int) -> LocalDate { plusDays(weeks * 7) }

    public func minusWeeks(_ weeks: Int) -> LocalDate { plusDays(-weeks * 7) }

    /// 그 달에 같은 날이 없으면 **그 달의 말일로 맞춘다**(01-31 + 1개월 = 02-28). Java 와 같다.
    public func plusMonths(_ months: Int) -> LocalDate {
        let total = year * 12 + (monthValue - 1) + months
        let newYear = Self.floorDiv(total, 12)
        let newMonth = total - newYear * 12 + 1
        let newDay = min(dayOfMonth, Self.lengthOfMonth(year: newYear, month: newMonth))
        return LocalDate(unchecked: newYear, newMonth, newDay)
    }

    public func minusMonths(_ months: Int) -> LocalDate { plusMonths(-months) }

    /// 2월 29일에서 평년으로 가면 **2월 28일로 맞춘다**(2008-02-29 + 14년 = 2022-02-28).
    /// `AuthPolicy.isOldEnough` 가 민법 제160조 ③ 과 같은 답을 내는 근거다.
    public func plusYears(_ years: Int) -> LocalDate {
        let newYear = year + years
        return LocalDate(unchecked: newYear, monthValue, min(dayOfMonth, Self.lengthOfMonth(year: newYear, month: monthValue)))
    }

    public func minusYears(_ years: Int) -> LocalDate { plusYears(-years) }

    // MARK: 비교

    public func isBefore(_ other: LocalDate) -> Bool { self < other }

    public func isAfter(_ other: LocalDate) -> Bool { other < self }

    public func isEqual(_ other: LocalDate) -> Bool { self == other }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.monthValue, lhs.dayOfMonth) < (rhs.year, rhs.monthValue, rhs.dayOfMonth)
    }

    // MARK: 문자열

    /// Java `LocalDate.toString()` — `2000-01-01`. 화면 복원·전송에서 `parse` 와 왕복한다.
    public func toString() -> String {
        let sign = year > 9_999 ? "+" : (year < 0 ? "-" : "")
        return "\(sign)\(Self.pad(abs(year), 4))-\(Self.pad(monthValue, 2))-\(Self.pad(dayOfMonth, 2))"
    }

    public var description: String { toString() }

    /// Java `date.format(formatter)`.
    public func format(_ formatter: DateTimeFormatter) -> String {
        switch formatter {
        case .isoLocalDate:
            return toString()
        case .basicIsoDate:
            return "\(Self.pad(year, 4))\(Self.pad(monthValue, 2))\(Self.pad(dayOfMonth, 2))"
        }
    }

    // MARK: 내부

    private static func isLeap(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    private static func lengthOfMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func twoDigits(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard bytes.allSatisfy(isASCIIDigit) else { return nil }
        return bytes.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
    }
}

/// 원본이 쓰는 `java.time.format.DateTimeFormatter` 상수들의 자리.
public enum DateTimeFormatter: Sendable {
    /// `BASIC_ISO_DATE` — `20000101`.
    case basicIsoDate
    /// `ISO_LOCAL_DATE` — `2000-01-01`.
    case isoLocalDate
}

/// `java.time.DateTimeException`(`DateTimeParseException` 포함)의 자리.
public struct DateTimeException: Throwable {
    public let message: String?
    public let cause: (any Error)?

    public init(_ message: String? = nil, cause: (any Error)? = nil) {
        self.message = message
        self.cause = cause
    }
}
