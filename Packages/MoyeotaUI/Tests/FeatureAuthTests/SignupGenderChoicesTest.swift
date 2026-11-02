import MoyeotaDomain
import Testing
@testable import FeatureAuth

/// 10 프로필 만들기의 성별 선택지 목록.
///
/// 목록이 화면 대신 선택지를 들고 있는 이유는 **노출 판정이 한 곳에만 있어야** 하기 때문이다.
/// 특히 `ServerAcceptsUndisclosedGender` 는 운영 서버가 `"UNDISCLOSED"` 를 받는지에 대한
/// 사실이라, 상수와 목록이 어긋나면 서버가 모르는 값을 고를 수 있게 되거나(가입이 400),
/// 서버는 받는데 선택지가 안 보이는 상태가 된다. 그 어긋남을 여기서 잡는다.
@Suite struct SignupGenderChoicesTest {
    /// **이 테스트가 노출 스위치의 유일한 감시자다.** 상수만 켜고 목록을 안 고치거나(또는 반대로)
    /// 하는 일이 없게 양방향으로 묶어 둔다 — 상수를 `true` 로 바꾸면 이 단정이 그대로 통과하고,
    /// 둘이 어긋나면 실패한다.
    @Test("선택 안 함은 서버가 그 값을 받을 때만 선택지에 들어간다")
    func undisclosedFollowsServerFlag() {
        let exposed = SignupGenderChoices.contains { $0.gender == .undisclosed }
        #expect(exposed == ServerAcceptsUndisclosedGender, "\(SignupGenderChoices)")
    }

    /// 라벨은 노출 전에도 고정이다 — 켜지는 날 「비공개」 같은 다른 말로 갈리지 않게 한다.
    @Test("선택 안 함의 라벨은 선택 안 함이다")
    func undisclosedLabel() {
        #expect(UndisclosedGenderChoice.label == "선택 안 함")
        #expect(UndisclosedGenderChoice.gender == .undisclosed)
    }

    /// 남성·여성은 서버 배포와 무관하게 늘 있고, 순서도 고정이다(와이어프레임 순서).
    @Test("남성 여성은 늘 이 순서로 있다")
    func maleFemaleOrder() {
        let genders = SignupGenderChoices.map(\.gender)
        #expect(genders[0] == .male, "\(genders)")
        #expect(genders[1] == .female, "\(genders)")
    }

    /// 「고르지 않은 상태」는 선택지가 아니다. `nil` 을 칩으로 세우면 「선택 안 함」과 같은 줄에
    /// 서게 되고, 그 순간 둘의 차이(제출 가능 / 불가)가 화면에서 사라진다.
    @Test("선택지는 중복 없는 값과 비어 있지 않은 라벨만 갖는다")
    func uniqueValuesAndLabels() {
        #expect(!SignupGenderChoices.isEmpty, "\(SignupGenderChoices)")
        #expect(SignupGenderChoices.count == Set(SignupGenderChoices.map(\.gender)).count)
        #expect(SignupGenderChoices.count == Set(SignupGenderChoices.map(\.label)).count)
        for choice in SignupGenderChoices {
            #expect(!choice.label.isBlank, "\(choice.gender)")
        }
    }
}
