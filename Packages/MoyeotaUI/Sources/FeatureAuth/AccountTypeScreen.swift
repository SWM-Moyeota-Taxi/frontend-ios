import MoyeotaDesignSystem
import PresentationCore
import SwiftUI

private let ScreenBackground = Color(argb: 0xFFF5F7FA)
private let TextSlate = Color(argb: 0xFF4B5563)
private let TextSoft = Color(argb: 0xFF8A93A0)
private let TextFaint = Color(argb: 0xFF9AA1AC)
private let IconBoxIdle = Color(argb: 0xFFF6F8FB)
private let RadioIdleBorder = Color(argb: 0xFFD1D5DB)
private let CardShadow = Color(argb: 0x0F1B2A4A)

// ⚠️ 05 는 현재 어떤 그래프에도 등록되어 있지 않다 — 가입 API 에 계정 유형 개념이 없어
// 가입 필수 경로(09 → 10 → 11 → 12)에서 제외했다. 인증 기능을 마이페이지로 옮길 때
// 재사용할 수 있도록 파일은 남겨 둔다.
//
// 05 화면에서 분기되는 계정 유형 (라디오 1개만 선택 가능, 기본 선택 없음)
public enum AccountType: Sendable {
    case student // 학생 → 06 학교 이메일 → 07 코드 → 09
    case worker // 직장인 → 08 재직 인증 → 09
    case general // 일반 → 09 본인 인증 직행 (재직 인증 화면을 거치지 않는다)
}

/// 05 · 계정 유형 선택 [S25]
///
/// 진입: 04 로그인 성공
public struct AccountTypeScreen: View {
    private let onBack: () -> Void
    private let onNext: (AccountType) -> Void
    private let onSkipVerification: () -> Void

    // 라디오 1개만 선택 가능, 기본 선택 없음 — 미선택 시 「다음」 비활성
    @State private var selectedType: AccountType?

    /// - Parameter onBack: 뒤로 → 04 시작 — 로그인 방식
    /// - Parameter onNext: 유형 선택 + 「다음」 → 학생: 06 학교 이메일 / 직장인: 08 재직 인증 / 일반: 09 본인 인증
    /// - Parameter onSkipVerification: 「나중에 인증할게요」 → 14 홈 (미인증 상태)
    public init(
        onBack: @escaping () -> Void,
        onNext: @escaping (AccountType) -> Void,
        onSkipVerification: @escaping () -> Void
    ) {
        self.onBack = onBack
        self.onNext = onNext
        self.onSkipVerification = onSkipVerification
    }

