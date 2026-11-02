import SwiftUI

/// 원본 `lightColorScheme(...)` 에서 지정한 값. 머티리얼 기본 색을 쓰는 자리를 그대로 옮기려고 둔다.
enum LightColorScheme {
    static let primary = MoyeotaColor.Primary500
    static let onPrimary = MoyeotaColor.TextOnDark
    static let primaryContainer = MoyeotaColor.Primary50
    static let onPrimaryContainer = MoyeotaColor.Primary700
    static let error = MoyeotaColor.Danger500
    static let onError = MoyeotaColor.TextOnDark
    static let background = MoyeotaColor.SurfaceCanvas
    static let onBackground = MoyeotaColor.InkPrimary
    static let surface = MoyeotaColor.SurfaceCanvas
    static let onSurface = MoyeotaColor.InkPrimary
    static let surfaceVariant = MoyeotaColor.SurfaceSoft
    static let onSurfaceVariant = MoyeotaColor.TextMute
    static let outline = MoyeotaColor.Hairline
}

/// Compose `LocalContentColor` 의 기본값. 원본은 화면을 `Surface` 로 감싸지 않아, 색을 지정하지 않은
/// `Text` 가 `onSurface` 가 아니라 이 검정으로 그려진다.
let LocalContentColorDefault = Color(argb: 0xFF000000)

public struct MoyeotaTheme<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        // 와이어프레임은 라이트 단일 테마
        content
            .tint(LightColorScheme.primary)
            .foregroundStyle(LocalContentColorDefault)
            .environment(\.colorScheme, .light)
            .preferredColorScheme(.light)
    }
}
