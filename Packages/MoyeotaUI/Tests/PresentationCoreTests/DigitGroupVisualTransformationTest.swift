import MoyeotaDesignSystem
import Testing
@testable import PresentationCore

/// D-7 회귀 방어: 커서 좌표 변환(OffsetMapping)의 경계값 검증.
///
/// 실기에서 순서가 뒤집혔던 원인은 "구분자가 새로 끼는 순간"의 offset 처리였으므로,
/// 그 경계(휴대폰 3·7, 생년월일 4·6)와 길이 끝을 집중적으로 본다.
@Suite struct DigitGroupVisualTransformationTest {
    private let phone = PhoneNumberTransformation
    private let birth = BirthDateTransformation
    private let card = CardNumberTransformation
    private let expiry = CardExpiryTransformation

    @Test("휴대폰 표시 문자열은 자릿수에 따라 하이픈이 늘어난다")
    func phoneFormat() {
        #expect(phone.format("") == "")
        #expect(phone.format("010") == "010")
        // 뒤따르는 숫자가 없으면 꼬리 하이픈을 만들지 않는다
        #expect(phone.format("0101") == "010-1")
        #expect(phone.format("0101234") == "010-1234")
        #expect(phone.format("01012345") == "010-1234-5")
        #expect(phone.format("01012345678") == "010-1234-5678")
    }

    @Test("생년월일 표시 문자열은 YYYY-MM-DD 로 끊긴다")
    func birthFormat() {
        #expect(birth.format("1995") == "1995")
        #expect(birth.format("19950") == "1995-0")
        #expect(birth.format("199503") == "1995-03")
        #expect(birth.format("1995031") == "1995-03-1")
        #expect(birth.format("19950315") == "1995-03-15")
    }

    @Test("휴대폰 - 원시 offset 이 하이픈 개수만큼 밀린다")
    func phoneOriginalToTransformed() {
        let mapping = phone.filter("01012345678").offsetMapping
        // "010-1234-5678"
        #expect(mapping.originalToTransformed(0) == 0)
        #expect(mapping.originalToTransformed(2) == 2)
        // 경계 3: 커서는 하이픈 뒤 → "010-|1234-5678"
        #expect(mapping.originalToTransformed(3) == 4)
        #expect(mapping.originalToTransformed(4) == 5)
        // 경계 7: 하이픈 2 개를 지났다 → "010-1234-|5678"
        #expect(mapping.originalToTransformed(7) == 9)
        // 문자열 끝
        #expect(mapping.originalToTransformed(11) == 13)
    }

    @Test("휴대폰 - 표시 offset 이 원시 offset 으로 되돌아온다")
    func phoneTransformedToOriginal() {
        let mapping = phone.filter("01012345678").offsetMapping
        #expect(mapping.transformedToOriginal(0) == 0)
        // 하이픈 앞뒤(3·4)는 같은 원시 3 으로 접힌다
        #expect(mapping.transformedToOriginal(3) == 3)
        #expect(mapping.transformedToOriginal(4) == 3)
        #expect(mapping.transformedToOriginal(5) == 4)
        #expect(mapping.transformedToOriginal(8) == 7)
        #expect(mapping.transformedToOriginal(9) == 7)
        #expect(mapping.transformedToOriginal(13) == 11)
    }

    @Test("생년월일 - 경계 4 와 6 에서 커서가 하이픈 뒤에 선다")
    func birthBoundaries() {
        let mapping = birth.filter("19950315").offsetMapping
        // "1995-03-15"
        #expect(mapping.originalToTransformed(0) == 0)
        #expect(mapping.originalToTransformed(4) == 5)
        #expect(mapping.originalToTransformed(6) == 8)
        #expect(mapping.originalToTransformed(8) == 10)
        #expect(mapping.transformedToOriginal(4) == 4)
        #expect(mapping.transformedToOriginal(5) == 4)
        #expect(mapping.transformedToOriginal(8) == 6)
        #expect(mapping.transformedToOriginal(10) == 8)
    }

    @Test("타이핑 도중 모든 길이에서 왕복 변환과 표시 길이가 일치한다")
    func roundTripWhileTypingBirth() {
        // 19950315 를 한 글자씩 치는 과정 = D-7 재현 시나리오
        let full = "19950315"
        for length in 0...full.count {
            let digits = String(full.prefix(length))
            let transformed = birth.filter(digits)
            let displayed = transformed.text
            #expect(birth.format(digits) == displayed)

            var previous = -1
            for offset in 0...digits.count {
                let mapped = transformed.offsetMapping.originalToTransformed(offset)
                // 경계 안 + 단조 증가 — 둘 중 하나만 깨져도 커서가 튄다
                #expect((0...displayed.count).contains(mapped), "offset \(offset) out of bounds in '\(displayed)'")
                #expect(mapped > previous, "offset \(offset) not monotonic in '\(displayed)'")
                previous = mapped
                // 왕복 보존: 원시 → 표시 → 원시
                #expect(transformed.offsetMapping.transformedToOriginal(mapped) == offset)
            }
            // 표시 → 원시도 경계 안에 머문다
            for offset in 0...displayed.count {
                #expect((0...digits.count).contains(transformed.offsetMapping.transformedToOriginal(offset)))
            }
        }
    }

