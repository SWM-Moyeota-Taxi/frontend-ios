import CoreText
import SwiftUI
import UIKit

/// 줄 높이 단위. Compose 의 `1.25.em`(글자 크기 배수)과 `22.sp`(절대값)를 모두 담는다.
/// `copy(fontSize:)` 로 크기만 바꾸면 em 은 따라가고 sp 는 그대로다 — 원본 `TextStyle` 과 같다.
public enum TextLineHeight: Equatable, Sendable {
    case em(CGFloat)
    case sp(CGFloat)
}

/// Compose `TextStyle` 의 자리. `MoyeotaType.BodyMd` 처럼 원본과 같은 이름으로 쓰고,
/// 화면에는 `.moyeotaText(.BodyMd)` 또는 `.moyeotaText(.bodyMd)` 로 입힌다.
///
/// moyeota-figma-tokens.json 의 core.font 값 그대로.
/// 폰트 패밀리는 Pretendard 지정이지만 초안에서는 시스템 기본 sans 사용.
public struct MoyeotaType: Equatable, Sendable {
    public var fontSize: CGFloat
    public var fontWeight: Font.Weight
    /// nil 이면 줄 높이를 지정하지 않는다(버튼 토큰). 폰트 고유의 줄 높이를 그대로 쓴다.
    public var lineHeight: TextLineHeight?
    public var letterSpacing: CGFloat
    /// nil 이면 부모의 전경색을 따른다(`TextStyle.color` 미지정과 같다).
    public var color: Color?
    /// 첫 줄 위·끝 줄 아래를 한글 대체 글꼴의 상자로 자르는가. `hangulTrimmed` 참고.
    public var trimsToHangulLineBox: Bool

    public init(
        fontSize: CGFloat = 14,
        fontWeight: Font.Weight = .regular,
        lineHeight: TextLineHeight? = nil,
        letterSpacing: CGFloat = 0,
        color: Color? = nil,
        trimsToHangulLineBox: Bool = false
    ) {
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
        self.color = color
        self.trimsToHangulLineBox = trimsToHangulLineBox
    }

    /// `TextStyle.copy(...)` 자리. 넘긴 값만 바꾼다.
    public func copy(
        fontSize: CGFloat? = nil,
        fontWeight: Font.Weight? = nil,
        lineHeight: TextLineHeight? = nil,
        letterSpacing: CGFloat? = nil,
        color: Color? = nil
    ) -> MoyeotaType {
        var result = self
        if let fontSize { result.fontSize = fontSize }
        if let fontWeight { result.fontWeight = fontWeight }
        if let lineHeight { result.lineHeight = lineHeight }
        if let letterSpacing { result.letterSpacing = letterSpacing }
        if let color { result.color = color }
        return result
    }

    public static let DisplayXl = MoyeotaType(fontSize: 32, fontWeight: .bold, lineHeight: .em(1.25), letterSpacing: -0.4)
    public static let DisplayLg = MoyeotaType(fontSize: 28, fontWeight: .bold, lineHeight: .em(1.25), letterSpacing: -0.3)
    public static let DisplayMd = MoyeotaType(fontSize: 24, fontWeight: .bold, lineHeight: .em(1.25), letterSpacing: -0.2)
    public static let HeadingXl = MoyeotaType(fontSize: 22, fontWeight: .semibold, lineHeight: .em(1.35), letterSpacing: -0.1)
    public static let HeadingLg = MoyeotaType(fontSize: 18, fontWeight: .semibold, lineHeight: .em(1.35), letterSpacing: -0.1)
    public static let HeadingMd = MoyeotaType(fontSize: 16, fontWeight: .semibold, lineHeight: .em(1.35), letterSpacing: -0.1)
    public static let BodyMd = MoyeotaType(fontSize: 15, fontWeight: .regular, lineHeight: .em(1.5))
    public static let BodySm = MoyeotaType(fontSize: 13, fontWeight: .regular, lineHeight: .em(1.5))
    public static let CaptionMd = MoyeotaType(fontSize: 12, fontWeight: .regular, lineHeight: .em(1.35), letterSpacing: 0.2)
    public static let CaptionSm = MoyeotaType(fontSize: 11, fontWeight: .regular, lineHeight: .em(1.35), letterSpacing: 0.2)
    public static let ButtonLg = MoyeotaType(fontSize: 16, fontWeight: .bold)
    public static let ButtonMd = MoyeotaType(fontSize: 14, fontWeight: .semibold)
    public static let ButtonSm = MoyeotaType(fontSize: 12, fontWeight: .semibold)

