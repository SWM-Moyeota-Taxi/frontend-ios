import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

// 와이어프레임 그레이 (core token 미정의 색 — 화면 재현용)
private let CanvasBg = Color(argb: 0xFFF5F7FA)
private let GrayMute = Color(argb: 0xFF8A93A0)
private let GrayAsh = Color(argb: 0xFF9AA1AC)

/// 23 · 동승자 프로필 [S13]
///
/// 이동(디스크립션):
/// - 뒤로 → 22 탑승 상세 (onBack)
/// - 「채팅으로 물어보기」 → 24 채팅 (onChatClick)
///
/// 서버 계약(2026-09): 방 상세 `members[]` 가 주는 것은 닉네임·이미지·탑승 횟수뿐이다.
/// 그래서 이 화면은 그 값만 보여 준다 — 지표는 탑승 횟수 한 칸이고, 서버에 없는 평가·집계·검증
/// 항목은 「준비 중」 자리표시도 두지 않고 요소째 뺐다. 프로필은 사람을 판단하는 화면이라
/// 지어낸 수치나 빈 칸 하나가 그대로 신뢰의 근거가 된다.
public struct PartnerProfileScreen: View {
    private let user: User
    private let onBack: () -> Void
    private let onChatClick: () -> Void

    /// - Parameter user: 22·20 에서 탭한 그 멤버. 호출부가 반드시 넘긴다(기본값 없음).
    public init(user: User, onBack: @escaping () -> Void = {}, onChatClick: @escaping () -> Void = {}) {
        self.user = user
        self.onBack = onBack
        self.onChatClick = onChatClick
    }

    public var body: some View {
        let hasBadge = !user.verifiedLabel.isBlank
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .circular)
        let ctaShape = RoundedRectangle(cornerRadius: 16, style: .circular)

