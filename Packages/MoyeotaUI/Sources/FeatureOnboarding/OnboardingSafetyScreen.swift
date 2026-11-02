import MoyeotaDesignSystem
import SwiftUI

/// 03 · 온보딩 — 안심 [O03]
///
/// 진입: 02에서 다음
/// 목적: 합류하는 순간 열리는 채팅으로 만날 곳을 정한다는 안내 후 가입 유도
///
/// 문구는 `OnboardingMeetingCopy` 에 있다 — 예전 본문 「운행 중 긴급 신고가 바로 되고 / 요금은
/// 인원수대로 나눠 안내해요」는 **동승 모드가 26 운행 중에 닿지 않아 27 긴급 신고로 들어갈 길이
/// 없고**(`docs/MODE-ROUTES.md`) **요금 정산 기능도 없어서** 지웠다(2026-10-13).
/// 파일·라우트 이름(`safety`)은 그대로 둔다 — 내비게이션 상수를 바꿀 이유가 아니다.
///
/// 인터랙션
/// - 「시작하기」 → 04 시작(로그인 방식) (onStart)
/// - 「이미 계정이 있어요」 → 04a 로그인 폼 `LOGIN_FORM` (onAlreadyHaveAccount). 원본 KDoc 의 「14 홈」은
///   낡은 기록이다 — 실제 이동은 `MainNavGraph.kt:566` 이고 내비게이션은 그쪽을 따라 옮긴다.
/// - 「건너뛰기」 → 04 로그인 (onSkip)
///
/// 검증·상태
/// - 화면은 콜백만 노출. 원본 호출부에 토큰 검사는 없다(`MainNavGraph.kt:566` — 곧바로 로그인 폼으로 간다)
public struct OnboardingSafetyScreen: View {
    private let onStart: () -> Void
    private let onAlreadyHaveAccount: () -> Void
    private let onSkip: () -> Void

    public init(
        onStart: @escaping () -> Void,
        onAlreadyHaveAccount: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.onStart = onStart
        self.onAlreadyHaveAccount = onAlreadyHaveAccount
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

            SafetyIllustration()
                .frame(maxWidth: .infinity)
                .frame(height: 330)
                .padding(.horizontal, 16)

            Spacer().frame(height: 32)

            Text(OnboardingMeetingCopy.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .moyeotaText(
                    MoyeotaType.DisplayMd.copy(fontSize: 26, letterSpacing: -0.52).hangulTrimmed,
                    color: MoyeotaColor.InkPrimary
                )
                .frame(maxWidth: .infinity)

            Spacer().frame(height: 12)

            Text(OnboardingMeetingCopy.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .moyeotaText(
                    MoyeotaType.BodyMd.copy(lineHeight: .sp(22), letterSpacing: -0.3).hangulTrimmed,
                    color: MoyeotaColor.TextMute
                )
                .frame(maxWidth: .infinity)

            Spacer().frame(height: 32)

            PageDots(count: 3, activeIndex: 2)

            Spacer(minLength: 0)

            PrimaryCtaButton(text: "시작하기", onClick: onStart)
                .padding(.horizontal, 16)

            Spacer().frame(height: 18)

            Button(action: onAlreadyHaveAccount) {
                Text("이미 계정이 있어요")
                    .moyeotaText(
                        MoyeotaType.BodySm.copy(fontWeight: .medium, letterSpacing: -0.26).hangulTrimmed,
                        color: MoyeotaColor.TextMute
                    )
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackStyle())

            Spacer(minLength: 0)

            NavigationBarSpacer()
        }
        // 작은 화면에서 넘치면 원본 Column 처럼 위를 고정하고 아래로 넘긴다(기본값이면 위아래로 나뉜다).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MoyeotaColor.SurfaceSoft)
    }
}

// 일러스트 — 지도(만날 곳: 파란 점 → 빨간 핀). 공유 배지는 보호자 공유 기능이 없어 뺐고, 지도를 카드 가운데에 둔다
private struct SafetyIllustration: View {
    var body: some View {
        ZStack {
            // 지도 목업 (경로 라인) — 배지가 빠진 만큼 키워 카드를 채운다
            Canvas { context, size in
                let start = CGPoint(x: size.width * 0.16, y: size.height * 0.78)
                let end = CGPoint(x: size.width * 0.84, y: size.height * 0.24)

                // 경로 라인
                var line = Path()
                line.move(to: start)
                line.addLine(to: end)
                context.stroke(
                    line,
                    with: .color(MoyeotaColor.Primary500),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )

                // 출발 지점 — 파란 점 (흰 테두리)
                context.fill(circle(center: start, radius: 9.0 / 2 + 2), with: .color(.white))
                context.fill(circle(center: start, radius: 9.0 / 2), with: .color(MoyeotaColor.Primary500))

                // 도착 지점 — 빨간 핀
                let pinCenter = CGPoint(x: end.x, y: end.y - 8)
                let pinRadius: CGFloat = 9
                var pinPath = Path()
                pinPath.move(to: CGPoint(x: pinCenter.x, y: pinCenter.y + pinRadius * 2.1))
                pinPath.addLine(to: CGPoint(x: pinCenter.x - pinRadius * 0.8, y: pinCenter.y + pinRadius * 0.5))
                pinPath.addLine(to: CGPoint(x: pinCenter.x + pinRadius * 0.8, y: pinCenter.y + pinRadius * 0.5))
                pinPath.closeSubpath()
                context.fill(pinPath, with: .color(MoyeotaColor.Danger500))
                context.fill(circle(center: pinCenter, radius: pinRadius), with: .color(MoyeotaColor.Danger500))
                context.fill(circle(center: pinCenter, radius: pinRadius * 0.35), with: .color(.white))
            }
            .frame(width: 260, height: 180)
            .background(Color(argb: 0xFFE2E7EF), in: RoundedRectangle(cornerRadius: 16, style: .circular))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.Primary50, in: RoundedRectangle(cornerRadius: 24, style: .circular))
    }

    private func circle(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