    public var body: some View {
        VStack(spacing: 0) {
            StatusBarSpacer()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 머티리얼 `IconButton` 의 레이아웃 크기는 최소 터치 영역인 48dp 다.
                    Button(action: onBack) {
                        BackArrowIcon()
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressFeedbackStyle())
                    .padding(.top, 12)

                    Spacer().frame(height: 20)
                    Text("어떤 방법으로\n인증할까요?")
                        .moyeotaText(
                            MoyeotaType(fontSize: 24, fontWeight: .bold, lineHeight: .sp(34), letterSpacing: -0.48),
                            color: MoyeotaColor.InkPrimary
                        )

                    Spacer().frame(height: 16)
                    Text("신분에 맞는 인증으로 신뢰를 확인해요")
                        .moyeotaText(
                            MoyeotaType(fontSize: 14, lineHeight: .sp(20), letterSpacing: -0.28),
                            color: MoyeotaColor.TextMute
                        )

                    Spacer().frame(height: 34)
                    typeCards

                    Spacer().frame(height: 8)
                    footnote("인증 사용자에게 마일리지를 적립해 신뢰를 쌓는 방식은 고도화 시 검토")
                    Spacer().frame(height: 7)
                    footnote("인증 유형은 마이페이지에서 추가할 수 있어요")

                    Spacer().frame(height: 13)
                    PrimaryCtaButton(
                        text: "다음",
                        onClick: {
                            if let selectedType { onNext(selectedType) }
                        },
                        enabled: selectedType != nil
                    )

                    Spacer().frame(height: 18)
                    Button(action: onSkipVerification) {
                        Text("나중에 인증할게요")
                            .moyeotaText(
                                MoyeotaType(fontSize: 13, fontWeight: .medium, lineHeight: .sp(19), letterSpacing: -0.26),
                                color: MoyeotaColor.TextMute
                            )
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(NoIndicationButtonStyle())
                    .frame(maxWidth: .infinity)
                    Spacer().frame(height: 28)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ScreenBackground)
        // 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라진다. `@State` 는 스택에 있는 동안 남으므로 직접 비운다.
        .onDisappear { selectedType = nil }
    }

    @ViewBuilder
    private var typeCards: some View {
        AccountTypeCard(
            title: "학생",
            subtitle: "학교 이메일로 인증해요",
            caption: "부산대 · 부경대 · 동아대",
            icon: { GraduationCapIcon(color: $0) },
            selected: selectedType == .student,
            onClick: { selectedType = .student }
        )

        Spacer().frame(height: 16)
        AccountTypeCard(
            title: "직장인",
            subtitle: "재직 정보로 인증해요",
            caption: "회사 메일 또는 재직 서류",
            icon: { BriefcaseIcon(color: $0) },
            selected: selectedType == .worker,
            onClick: { selectedType = .worker }
        )

        Spacer().frame(height: 16)
        AccountTypeCard(
            title: "일반",
            subtitle: "휴대폰 본인 인증으로 시작해요",
            caption: "누구나 · 매너 기록으로 신뢰를 쌓아요",
            icon: { IdCardIcon(color: $0) },
            selected: selectedType == .general,
            onClick: { selectedType = .general }
        )
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .moyeotaText(
                MoyeotaType(fontSize: 12, fontWeight: .medium, lineHeight: .sp(17), letterSpacing: -0.24),
                color: TextFaint
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

// 인증 유형 선택 카드 — 선택 시 파란 테두리 + 파란 아이콘/라디오
private struct AccountTypeCard<Icon: View>: View {
    let title: String
    let subtitle: String
    let caption: String
    let icon: (Color) -> Icon
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .circular)
        Button(action: onClick) {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: shape)
                .overlay {
                    if selected {
                        shape.strokeBorder(MoyeotaColor.Primary500, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(PressOverlayStyle(shape: shape))
        .moyeotaShadow(
            elevation: selected ? 0 : 3,
            shape: shape,
            ambientColor: selected ? .clear : CardShadow,
            spotColor: selected ? .clear : CardShadow
        )
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .circular)
                    .fill(selected ? MoyeotaColor.Primary50 : IconBoxIdle)
                icon(selected ? MoyeotaColor.Primary500 : TextSlate)
            }
            .frame(width: 48, height: 48)
            Spacer().frame(width: 16, height: 0)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .moyeotaText(
                        MoyeotaType(fontSize: 17, fontWeight: .bold, lineHeight: .sp(25), letterSpacing: -0.34),
                        color: MoyeotaColor.InkPrimary
                    )
                Spacer().frame(height: 1)
                Text(subtitle)
                    .moyeotaText(
                        MoyeotaType(fontSize: 13, fontWeight: .medium, lineHeight: .sp(19), letterSpacing: -0.26),
                        color: TextSlate
                    )
                Spacer().frame(height: 3)
                Text(caption)
                    .moyeotaText(
                        MoyeotaType(fontSize: 12, fontWeight: .medium, lineHeight: .sp(17), letterSpacing: -0.24),
                        color: TextSoft
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 12, height: 0)
            RadioMark(selected: selected)
        }
    }
}

// 라디오 표시 — 선택: 파란 원 + 흰 체크 / 미선택: 회색 외곽선 원
private struct RadioMark: View {
    let selected: Bool

    var body: some View {
        ZStack {
            if selected {
                Circle().fill(MoyeotaColor.Primary500)
                CheckMarkIcon(iconSize: 12, color: Color.white)
            } else {
                Circle().strokeBorder(RadioIdleBorder, lineWidth: 2)
            }
        }
        .frame(width: 24, height: 24)
    }
}

private func iconLine(_ from: CGPoint, _ to: CGPoint) -> Path {
    var path = Path()
    path.move(to: from)
    path.addLine(to: to)
    return path
}

// 학사모 아이콘 (아이콘 라이브러리 없이 Canvas 로 표현)
private struct GraduationCapIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke = StrokeStyle(lineWidth: 1.8, lineCap: .round)
            // 모자 상판 (마름모)
            var board = Path()
            board.move(to: CGPoint(x: w * 0.5, y: h * 0.14))
            board.addLine(to: CGPoint(x: w * 0.95, y: h * 0.38))
            board.addLine(to: CGPoint(x: w * 0.5, y: h * 0.62))
            board.addLine(to: CGPoint(x: w * 0.05, y: h * 0.38))
            board.closeSubpath()
            context.fill(board, with: .color(color))
            // 모자 몸통
            var body = Path()
            body.move(to: CGPoint(x: w * 0.26, y: h * 0.5))
            body.addLine(to: CGPoint(x: w * 0.26, y: h * 0.74))
            body.addQuadCurve(to: CGPoint(x: w * 0.74, y: h * 0.74), control: CGPoint(x: w * 0.5, y: h * 0.92))
            body.addLine(to: CGPoint(x: w * 0.74, y: h * 0.5))
            context.stroke(body, with: .color(color), style: stroke)
            // 태슬
            context.stroke(
                iconLine(CGPoint(x: w * 0.95, y: h * 0.38), CGPoint(x: w * 0.95, y: h * 0.62)),
                with: .color(color),
                style: stroke
            )
        }
        .frame(width: 24, height: 24)
    }
}

