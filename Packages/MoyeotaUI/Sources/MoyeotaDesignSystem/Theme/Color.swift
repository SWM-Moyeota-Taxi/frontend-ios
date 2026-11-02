import SwiftUI
import UIKit

// moyeota-figma-tokens.json 의 core.color 값 그대로
public enum MoyeotaColor {
    // primary
    public static let Primary500 = Color(argb: 0xFF085AF5)
    public static let Primary600 = Color(argb: 0xFF054BC7)
    public static let Primary700 = Color(argb: 0xFF033D9F)
    public static let Primary50 = Color(argb: 0xFFE6EEFE)

    // status
    public static let Success500 = Color(argb: 0xFF10B981)
    public static let Success600 = Color(argb: 0xFF0F8F66)
    public static let Success50 = Color(argb: 0xFFD1FAE5)
    public static let Waiting500 = Color(argb: 0xFFF59E0B)
    public static let Waiting600 = Color(argb: 0xFFB57407)
    public static let Waiting50 = Color(argb: 0xFFFEF3C7)
    public static let Danger500 = Color(argb: 0xFFE63946)
    public static let Danger600 = Color(argb: 0xFFB32836)
    public static let Danger50 = Color(argb: 0xFFFDECEE)

    // 비상 신고 전용 — 다른 곳 사용 금지
    public static let Safety500 = Color(argb: 0xFFDC2626)
    public static let Safety600 = Color(argb: 0xFFA81D1D)

    // ink / text
    public static let InkPrimary = Color(argb: 0xFF111111)
    public static let InkDeep = Color(argb: 0xFF0A0A0B)
    public static let TextBody = Color(argb: 0xB8111111)      // rgba(17,17,17,0.72)
    public static let TextMute = Color(argb: 0xFF6B7280)
    public static let TextAsh = Color(argb: 0xFFD1D5DB)
    public static let TextOnDark = Color(argb: 0xFFFFFFFF)
    public static let Link = Color(argb: 0xFF054BC7)

    // surface
    public static let SurfaceCanvas = Color(argb: 0xFFFFFFFF)
    public static let SurfaceSoft = Color(argb: 0xFFF4F6FA)
    public static let SurfaceCard = Color(argb: 0xFFFFFFFF)
    public static let MapOverlay = Color(argb: 0xF0FFFFFF)    // rgba(255,255,255,0.94)
    public static let Hairline = Color(argb: 0xFFEDEFF3)

    // route / marker
    public static let RouteShared = Color(argb: 0xFF085AF5)
    public static let RouteUserA = Color(argb: 0xFF3B82F6)
    public static let RouteUserB = Color(argb: 0xFF8B5CF6)
    public static let MarkerOrigin = Color(argb: 0xFF085AF5)
    public static let MarkerDestination = Color(argb: 0xFFEF4444)
    public static let MarkerPickup = Color(argb: 0xFF10B981)
    public static let MarkerDropoff = Color(argb: 0xFFF97316)

    public static let Scrim = Color(argb: 0x66000000)         // opacity.scrim 40%
}

public extension Color {
    /// Compose 의 `Color(0xAARRGGBB)` 자리. 값은 sRGB 다.
    init(argb: UInt32) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }

    /// Compose 의 `color.copy(alpha = x)` 자리. `opacity(_:)` 는 원래 알파에 **곱하지만** 이것은 알파를 x 로 **바꾼다.**
    func copy(alpha: Double) -> Color {
        Color(uiColor: UIColor(self).withAlphaComponent(alpha))
    }

    /// 지도 오버레이처럼 `UIColor` 를 받는 자리에 넘길 때 쓴다 (Compose 의 `toArgb()` 자리).
    func toUIColor() -> UIColor {
        UIColor(self)
    }
}
