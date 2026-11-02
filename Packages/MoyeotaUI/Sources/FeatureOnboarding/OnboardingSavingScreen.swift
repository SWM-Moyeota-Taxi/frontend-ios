import MoyeotaDesignSystem
import SwiftUI

/// 01 · 온보딩 — 절약 [O01]
///
/// 진입: 로그인되지 않은 채 앱을 켤 때마다 시작 화면(`MainNavGraph.kt:448`). 원본 KDoc 의 「최초 실행 1회,
/// 마이 > 도움말에서 재열람」은 낡은 기록이다 — 원본에 그런 플래그도, 다른 진입 경로도 없다.
/// 목적: 1/N 절약 가치 전달
///
/// 인터랙션
/// - 「다음」 → 02 온보딩 신뢰 (onNext)
/// - 「건너뛰기」 → 04 로그인 (onSkip)
/// - 좌우 스와이프 → 02 (제스처, 프로토타입 미구현 → 미구현)
///
/// 검증·상태
/// - 화면은 콜백만 노출. 시작 분기는 `loggedIn` 하나뿐이고 온보딩 완료 플래그는 없다(원본 KDoc 과 다르다)
/// - 요금 예시(9,600 → 3,200)는 3인 기준 하드코딩 값
public struct OnboardingSavingScreen: View {
    private let onNext: () -> Void
    private let onSkip: () -> Void

    public init(onNext: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.onNext = onNext
        self.onSkip = onSkip
    }

    public var body: some View {
        VStack(spacing: 0) {
            StatusBarSpacer()

            // 건너뛰기 (우상단)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button(action: onSkip) {
                    Text("건너뛰기")
                        .moyeotaText(MoyeotaType.ButtonMd.hangulTrimmed, color: MoyeotaColor.TextMute)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressFeedbackStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Spacer().frame(height: 24)

            SavingIllustration()
                .frame(maxWidth: .infinity)
                .frame(height: 330)
                .padding(.horizontal, 16)

            Spacer().frame(height: 32)

            Text(OnboardingSavingCopy.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .moyeotaText(
                    MoyeotaType.DisplayMd.copy(fontSize: 26, letterSpacing: -0.52).hangulTrimmed,
                    color: MoyeotaColor.InkPrimary
                )
                .frame(maxWidth: .infinity)

            Spacer().frame(height: 12)

            Text(OnboardingSavingCopy.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .moyeotaText(
                    MoyeotaType.BodyMd.copy(lineHeight: .sp(22), letterSpacing: -0.3).hangulTrimmed,
                    color: MoyeotaColor.TextMute
                )
                .frame(maxWidth: .infinity)

            Spacer().frame(height: 32)

            PageDots(count: 3, activeIndex: 0)

            Spacer(minLength: 0)

            PrimaryCtaButton(text: "다음", onClick: onNext)
                .padding(.horizontal, 16)

            Spacer(minLength: 0)

            NavigationBarSpacer()
        }
        // 작은 화면에서 넘치면 원본 Column 처럼 위를 고정하고 아래로 넘긴다(기본값이면 위아래로 나뉜다).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MoyeotaColor.SurfaceSoft)
    }
}

// 일러스트 — 원 안의 ₩ + 요금 비교 (9,600원 → 3,200원)
private struct SavingIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 72)

            ZStack {
                Circle().fill(Color(argb: 0xFFDCE7FB))
                Circle().strokeBorder(MoyeotaColor.Primary500.opacity(0.35), lineWidth: 2)
                WonGlyphShape()
                    .fill(MoyeotaColor.Primary500)
                    .frame(width: WonGlyphShape.width, height: WonGlyphShape.height)
                    .offset(y: WonGlyphShape.centerOffsetY)
                    .accessibilityElement()
                    .accessibilityLabel(Text("₩"))
            }
            .frame(width: 140, height: 140)

            Spacer().frame(height: 22)

            HStack(alignment: .center, spacing: 12) {
                FarePill(text: "9,600원", background: MoyeotaColor.SurfaceCanvas, textColor: MoyeotaColor.InkPrimary)
                PlusIcon()
                FarePill(text: "3,200원", background: MoyeotaColor.Primary500, textColor: MoyeotaColor.TextOnDark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MoyeotaColor.Primary50, in: RoundedRectangle(cornerRadius: 24, style: .circular))
    }
}

/// 원 안의 ₩. 원본은 44sp 굵은 글자(`Text("₩")`)지만 그림처럼 보이는 자리이고, iOS 시스템 글꼴의 ₩ 는 가로줄이 하나에
/// 획도 가늘어 모양이 다르다. 그래서 원본 스크린샷(2.625배)에서 잰 윤곽을 그린다. 좌표 단위는 그 스크린샷의 픽셀이다.
private struct WonGlyphShape: Shape {
    private static let scale: CGFloat = 2.625
    static let width: CGFloat = 90 / scale
    static let height: CGFloat = 83 / scale
    /// 원 가운데에서 글자 윤곽 가운데까지(원본 스크린샷에서 쟀다).
    static let centerOffsetY: CGFloat = -1.5 / scale

    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 90
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        path.addLines([
            point(5, 1), point(22, 1), point(29.5, 54), point(37, 1), point(52, 1), point(60.5, 54),
            point(68, 1), point(85, 1), point(69, 83), point(52, 83), point(45, 38), point(38, 83), point(21, 83),
        ])
        path.closeSubpath()
        path.addRect(CGRect(x: rect.minX, y: rect.minY + 18 * unit, width: rect.width, height: 9 * unit))
        path.addRect(CGRect(x: rect.minX, y: rect.minY + 35 * unit, width: rect.width, height: 9 * unit))
        return path
    }
}

private struct FarePill: View {
    let text: String
    let background: Color
    let textColor: Color

    var body: some View {
        Text(text)
            .moyeotaText(inheritedBodyLarge(fontSize: 16), color: textColor)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .circular))
    }
}

/// 원본 `Text(fontSize = …, fontWeight = Bold)` 의 실제 스타일. `style` 을 주지 않으면 머티리얼 테마의
/// `bodyLarge` 를 물려받아 줄 높이 24sp·자간 0.5sp 가 남는다. 요금 알약의 높이 44dp 가 여기서 나온다.
private func inheritedBodyLarge(fontSize: CGFloat) -> MoyeotaType {
    MoyeotaType(fontSize: fontSize, fontWeight: .bold, lineHeight: .sp(24), letterSpacing: 0.5)
}

private struct PlusIcon: View {
    var body: some View {
        // 둥근 끝이 14pt 밖으로 1.25pt 나온다. 원본 Canvas 는 자르지 않지만 SwiftUI `Canvas` 는 잘라서 Shape 로 그린다.
        PlusShape()
            .stroke(Color(argb: 0xFF8A93A0), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 14, height: 14)
    }
}

private struct PlusShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = rect.width / 2
        var path = Path()
        path.move(to: CGPoint(x: 0, y: c))
        path.addLine(to: CGPoint(x: rect.width, y: c))
        path.move(to: CGPoint(x: c, y: 0))
        path.addLine(to: CGPoint(x: c, y: rect.height))
        return path
    }
}
