import Foundation
import MoyeotaDomain

// 34 지난 탑승 기록의 **표시 규칙** — 무엇을 글자로 만들고, 무엇을 아예 그리지 않는가.
//
// 화면(`RideHistoryScreen`)에서 떼어 둔 이유는 `MyPageMenu` 와 같다: 「요금이 없으면 요금 줄을
// 그리지 않는다」는 규칙은 눈으로 확인하려면 **1차 모드로 끝난 방을 하나 만들어** 다시 빌드해야
// 하는 종류다. 순수 함수로 두면 `RideHistoryRulesTest` 가 값으로 고정한다.
//
// SwiftUI 를 모르는 파일로 둔다.

/// 기록이 하나도 없을 때의 문구. 「없어요」까지가 사실이고 그 이상을 약속하지 않는다.
let RIDE_HISTORY_EMPTY_TEXT = "아직 탑승 기록이 없어요"

/// 불러오기가 실패했을 때의 문구. 사용자가 할 일은 「다시 시도」 하나뿐이다.
let RIDE_HISTORY_ERROR_TEXT = "탑승 기록을 불러오지 못했어요"

/// 카드 한 장이 그릴 값. **없는 값은 nil 이고, nil 인 자리는 그리지 않는다.**
///
/// 「0원」·「0명」·「날짜 모름」 같은 자리값을 두지 않는 것이 이 모델의 전부다 — 이 저장소가
/// 거짓 문구를 들어낸 이력이 있어 「모른다」를 **타입으로** 남긴다.
struct RideHistoryItem: Equatable, Sendable {
    var partyId: Int64
    /// 하차 시각 표기. 파싱할 수 없으면 nil — 틀린 날짜보다 없는 편이 낫다.
    var dateLabel: String?
    /// `출발 → 도착`. 둘 중 하나라도 없으면 있는 쪽만, 둘 다 없으면 nil.
    var routeLabel: String?
    /// 「나 포함 3명」. 서버 인원이 0 이면 nil(셀 수 없는 것을 세지 않는다).
    var memberLabel: String?
    /// **nil 이면 요금 줄을 아예 그리지 않는다.** 1차 모드 기록이 그렇다.
    var fare: RideHistoryFare?
    var members: [RideRecordMember]

    init(
        partyId: Int64,
        dateLabel: String?,
        routeLabel: String?,
        memberLabel: String?,
        fare: RideHistoryFare?,
        members: [RideRecordMember]
    ) {
        self.partyId = partyId
        self.dateLabel = dateLabel
        self.routeLabel = routeLabel
        self.memberLabel = memberLabel
        self.fare = fare
        self.members = members
    }
}

/// 요금 두 줄. **서버 값을 그대로 쓴다** — 앱이 다시 나누지 않는다.
///
/// 서버 `farePerPerson` 은 `totalFare / memberCount` **정수 나눗셈(내림)** 인데, 앱의
/// `farePerPersonWon`(14·15 의 예상 요금)은 10원 단위로 올림/반올림한다. 그걸 끌어다 쓰면
/// **기록 화면 금액이 실제 결제액과 어긋난다** — 사용자는 어느 쪽이 거짓인지 알 길이 없다.
struct RideHistoryFare: Equatable, Sendable {
    /// 「1인 16,500원」. 서버가 1인 부담을 주지 않았으면 nil.
    var perPersonLabel: String?
    /// 「총 16,500원」. 서버가 총액을 주지 않았으면 nil.
    var totalLabel: String?

    init(perPersonLabel: String?, totalLabel: String?) {
        self.perPersonLabel = perPersonLabel
        self.totalLabel = totalLabel
    }
}

extension RideRecord {
    /// 기록 한 건 → 카드 한 장.
    ///
    /// ### 요금이 없으면 요금 자체를 안 만든다 ★ 이 화면의 1급 규칙
    /// `RideRecord.totalFare`·`RideRecord.farePerPerson` 이 **둘 다** nil 인 기록은 1차 모드다
    /// (기사 없이 방장이 합승 종료 — 서버가 요금을 입력받는 자리가 기사 하차 처리뿐이다).
    /// 0 으로 접어 「0원」을 그리면 **「공짜로 탔다」는 거짓말**이 된다. 그래서 `RideHistoryFare` 를
    /// 만들지 않고, 화면은 nil 을 보고 줄을 건너뛴다.
    ///
    /// 한쪽만 있는 응답은 실측에서 본 적이 없지만(서버가 같은 `fare` 에서 둘을 만든다) 그때도
    /// **있는 값만** 그린다 — 없는 쪽을 다른 쪽에서 계산해 채우면 위 어긋남이 그대로 일어난다.
    ///
    /// ### 그리지 않는 것
    /// 상태 칩(서버가 상태를 주지 않는다) · 방장 표시(`host` 필드가 없다) · 평점·매너 점수
    /// (서버에 평가 API 가 없다) · 「예정」(예약 개념이 서버에 없다). 전부 지어낼 수밖에 없는 값이다.
    func toHistoryItem(now: Date = Date(), zone: TimeZone = .current) -> RideHistoryItem {
        RideHistoryItem(
            partyId: partyId,
            dateLabel: dropoffTime.flatMap { rideHistoryDateLabel(isoTime: $0, now: now, zone: zone) },
            routeLabel: routeLabel(departure: departure, destination: destination),
            memberLabel: memberLabel(memberCount: memberCount, members: members),
            fare: fareOrNull(totalFare: totalFare, farePerPerson: farePerPerson),
            members: members
        )
    }
}