    // `.moyeotaText(.bodyMd)` 로도 쓸 수 있게 하는 별칭. 값은 위의 토큰 그대로다.
    public static var displayXl: MoyeotaType { DisplayXl }
    public static var displayLg: MoyeotaType { DisplayLg }
    public static var displayMd: MoyeotaType { DisplayMd }
    public static var headingXl: MoyeotaType { HeadingXl }
    public static var headingLg: MoyeotaType { HeadingLg }
    public static var headingMd: MoyeotaType { HeadingMd }
    public static var bodyMd: MoyeotaType { BodyMd }
    public static var bodySm: MoyeotaType { BodySm }
    public static var captionMd: MoyeotaType { CaptionMd }
    public static var captionSm: MoyeotaType { CaptionSm }
    public static var buttonLg: MoyeotaType { ButtonLg }
    public static var buttonMd: MoyeotaType { ButtonMd }
    public static var buttonSm: MoyeotaType { ButtonSm }
}

public extension MoyeotaType {
    var font: Font {
        .system(size: fontSize, weight: fontWeight)
    }

    var uiFont: UIFont {
        .systemFont(ofSize: fontSize, weight: fontWeight.uiFontWeight)
    }

    /// 지정한 줄 높이(pt). 지정이 없으면 nil.
    var lineHeightPoints: CGFloat? {
        switch lineHeight {
        case .em(let multiple): multiple * fontSize
        case .sp(let points): points
        case nil: nil
        }
    }

    /// 폰트 자체의 줄 높이와 지정 줄 높이의 차이. 음수일 수도 있다.
    ///
    /// SwiftUI 에는 「줄 높이」가 없고 `lineSpacing`(줄 **사이** 간격)만 있다. 그래서
    /// 지정 줄 높이 − 폰트 줄 높이를 줄 사이 간격으로 주고, 같은 값을 위아래 절반씩 패딩으로 더해
    /// 첫 줄·마지막 줄까지 Compose 와 같은 줄 상자 높이를 만든다(n 줄 = 지정 줄 높이 × n).
    /// 한글은 대체 폰트로 그려지지만 SwiftUI 의 줄 높이는 시스템 폰트 값 그대로다(시뮬레이터에서 실측).
    var lineHeightDelta: CGFloat {
        guard let target = lineHeightPoints else { return 0 }
        return target - uiFont.lineHeight
    }

    /// 안드로이드 한글 대체 글꼴의 줄 상자 ÷ 글자 크기. 원본 UI 트리에서 쟀다(12sp 17.1, 13sp 18.7, 16sp 23.2, 18sp 26.3, 24sp 34.6).
    static var hangulLineBoxRatio: CGFloat { 1.44 }

    /// 원본 토큰(`style = MoyeotaType.*`)이 한글을 그릴 때의 글자 상자.
    ///
    /// 토큰은 `LineHeightStyle` 을 지정하지 않아 Compose 기본값 `Trim.Both` 를 따른다. 첫 줄 위·끝 줄 아래가 **글꼴 상자에서** 잘려
    /// 한 줄 상자는 지정 줄 높이가 아니라 대체 글꼴의 높이이고(13sp 1.5em 이 19.5 가 아니라 18.7, 24sp 1.25em 이 30 이 아니라 34.6),
    /// 줄 간격만 지정값이다(n 줄 = 글꼴 상자 + 지정 줄 높이 × (n − 1)). 한글이 없는 글(「 · 」)은 Roboto 상자라 맞지 않으니 그 자리에는 쓰지 않는다.
    ///
    /// 토큰 값 자체를 바꾸지 않고 고르게 둔 이유: 다른 화면들은 지정 줄 높이 위에서 이미 맞춰 재 놓았다.
    var hangulTrimmed: MoyeotaType {
        var result = self
        result.trimsToHangulLineBox = true
        return result
    }

