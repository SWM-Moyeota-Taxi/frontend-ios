import SwiftUI

/// 글꼴이 플랫폼마다 달리 그리는 기호(⌄ ⌃ › ＋)를 원본 렌더의 크기대로 그린 도형.
///
/// 같은 글자라도 iOS 대체 글꼴은 ⌃ 가 거의 2배 넓고 ＋ 는 절반 남짓이다. 글꼴을 번들하지 않으면 글자로는 같아지지 않는다.
/// 도형은 보이는 모양만 맡는다. 호출부는 옆의 `Text` 에 원문을 `accessibilityLabel` 로 줘서 VoiceOver 가 읽는 값을 지킨다.
public struct GlyphMark: View {
    public enum Kind: Sendable {
        case chevronDown, chevronUp, chevronRight, plus

        /// 원본 렌더에서 잰 잉크 크기 (⌄ 5×5, ⌃ 5×5, › 2.7×5, ＋ 10.7×11)
        fileprivate var size: CGSize {
            switch self {
            case .chevronDown, .chevronUp: CGSize(width: 5, height: 5)
            case .chevronRight: CGSize(width: 2.7, height: 5)
            case .plus: CGSize(width: 10.7, height: 11)
            }
        }
    }

    private let kind: Kind
    private let color: Color
    private let lineWidth: CGFloat

    public init(_ kind: Kind, color: Color, lineWidth: CGFloat) {
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        GlyphMarkShape(kind: kind, lineWidth: lineWidth)
            .fill(color)
            .frame(width: kind.size.width, height: kind.size.height)
            .accessibilityHidden(true)
    }
}

private struct GlyphMarkShape: Shape {
    let kind: GlyphMark.Kind
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let inset = lineWidth / 2
        var path = Path()
        switch kind {
        case .plus:
            path.addRect(CGRect(x: 0, y: (h - lineWidth) / 2, width: w, height: lineWidth))
            path.addRect(CGRect(x: (w - lineWidth) / 2, y: 0, width: lineWidth, height: h))
            return path.offsetBy(dx: rect.minX, dy: rect.minY)
        case .chevronDown:
            path.move(to: CGPoint(x: inset, y: inset))
            path.addLine(to: CGPoint(x: w / 2, y: h - inset))
            path.addLine(to: CGPoint(x: w - inset, y: inset))
        case .chevronUp:
            path.move(to: CGPoint(x: inset, y: h - inset))
            path.addLine(to: CGPoint(x: w / 2, y: inset))
            path.addLine(to: CGPoint(x: w - inset, y: h - inset))
        case .chevronRight:
            path.move(to: CGPoint(x: inset, y: inset))
            path.addLine(to: CGPoint(x: w - inset, y: h / 2))
            path.addLine(to: CGPoint(x: inset, y: h - inset))
        }
        return path
            .strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .miter))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