// 서류 가방 아이콘
private struct BriefcaseIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke = StrokeStyle(lineWidth: 1.8, lineCap: .round)
            // 가방 몸통
            context.stroke(
                Path(
                    roundedRect: CGRect(x: w * 0.1, y: h * 0.32, width: w * 0.8, height: h * 0.52),
                    cornerRadius: 3,
                    style: .circular
                ),
                with: .color(color),
                style: stroke
            )
            // 손잡이
            var handle = Path()
            handle.move(to: CGPoint(x: w * 0.36, y: h * 0.32))
            handle.addLine(to: CGPoint(x: w * 0.36, y: h * 0.2))
            handle.addLine(to: CGPoint(x: w * 0.64, y: h * 0.2))
            handle.addLine(to: CGPoint(x: w * 0.64, y: h * 0.32))
            context.stroke(handle, with: .color(color), style: stroke)
            // 가운데 라인
            context.stroke(
                iconLine(CGPoint(x: w * 0.1, y: h * 0.56), CGPoint(x: w * 0.9, y: h * 0.56)),
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.8)
            )
        }
        .frame(width: 24, height: 24)
    }
}

// 신분증 아이콘
private struct IdCardIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke = StrokeStyle(lineWidth: 1.8, lineCap: .round)
            // 카드 외곽
            context.stroke(
                Path(
                    roundedRect: CGRect(x: w * 0.06, y: h * 0.22, width: w * 0.88, height: h * 0.56),
                    cornerRadius: 3,
                    style: .circular
                ),
                with: .color(color),
                style: stroke
            )
            // 얼굴 원
            let radius = w * 0.09
            context.stroke(
                Path(ellipseIn: CGRect(x: w * 0.3 - radius, y: h * 0.48 - radius, width: radius * 2, height: radius * 2)),
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.8)
            )
            // 정보 라인
            context.stroke(
                iconLine(CGPoint(x: w * 0.52, y: h * 0.42), CGPoint(x: w * 0.8, y: h * 0.42)),
                with: .color(color),
                style: stroke
            )
            context.stroke(
                iconLine(CGPoint(x: w * 0.52, y: h * 0.58), CGPoint(x: w * 0.8, y: h * 0.58)),
                with: .color(color),
                style: stroke
            )
        }
        .frame(width: 24, height: 24)
    }
}
