import MoyeotaDomain
import Testing
@testable import FeatureAuth

/// 10 프로필 만들기(와 09 본인 인증)의 생년월일 판정 — **만 14세 미만 가입 차단**이 핵심이다.
///
/// 문구까지 못 박는 이유: 개인정보 처리방침에 「만 14세 미만은 가입할 수 없습니다」로 고지할 예정이고,
/// 서버에는 연령 제한이 없어(`UserRegisterRequest` 는 `@Past` 뿐) **이 판정이 앱의 유일한 방어선**이다.
/// 고지와 동작이 어긋나면 둘 중 하나가 거짓이 되고, 뭉뚱그린 문구를 쓰면 사용자는 왜 막혔는지 모른다.
///
/// 기준일을 전부 고정값(`Today`)으로 넣는다 — 경계값(생일 하루 전/당일/하루 뒤)이 이 테스트의
/// 전부인데 기기 시계에 묶이면 셋 중 어느 것도 검증할 수 없다. 기준일을 **인자로 받는 설계**가
/// 그래서 필요했다(`AuthPolicy.isOldEnough`).
@Suite struct BirthDateRulesTest {
    /// 고정 기준일. 아래 생년월일은 모두 이 날짜에 대해 계산한다.
    private let Today = date(2026, 10, 13)

    /// 기대 문구를 상수가 아니라 **글자 그대로** 적는다. `AuthPolicy.MIN_AGE` 를 고치면 이 테스트가
    /// 깨져야 한다 — 숫자만 바꾸고 개인정보 처리방침 고지를 그대로 두는 일을 막는 장치다.
    private let UnderAgeMessage = "만 14세 미만은 가입할 수 없어요. 생년월일을 다시 확인해 주세요"
    private let FutureMessage = "생년월일은 오늘 이전 날짜로 입력해 주세요"
    private let NotADateMessage = "실제로 있는 날짜를 YYYYMMDD 로 입력해 주세요"

    private func digits(_ date: LocalDate) -> String { date.format(.basicIsoDate) }

    /// 10·09 의 「다음」 판정과 같은 식 — 문구가 남아 있으면 넘어가지 않는다.
    private func canProceed(_ digits: String, _ today: LocalDate) -> Bool {
        parseBirthDate(digits: digits, today: today) != nil && birthDateError(digits: digits, today: today) == nil
    }

    // ─────────────────────────── 경계값: 만 14세 생일 ───────────────────────────

    @Test("만 14세 생일 하루 전이면 가입할 수 없다")
    func dayBeforeBirthday() {
        // 2012-10-14 생은 2026-10-14 에 만 14세가 된다 — 기준일은 그 하루 전이다
        let birth = date(2012, 10, 14)

        #expect(!AuthPolicy.isOldEnough(birthDate: birth, today: Today))
        #expect(!canProceed(digits(birth), Today))
        #expect(birthDateError(digits: digits(birth), today: Today) == UnderAgeMessage)
    }

    @Test("만 14세 생일 당일부터 가입할 수 있다")
    func onBirthday() {
        let birth = date(2012, 10, 13)

        #expect(AuthPolicy.isOldEnough(birthDate: birth, today: Today), "생일 당일에 만 14세가 된다")
        #expect(canProceed(digits(birth), Today))
        #expect(birthDateError(digits: digits(birth), today: Today) == nil)
    }

    @Test("만 14세 생일 하루 뒤도 통과한다")
    func dayAfterBirthday() {
        let birth = date(2012, 10, 12)

        #expect(AuthPolicy.isOldEnough(birthDate: birth, today: Today))
        #expect(birthDateError(digits: digits(birth), today: Today) == nil)
    }

    /// 연도 빼기로 계산하면 통과해 버리는 입력 — 만 나이로 세야 하는 이유 그 자체다.
    @Test("연도 차이가 14여도 생일 전이면 거절한다")
    func yearDifferenceIsNotAge() {
        let birth = date(2012, 12, 31)
        let newYearsDay = date(2026, 1, 1) // 2026 - 2012 = 14

        #expect(!AuthPolicy.isOldEnough(birthDate: birth, today: newYearsDay), "아직 13세다")
        #expect(birthDateError(digits: digits(birth), today: newYearsDay) == UnderAgeMessage)
        // 그 해 생일이 오면 통과한다
        #expect(AuthPolicy.isOldEnough(birthDate: birth, today: date(2026, 12, 31)))
    }

    // ─────────────────────────── 윤년 2월 29일생 ───────────────────────────