/// `출발 → 도착`. 한쪽이 비면 있는 쪽만 쓰고, 둘 다 비면 nil 이다(빈 화살표를 그리지 않는다).
private func routeLabel(departure: String, destination: String) -> String? {
    if !departure.isBlank && !destination.isBlank { return "\(departure) → \(destination)" }
    if !departure.isBlank { return departure }
    if !destination.isBlank { return destination }
    return nil
}

/// 「나 포함 3명」. 서버 `currentMembers` 를 쓰고 **`members.count` 로 세지 않는다** — 요약을 못 찾은
/// 멤버도 항목으로는 오지만, 반대로 목록이 비어 있어도 인원 수는 올 수 있다.
///
/// 「나 포함」은 내가 실제로 그 목록에 있을 때만 붙인다. 내 기록이니 당연히 있어야 하지만,
/// 서버가 `isMe` 를 주지 않아 앱이 publicId 비교로 만드는 값이라 **틀릴 수 있다**(미로그인·요약 없음).
/// 그때 「나 포함」을 그대로 쓰면 없는 근거로 단정하는 말이 된다.
///
/// 정원(`capacity`)이 아니므로 「2/3명」은 만들지 않는다 — 서버가 정원을 주지 않는다.
private func memberLabel(memberCount: Int, members: [RideRecordMember]) -> String? {
    if memberCount <= 0 { return nil }
    if members.contains(where: \.isMe) { return "나 포함 \(memberCount)명" }
    return "\(memberCount)명"
}

/// 둘 다 없으면 요금 블록 자체가 없다. 있는 값만 글자로 만든다.
private func fareOrNull(totalFare: Int?, farePerPerson: Int?) -> RideHistoryFare? {
    if totalFare == nil && farePerPerson == nil { return nil }
    return RideHistoryFare(
        perPersonLabel: farePerPerson.map { "1인 \(wonLabel(amount: $0))" },
        totalLabel: totalFare.map { "총 \(wonLabel(amount: $0))" }
    )
}

/// 이 앱의 다른 요금 자리들과 같은 표기(`%,d원`). 세 자리마다 쉼표다.
func wonLabel(amount: Int) -> String {
    let digits = Array(String(amount.magnitude))
    var grouped = ""
    for (index, digit) in digits.enumerated() {
        if index > 0 && (digits.count - index) % 3 == 0 { grouped.append(",") }
        grouped.append(digit)
    }
    return "\(amount < 0 ? "-" : "")\(grouped)원"
}

/// 하차 시각 표기. 올해면 `10월 31일 오후 4:15`, 다른 해면 `2026년 10월 31일`.
///
/// 서버는 UTC ISO-8601 로 내려주므로 **문자열을 그대로 자르면 KST 오후 4시가 오전 7시로 보인다**
/// (채팅에서 실제로 났던 결함과 같은 함정). 기기 시간대로 바꿔 쓴다.
///
/// 다른 해의 기록에 시각을 붙이지 않는 이유: 몇 달 전 탑승에서 사용자가 찾는 것은 「언제쯤」이고,
/// 분 단위는 줄만 길어지게 한다. 파싱할 수 없는 형식이면 nil — 그 줄을 비운다.
func rideHistoryDateLabel(isoTime: String, now: Date = Date(), zone: TimeZone = .current) -> String? {
    guard let at = isoTime.toInstantOrNull()?.local(zone: zone) else { return nil }
    let thisYear = RideHistoryInstant(
        epochSecond: Int64(now.timeIntervalSince1970.rounded(.down)),
        nano: 0
    ).local(zone: zone).year
    if at.year != thisYear { return "\(at.year)년 \(at.month)월 \(at.day)일" }
    let meridiem = at.hour < 12 ? "오전" : "오후"
    // 0시·12시가 12 가 되어야 한다 — `hour % 12` 만 쓰면 자정이 「오전 0:05」로 찍힌다.
    let hour12 = at.hour % 12 == 0 ? 12 : at.hour % 12
    let minute = String(format: "%02d", at.minute)
    return "\(at.month)월 \(at.day)일 \(meridiem) \(hour12):\(minute)"
}

