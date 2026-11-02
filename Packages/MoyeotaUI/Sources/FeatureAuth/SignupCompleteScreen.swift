import MoyeotaDesignSystem
import SwiftUI

// 13 · 가입 완료 [S08]
// 진입: 12 동의 완료 — 뒤로가기로 가입 플로우 재진입 불가 (스택 초기화는 호출부 책임)
// 「탑승할 사람 찾기」 → 14 홈 / 「앱 먼저 둘러보기」 → 17 합승 지도 (peek)
// 첫 탑승 할인 배너는 뺐다 — 백엔드에 발급·차감 API 가 없다.
public struct SignupCompleteScreen: View {
    private let onStart: () -> Void
    private let onExplore: () -> Void

    public init(onStart: @escaping () -> Void, onExplore: @escaping () -> Void = {}) {
        self.onStart = onStart
        self.onExplore = onExplore
    }

    public var body: some View {
        VStack(spacing: 0) {
            StatusBarSpacer()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 104)
                    CompleteCheckBadge()
                        .frame(maxWidth: .infinity)
                    Spacer().frame(height: 32)
                    Text("가입이 끝났어요")
                        .moyeotaText(MoyeotaType.DisplayMd.copy(fontSize: 26).hangulTrimmed, color: MoyeotaColor.InkPrimary)
                        .frame(maxWidth: .infinity)
                    Spacer().frame(height: 8)
                    Text("이제 같이 탈 사람을 찾아볼까요?")
                        .moyeotaText(MoyeotaType.BodyMd.hangulTrimmed, color: MoyeotaColor.TextMute)
                        .frame(maxWidth: .infinity)

                    Spacer().frame(height: 40)
                    Text("이렇게 이용해요")
                        .moyeotaText(
                            MoyeotaType.BodySm.copy(fontSize: 14, fontWeight: .bold).hangulTrimmed,
                            color: MoyeotaColor.InkPrimary
                        )
                    Spacer().frame(height: 12)
                    ForEach(Array(completeGuideSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .center, spacing: 0) {
                            ZStack {
                                Circle().fill(MoyeotaColor.Primary50)
                                Text(verbatim: "\(index + 1)")
                                    .moyeotaText(
                                        MoyeotaType.CaptionMd.copy(fontWeight: .bold),
                                        color: MoyeotaColor.Primary500
                                    )
                            }
                            .frame(width: 26, height: 26)
                            Spacer().frame(width: 11, height: 0)
                            Text(step)
                                .moyeotaText(
                                    MoyeotaType.BodySm.copy(fontSize: 14, fontWeight: .medium).hangulTrimmed,
                                    color: Color(argb: 0xFF4B5563)
                                )
                        }
                        if index != completeGuideSteps.count - 1 {
                            Spacer().frame(height: 18)
                        }
                    }
                    Spacer().frame(height: 24)
                }
                // 원본 Column 에는 fillMaxWidth 가 없어 폭이 가장 넓은 안내 줄에 맞춰 줄고, 왼쪽에 붙는다. 그래서 배지와
                // 위 두 줄의 가운데는 화면 가운데가 아니라 그 폭의 가운데다. 안내 줄은 고정 pt 라 가장 좁은 기기에도 들어간다.
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                PrimaryCtaButton(text: "탑승할 사람 찾기", onClick: onStart)
                Spacer().frame(height: 16)
                Button(action: onExplore) {
                    Text("앱 먼저 둘러보기")
                        .moyeotaText(MoyeotaType.BodySm.copy(fontWeight: .medium).hangulTrimmed, color: MoyeotaColor.TextMute)
                }
                .buttonStyle(NoIndicationButtonStyle())
            }
            .padding(.horizontal, 16)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.SurfaceSoft)
    }
}

private let completeGuideSteps = [
    "목적지를 넣으면 같은 방향 사람을 찾아요",
    "매칭되면 채팅으로 만날 곳을 정해요",
    "내릴 때 1/N으로 나눠 내면 끝이에요",
]

// 큰 체크 배지 — Primary50 원 안에 Primary 체크표시
private struct CompleteCheckBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(MoyeotaColor.Primary50)
            Canvas { context, size in
                let w = size.width
                let h = size.height
                var head = Path()
                head.move(to: CGPoint(x: w * 0.08, y: h * 0.55))
                head.addLine(to: CGPoint(x: w * 0.38, y: h * 0.85))
                var tail = Path()
                tail.move(to: CGPoint(x: w * 0.38, y: h * 0.85))
                tail.addLine(to: CGPoint(x: w * 0.92, y: h * 0.15))
                let style = StrokeStyle(lineWidth: 5, lineCap: .round)
                context.stroke(head, with: .color(MoyeotaColor.Primary500), style: style)
                context.stroke(tail, with: .color(MoyeotaColor.Primary500), style: style)
            }
            .frame(width: 37, height: 37)
        }
        .frame(width: 88, height: 88)
    }
}