    /// 평년에는 2월 29일이 없다. 민법 제160조 ③(해당일이 없으면 그 달 말일)과 같게
    /// **2월 28일에 만 14세가 된다** — 법적으로 14세인 사람을 하루 더 막지 않는다.
    /// 무엇보다 **어떤 조합에서도 예외를 던지지 않아야 한다**(윤년 계산은 그래서 직접 하지 않는다).
    @Test("윤년 2월 29일생은 평년에도 예외 없이 판정된다")
    func leapBirthday() {
        let birth = date(2008, 2, 29)

        #expect(!AuthPolicy.isOldEnough(birthDate: birth, today: date(2022, 2, 27)), "2월 27일은 아직 13세")
        #expect(AuthPolicy.isOldEnough(birthDate: birth, today: date(2022, 2, 28)), "평년 생일은 2월 28일")
        #expect(AuthPolicy.isOldEnough(birthDate: birth, today: date(2022, 3, 1)))
        // 윤년이 돌아온 해의 2월 29일(만 16세)도 그대로 통과한다
        #expect(AuthPolicy.isOldEnough(birthDate: birth, today: date(2024, 2, 29)))

        #expect(birthDateError(digits: "20080229", today: date(2022, 2, 28)) == nil)
        #expect(birthDateError(digits: "20080229", today: date(2022, 2, 27)) == UnderAgeMessage)
    }

    /// 기준일이 2월 29일인 경우도 같은 규칙이다 — 경계가 윤일에 걸려도 하루 전은 하루 전이다.
    /// (2010-02-29 생은 애초에 `LocalDate` 가 될 수 없어 입력 단계에서 걸린다 — 그래서 여기 없다)
    @Test("기준일이 윤일이어도 생일 하루 전은 거절한다")
    func leapToday() {
        let leapDay = date(2024, 2, 29)

        #expect(AuthPolicy.isOldEnough(birthDate: date(2010, 2, 28), today: leapDay), "전날이 생일이면 이미 14세")
        #expect(!AuthPolicy.isOldEnough(birthDate: date(2010, 3, 1), today: leapDay), "3월 1일이 생일이면 아직 하루 남았다")
        // 윤일에 태어난 사람의 생일 당일(평년 2월 28일)은 위 테스트가 본다
        #expect(birthDateError(digits: "20100228", today: leapDay) == nil)
        #expect(birthDateError(digits: "20100301", today: leapDay) == UnderAgeMessage)
    }

    // ─────────────────────────── 미래 날짜는 기존 검증이 잡는다 ───────────────────────────

    /// 미래 날짜는 **연령과 다른 문구**로 막아야 한다. 서버 `@Past` 에 걸려 400 이 될 값이므로
    /// 할 일은 "숫자를 고치는 것"이고, 만 14세 미만은 고칠 게 없는 상황이다.
    @Test("미래 날짜는 연령과 다른 문구로 막는다")
    func futureDate() {
        #expect(!AuthPolicy.isValidBirthDate(value: date(2999, 1, 1)))
        #expect(parseBirthDate(digits: "29990101", today: Today) == nil, "파싱 단계에서 이미 걸러진다")
        #expect(birthDateError(digits: "29990101", today: Today) == FutureMessage)
        #expect(birthDateError(digits: "29990101", today: Today) != UnderAgeMessage)
        // 연령 판정에 넣어도 예외 없이 false 다(막는 방향은 같다 — 문구만 다르다)
        #expect(!AuthPolicy.isOldEnough(birthDate: date(2999, 1, 1), today: Today))
    }

    /// 내일은 어느 시계로 봐도 미래다. 실제 시계를 쓰는 이유는 고정 날짜로 적으면 테스트를
    /// 돌리는 날에 따라 "내일"이 아니게 되기 때문이다.
    @Test("내일 날짜는 오늘 이전 날짜 문구로 막는다")
    func tomorrow() {
        let now = LocalDate.now()

        #expect(birthDateError(digits: digits(now.plusDays(1)), today: now) == FutureMessage)
        #expect(!canProceed(digits(now.plusDays(1)), now))
    }

    /// 오늘 태어난 값도 가입으로 넘어갈 수 없다.
    ///
    /// **문구는 단정하지 않는다**: UTC 보다 앞선 지역(KST)에서는 서버 `@Past` 에 걸릴 값이라
    /// "오늘 이전 날짜로" 가 맞고, UTC 보다 뒤진 지역에서는 서버가 받아 줄 과거 Instant 라
    /// 연령 문구가 맞다. 둘 다 사실이므로 **막히는 것만** 못 박는다.
    @Test("오늘 날짜로는 가입을 진행할 수 없다")
    func todayBlocked() {
        let now = LocalDate.now()

        #expect(!canProceed(digits(now), now))
        #expect(birthDateError(digits: digits(now), today: now) != nil)
        #expect(!AuthPolicy.isOldEnough(birthDate: now, today: now))
    }