/// 다음 페이지를 불러야 하는가.
///
/// **`hasNext` 가 false 면 절대 부르지 않는다.** 서버는 `hasNext == false` 일 때 `nextCursor` 를
/// 항상 nil 로 주므로, 그래도 부르면 **커서 없이 첫 페이지를 다시 받아** 목록이 무한히 중복된다
/// (실측 근거는 `RideRecordPageResponse` 주석). `loading` 가드는 스크롤이 같은 커서로 두 번
/// 불리는 흔한 사고를 막는다.
///
/// ### `failed` 가 세 번째 가드인 이유 — 여기가 진짜 무한 루프였다
/// 다음 페이지 조회가 실패해도 `hasNext`·`nextCursor` 는 살아 있다. 그래서 실패로 `loading` 이
/// true→false 로 떨어지는 순간 바닥에 머물러 있던 스크롤이 **같은 요청을 즉시 다시 쏜다.**
/// 백오프가 없어 응답 실패마다 재발사되고, 사용자는 화면에서 아무 안내도 못 본 채 스피너가
/// 깜빡이는 것만 본다 — 멈추는 길은 위로 스크롤하거나 화면을 떠나는 것뿐이다.
///
/// 그래서 실패 뒤 자동 재시도를 끊고, 재개는 사용자가 「다시 시도」를 눌러 `failed` 를 내렸을 때만 한다.
func shouldLoadMore(hasNext: Bool, loading: Bool, failed: Bool = false) -> Bool {
    hasNext && !loading && !failed
}

// ─── 서버 시각 ───────────────────────────────────────────────────────────────
//
// 원본도 `toInstantOrNull` 을 `ChatRoute.kt` 와 이 파일에 따로 둔다. 기능 모듈끼리는 서로 import 할 수
// 없어 FeatureChat 의 해석기를 쓰지 못하고, 받는 꼴이 같아야 하므로 같은 구현을 옮겼다.

/// `java.time.Instant` 자리. `Date` 는 초를 `Double` 로 들고 있어 소수 초가 어긋날 수 있다.
struct RideHistoryInstant: Equatable, Sendable {
    let epochSecond: Int64
    let nano: Int

    /// 기기 시간대의 달력 값. java.time 과 같이 그레고리력을 과거로 그대로 늘린 달력이다.
    func local(zone: TimeZone) -> RideHistoryLocalDateTime {
        let probe = Date(timeIntervalSince1970: TimeInterval(epochSecond))
        let seconds = epochSecond + Int64(zone.secondsFromGMT(for: probe))
        let days = floorDiv(seconds, 86_400)
        let secondOfDay = seconds - days * 86_400
        let (year, month, day) = civilFromDays(days)
        return RideHistoryLocalDateTime(
            year: year,
            month: month,
            day: day,
            hour: Int(secondOfDay / 3_600),
            minute: Int(secondOfDay % 3_600 / 60)
        )
    }
}

struct RideHistoryLocalDateTime: Equatable, Sendable {
    let year: Int64
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
}

private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let quotient = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
}

