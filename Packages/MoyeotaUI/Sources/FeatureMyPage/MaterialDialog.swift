import MoyeotaDesignSystem
import PresentationCore
import SwiftUI

// 원본 머티리얼 부품이 글자에 몰래 입히던 값과 `AlertDialog` 의 자리. 원본 파일에는 없는 파일이다
// — `MyPageScreen` 과 `AccountDeleteScreen` 이 함께 쓴다.

/// Compose `Text` 가 `style` 을 받지 않았을 때 물려받는 머티리얼 3 글자 스타일.
///
/// `Text(fontSize = 12.sp)` 는 크기만 바꾸고 **줄 높이와 자간은 `LocalTextStyle` 값이 남는다.**
/// 앱 전체가 `MoyeotaTheme`(= `MaterialTheme`) 안이라 본문에서는 `bodyLarge` 가, `AlertDialog` 의
/// 제목·내용·버튼에서는 각각 `headlineSmall`·`bodyMedium`·`labelLarge` 가 깔린다.
/// 이 값을 빼면 12sp 머리말의 줄 상자가 24pt 가 아니라 15pt 가 되어 카드 사이 여백이 전부 줄어든다.
enum MaterialTextStyle {
    /// `typography.bodyLarge` — 줄 높이 24, 자간 0.5.
    ///
    /// 33 제목·35 제목 아래가 모두 이 값으로 내려간다.
    static func bodyLarge(fontSize: CGFloat, fontWeight: Font.Weight = .regular) -> MoyeotaType {
        MoyeotaType.inheritedBodyLarge(fontSize: fontSize, fontWeight: fontWeight)
    }

    /// `typography.headlineSmall` — 줄 높이 32, 자간 0. `AlertDialog` 제목.
    static func headlineSmall(fontSize: CGFloat, fontWeight: Font.Weight = .regular) -> MoyeotaType {
        MoyeotaType(fontSize: fontSize, fontWeight: fontWeight, lineHeight: .sp(32), letterSpacing: 0)
    }

    /// `typography.bodyMedium` — 줄 높이 20, 자간 0.25. `AlertDialog` 내용.
    static func bodyMedium(fontSize: CGFloat = 14, fontWeight: Font.Weight = .regular) -> MoyeotaType {
        MoyeotaType(fontSize: fontSize, fontWeight: fontWeight, lineHeight: .sp(20), letterSpacing: 0.25)
    }

    /// `typography.labelLarge` — 14sp Medium, 줄 높이 20, 자간 0.1. `TextButton` 글자.
    static func labelLarge(fontWeight: Font.Weight = .medium) -> MoyeotaType {
        MoyeotaType(fontSize: 14, fontWeight: fontWeight, lineHeight: .sp(20), letterSpacing: 0.1)
    }
}

/// 머티리얼 `AlertDialog` 자리. 화면 전체를 덮는 오버레이로 그린다.
///
/// 치수는 머티리얼 3 값이다: 모서리 28, 안쪽 여백 24, 제목 아래 16, 내용 아래 24, 버튼 사이 8, 폭 최소 280.
/// 폭 상한 320 과 자리(시스템 바를 뺀 영역의 가운데)는 원본 렌더에서 쟀다(37 에서 320dp, 화면 가운데보다 12dp 아래).
/// 21·27 확인창과 같은 값이다. 버튼은 원본처럼 **취소 → 확인** 순서로 오른쪽에 붙는다.
///
/// 바깥을 누르거나 뒤로가기를 하면 `onDismissRequest` 다.
struct MaterialAlertDialog<Title: View, Message: View, Confirm: View, Dismiss: View>: View {
    private let onDismissRequest: () -> Void
    private let title: Title
    private let text: Message
    private let confirmButton: Confirm
    private let dismissButton: Dismiss

    init(
        onDismissRequest: @escaping () -> Void,
        @ViewBuilder title: () -> Title,
        @ViewBuilder text: () -> Message,
        @ViewBuilder confirmButton: () -> Confirm,
        @ViewBuilder dismissButton: () -> Dismiss
    ) {
        self.onDismissRequest = onDismissRequest
        self.title = title()
        self.text = text()
        self.confirmButton = confirmButton()
        self.dismissButton = dismissButton()
    }

