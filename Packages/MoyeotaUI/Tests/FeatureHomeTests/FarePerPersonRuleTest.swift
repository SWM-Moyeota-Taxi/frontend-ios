import Testing
@testable import FeatureHome

/// 16 도착지 확인의 1인 요금 계산 규칙.
///
/// **이 테스트의 존재 이유는 「두 화면이 같은 금액을 쓴다」를 못 박는 것이다.** 16 은 방을 만들기
/// 전의 추정 총액을 고른 인원으로 나누고(여기), 19 합류·22 상세·25 배차는 서버가 방에 박아 둔 요금을
/// 정원으로 나눈 값을 쓴다(data 쪽 `farePerPerson`). 나누는 수가 같은 값(정원)이라 **반올림 규칙만
/// 어긋나도 같은 방이 화면마다 다른 금액**을 보여 준다 — 실제로 7,900원·3인 방이 16 에서 2,630원,
/// 25 에서 2,633원이었다(모달만 10원 단위로 반올림하고 매퍼는 Int 나눗셈으로 절삭했다).
///
/// 모듈 경계(presentation ↔ data) 때문에 함수를 공유할 수 없으므로, **아래 표를 data 쪽
/// `PartyMappersTest.1인당 요금은 10원 단위로 반올림한다` 와 같은 값으로 유지한다.** 한쪽 규칙만
/// 고치면 반대쪽 테스트가 깨지고, 그때 두 화면 중 어디가 틀렸는지 다시 묻게 된다.
@Suite struct FarePerPersonRuleTest {

    @Test("10원 단위로 반올림한다")
    func roundsToTens() {
        #expect(farePerPersonWon(totalFare: 7900, people: 3) == 2630) // 2633.33 → 내림
        #expect(farePerPersonWon(totalFare: 8000, people: 3) == 2670) // 2666.67 → 올림
        #expect(farePerPersonWon(totalFare: 9650, people: 2) == 4830) // 4825 → 올림(.5)
        #expect(farePerPersonWon(totalFare: 9600, people: 3) == 3200) // 딱 나뉘는 값
        #expect(farePerPersonWon(totalFare: 7900, people: 1) == 7900) // 혼자 타면 전액
    }

    /// 1원 단위 금액을 쓰지 않는다는 것 — 택시 요금은 10원 단위로 표기되고, 「2,633원」은 실제로
    /// 낼 수 없는 금액을 1원까지 약속하는 셈이다. 칩이 고를 수 있는 세 인원 모두에서 확인한다.
    @Test("어떤 인원에서도 10원 단위로만 끊는다")
    func alwaysTens() {
        for people in [1, 2, 3] {
            for total in [3300, 7900, 8000, 9650, 12_340] {
                let perPerson = farePerPersonWon(totalFare: total, people: people)
                #expect(perPerson % 10 == 0, "총 \(total)원 ÷ \(people)명 이 10원 단위가 아니다")
            }
        }
    }

    /// 인원이 0 이하면 0 — 화면에서는 칩이 1~3 뿐이라 닿지 않는 길이지만, data 쪽의
    /// `capacity <= 0` 가드와 **같은 모양**을 유지해 두 규칙의 비교가 성립하게 한다.
    @Test("인원이 0 이하면 0 이다")
    func nonPositivePeople() {
        #expect(farePerPersonWon(totalFare: 9600, people: 0) == 0)
        #expect(farePerPersonWon(totalFare: 9600, people: -1) == 0)
    }
}