    /// 안드로이드 한글 잉크가 줄 상자 가운데보다 내려가는 정도 ÷ 글자 크기. 원본 렌더와 UI 트리에서 쟀다(13sp 0.6, 14sp 0.8, 16sp 0.9, 24sp 1.7).
    /// iOS 글자는 상자 가운데에 놓여, 없으면 상자가 같아도 글자가 그만큼 위에 그려진다.
    static var hangulInkDropRatio: CGFloat { 0.06 }

    /// 글자 위아래에 더하는 패딩의 평균.
    var edgePadding: CGFloat {
        guard trimsToHangulLineBox else { return lineHeightDelta / 2 }
        return (fontSize * Self.hangulLineBoxRatio - uiFont.lineHeight) / 2
    }

    /// 위 패딩에 더하고 아래 패딩에서 뺄 값. 상자 높이는 그대로 두고 글자만 내린다.
    var inkDrop: CGFloat {
        trimsToHangulLineBox ? fontSize * Self.hangulInkDropRatio : 0
    }

    /// Compose `Text` 가 `style` 을 받지 않았을 때 물려받는 머티리얼 3 `bodyLarge` — 자간 0.5.
    ///
    /// 머티리얼 스타일은 줄을 자르지 않아(`Trim.None`) 16sp 이하의 줄 상자는 24 다. 그 위로는 한글 대체 글꼴이 줄을 밀어 올린다
    /// (원본 UI 트리: 18sp 26.3, 20sp 28.5, 24sp 34.6).
    static func inheritedBodyLarge(fontSize: CGFloat, fontWeight: Font.Weight = .regular) -> MoyeotaType {
        let hangulBox = fontSize * hangulLineBoxRatio
        return MoyeotaType(
            fontSize: fontSize,
            fontWeight: fontWeight,
            lineHeight: .sp(max(24, hangulBox)),
            letterSpacing: 0.5,
            trimsToHangulLineBox: hangulBox > 24
        )
    }
}

extension Font.Weight {
    var uiFontWeight: UIFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

private struct MoyeotaTextModifier: ViewModifier {
    let style: MoyeotaType

    func body(content: Content) -> some View {
        let delta = style.lineHeightDelta
        colored(content)
            .font(style.font)
            .tracking(style.letterSpacing)
            .lineSpacing(max(0, delta))
            .padding(.top, style.edgePadding + style.inkDrop)
            .padding(.bottom, style.edgePadding - style.inkDrop)
    }

    @ViewBuilder
    private func colored(_ content: Content) -> some View {
        if let color = style.color {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}

public extension View {
    /// `Text(style = …)` 자리. 크기·굵기·줄 높이·자간(·색이 있으면 색)을 입힌다.
    ///
    /// 줄 높이를 패딩으로 맞추므로 이 모디파이어 **뒤에** `.padding` 등을 잇는다.
    func moyeotaText(_ style: MoyeotaType, color: Color? = nil) -> some View {
        modifier(MoyeotaTextModifier(style: color.map { style.copy(color: $0) } ?? style))
    }
}

public extension Text {
    /// `Text` 끼리 이어 붙일 때(`AnnotatedString` 의 SpanStyle 자리) 쓴다.
    /// 결과가 `Text` 라 크기·굵기·자간·색만 입고, 줄 높이는 이어 붙인 전체에 `.moyeotaText` 로 준다.
    func moyeotaStyled(_ style: MoyeotaType, color: Color? = nil) -> Text {
        let styled = font(style.font).tracking(style.letterSpacing)
        if let resolved = color ?? style.color {
            return styled.foregroundColor(resolved)
        }
        return styled
    }
}

private let ZeroWidthSpace: Character = "\u{200B}"
private let ClosingBeforeHangul = Set("」』)]}>.,!?…~")
private let OpeningAfterHangul = Set("「『([{<")

private func isHangul(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first?.value else { return false }
    return (0xAC00...0xD7A3).contains(scalar) || (0x1100...0x11FF).contains(scalar) || (0x3131...0x318E).contains(scalar)
}

private func isAsciiAlphanumeric(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber)
}

public extension String {
    /// 안드로이드 줄바꿈 자리를 `Text` 에 알려 주는 표시용 문자열.
    ///
    /// 원본 `Text` 는 한글을 글자 단위로 꺾는다(ICU 기본 규칙). iOS `Text` 는 어절 단위라 같은 문장이 다른 자리에서 꺾이고
    /// 말풍선 폭까지 달라지며, 끌 공개 API 가 없다. 그래서 ICU 가 꺾는 자리에 폭 없는 공백(U+200B)을 넣는다:
    /// 한글끼리, 한글과 숫자·영문 사이, 닫는 문장부호 뒤, 여는 문장부호 앞. 문장부호 앞과 영문 단어 안은 원본처럼 꺾지 않는다.
    ///
    /// **그리기 전용이다.** 값으로 쓰지 말고, 읽어 주는 글이 끊기지 않게 `accessibilityLabel` 에 원문을 함께 준다.
    var characterWrapped: String {
        var result = ""
        result.reserveCapacity(utf8.count + count * 3)
        var previous: Character?
        for character in self {
            if let previous, Self.breaksBetween(previous, character) {
                result.append(ZeroWidthSpace)
            }
            result.append(character)
            previous = character
        }
        return result
    }

