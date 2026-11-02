/// Kotlin 문자 판정을 그대로 옮긴 것. Swift 표준 판정은 범위가 달라서(`Character.isWhitespace` 는 U+001C~1F 를
/// 빼고 U+0085 를 넣는다, `Character.isNumber` 는 로마 숫자까지 받는다) 입력 검사 결과가 원본과 어긋난다.
extension Unicode.Scalar {
    /// Kotlin `Char.isWhitespace()` — `Character.isWhitespace(c) || Character.isSpaceChar(c)`.
    public var isKotlinWhitespace: Bool {
        switch value {
        case 0x09...0x0D, 0x1C...0x1F:
            return true
        default:
            switch properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    /// Kotlin `Char.isDigit()` — 유니코드 Nd 전부(ASCII 만이 아니다). Kotlin `Char` 는 UTF-16 한 칸이라
    /// BMP 밖의 숫자는 대리 쌍으로 쪼개져 거짓이 된다.
    public var isKotlinDigit: Bool {
        value <= 0xFFFF && properties.generalCategory == .decimalNumber
    }

    /// java.util.regex 의 `.` 이 넘지 못하는 줄 끝 문자.
    public var isJavaLineTerminator: Bool {
        switch value {
        case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}

extension String {
    /// Kotlin `String.trim()` — 양끝의 `isKotlinWhitespace` 를 떼어 낸다.
    public func trim() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.isKotlinWhitespace }),
              let last = scalars.lastIndex(where: { !$0.isKotlinWhitespace })
        else { return "" }
        return String(scalars[first...last])
    }

    /// Kotlin `String.isBlank()` — 비었거나 전부 `isKotlinWhitespace`.
    public var isBlank: Bool {
        unicodeScalars.allSatisfy(\.isKotlinWhitespace)
    }
}
