import SwiftUI

/// 머티리얼 잉크 리플 자리의 눌림 표시. 배경이 없는 탭 영역(아이콘 버튼, 하단탭)에 쓴다.
public struct PressFeedbackStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 머티리얼 버튼의 모양: 알약 + 활성/비활성 색 + 눌림 오버레이(상태 레이어 10%).
private struct CtaButtonStyle: ButtonStyle {
    let containerColor: Color
    let contentColor: Color
    let disabledContainerColor: Color
    let disabledContentColor: Color
    var border: Color?

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let content = isEnabled ? contentColor : disabledContentColor
        configuration.label
            .foregroundStyle(content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isEnabled ? containerColor : disabledContainerColor, in: Capsule(style: .circular))
            .overlay {
                if configuration.isPressed {
                    Capsule(style: .circular).fill(content.opacity(0.1))
                }
            }
            .overlay {
                if let border {
                    Capsule(style: .circular).strokeBorder(border, lineWidth: 1)
                }
            }
            .contentShape(Capsule(style: .circular))
    }
}

/// 두 CTA 가 공유하는 본체. 색만 다르다.
private struct LoadingCtaButton: View {
    let text: String
    let onClick: () -> Void
    let enabled: Bool
    let loading: Bool
    let containerColor: Color

    var body: some View {
        Button(action: onClick) {
            Group {
                if loading {
                    CircularProgressIndicator(size: 20, strokeWidth: 2)
                } else {
                    Text(text)
                        .moyeotaText(MoyeotaType.ButtonLg.hangulTrimmed)
                        .padding(.horizontal, 24)
                }
            }
        }
        .buttonStyle(
            CtaButtonStyle(
                containerColor: containerColor,
                contentColor: MoyeotaColor.TextOnDark,
                disabledContainerColor: MoyeotaColor.SurfaceSoft,
                disabledContentColor: MoyeotaColor.TextAsh
            )
        )
        .disabled(!enabled || loading)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }
}

// 주 CTA. 필수 조건 미충족 시 enabled=false, 제출 중이면 loading=true (공통 규칙: 중복 제출 차단)
public struct PrimaryCtaButton: View {
    private let text: String
    private let onClick: () -> Void
    private let enabled: Bool
    private let loading: Bool

    public init(text: String, onClick: @escaping () -> Void, enabled: Bool = true, loading: Bool = false) {
        self.text = text
        self.onClick = onClick
        self.enabled = enabled
        self.loading = loading
    }

    public var body: some View {
        LoadingCtaButton(
            text: text,
            onClick: onClick,
            enabled: enabled,
            loading: loading,
            containerColor: MoyeotaColor.Primary500
        )
    }
}

/// 되돌릴 수 없는 파괴적 동작의 주 CTA — 지금 쓰는 곳은 37 회원 탈퇴 하나다.
///
/// `PrimaryCtaButton` 과 모양·크기·중복 제출 차단 규칙이 같고 **색만 Danger** 다. 색을 바꾸는 이유는
/// 장식이 아니라 경고다: 같은 자리의 같은 파란 버튼이면 「저장」·「다음」과 구분되지 않는다.
///
/// 비활성 색은 `PrimaryCtaButton` 과 똑같이 둔다 — 못 누르는 버튼은 위험하지 않으므로
/// 빨간색을 유지하면 "눌리지 않는데 위험해 보이는" 상태가 된다.
///
/// `SafetyButton` 과 혼동하지 말 것. 그쪽은 긴급 신고(도움을 부르는 행동) 전용이고,
/// 이쪽은 사용자가 자기 것을 지우는 행동이다.
public struct DangerCtaButton: View {
    private let text: String
    private let onClick: () -> Void
    private let enabled: Bool
    private let loading: Bool

    public init(text: String, onClick: @escaping () -> Void, enabled: Bool = true, loading: Bool = false) {
        self.text = text
        self.onClick = onClick
        self.enabled = enabled
        self.loading = loading
    }

    public var body: some View {
        LoadingCtaButton(
            text: text,
            onClick: onClick,
            enabled: enabled,
            loading: loading,
            containerColor: MoyeotaColor.Danger500
        )
    }
}

public struct SecondaryButton: View {
    private let text: String
    private let onClick: () -> Void
    private let enabled: Bool

    public init(text: String, onClick: @escaping () -> Void, enabled: Bool = true) {
        self.text = text
        self.onClick = onClick
        self.enabled = enabled
    }

    public var body: some View {
        Button(action: onClick) {
            Text(text)
                .moyeotaText(MoyeotaType.ButtonLg.hangulTrimmed)
                .padding(.horizontal, 24)
        }
        .buttonStyle(
            CtaButtonStyle(
                containerColor: .clear,
                contentColor: MoyeotaColor.InkPrimary,
                disabledContainerColor: .clear,
                // 머티리얼 1.4.0 outlinedButtonColors 의 비활성 글자색: onSurfaceVariant 38%
                // (`OutlinedButtonTokens.DisabledLabelTextColor`, 바이트코드와 원본 스크린샷 #C0C3CC 로 확인)
                disabledContentColor: LightColorScheme.onSurfaceVariant.opacity(0.38),
                border: MoyeotaColor.Hairline
            )
        )
        .disabled(!enabled)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }
}

