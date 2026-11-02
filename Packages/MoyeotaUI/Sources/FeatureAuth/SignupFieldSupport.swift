import MoyeotaDesignSystem
import MoyeotaDomain
import SwiftUI

// 가입 폼 화면들이 공유하는 입력 검증·소형 컴포넌트.
//
// 여기 모인 것들은 원래 09 본인 인증 화면 안의 private 선언이었다. 09 가 가입 경로에서 빠지고
// 실명·생년월일·성별·휴대폰 입력이 10 프로필 만들기로 합쳐지면서, **같은 규칙을 두 파일이
// 각자 복제하지 않도록** 패키지 공용으로 끌어올렸다(09 파일은 재사용 대비로 남아 있다).
// 규칙 자체는 하나도 바꾸지 않았다 — 옮기기만 했다.
//
// 원본의 `NicknamePolicy` 는 다른 기능도 쓰므로 `PresentationCore` 로 옮겼다.

/// 원본 `Regex.matches(input)`(java.util.regex 전체 일치)와 **같은 판정**을 내는 자리.
///
/// 패턴 문자열은 원본과 글자까지 같고, 해석만 Swift 기본값에서 Java 쪽으로 맞춘다.
/// - Java 정규식은 코드포인트 단위다 — Swift 기본값은 문자소 단위라 자모로 풀어 쓴 「가」(NFD)가 `[가-힣]` 을 통과한다.
/// - Java 의 `\s` 는 ASCII 공백뿐이다 — Swift 기본값은 전각 공백까지 공백으로 쳐서 이메일 판정이 달라진다.
struct JavaRegex: Sendable {
    let pattern: String

    init(_ pattern: String) {
        self.pattern = pattern
    }

    func matches(_ input: String) -> Bool {
        // 패턴은 이 파일의 상수뿐이고 테스트가 전부 지나간다 — 여기서 실패하면 코드 결함이다.
        guard let regex = try? Regex(pattern) else {
            preconditionFailure("잘못된 정규식 상수: \(pattern)")
        }
        return input.wholeMatch(
            of: regex.asciiOnlyWhitespace().matchingSemantics(.unicodeScalar)
        ) != nil
    }
}

/// 유효값 검증: 이름 — 한글 또는 영문 2~20자 (서버 `AuthPolicy.NAME_MAX_LENGTH` = 20).
///
/// 한글 전용이던 규칙을 넓혔다: 에뮬레이터에는 한글 IME 가 없어 한글만 받으면 QA 가 막히고,
/// 서버도 한글을 강제하지 않는다.
let PersonNameRegex = JavaRegex("^[가-힣a-zA-Z]{2,20}$")

/// 생년월일 입력 하한 — 이보다 이르면 오타로 본다
private let MIN_BIRTH_YEAR = 1900

/// Kotlin `String.toIntOrNull()` — 앞의 `+`·`-` 를 받고, 숫자는 유니코드 Nd 전부를 받는다.
/// 입력은 생년월일 조각(최대 4칸)이라 넘침이 없다.
private func toIntOrNull(_ units: ArraySlice<UInt16>) -> Int? {
    guard let first = units.first else { return nil }
    let negative = first == UInt16(ascii: "-")
    let digits = negative || first == UInt16(ascii: "+") ? units.dropFirst() : units
    if digits.isEmpty { return nil }
    var result = 0
    for unit in digits {
        guard let scalar = Unicode.Scalar(unit), scalar.isKotlinDigit,
              let value = scalar.properties.numericValue
        else { return nil }
        result = result * 10 + Int(value)
    }
    return negative ? -result : result
}

private extension UInt16 {
    init(ascii scalar: Unicode.Scalar) {
        self = UInt16(UInt8(ascii: scalar))
    }
}

