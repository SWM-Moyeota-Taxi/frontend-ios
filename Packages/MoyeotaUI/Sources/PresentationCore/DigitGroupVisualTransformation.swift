import MoyeotaDesignSystem
import MoyeotaDomain
import SwiftUI

/// 숫자만 담긴 원시 값을 화면에서만 그룹 구분자로 끊어 보여주는 변환.
///
/// 왜 필요한가 (D-7):
/// 예전에는 `value = formatPhone(digits)` 처럼 하이픈이 낀 **표시 문자열**을 입력 칸의 값으로 넘기고
/// 입력 콜백에서 숫자만 다시 뽑아냈다. 이러면 한 글자를 칠 때마다 표시 문자열 길이가 1 이 아니라
/// 2 만큼 늘어나는 구간(구분자가 새로 끼는 순간)이 생기는데, 입력 칸은 이전 선택 위치를 그대로 들고
/// 새 텍스트에 얹는다. 그래서 커서가 구분자 앞쪽으로 밀리고 이후 입력이 그 자리에 꽂혀
/// `19950315` → `1995-31-50` 처럼 순서가 뒤집혔다.
///
/// 해결: 값은 항상 원시 숫자만 유지하고(입력 1 글자 = 길이 1 증가라 커서가 어긋날 여지가 없다),
/// 하이픈은 표시 변환으로만 그린다. 커서 좌표 변환은 `OffsetMapping` 이 책임진다.
///
/// SwiftUI 에는 `VisualTransformation` 이 없다. 그 자리는 `MoyeotaDesignSystem` 의 `VisualTransformation` 이고
/// `BasicTextField`·`MoyeotaTextField` 가 받는다. 화면에서는 이렇게 쓴다.
/// ```
/// MoyeotaTextField(
///     value: phoneDigits,
///     onValueChange: { onPhoneChange(digitsOnly($0, maxDigits: 11)) },
///     visualTransformation: PhoneNumberTransformation.visualTransformation
/// ) { EmptyView() }
/// ```
/// 머리말·오류 문구가 필요 없는 칸은 `DigitGroupTextField` 하나로 끝난다.
///
/// - Parameters:
///   - groupSizes: 앞에서부터의 그룹 크기. 휴대폰 `[3, 4, 4]` → `010-1234-5678`,
///     생년월일 `[4, 2, 2]` → `1995-03-15`
///   - separator: 그룹 사이에 그리는 문자
public struct DigitGroupVisualTransformation: Sendable {
    /// 구분자가 **앞에** 붙는 원시 인덱스들. `[3, 4, 4]` → `[3, 7]`.
    /// 마지막 그룹 뒤에는 경계가 없으므로 그룹 수보다 하나 적다.
    private let boundaries: [Int]
    private let separator: Character

    public init(groupSizes: [Int], separator: Character = "-") {
        var acc = 0
        var boundaries: [Int] = []
        for size in groupSizes.dropLast() {
            acc += size
            boundaries.append(acc)
        }
        self.boundaries = boundaries
        self.separator = separator
    }