    @Test("휴대폰도 모든 길이에서 왕복 변환이 보존된다")
    func roundTripPhone() {
        let full = "01012345678"
        for length in 0...full.count {
            let digits = String(full.prefix(length))
            let transformed = phone.filter(digits)
            let displayed = transformed.text
            for offset in 0...digits.count {
                let mapped = transformed.offsetMapping.originalToTransformed(offset)
                #expect((0...displayed.count).contains(mapped))
                #expect(transformed.offsetMapping.transformedToOriginal(mapped) == offset)
            }
        }
    }

    @Test("카드번호 표시는 종전 chunked(4) 표기와 같다")
    func cardMatchesChunked() {
        // 옛 구현 `digits.chunked(4).joinToString("-")` 와 전 길이에서 동일해야 표시 규칙이 안 바뀐다
        let full = "3400000000000009" // 16 자리
        for length in 0...full.count {
            let digits = String(full.prefix(length))
            let chunked = stride(from: 0, to: digits.count, by: 4).map { start in
                String(digits.dropFirst(start).prefix(4))
            }
            #expect(card.format(digits) == chunked.joined(separator: "-"))
        }
        // AMEX 15 자리도 4-4-4-3
        #expect(card.format("340000000000000") == "3400-0000-0000-000")
    }

    @Test("카드번호 - 4 자리 경계마다 커서가 하이픈 뒤에 선다")
    func cardBoundaries() {
        let mapping = card.filter("4000123412341234").offsetMapping
        // "4000-1234-1234-1234"
        #expect(mapping.originalToTransformed(4) == 5)
        #expect(mapping.originalToTransformed(8) == 10)
        #expect(mapping.originalToTransformed(12) == 15)
        #expect(mapping.originalToTransformed(16) == 19)
        #expect(mapping.transformedToOriginal(4) == 4)
        #expect(mapping.transformedToOriginal(5) == 4)
        #expect(mapping.transformedToOriginal(19) == 16)
    }

    @Test("유효기간은 하이픈이 아닌 슬래시로 끊긴다")
    func expirySeparator() {
        #expect(expiry.format("12") == "12")
        #expect(expiry.format("122") == "12/2")
        #expect(expiry.format("1228") == "12/28")
        let mapping = expiry.filter("1228").offsetMapping
        #expect(mapping.originalToTransformed(2) == 3)
        #expect(mapping.originalToTransformed(4) == 5)
        #expect(mapping.transformedToOriginal(3) == 2)
        #expect(mapping.transformedToOriginal(5) == 4)
    }

    @Test("카드 필드도 모든 길이에서 왕복 변환이 보존된다")
    func roundTripCardFields() {
        // 15(AMEX)·16 자리, 유효기간 4 자리 — 타이핑 도중 전 구간
        let cases: [(DigitGroupVisualTransformation, String)] = [
            (card, "4000123412341234"),
            (card, "340000000000000"),
            (expiry, "1228"),
        ]
        for (transformation, full) in cases {
            for length in 0...full.count {
                let digits = String(full.prefix(length))
                let transformed = transformation.filter(digits)
                let displayed = transformed.text
                var previous = -1
                for offset in 0...digits.count {
                    let mapped = transformed.offsetMapping.originalToTransformed(offset)
                    #expect((0...displayed.count).contains(mapped), "offset \(offset) out of bounds in '\(displayed)'")
                    #expect(mapped > previous, "offset \(offset) not monotonic in '\(displayed)'")
                    previous = mapped
                    #expect(transformed.offsetMapping.transformedToOriginal(mapped) == offset)
                }
                for offset in 0...displayed.count {
                    #expect((0...digits.count).contains(transformed.offsetMapping.transformedToOriginal(offset)))
                }
            }
        }
    }

    @Test("범위를 벗어난 offset 은 크래시 대신 경계로 잘린다")
    func outOfRangeOffsetsClamp() {
        let transformed = birth.filter("1995")
        #expect(transformed.offsetMapping.originalToTransformed(99) == 4)
        #expect(transformed.offsetMapping.originalToTransformed(-3) == 0)
        #expect(transformed.offsetMapping.transformedToOriginal(99) == 4)
        #expect(transformed.offsetMapping.transformedToOriginal(-3) == 0)
    }

    // ─── iOS 입력 칸 보조 (원본에 없는 것) ───

    @Test("끝에서 치는 동안 커서는 표시 문자열의 끝에 남는다")
    func caretStaysAtEnd() {
        let full = "01012345678"
        for length in 0...full.count {
            let digits = String(full.prefix(length))
            let transformed = phone.filter(digits)
            #expect(transformed.offsetMapping.originalToTransformed(digits.utf16.count) == transformed.text.utf16.count)
        }
    }

    @Test("입력 값에서 숫자만 남기고 자릿수를 자른다")
    func digitsOnlyFilters() {
        #expect(digitsOnly("010-1234-5678") == "01012345678")
        #expect(digitsOnly("010-1234-56789", maxDigits: 11) == "01012345678")
        #expect(digitsOnly("abc") == "")
        #expect(digitsOnly("123", maxDigits: 0) == "")
    }

    @Test("표시 변환으로 넘겨도 같은 문자열이 그려진다")
    func visualTransformationBridge() {
        #expect(phone.visualTransformation.filter("0101").text == "010-1")
    }
}