    var body: some View {
        ZStack {
            // 안드로이드 대화상자 창의 기본 어둡기(0.6)다. 앱의 `Scrim` 토큰(40%)은 시트용이라 쓰지 않는다.
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismissRequest)
                .accessibilityHidden(true)

            // 원본 대화상자 창은 시스템 바를 뺀 영역의 가운데에 놓인다. 이 오버레이는 화면 전체라 두 바의 높이를 직접 뺀다.
            VStack(spacing: 0) {
                StatusBarSpacer()
                card.frame(maxHeight: .infinity)
                NavigationBarSpacer()
            }
        }
        .moyeotaBackHandler(action: onDismissRequest)
    }

    private var card: some View {
        AlertDialogContentLayout(minWidth: 280 - 48, maxWidth: AlertDialogContentMaxWidth) {
            title.padding(.bottom, 16)
            text.padding(.bottom, 24)
            HStack(spacing: 8) {
                dismissButton
                confirmButton
            }
        }
        .padding(24)
        .background(MoyeotaColor.SurfaceCanvas, in: RoundedRectangle(cornerRadius: 28, style: .circular))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismissRequest)
    }
}

/// 대화상자 내용의 최대 폭(320 − 좌우 여백 24 둘).
private let AlertDialogContentMaxWidth: CGFloat = 320 - 48

/// 접힐 수 있는 대화상자 본문. 원본처럼 줄 끝까지 채우고(`softWrappedLines`), 접히면 폭 상한을 다 쓴다.
/// 그냥 `Text` 면 마지막 줄이 짧아지지 않게 앞 줄의 어절을 밀어 내려 37 이 「…되돌릴 / 수 없어요」로 꺾인다.
struct MaterialDialogBodyText: View {
    let text: String
    let style: MoyeotaType
    let color: Color

    var body: some View {
        let lines = style.softWrappedLines(text, width: AlertDialogContentMaxWidth)
        Text(lines.text)
            .moyeotaText(style, color: color)
            .frame(width: lines.wrapped ? AlertDialogContentMaxWidth : nil, alignment: .leading)
            .accessibilityLabel(text)
    }
}

/// 제목·내용은 왼쪽, 마지막(버튼 줄)은 오른쪽에 붙인다.
///
/// 폭이 **가장 넓은 내용**으로 정해지는 것이 원본과 같은 점이다 — `frame(maxWidth: .infinity)` 로 오른쪽에
/// 붙이면 대화상자가 화면 폭까지 늘어난다.
///
/// 폭은 줄바꿈 전 너비로 정한다. 본문이 접히면 원본 `Text` 는 상한까지 채우지만 SwiftUI `Text` 는 가장 긴 줄로 줄어들어,
/// 접힌 뒤의 너비로 정하면 문구마다 대화상자 폭이 달라진다.
private struct AlertDialogContentLayout: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = childProposal(proposal)
        let widest = subviews.map { $0.sizeThatFits(ProposedViewSize(width: nil, height: nil)).width }.max() ?? 0
        let width = min(max(widest, minWidth), limit.width ?? maxWidth)
        let children = ProposedViewSize(width: width, height: nil)
        return CGSize(
            width: width,
            height: subviews.map { $0.sizeThatFits(children).height }.reduce(0, +)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let limit = childProposal(ProposedViewSize(width: bounds.width, height: nil))
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(limit)
            let isLast = index == subviews.count - 1
            let x = isLast ? bounds.maxX - size.width : bounds.minX
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: limit)
            y += size.height
        }
    }

    private func childProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: nil)
    }
}

/// 머티리얼 `TextButton` 자리 — 글자 좌우 12·위아래 8, 최소 58×40, 터치 영역 높이 48.
struct MaterialTextButton: View {
    private let text: String
    private let style: MoyeotaType
    private let color: Color
    private let onClick: () -> Void

    init(
        text: String,
        style: MoyeotaType = MaterialTextStyle.labelLarge(),
        color: Color,
        onClick: @escaping () -> Void
    ) {
        self.text = text
        self.style = style
        self.color = color
        self.onClick = onClick
    }

    var body: some View {
        Button(action: onClick) {
            Text(text)
                .moyeotaText(style, color: color)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 58, minHeight: 40)
        }
        .buttonStyle(MaterialTextButtonStyle())
    }
}

private struct MaterialTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    Capsule(style: .circular).fill(Color.black.opacity(0.1))
                }
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
    }
}