/// 1970-01-01 부터의 일 수 ← 달력 날짜 (Howard Hinnant `days_from_civil`).
private func daysFromCivil(year: Int64, month: Int, day: Int) -> Int64 {
    let y = month <= 2 ? year - 1 : year
    let era = floorDiv(y, 400)
    let yearOfEra = y - era * 400
    let shiftedMonth = Int64(month > 2 ? month - 3 : month + 9)
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + Int64(day) - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

/// 달력 날짜 ← 1970-01-01 부터의 일 수 (Howard Hinnant `civil_from_days`).
private func civilFromDays(_ days: Int64) -> (year: Int64, month: Int, day: Int) {
    let shifted = days + 719_468
    let era = floorDiv(shifted, 146_097)
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = Int(dayOfYear - (153 * shiftedMonth + 2) / 5 + 1)
    let month = Int(shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9)
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return (year, month, day)
}

private func daysInMonth(year: Int64, month: Int) -> Int {
    switch month {
    case 2:
        let leap = (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0)
        return leap ? 29 : 28
    case 4, 6, 9, 11:
        return 30
    default:
        return 31
    }
}

/// `Instant.parse` 실패 시 `OffsetDateTime.parse` 로 넘어가는 원본의 두 단계를 한 번에 받는 해석기.
/// `ISO8601DateFormatter` 는 소수 초 유무를 옵션으로 갈라야 하고 자릿수·소문자·오프셋 초 처리도 달라 쓰지 않는다.
///
/// 받는 꼴(JDK 결과와 대조해 `RideHistoryBehaviorTest` 에 못 박았다):
/// `연-월-일 T 시:분[:초[.소수 0~9자리]] (Z | ±시[:분[:초]])`, `T`·`Z` 는 소문자도 된다.
/// 연도는 부호 없이 4자리, `+` 면 5자리 이상, `-` 면 4자리 이상이다. `24:00:00`(다음 날 0시)과 `23:59:60`(윤초)을 받는다.
private struct InstantScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    private var isAtEnd: Bool { index >= bytes.count }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard !isAtEnd, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func consumeIgnoringCase(_ upper: UInt8) -> Bool {
        consume(upper) || consume(upper + 32)
    }

    /// 숫자 정확히 `count` 자리.
    private mutating func digits(_ count: Int) -> Int? {
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for offset in 0..<count {
            let byte = bytes[index + offset]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        index += count
        return value
    }

    private mutating func digitRun() -> [UInt8] {
        let start = index
        while !isAtEnd, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            index += 1
        }
        return Array(bytes[start..<index])
    }

    private mutating func year() -> Int64? {
        let negative = consume(0x2D)
        let positive = !negative && consume(0x2B)
        let run = digitRun()
        if positive {
            guard run.count >= 5 else { return nil }
        } else if negative {
            guard run.count >= 4 else { return nil }
        } else {
            guard run.count == 4 else { return nil }
        }
        // java.time 의 연도 범위(±999,999,999)
        guard run.count <= 9 else { return nil }
        let value = run.reduce(Int64(0)) { $0 * 10 + Int64($1 - 0x30) }
        return negative ? -value : value
    }

    /// `Z` 또는 `±시[:분[:초]]` → 초. 범위는 `ZoneOffset` 과 같이 ±18:00 이다.
    private mutating func offsetSeconds() -> Int? {
        if consumeIgnoringCase(0x5A) { return 0 }
        let sign: Int
        if consume(0x2B) {
            sign = 1
        } else if consume(0x2D) {
            sign = -1
        } else {
            return nil
        }
        guard let hours = digits(2) else { return nil }
        var minutes = 0
        var seconds = 0
        if consume(0x3A) {
            guard let parsedMinutes = digits(2), parsedMinutes <= 59 else { return nil }
            minutes = parsedMinutes
            if consume(0x3A) {
                guard let parsedSeconds = digits(2), parsedSeconds <= 59 else { return nil }
                seconds = parsedSeconds
            }
        }
        let total = hours * 3_600 + minutes * 60 + seconds
        guard total <= 18 * 3_600 else { return nil }
        return sign * total
    }

    mutating func parse() -> RideHistoryInstant? {
        guard let year = year(), consume(0x2D),
              let month = digits(2), (1...12).contains(month), consume(0x2D),
              let day = digits(2), day >= 1, day <= daysInMonth(year: year, month: month),
              consumeIgnoringCase(0x54),
              let hour = digits(2), consume(0x3A),
              let minute = digits(2)
        else { return nil }

        var second = 0
        var nano = 0
        var hasSeconds = false
        if consume(0x3A) {
            guard let parsedSecond = digits(2) else { return nil }
            second = parsedSecond
            hasSeconds = true
            if consume(0x2E) {
                let fraction = digitRun()
                guard fraction.count <= 9 else { return nil }
                nano = fraction.reduce(0) { $0 * 10 + Int($1 - 0x30) }
                for _ in fraction.count..<9 {
                    nano *= 10
                }
            }
        }
        guard let offset = offsetSeconds(), isAtEnd else { return nil }

        var dayCarry: Int64 = 0
        var resolvedHour = hour
        var resolvedSecond = second
        if hour == 24, minute == 0, second == 0, nano == 0, hasSeconds {
            // `Instant.parse` 는 하루의 끝 24:00:00 을 다음 날 0시로 받는다.
            resolvedHour = 0
            dayCarry = 1
        } else if hour == 23, minute == 59, second == 60 {
            // 윤초 — `Instant.parse` 는 59초로 접는다.
            resolvedSecond = 59
        } else {
            guard hour <= 23, minute <= 59, second <= 59 else { return nil }
        }

        let days = daysFromCivil(year: year, month: month, day: day) + dayCarry
        let secondOfDay = Int64(resolvedHour * 3_600 + minute * 60 + resolvedSecond)
        return RideHistoryInstant(epochSecond: days * 86_400 + secondOfDay - Int64(offset), nano: nano)
    }
}

extension String {
    /// 서버 ISO-8601(Instant 또는 오프셋 표기) → Instant. 그 외 형식은 nil.
    func toInstantOrNull() -> RideHistoryInstant? {
        var scanner = InstantScanner(self)
        return scanner.parse()
    }
}