        VStack(spacing: 0) {
            StatusBarSpacer()

            // 헤더
            HStack(spacing: 0) {
                MatchingBackButton(onBack: onBack)
                Text("프로필")
                    .moyeotaText(inlineType(18, .bold), color: MoyeotaColor.InkPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.trailing, 24)
            .padding(.top, 8)
            .padding(.bottom, 8)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 16)

                    // 아바타 + 인증 배지 — 인증 배지는 서버가 badgeId 를 주기 시작할 때만 붙인다.
                    // 아무나 체크 표시를 달면 "확인된 사람" 이라는 잘못된 신호가 된다.
                    ZStack(alignment: .bottomTrailing) {
                        MemberAvatar(user: user, size: 80)
                        if hasBadge {
                            CheckSmallIcon(tint: MoyeotaColor.TextOnDark)
                                .frame(width: 28, height: 28)
                                .background(MoyeotaColor.Primary500, in: Circle())
                        }
                    }
                    Spacer().frame(height: 12)
                    Text(user.displayNickname)
                        .moyeotaText(inlineType(24, .bold), color: MoyeotaColor.InkPrimary)
                    // 서버가 배지 라벨을 줄 때만 한 줄 붙인다 — 없으면 줄째 생략한다
                    if hasBadge {
                        Spacer().frame(height: 4)
                        Text(user.verifiedLabel)
                            .moyeotaText(inlineType(13, .medium), color: GrayMute)
                    }
                    Spacer().frame(height: 20)

                    // 지표 카드 — 서버가 주는 지표는 탑승 횟수 하나뿐이다
                    StatCell(
                        value: user.rideCount <= 0 ? "첫 탑승" : "\(user.rideCount)회",
                        label: "탑승 횟수",
                        valueFontSize: user.rideCount <= 0 ? 16 : 20
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
                    .background(MoyeotaColor.SurfaceCanvas)
                    .clipShape(cardShape)
                    .moyeotaShadow(elevation: 4, shape: cardShape, spotColor: Color(argb: 0x0F1B2A4A))
                    Spacer().frame(height: 20)

                    // 「학번」은 지웠다 — 학교 인증(06·07)이 가입 경로에 없어 학번을 받은 적이 없다.
                    // 서버가 주는 멤버 정보는 publicId·닉네임·이미지·탑승 횟수뿐이다(2026-10-13).
                    Text("실명과 연락처는 서로에게 공개되지 않아요")
                        .moyeotaText(inlineType(12, .medium), color: GrayAsh)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Spacer().frame(height: 16)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            // CTA — 채팅으로 물어보기 → 24 채팅
            Button(action: onChatClick) {
                HStack(spacing: 0) {
                    ChatBubbleIcon()
                    Spacer().frame(width: 9)
                    Text("채팅으로 물어보기")
                        .moyeotaText(inlineType(17, .bold), color: MoyeotaColor.TextOnDark)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(MoyeotaColor.Primary500, in: ctaShape)
            }
            .buttonStyle(PressOverlayStyle(shape: ctaShape))
            // 원본 `Modifier.shadow(10.dp, …, spotColor = 0x42085AF5)` 자리. 안드로이드 스폿 그림자는 광원이 화면 위쪽에 있어
            // 화면 아래 물체일수록 더 밀려 내려간다. `moyeotaShadow` 의 근사(거리 5)로는 12pt 아래에서 거의 사라져
            // 내비게이션 바 자리의 끊김이 보이지 않으므로, 원본 픽셀에 맞춘 거리·번짐을 쓴다. 알파는 같다.
            .background {
                ZStack {
                    ctaShape.fill(Color.white).shadow(color: Color.black.opacity(0.039), radius: 5)
                    ctaShape.fill(Color.white).shadow(color: Color(argb: 0x42085AF5).opacity(0.19), radius: 8, y: 14)
                }
            }
            .padding(.horizontal, 16)
            Spacer().frame(height: 12)
            // 원본처럼 배경을 깔아 내비게이션 바 자리에서 CTA 그림자가 끊긴다.
            NavigationBarSpacer()
                .frame(maxWidth: .infinity)
                .background(CanvasBg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBg)
    }
}

private struct StatCell: View {
    let value: String
    let label: String
    // 숫자 대신 「첫 탑승」 같은 문구가 들어가면 작게 줄인다
    let valueFontSize: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // 원본 숫자(Roboto)는 폭이 모두 같아 「11회」와 「25회」의 폭이 같다. SF 는 1 이 좁다.
            Text(value)
                .monospacedDigit()
                .moyeotaText(inlineType(valueFontSize, .bold), color: MoyeotaColor.InkPrimary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 2)
            Text(label)
                .moyeotaText(inlineType(11, .medium), color: GrayMute)
        }
    }
}

// ─── 아이콘 (머티리얼 아이콘 미사용 — Canvas 직접 드로잉) ─────────────────────

private struct CheckSmallIcon: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w * 0.12, y: h * 0.55))
            path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.82))
            path.move(to: CGPoint(x: w * 0.42, y: h * 0.82))
            path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.2))
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 14, height: 14)
    }
}

private struct ChatBubbleIcon: View {
    var tint: Color = MoyeotaColor.TextOnDark

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke = StrokeStyle(lineWidth: 1.8, lineCap: .round)
            context.stroke(
                Path(
                    roundedRect: CGRect(x: w * 0.08, y: h * 0.12, width: w * 0.84, height: h * 0.6),
                    cornerRadius: 4,
                    style: .circular
                ),
                with: .color(tint),
                style: stroke
            )
            // 말풍선 꼬리
            var tail = Path()
            tail.move(to: CGPoint(x: w * 0.3, y: h * 0.72))
            tail.addLine(to: CGPoint(x: w * 0.3, y: h * 0.92))
            tail.move(to: CGPoint(x: w * 0.3, y: h * 0.92))
            tail.addLine(to: CGPoint(x: w * 0.5, y: h * 0.72))
            context.stroke(tail, with: .color(tint), style: stroke)
        }
        .frame(width: 19, height: 19)
    }
}
