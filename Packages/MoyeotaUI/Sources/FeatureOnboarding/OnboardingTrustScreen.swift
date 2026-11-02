import MoyeotaDesignSystem
import SwiftUI

/// 02 · 온보딩 — 신뢰 [O02]
///
/// 진입: 01에서 다음
/// 목적: 휴대폰 인증을 마친 사람만 가입하고, 상대의 탑승 횟수를 볼 수 있다는 신뢰 전달
///
/// 문구는 `OnboardingTrustCopy` 에 있다 — 예전 본문 「같은 성별끼리만 함께 타요」는 **성별 조건
/// 매칭이 없어서** 지웠다(2026-10-13). 일러스트의 체크 배지는 휴대폰 인증을 뜻한다.
///
/// 인터랙션
/// - 「다음」 → 03 온보딩 안심 (onNext)
/// - 「건너뛰기」 → 04 로그인 (onSkip)
///
/// 검증·상태
/// - 별도 입력 없음. 페이지 인디케이터 2/3 표시
public struct OnboardingTrustScreen: View {
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

            TrustIllustration()
                .frame(maxWidth: .infinity)
                .frame(height: 330)
                .padding(.horizontal, 16)

            Spacer().frame(height: 32)

            Text(OnboardingTrustCopy.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .moyeotaText(
                    MoyeotaType.DisplayMd.copy(fontSize: 26, letterSpacing: -0.52).hangulTrimmed,
                    color: MoyeotaColor.InkPrimary
                )
                .frame(maxWidth: .infinity)

            Spacer().frame(height: 12)

            Text(OnboardingTrustCopy.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .moyeotaText(
                    MoyeotaType.BodyMd.copy(lineHeight: .sp(22), letterSpacing: -0.3).hangulTrimmed,
                    color: MoyeotaColor.TextMute
                )
                .frame(maxWidth: .infinity)

            Spacer().frame(height: 32)

            PageDots(count: 3, activeIndex: 1)

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

// 일러스트 — 휴대폰 인증을 마친 프로필 카드 (아바타 + 체크 배지 + 이름 자리 바)
private struct TrustIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 86)

            VStack(spacing: 0) {
                Spacer().frame(height: 18)

                // 아바타 (사람 실루엣)
                ZStack {
                    Circle().fill(Color(argb: 0xFFCBD2DA))
                    PersonGlyph()
                        .frame(width: 24, height: 24)
                }
                .frame(width: 44, height: 44)
                // 파란 체크 배지 (휴대폰 인증 완료)
                .overlay(alignment: .bottomTrailing) {
                    ZStack {
                        Circle().fill(MoyeotaColor.Primary500)
                        Circle().strokeBorder(MoyeotaColor.SurfaceCanvas, lineWidth: 2)
                        CheckGlyph(color: MoyeotaColor.TextOnDark)
                            .frame(width: 10, height: 10)
                    }
                    .frame(width: 20, height: 20)
                    .offset(x: 6, y: 4)
                }

                Spacer().frame(height: 16)

                // 이름 자리 표시 바
                Capsule(style: .circular)
                    .fill(Color(argb: 0xFFD3DAE4))
                    .frame(width: 112, height: 14)
            }
            .frame(width: 166, height: 120, alignment: .top)
            .background(MoyeotaColor.SurfaceCanvas, in: RoundedRectangle(cornerRadius: 16, style: .circular))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MoyeotaColor.Primary50, in: RoundedRectangle(cornerRadius: 24, style: .circular))
    }
}

private struct PersonGlyph: View {
    var color = Color(argb: 0xFF7C8592)

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            // 머리
            let headRadius = w * 0.22
            context.fill(
                Path(ellipseIn: CGRect(
                    x: w / 2 - headRadius,
                    y: h * 0.3 - headRadius,
                    width: headRadius * 2,
                    height: headRadius * 2
                )),
                with: .color(color)
            )
            // 어깨 (반원) — topLeft (0.12w, 0.62h), 크기 (0.76w, 0.72h) 타원의 위쪽 절반. 180° → 360°
            var shoulders = Path()
            shoulders.addArc(
                center: .zero,
                radius: 1,
                startAngle: .degrees(180),
                endAngle: .degrees(360),
                clockwise: false,
                transform: CGAffineTransform(translationX: w * 0.5, y: h * (0.62 + 0.36))
                    .scaledBy(x: w * 0.38, y: h * 0.36)
            )
            shoulders.closeSubpath()
            context.fill(shoulders, with: .color(color))
        }
    }
}

private struct CheckGlyph: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w * 0.1, y: h * 0.55))
            path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.85))
            path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.2))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
    }
}
