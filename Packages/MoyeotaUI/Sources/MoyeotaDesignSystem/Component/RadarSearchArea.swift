import SwiftUI

private let RadarBg = Color(argb: 0xFFEEF2F8)
private let RadarRing = Color(argb: 0xFFD7DFEC)

/// 펄스 한 바퀴의 길이(초). 원본 `tween(durationMillis = 1800, easing = LinearEasing)`.
private let RadarPulseSeconds = 1.8

/// 동심원 + 바깥으로 퍼지는 펄스 링. 「지금 주변에 요청을 보내고 있다」는 상태를 나타낸다.
///
/// **21 매칭 대기가 아니라 25b 기사 찾는 중의 그림이다.** 21 에서는 배경이 실지도로 바뀌면서
/// 이 레이더를 걷어냈다 — 출발·도착과 경로라는 **진짜 정보**가 그 자리에 있는데 동심원이 그걸
/// 가리기만 했다. 「어느 범위에서 찾는지」는 21 에서 아무도 말할 수 없다: 매칭은 반경을 보지 않는다
/// (그래서 탐색 반경 원도 2026-10-14 에 지웠다). 반대로 25b 에는 보여 줄 지도가 없다(기사 위치는
/// 아직 없고 경로는 이미 확정돼 새 정보가 아니다). 기다림 자체가 화면의 내용인 단계라 제 몫을 한다.
///
/// 25b 의 「주변 기사님에게 요청하고 있어요」는 참이다 — 서버 배차가 실제로 반경 안의 기사에게
/// 콜을 보낸다(`DispatchService`). 21 의 동승자 찾기와 달리 여기엔 범위 개념이 실재한다.
///
/// 그림의 점들은 **데이터가 아니라 장식**이다. 실제 인원·기사 수를 뜻하지 않는다.
public struct RadarSearchArea: View {
    public init() {}

    public var body: some View {
        TimelineView(.animation) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let pulse = seconds.truncatingRemainder(dividingBy: RadarPulseSeconds) / RadarPulseSeconds
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for radius: CGFloat in [34, 60, 88] {
                    context.stroke(circle(center, radius), with: .color(RadarRing), lineWidth: 1.5)
                }
                // 확장 펄스 링
                context.stroke(
                    circle(center, 34 + (88 - 34) * pulse),
                    with: .color(MoyeotaColor.Primary500.opacity((1 - pulse) * 0.35)),
                    lineWidth: 2
                )
                // 요청을 보내는 나
                context.fill(circle(center, 8), with: .color(MoyeotaColor.Primary500))
                // 주변 — 장식용 점 (실제 기사 수가 아니다)
                context.fill(
                    circle(CGPoint(x: center.x - 66, y: center.y - 32), 5),
                    with: .color(MoyeotaColor.RouteUserA.opacity(0.85))
                )
                context.fill(
                    circle(CGPoint(x: center.x + 58, y: center.y + 42), 5),
                    with: .color(MoyeotaColor.RouteUserA.opacity(0.5))
                )
            }
        }
        .background(RadarBg)
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