// 비상 신고 전용 버튼 — Safety 색은 여기 외 사용 금지
public struct SafetyButton: View {
    private let text: String
    private let onClick: () -> Void

    public init(text: String, onClick: @escaping () -> Void) {
        self.text = text
        self.onClick = onClick
    }

    public var body: some View {
        Button(action: onClick) {
            Text(text)
                .moyeotaText(MoyeotaType.ButtonLg.hangulTrimmed)
                .padding(.horizontal, 24)
        }
        .buttonStyle(
            CtaButtonStyle(
                containerColor: MoyeotaColor.Safety500,
                contentColor: MoyeotaColor.TextOnDark,
                disabledContainerColor: MoyeotaColor.Safety500,
                disabledContentColor: MoyeotaColor.TextOnDark
            )
        )
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }
}

/// 머티리얼 3 `CircularProgressIndicator`(무한 회전형) 자리. 원본의 호 길이·회전 움직임을 옮겼다.
/// 색 기본값은 원본처럼 테마 primary 다 — 그래서 CTA 로딩 스피너도 버튼 글자색이 아니라 파란색이다.
public struct CircularProgressIndicator: View {
    private let size: CGFloat
    private let color: Color
    private let strokeWidth: CGFloat

    public init(size: CGFloat = 40, color: Color = MoyeotaColor.Primary500, strokeWidth: CGFloat = 4) {
        self.size = size
        self.color = color
        self.strokeWidth = strokeWidth
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let millis = timeline.date.timeIntervalSinceReferenceDate * 1000
            Canvas { context, canvasSize in
                let arc = indeterminateArc(millis: millis)
                let radius = (min(canvasSize.width, canvasSize.height) - strokeWidth) / 2
                // 사각 끝처리가 시작점 뒤로 두께 절반만큼 나오므로 그만큼 앞으로 민다(원본 drawIndeterminateCircularIndicator).
                // 원본 식의 지름은 실제 크기가 아니라 기본 지름 상수 40dp 다.
                let capOffset = (180 / Double.pi) * Double(strokeWidth / (40 / 2)) / 2
                var path = Path()
                path.addRelativeArc(
                    center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
                    radius: radius,
                    startAngle: .degrees(arc.start + capOffset),
                    delta: .degrees(max(arc.sweep, 0.1))
                )
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .square))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 시각(ms) → 호의 시작 각도·길이(도). 머티리얼 3 `CircularProgressIndicator` 의 애니메이션 상수.
func indeterminateArc(millis: Double) -> (start: Double, sweep: Double) {
    let rotationDuration = 1332.0
    let rotationsPerCycle = 5.0
    let baseRotationAngle = 286.0
    let jumpRotationAngle = 290.0
    let rotationAngleOffset = 216.0
    let startAngleOffset = -90.0
    let headAndTailDuration = 666.0

    let cycle = rotationDuration * rotationsPerCycle
    // 원본은 정수 애니메이션이라 한 바퀴마다 계단으로 오른다(0…4).
    let currentRotation = floor(millis.truncatingRemainder(dividingBy: cycle) / rotationDuration)
    let baseRotation = millis.truncatingRemainder(dividingBy: rotationDuration) / rotationDuration * baseRotationAngle

    let phase = millis.truncatingRemainder(dividingBy: rotationDuration)
    let head = phase < headAndTailDuration
        ? fastOutSlowIn(phase / headAndTailDuration) * jumpRotationAngle
        : jumpRotationAngle
    let tail = phase < headAndTailDuration
        ? 0
        : fastOutSlowIn((phase - headAndTailDuration) / headAndTailDuration) * jumpRotationAngle

    let offset = startAngleOffset
        + (currentRotation * rotationAngleOffset).truncatingRemainder(dividingBy: 360)
        + baseRotation
    return (start: tail + offset, sweep: abs(head - tail))
}

/// `FastOutSlowInEasing` = cubic-bezier(0.4, 0, 0.2, 1).
func fastOutSlowIn(_ fraction: Double) -> Double {
    let x1 = 0.4, y1 = 0.0, x2 = 0.2, y2 = 1.0
    func bezier(_ a: Double, _ b: Double, _ t: Double) -> Double {
        3 * a * (1 - t) * (1 - t) * t + 3 * b * (1 - t) * t * t + t * t * t
    }
    var low = 0.0, high = 1.0
    for _ in 0..<24 {
        let mid = (low + high) / 2
        if bezier(x1, x2, mid) < fraction {
            low = mid
        } else {
            high = mid
        }
    }
    return bezier(y1, y2, (low + high) / 2)
}
