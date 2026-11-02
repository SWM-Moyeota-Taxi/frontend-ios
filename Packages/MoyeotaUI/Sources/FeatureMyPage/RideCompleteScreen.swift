import MoyeotaDesignSystem
import PresentationCore
import SwiftUI

// 와이어프레임 그레이 (core token 미정의 색 — 화면 재현용)
private let GrayMute = Color(argb: 0xFF8A93A0)
private let SoftBg = Color(argb: 0xFFF6F8FB)
private let SoftDivider = Color(argb: 0xFFE4E9F0)

/// 33 · 도착 완료 [S18]
///
/// 진입: 26 운행 중에서 서버 FINISHED 감지 시 자동 전이(26 은 스택에서 제거) — 하단탭 없음
///
/// 이동(디스크립션):
/// - 「홈으로」 → 14 홈 (onDone)
///
/// 표시 값(전부 진행 중이던 방 `Ride` 에서 온다):
/// - `routeLabel` 「출발지 → 도착지」. nil 이면 줄을 숨긴다
/// - 요약 카드 「내가 낸 돈」(farePerPerson) · 「함께 탄 사람」(나를 뺀 멤버 수). 값이 없는 칸은 빼고,
///   두 칸 다 없으면 카드 자체를 숨긴다
///
/// 동승자 평가(좋았어요/아쉬웠어요 · 태그)와 「아낀 돈」은 뺐다 — 평가를 받을 서버 API 가 없고,
/// 아낀 돈은 계산 근거(혼자 탔을 때 요금)가 확정되지 않았다.
public struct RideCompleteScreen: View {
    private let routeLabel: String?
    private let paidAmount: Int?
    private let companionCount: Int?
    private let onDone: () -> Void

    public init(
        routeLabel: String?,
        paidAmount: Int?,
        companionCount: Int?,
        onDone: @escaping () -> Void
    ) {
        self.routeLabel = routeLabel
        self.paidAmount = paidAmount
        self.companionCount = companionCount
        self.onDone = onDone
    }

    public var body: some View {
        // 요약 카드 — 내가 낸 돈 / 함께 탄 사람 (값이 있는 칸만)
        let cells = rideCompleteSummaryCells(paidAmount: paidAmount, companionCount: companionCount)

        VStack(spacing: 0) {
            StatusBarSpacer()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 82)

                    // 도착 완료 체크 원
                    ZStack {
                        Circle().fill(MoyeotaColor.Success50)
                        CheckIcon(color: MoyeotaColor.Success600)
                    }
                    .frame(width: 76, height: 76)

                    Spacer().frame(height: 22)
                    Text("잘 도착했어요")
                        .moyeotaText(
                            MaterialTextStyle.bodyLarge(fontSize: 24, fontWeight: .bold),
                            color: MoyeotaColor.InkPrimary
                        )
                    if let routeLabel {
                        Spacer().frame(height: 3)
                        Text(routeLabel)
                            .moyeotaText(MaterialTextStyle.bodyLarge(fontSize: 15), color: MoyeotaColor.TextMute)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    if !cells.isEmpty {
                        Spacer().frame(height: 22)
                        HStack(spacing: 0) {
                            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                                if index > 0 {
                                    SoftDivider.frame(width: 1, height: 44)
                                }
                                SummaryCell(value: cell.value, label: cell.label)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 96)
                        .background(SoftBg, in: RoundedRectangle(cornerRadius: 18, style: .circular))
                        .padding(.horizontal, 16)
                    }

                    Spacer().frame(height: 24)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // 원본 `verticalScroll` 은 자기 칸에서 잘린다. SwiftUI `ScrollView` 는 안전 영역까지 그려 내용이 상태바에 겹친다.
            .clipped()

            PrimaryCtaButton(text: "홈으로", onClick: onDone)
                .padding(.horizontal, 16)
            Spacer().frame(height: 16)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoyeotaColor.SurfaceCanvas)
    }
}

/// 요약 칸. 값이 있는 칸만 만든다.
func rideCompleteSummaryCells(paidAmount: Int?, companionCount: Int?) -> [(value: String, label: String)] {
    var cells: [(value: String, label: String)] = []
    // 「내가 낸 돈」이 아니라 「1인 부담」이다 — 결제 기능이 없어 앱은 실제로 낸 돈을
    // 알 수 없다. 이 값은 예상 요금을 정원으로 나눈 추정치(`Ride.farePerPerson`)로,
    // 20·22·25 가 쓰는 라벨과 같게 맞췄다(2026-10-13).
    if let paidAmount { cells.append((wonLabel(amount: paidAmount), "1인 부담")) }
    if let companionCount { cells.append(("\(companionCount)명", "함께 탄 사람")) }
    return cells
}

private struct SummaryCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .moyeotaText(
                    MaterialTextStyle.bodyLarge(fontSize: 18, fontWeight: .bold),
                    color: MoyeotaColor.InkPrimary
                )
            Spacer().frame(height: 4)
            Text(label)
                .moyeotaText(MaterialTextStyle.bodyLarge(fontSize: 11, fontWeight: .medium), color: GrayMute)
        }
    }
}

// ─── 아이콘 (아이콘 라이브러리 미사용 — Canvas 직접 드로잉) ─────────────────────

private struct CheckIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke = StrokeStyle(lineWidth: 3.5, lineCap: .round)
            var first = Path()
            first.move(to: CGPoint(x: w * 0.12, y: h * 0.55))
            first.addLine(to: CGPoint(x: w * 0.4, y: h * 0.82))
            context.stroke(first, with: .color(color), style: stroke)
            var second = Path()
            second.move(to: CGPoint(x: w * 0.4, y: h * 0.82))
            second.addLine(to: CGPoint(x: w * 0.88, y: h * 0.22))
            context.stroke(second, with: .color(color), style: stroke)
        }
        .frame(width: 31, height: 31)
        .accessibilityHidden(true)
    }
}