/// YYYYMMDD 8자리를 **달력에 실제로 있는 날짜**로. 과거·미래는 따지지 않는다.
///
/// `LocalDate(year:month:dayOfMonth:)` 는 없는 날짜(20250230)에 nil 이다.
/// 미래 판정을 여기서 하지 않는 이유: 호출부가 "날짜가 아니다"와 "미래다"를 **다른 문구로**
/// 말해야 하는데, 둘을 한 nil 로 뭉개면 구분할 방법이 없다(`birthDateError`).
private func parseCalendarDate(digits: String) -> LocalDate? {
    let units = Array(digits.utf16)
    if units.count != 8 { return nil }
    guard let year = toIntOrNull(units[0..<4]) else { return nil }
    if year < MIN_BIRTH_YEAR { return nil }
    guard let month = toIntOrNull(units[4..<6]) else { return nil }
    guard let day = toIntOrNull(units[6..<8]) else { return nil }
    return LocalDate(year: year, month: month, dayOfMonth: day)
}

/// YYYYMMDD 8자리를 **생년월일로 쓸 수 있는** `LocalDate` 로. 아니면 nil.
///
/// 없는 날짜(20250230)와 미래 날짜를 모두 거른다 — 화면은 이 값이 nil 이면 「다음」을 닫고,
/// 왜 닫혔는지는 `birthDateError` 가 말한다. 두 함수가 같은 입력에 대해 어긋나지 않게
/// 같은 `today` 를 받는다.
///
/// - Parameter today: 미래 판정 기준일. 기본값은 기기 시계이고, 테스트는 고정 날짜를 넣는다.
///   **연령 제한은 여기서 보지 않는다** — 만 14세 미만도 "실제로 있는 과거 날짜"이므로
///   파싱은 통과시키고, 가입을 막는 일은 `birthDateError` 와 화면의 「다음」 판정이 한다.
func parseBirthDate(digits: String, today: LocalDate = LocalDate.now()) -> LocalDate? {
    guard let date = parseCalendarDate(digits: digits), !date.isAfter(today) else { return nil }
    return date
}

/// 생년월일 입력의 오류 문구. 쓸 말이 없으면 nil.
///
/// 거절 사유가 셋이고 **할 일이 전부 다르므로 한 문구도 겹치지 않는다**:
/// 1. 달력에 없는 날짜(20250230) → 숫자를 고치면 된다
/// 2. 오늘 이후(`AuthPolicy.isValidBirthDate`) → 역시 숫자를 고치면 된다. 보내면 서버가 400 이다
/// 3. 만 `AuthPolicy.MIN_AGE` 세 미만(`AuthPolicy.isOldEnough`) → **고칠 게 없다. 가입이 안 된다**
///
/// 3번을 1·2번과 같은 문구("입력이 올바르지 않습니다" 류)로 접으면 사용자는 날짜를 몇 번 고쳐
/// 보다가 왜 막혔는지 끝까지 모른다. 반대로 1·2번에 "만 14세 미만은…"을 띄우면 2005 를 2025 로
/// 잘못 친 사람에게 엉뚱한 사실을 말하게 된다.
///
/// 8자리를 채우기 전에는 아무 말도 하지 않는다 — "아직 안 썼다"는 틀린 게 아니다(닉네임과 같은 규칙).
///
/// - Parameter today: 만 나이 계산 기준일. 기본값은 기기 시계다.
func birthDateError(digits: String, today: LocalDate = LocalDate.now()) -> String? {
    if digits.utf16.count < 8 { return nil }
    guard let date = parseCalendarDate(digits: digits) else { return "실제로 있는 날짜를 YYYYMMDD 로 입력해 주세요" }
    // 사용자 지역의 오늘(date.isAfter)과 서버 @Past 기준(UTC)을 함께 본다 — 어느 쪽이든 보낼 수 없는 값이다
    if date.isAfter(today) || !AuthPolicy.isValidBirthDate(value: date) {
        return "생년월일은 오늘 이전 날짜로 입력해 주세요"
    }
    if !AuthPolicy.isOldEnough(birthDate: date, today: today) {
        return "만 \(AuthPolicy.MIN_AGE)세 미만은 가입할 수 없어요. 생년월일을 다시 확인해 주세요"
    }
    return nil
}