    fileprivate static func breaksBetween(_ left: Character, _ right: Character) -> Bool {
        if isHangul(right) {
            return isHangul(left) || isAsciiAlphanumeric(left) || ClosingBeforeHangul.contains(left)
        }
        if isHangul(left) {
            return isAsciiAlphanumeric(right) || OpeningAfterHangul.contains(right)
        }
        return false
    }
}

/// `softWrappedLines` 의 결과.
public struct SoftWrappedText: Equatable, Sendable {
    /// 줄 끝마다 `\n` 을 넣은 표시용 글.
    public let text: String
    /// 폭 때문에 꺾인 줄이 있는가(글 안의 `\n` 은 세지 않는다).
    public let wrapped: Bool

    public init(text: String, wrapped: Bool) {
        self.text = text
        self.wrapped = wrapped
    }
}

public extension MoyeotaType {
    /// 폭을 아는 칸에서 원본처럼 줄을 나눈다: 줄 끝까지 채우고(앞에서부터 욕심껏) 꺾이는 자리는 `characterWrapped` 와 같다.
    ///
    /// 표시용 글에 폭 없는 공백만 넣으면 `Text` 가 마지막 줄이 짧아지지 않게 앞 줄의 글자를 밀어 내려(「…챙기셨 / 어요?」) 원본(「…챙기셨어 / 요?」)과
    /// 다르다. 그 동작을 끌 공개 API 가 없어 CoreText 로 줄을 정해 `\n` 으로 고정한다. 호출부는 글자가 다시 꺾이지 않게 `fixedSize` 로 그린다.
    func softWrappedLines(_ text: String, width: CGFloat) -> SoftWrappedText {
        let marked = text.characterWrapped as NSString
        let attributed = NSAttributedString(
            string: marked as String,
            attributes: [.font: uiFont, .kern: letterSpacing]
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [String] = []
        var wrapped = false
        var start = 0
        while start < marked.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            let line = marked.substring(with: NSRange(location: start, length: count))
            start += count
            let endsParagraph = line.hasSuffix("\n") || start >= marked.length
            if !endsParagraph { wrapped = true }
            var clean = line.replacingOccurrences(of: String(ZeroWidthSpace), with: "")
            if clean.hasSuffix("\n") { clean.removeLast() }
            lines.append(endsParagraph ? clean : clean.trimmingTrailingSpaces)
        }
        if marked.hasSuffix("\n") { lines.append("") }
        return SoftWrappedText(text: lines.joined(separator: "\n"), wrapped: wrapped)
    }
}

private extension String {
    var trimmingTrailingSpaces: String {
        var result = self
        while result.last == " " { result.removeLast() }
        return result
    }
}
