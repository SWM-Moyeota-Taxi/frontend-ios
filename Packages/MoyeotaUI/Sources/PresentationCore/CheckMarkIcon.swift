import SwiftUI

// 아이콘 라이브러리 없이 그리는 체크 표시
public struct CheckMarkIcon: View {
    private let iconSize: CGFloat
    private let color: Color

    public init(iconSize: CGFloat, color: Color) {
        self.iconSize = iconSize
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w * 0.15, y: h * 0.55))
            path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.8))
            path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.25))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: iconSize, height: iconSize)
    }
}