/// 생년월일 입력란 아래에 늘 띄우는 안내 — 다 쓰고 나서 막히는 대신 **미리** 알려준다.
let BirthDateHelperText = "만 \(AuthPolicy.MIN_AGE)세 이상만 가입할 수 있어요"

/// 서버가 형식을 최종 판정하므로 여기서는 "@ 와 . 가 있는 한 덩어리"만 본다.
/// 정교한 RFC 검사를 흉내 내면 정상 주소를 막는 쪽 사고가 더 흔하다.
let SimpleEmailRegex = JavaRegex(#"^[^@\s]+@[^@\s]+\.[^@\s]+$"#)

// ─────────────────────────────── 성별 선택지 ───────────────────────────────

/// 성별 칩 하나 — 값과 화면에 보일 라벨.
struct GenderChoice: Equatable, Sendable {
    let gender: Gender
    let label: String
}

/// **운영 서버가 `Gender.undisclosed` 를 받는가.**
///
/// 제품 토글이 아니라 **서버에 대한 사실**이다. 백엔드 PR #235 가 2026-10-15 운영에 배포되면서
/// 운영 스펙(`/v3/api-docs`)의 `gender` 가 `["MALE","FEMALE","UNDISCLOSED"]` 가 된 것을
/// 실측 확인하고 `true` 로 열었다.
///
/// **상수를 남겨 두는 이유**는 서버가 값을 **되돌릴 수도** 있기 때문이다. 마이그레이션을 되감거나
/// 운영을 옛 버전으로 롤백하면 `user_profile.gender` 의 CHECK 제약이 다시 이 값을 거부한다.
/// 그때 선택지를 숨기는 길이 이 한 줄이면 되게 둔다.
///
/// 켜고 끄는 판단이 왜 중요한지 — **400 이 떨어지는 자리** 때문이다. 가입 제출은 10 이 아니라
/// 12 매너 서약의 「동의하고 가입 완료」 한 곳이고, 그때 사용자는 이미 9개 필드를 다 채우고
/// 문자 인증까지 끝낸 상태다(인증 문자는 하루 `AuthPolicy.SMS_DAILY_LIMIT` 번이 한도다).
/// 돌아오는 문구는 `AuthError.invalidRequest` 의 "입력한 정보를 다시 확인해 주세요" 뿐이라
/// 성별이 원인이라는 단서가 없다 — 사용자는 고칠 곳을 못 찾고 재시도로 문자 한도를 태운다.
/// 고를 수 있게 해 놓고 고르면 가입이 안 되는 선택지는 없는 선택지보다 나쁘다.
///
/// `SignupGenderChoicesTest` 가 이 상수와 선택지 목록이 어긋나지 않게 잡는다.
let ServerAcceptsUndisclosedGender = true

/// 「선택 안 함」 선택지. `ServerAcceptsUndisclosedGender` 가 `false` 인 동안에도 **라벨은 여기
/// 고정**된다 — 노출이 켜지는 시점에 「비공개」·「밝히지 않음」 같은 다른 말로 갈리지 않게 한다.
let UndisclosedGenderChoice = GenderChoice(gender: .undisclosed, label: "선택 안 함")

/// 가입 화면의 성별 선택지 — **라벨·순서·노출 여부의 유일한 출처.**
///
/// 화면이 칩을 직접 나열하면 선택지가 늘 때 두 화면이 어긋난다(09 가 10 과 성별 UI 를 복제하고
/// 있던 것이 그 예다). 목록을 돌려 그리면 노출 판정이 한 곳에만 있다.
///
/// **고르지 않은 상태(`nil`)는 이 목록에 없다.** 성별은 여전히 필수라서 `nil` 은 제출 불가를
/// 뜻하고(`SignupDraft.toNewUser`), 「선택 안 함」은 그와 **다른** 하나의 값이다.
let SignupGenderChoices: [GenderChoice] = [
    GenderChoice(gender: .male, label: "남성"),
    GenderChoice(gender: .female, label: "여성"),
] + (ServerAcceptsUndisclosedGender ? [UndisclosedGenderChoice] : [])

// ─────────────────────────────── 입력 거르기 ───────────────────────────────

/// `raw.filter { !it.isWhitespace() }` 자리. 공백은 규칙상 못 쓰는 문자다 — 오류로 튕기기보다 조용히 걸러 받는다.
func withoutWhitespace(_ raw: String) -> String {
    var kept = String.UnicodeScalarView()
    kept.append(contentsOf: raw.unicodeScalars.filter { !$0.isKotlinWhitespace })
    return String(kept)
}

/// Kotlin `String.take(n)` 자리. 원본 글자 수는 UTF-16 한 칸 단위라 이모지는 두 칸을 먹는다.
func takeUtf16(_ text: String, _ count: Int) -> String {
    String(decoding: text.utf16.prefix(count), as: UTF16.self)
}

/// 선택지 칩 안의 글자색 (미선택 상태)
private let SlateGray = Color(argb: 0xFF4B5563)

/// 가입 폼의 한 줄 선택지 칩 — 성별 3택처럼 값이 몇 개 안 되는 선택에 쓴다.
/// (09 의 통신사 4택에서 쓰던 모양 그대로다)
///
/// **선택 상태를 읽어 준다.** `selected` 를 색과 테두리로만 그리면 VoiceOver 에는 칩 셋이 전부
/// 같은 「버튼」으로 들린다. 성별에서는 그 손실이 특히 크다 — 「선택 안 함」이 **골라서** 그런
/// 것인지 **아직 아무것도 고르지 않아서** 그렇게 적혀 있는 것인지 구분할 길이 사라진다.
/// 그래서 선택 상태를 `.isSelected` 특성으로 싣는다.
///
/// 높이는 고정이 아니라 **최솟값**이다. 고정 44pt 였다면 두 줄이 된 「선택 안 함」의 둘째 줄이 잘려
/// 「선택」만 남는다 — 선택지의 뜻이 반대로 읽히는 쪽이 칩 높이가 들쭉날쭉한 쪽보다 나쁘다.
/// 한 줄이면 셋 다 44pt 그대로다.
///
/// 원본 호출부는 전부 `Modifier.weight(1f)` 로 균등 분할하므로 칩이 폭을 스스로 채운다.
struct SignupChoiceChip: View {
    let text: String
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .circular)
        Button(action: onClick) {
            Text(text)
                .moyeotaText(
                    MoyeotaType.BodySm.copy(fontWeight: selected ? .bold : .medium),
                    color: selected ? MoyeotaColor.Primary500 : SlateGray
                )
                .multilineTextAlignment(.center)
                // 3분할에서 테두리에 글자가 닿지 않게 한다. 360pt 폭 기준 칩 하나가 104pt 이고
                // 「선택 안 함」은 13pt 에서 60pt 가 채 안 되므로 한 줄로 들어간다.
                .lineLimit(2)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if selected {
                        shape.fill(MoyeotaColor.Primary50)
                            .overlay(shape.strokeBorder(MoyeotaColor.Primary500, lineWidth: 1.5))
                    } else {
                        shape.fill(Color.white)
                            .moyeotaShadow(elevation: 2, shape: shape)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(ChipPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 잉크 리플 자리의 눌림 표시. 칩은 투명도 60% 다(`docs/IOS-DIFFERENCES.md`).
private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// `Modifier.clickable(indication = null)` 자리. 눌러도 아무 표시가 없고, 글자 영역 전체가 탭 영역이다.
struct NoIndicationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
    }
}