    // ─────────────────────────── 아주 오래된 날짜 ───────────────────────────

    @Test("1900년생도 예외 없이 통과한다")
    func year1900() {
        let birth = date(1900, 1, 1)

        #expect(AuthPolicy.isOldEnough(birthDate: birth, today: Today))
        #expect(parseBirthDate(digits: "19000101", today: Today) == birth)
        #expect(birthDateError(digits: "19000101", today: Today) == nil)
    }

    /// 1900년 이전은 오타로 본다(입력 하한) — 연령 문구가 아니라 형식 문구다.
    @Test("1900년보다 이른 해는 오타로 본다")
    func before1900() {
        #expect(parseBirthDate(digits: "18991231", today: Today) == nil)
        #expect(birthDateError(digits: "18991231", today: Today) == NotADateMessage)
    }

    // ─────────────────────────── 형식·미입력 ───────────────────────────

    @Test("8자리를 채우기 전에는 아무 말도 하지 않는다")
    func incompleteSilent() {
        #expect(birthDateError(digits: "", today: Today) == nil)
        #expect(birthDateError(digits: "2012", today: Today) == nil)
        #expect(birthDateError(digits: "2012101", today: Today) == nil)
        // 그래도 「다음」은 열리지 않는다 — 아직 값이 없다
        #expect(!canProceed("2012101", Today))
    }

    @Test("달력에 없는 날짜는 형식 문구로 막는다")
    func notACalendarDate() {
        #expect(birthDateError(digits: "20250230", today: Today) == NotADateMessage)
        #expect(birthDateError(digits: "20251301", today: Today) == NotADateMessage)
        #expect(!canProceed("20250230", Today))
    }

    // ─────────────────────────── 문구가 서로 겹치지 않는지 ───────────────────────────

    /// 세 사유의 **할 일이 전부 다르므로** 한 문구도 겹쳐선 안 된다. 특히 연령은
    /// "입력이 올바르지 않습니다" 류로 접으면 사용자가 날짜만 고쳐 보다 끝까지 이유를 모른다.
    @Test("형식 미래 연령 세 문구는 서로 다르고 연령은 이유를 말한다")
    func threeMessagesDiffer() throws {
        let notADate = birthDateError(digits: "20250230", today: Today)
        let future = birthDateError(digits: "29990101", today: Today)
        let underAge = try #require(birthDateError(digits: "20121014", today: Today))

        #expect(notADate != future)
        #expect(notADate != underAge)
        #expect(future != underAge)

        #expect(underAge.contains("만 \(AuthPolicy.MIN_AGE)세 미만"), "무엇이 문제인지 말해야 한다")
        #expect(underAge.contains("가입할 수 없어요"))
        // 뭉뚱그린 문구 금지
        #expect(!underAge.contains("올바르지 않"))
    }

    /// 입력 전에 미리 알려주는 안내도 같은 숫자를 본다 — 고지와 동작이 어긋나지 않게.
    @Test("생년월일 안내 문구는 같은 최소 연령을 말한다")
    func helperText() {
        #expect(BirthDateHelperText == "만 \(AuthPolicy.MIN_AGE)세 이상만 가입할 수 있어요")
    }

    // ─────────────────────────── 09 본인 인증 ───────────────────────────

    /// 09 는 현재 어떤 그래프에도 등록되어 있지 않지만 코드는 살아 있고, 같은 파싱·검증을 쓴다.
    /// 되살아날 때 연령 제한이 빠진 채로 돌아오지 않게 **기본 기준일(기기 시계)로도** 확인한다.
    @Test("기준일을 생략하면 기기 시계를 쓴다")
    func defaultToday() {
        let thirteen = LocalDate.now().minusYears(13)

        #expect(birthDateError(digits: digits(thirteen)) == UnderAgeMessage)
        // 파싱은 통과한다 — 만 13세도 "실제로 있는 과거 날짜"다. 그래서 09 의 CTA 는 문구까지 봐야 한다
        #expect(parseBirthDate(digits: digits(thirteen)) == thirteen)

        let adult = LocalDate.now().minusYears(30)
        #expect(birthDateError(digits: digits(adult)) == nil)
        #expect(parseBirthDate(digits: digits(adult)) == adult)
    }
}