    /// 원시 숫자 → 표시 문자열. 뒤따르는 숫자가 없으면 구분자를 그리지 않는다("010-" 같은 꼬리 방지).
    public func format(_ digits: String) -> String {
        let separatorUnits = Array(String(separator).utf16)
        var units: [UInt16] = []
        units.reserveCapacity(digits.utf16.count + boundaries.count)
        for (index, unit) in digits.utf16.enumerated() {
            if boundaries.contains(index) { units.append(contentsOf: separatorUnits) }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// 표시 문자열과 커서 좌표 변환. 오프셋은 `BasicTextField` 와 같은 UTF-16 단위다.
    public func filter(_ text: String) -> TransformedText {
        let digitCount = text.utf16.count
        let formatted = format(text)
        let formattedCount = formatted.utf16.count

        // 실제로 그려진 구분자만 센다. 예: 휴대폰 7 자리면 경계 7 은 아직 구분자를 만들지 않는다.
        // 이 필터를 빠뜨리면 originalToTransformed(길이) 가 표시 길이를 넘겨 커서가 범위를 벗어난다.
        let emitted = boundaries.filter { $0 < digitCount }
        // k 번째 구분자의 표시 인덱스 = 원시 경계 + 그 앞에 이미 낀 구분자 수(k)
        let separatorOffsets = emitted.enumerated().map { k, boundary in boundary + k }

        return TransformedText(
            text: formatted,
            offsetMapping: OffsetMapping(
                // 원시 offset 앞에 놓인 구분자 개수만큼 밀어준다.
                // `<=` 라서 경계에 선 커서는 구분자 "뒤"에 놓인다: "1995-|03" (경계 4 → 표시 5).
                // 갱신 도중 옛 offset 이 들어올 수 있어 범위로 자른다(D-7 재발 시 크래시 방지).
                originalToTransformed: { offset in
                    let original = min(max(offset, 0), digitCount)
                    return original + emitted.filter { $0 <= original }.count
                },
                // 역변환: 표시 offset 왼쪽에 있는 구분자 수를 뺀다.
                // `<` 라서 구분자 바로 앞/뒤(표시 4·5)가 같은 원시 4 로 접힌다 — 왕복은 항상 보존된다.
                transformedToOriginal: { offset in
                    let transformed = min(max(offset, 0), formattedCount)
                    return transformed - separatorOffsets.filter { $0 < transformed }.count
                }
            )
        )
    }

    /// `BasicTextField`·`MoyeotaTextField` 의 `visualTransformation:` 에 넘기는 값.
    public var visualTransformation: VisualTransformation {
        VisualTransformation(filter: { filter($0) })
    }
}

/// 휴대폰 010-1234-5678 (원시 11 자리)
public let PhoneNumberTransformation = DigitGroupVisualTransformation(groupSizes: [3, 4, 4])

/// 생년월일 YYYY-MM-DD (원시 8 자리)
public let BirthDateTransformation = DigitGroupVisualTransformation(groupSizes: [4, 2, 2])

/// 카드번호 0000-0000-0000-0000 (원시 15~16 자리).
/// AMEX 15 자리도 종전 `chunked(4)` 표기와 같은 4-4-4-3 으로 그려진다 — 표시 규칙은 바꾸지 않는다.
public let CardNumberTransformation = DigitGroupVisualTransformation(groupSizes: [4, 4, 4, 4])

/// 카드 유효기간 MM/YY (원시 4 자리). 구분자만 다르고 매핑 규칙은 하이픈 필드와 동일하다.
public let CardExpiryTransformation = DigitGroupVisualTransformation(groupSizes: [2, 2], separator: "/")

/// 입력 값에서 숫자만 남겨 원시 값으로 만든다. 붙여 넣은 `010-1234-5678` 도 숫자 11자가 된다.
public func digitsOnly(_ text: String, maxDigits: Int? = nil) -> String {
    let digits = text.unicodeScalars.filter(\.isKotlinDigit)
    var kept = String.UnicodeScalarView()
    kept.append(contentsOf: maxDigits.map { Array(digits.prefix(max($0, 0))) } ?? Array(digits))
    return String(kept)
}

/// 원시 숫자를 상태로 들고 그룹으로 끊어 보여 주는 입력 칸.
///
/// 상태(`digits`)에는 숫자만 들어간다. 표시와 커서는 `BasicTextField` 가 `OffsetMapping` 으로 옮기므로,
/// 끝에서 치는 동안 구분자가 새로 끼어도 커서는 표시 문자열의 끝에 남는다.
public struct DigitGroupTextField: View {
    @Binding private var digits: String
    private let transformation: DigitGroupVisualTransformation
    private let maxDigits: Int?
    private let textStyle: MoyeotaType
    private let keyboardOptions: KeyboardOptions
    private let enabled: Bool

    public init(
        digits: Binding<String>,
        transformation: DigitGroupVisualTransformation,
        maxDigits: Int? = nil,
        textStyle: MoyeotaType = MoyeotaType(),
        keyboardOptions: KeyboardOptions = KeyboardOptions(keyboardType: .number),
        enabled: Bool = true
    ) {
        _digits = digits
        self.transformation = transformation
        self.maxDigits = maxDigits
        self.textStyle = textStyle
        self.keyboardOptions = keyboardOptions
        self.enabled = enabled
    }

    public var body: some View {
        BasicTextField(
            value: digits,
            onValueChange: { digits = digitsOnly($0, maxDigits: maxDigits) },
            textStyle: textStyle,
            keyboardOptions: keyboardOptions,
            visualTransformation: transformation.visualTransformation,
            singleLine: true,
            enabled: enabled
        )
    }
}
