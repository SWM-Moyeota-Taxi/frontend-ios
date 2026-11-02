import SwiftUI
import UIKit

// 시스템 상태바 인셋만큼의 여백.
//
// 앱은 가장자리까지 그려져 콘텐츠가 상태바 아래까지 올라온다(앱 루트가 `.ignoresSafeArea(.container)`).
// 예전에는 와이어프레임에서 따라온 상태바 목업(6:42 + 아이콘)이 44dp 를 차지하며 사실상 이 인셋 역할을
// 겸했는데, 실제 상태바와 이중으로 보여 제거했다. 목업이 있던 자리에 그대로 두어 콘텐츠가
// 상태바에 겹치지 않게 한다 — 배경은 바깥 컨테이너가 칠하므로 상태바 뒤까지 이어진다.
public struct StatusBarSpacer: View {
    private let ignoringPosition: Bool
    private var startsCollapsed = false

    public init() {
        ignoringPosition = false
    }

    /// - Parameter ignoringPosition: 참이면 놓인 위치와 상관없이 상태바 인셋 전체 높이다. 원본 `windowInsetsTopHeight` 는
    ///   위치를 보지 않아, 상태바 아래에 놓인 여백도 인셋만큼 자리를 차지한다(24 채팅방의 로딩·에러 골격). 그 모양을
    ///   그대로 옮겨야 하는 자리에서 쓴다. 기본 동작은 아래 `WindowInsetSpacer` 주석대로 겹침만큼이다.
    public init(ignoringPosition: Bool) {
        self.ignoringPosition = ignoringPosition
    }

    /// - Parameter startsCollapsed: 참이면 첫 프레임 높이가 0 이다. 안전 영역 안에 놓이는 것이 정해진 자리(16 모달)에서 쓴다.
    ///   기본 시작값(창 인셋)이면 첫 레이아웃만 62pt 높게 잡혔다가 잰 뒤에 0 으로 줄어, 그 아래 지도의 크기가 첫 카메라 뒤에 바뀐다.
    ///   SDK 는 크기가 바뀌어도 카메라를 새 콘텐츠 영역 가운데로 다시 맞추지 않아 지도가 늘어난 높이의 절반(31pt)만큼 내려앉는다(실측).
    public init(startsCollapsed: Bool) {
        ignoringPosition = false
        self.startsCollapsed = startsCollapsed
    }

    public var body: some View {
        WindowInsetSpacer(edge: .top, ignoringPosition: ignoringPosition, startsCollapsed: startsCollapsed)
    }
}

// 시스템 내비게이션바(제스처 인디케이터) 인셋만큼의 여백 — StatusBarSpacer 의 하단 짝.
//
// 와이어프레임에서 따라온 홈 인디케이터 목업(135x5dp 검은 바)이 실제 제스처 인디케이터와
// 겹쳐 보여 걷어냈고, 목업이 있던 자리에 그대로 넣어 하단 CTA·탭바가 제스처 영역에
// 닿지 않게 한다. 배경은 바깥 컨테이너가 칠한다 — 배경이 이어져야 하는 자리에서는
// `.background` 로 칠한다(예: `NavigationBarSpacer().background(MoyeotaColor.SurfaceCanvas)`).
public struct NavigationBarSpacer: View {
    public init() {}

    public var body: some View {
        WindowInsetSpacer(edge: .bottom)
    }
}

/// 이 뷰가 실제로 창의 안전 영역 밖과 **겹치는 만큼만** 높이를 갖는 여백.
///
/// 창의 인셋 값을 그대로 쓰면 안전 영역을 지키는 부모(시트·다이얼로그, `ignoresSafeArea` 를 뺀 화면) 안에서
/// 여백이 이중으로 들어간다. 원본의 「`dialog()` 안에서는 인셋이 0」과 같은 결과가 되도록 겹침을 직접 잰다.
private struct WindowInsetSpacer: View {
    let edge: VerticalEdge
    var ignoringPosition = false

    // 가장자리까지 그리는 일반 화면을 기준으로 시작해, 그 경우 첫 프레임부터 맞는 높이로 그린다.
    @State private var height: CGFloat
    // 자리만 옮기는 변화는 UIKit 이 알려 주지 않는다. 높이가 0 인 여백은 크기도 변하지 않아, 중간 레이아웃(안전 영역을 아직 빼기 전,
    // 키보드가 올라와 있던 동안)에 0 으로 접히면 제자리로 돌아와도 다시 재지 않고 접힌 채 남는다. SwiftUI 쪽에서 자리를 받아 다시 재게 한다.
    @State private var position: CGRect = .zero

    init(edge: VerticalEdge, ignoringPosition: Bool = false, startsCollapsed: Bool = false) {
        self.edge = edge
        self.ignoringPosition = ignoringPosition
        _height = State(initialValue: startsCollapsed ? 0 : WindowInsetProbeView.keyWindowInset(edge))
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                WindowInsetProbe(edge: edge, ignoringPosition: ignoringPosition, position: position, height: $height)
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { position = $0 }
            .accessibilityHidden(true)
    }
}

private struct WindowInsetProbe: UIViewRepresentable {
    let edge: VerticalEdge
    let ignoringPosition: Bool
    // 값을 쓰지 않는다. 바뀌면 `updateUIView` 가 불리는 것이 목적이다.
    let position: CGRect
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> WindowInsetProbeView {
        let view = WindowInsetProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: WindowInsetProbeView, context: Context) {
        uiView.edge = edge
        uiView.ignoringPosition = ignoringPosition
        let binding = $height
        uiView.onMeasure = { measured in
            guard abs(binding.wrappedValue - measured) > 0.5 else { return }
            // 레이아웃 도중에 상태를 바꾸지 않도록 다음 차례로 넘긴다.
            Task { @MainActor in binding.wrappedValue = measured }
        }
        uiView.scheduleMeasure()
    }
}

private final class WindowInsetProbeView: UIView {
    var edge: VerticalEdge = .top
    var ignoringPosition = false
    var onMeasure: ((CGFloat) -> Void)?
    private var measureScheduled = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleMeasure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleMeasure()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scheduleMeasure()
    }

    /// 다음 차례에 잰다. SwiftUI 가 자리와 크기를 나눠 적용하는 도중에 재면 「자리는 새 값, 높이는 옛 값」을 읽어 겹침을 0 으로 알리고,
    /// 그 값이 다시 레이아웃을 흔들어 0 과 인셋 사이를 끝없이 오간다.
    func scheduleMeasure() {
        guard !measureScheduled else { return }
        measureScheduled = true
        Task { @MainActor [weak self] in
            self?.measureScheduled = false
            self?.measure()
        }
    }

    private func measure() {
        guard let window else { return }
        let frame = convert(bounds, to: window)
        let overlap: CGFloat = switch edge {
        case .top:
            window.safeAreaInsets.top - frame.minY
        case .bottom:
            frame.maxY - (window.bounds.height - window.safeAreaInsets.bottom)
        }
        let inset = edge == .top ? window.safeAreaInsets.top : window.safeAreaInsets.bottom
        onMeasure?(ignoringPosition ? inset : min(max(overlap, 0), inset))
    }

    static func keyWindowInset(_ edge: VerticalEdge) -> CGFloat {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return 0 }
        return edge == .top ? window.safeAreaInsets.top : window.safeAreaInsets.bottom
    }
}

/// 머티리얼 `HorizontalDivider` 자리.
public struct HorizontalDivider: View {
    private let color: Color
    private let thickness: CGFloat

    public init(color: Color, thickness: CGFloat = 1) {
        self.color = color
        self.thickness = thickness
    }

    public var body: some View {
        Rectangle()
            .fill(color)
            .frame(maxWidth: .infinity)
            .frame(height: thickness)
    }
}

// 상단 앱바: 뒤로가기 + 타이틀 (+우측 액션)
public struct MoyeotaTopBar<Actions: View>: View {
    private let title: String
    private let onBack: (() -> Void)?
    private let actions: Actions

    public init(
        title: String,
        onBack: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.onBack = onBack
        self.actions = actions()
    }

    public var body: some View {
        ZStack {
            if let onBack {
                // 머티리얼 `IconButton` 의 레이아웃 크기는 최소 터치 영역인 48dp 다.
                Button(action: onBack) {
                    BackArrowIcon()
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(PressFeedbackStyle())
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(title)
                .moyeotaText(.HeadingMd, color: LocalContentColorDefault)
            HStack(spacing: 0) {
                actions
            }
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }
}

public extension MoyeotaTopBar where Actions == EmptyView {
    init(title: String, onBack: (() -> Void)? = nil) {
        self.init(title: title, onBack: onBack) { EmptyView() }
    }
}

// 아이콘 라이브러리 없이 그리는 뒤로가기 화살표
public struct BackArrowIcon: View {
    private let size: CGFloat

    /// - Parameter size: 원본 `BackArrowIcon(Modifier.size(22.dp))` 처럼 크기를 키우는 자리. 선 굵기는 그대로다.
    public init(size: CGFloat = 20) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, size in
            let cx = size.width
            let cy = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: cx * 0.15, y: cy))
            path.addLine(to: CGPoint(x: cx * 0.9, y: cy))
            path.move(to: CGPoint(x: cx * 0.15, y: cy))
            path.addLine(to: CGPoint(x: cx * 0.5, y: cy * 0.35))
            path.move(to: CGPoint(x: cx * 0.15, y: cy))
            path.addLine(to: CGPoint(x: cx * 0.5, y: cy * 1.65))
            context.stroke(
                path,
                with: .color(MoyeotaColor.InkPrimary),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

public enum MoyeotaTab: CaseIterable, Sendable {
    case home, explore, chat, mypage

    public var label: String {
        switch self {
        case .home: "홈"
        case .explore: "동승"
        case .chat: "채팅"
        case .mypage: "마이페이지"
        }
    }
}

// 하단탭 — 공통 규칙: 14(홈) · 17(합승) · 24(채팅) · 35(마이) 네 화면에서만 노출
//
// 배경(SurfaceCanvas)은 Column 전체에 칠해 내비게이션바 인셋 영역까지 이어지고,
// 아이콘·라벨은 인셋 위로만 올라온다 — 제스처 인디케이터와 겹치지 않게 하기 위함.
// (상단 StatusBarSpacer 와 같은 방식: 패딩 대신 같은 자리의 인셋 Spacer)
public struct MoyeotaBottomBar: View {
    private let selected: MoyeotaTab
    private let onSelect: (MoyeotaTab) -> Void

    public init(selected: MoyeotaTab, onSelect: @escaping (MoyeotaTab) -> Void) {
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(spacing: 0) {
            HorizontalDivider(color: MoyeotaColor.Hairline)
            // Arrangement.SpaceEvenly: 양끝과 항목 사이의 빈칸이 모두 같다.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(MoyeotaTab.allCases, id: \.self) { tab in
                    let color = tab == selected ? MoyeotaColor.Primary500 : MoyeotaColor.TextMute
                    Button {
                        onSelect(tab)
                    } label: {
                        VStack(spacing: 2) {
                            TabIcon(tab: tab, tint: color)
                            Text(tab.label)
                                .moyeotaText(.CaptionSm, color: color)
                                .fixedSize()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFeedbackStyle())
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity)
        .background(MoyeotaColor.SurfaceCanvas)
    }
}

// ─── 하단탭 아이콘 ──────────────────────────────────────────────────────────
// 아이콘 의존성 없이 24dp 그리드 위에 직접 그린 스트로크 아이콘.
// (같은 파일의 BackArrowIcon 과 동일한 Canvas 방식 — 선택/비선택은 tint 로만 구분)

private let TabIconSize: CGFloat = 24

private struct TabIcon: View {
    let tab: MoyeotaTab
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            switch tab {
            case .home: drawHomeIcon(context, size, tint, stroke)
            case .explore: drawTaxiIcon(context, size, tint, stroke)
            case .chat: drawChatIcon(context, size, tint, stroke)
            case .mypage: drawPersonIcon(context, size, tint, stroke)
            }
        }
        .frame(width: TabIconSize, height: TabIconSize)
    }
}

private func polyline(_ points: [(CGFloat, CGFloat)]) -> Path {
    var path = Path()
    for (index, point) in points.enumerated() {
        let cgPoint = CGPoint(x: point.0, y: point.1)
        if index == 0 {
            path.move(to: cgPoint)
        } else {
            path.addLine(to: cgPoint)
        }
    }
    return path
}

private func circlePath(radius: CGFloat, center: CGPoint) -> Path {
    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

// 홈 — 집
private func drawHomeIcon(_ context: GraphicsContext, _ size: CGSize, _ tint: Color, _ stroke: StrokeStyle) {
    let w = size.width
    let h = size.height
    let roof = polyline([(w * 0.08, h * 0.47), (w * 0.50, h * 0.12), (w * 0.92, h * 0.47)])
    context.stroke(roof, with: .color(tint), style: stroke)
    let body = polyline([(w * 0.20, h * 0.38), (w * 0.20, h * 0.88), (w * 0.80, h * 0.88), (w * 0.80, h * 0.38)])
    context.stroke(body, with: .color(tint), style: stroke)
    let door = polyline([(w * 0.41, h * 0.88), (w * 0.41, h * 0.62), (w * 0.59, h * 0.62), (w * 0.59, h * 0.88)])
    context.stroke(door, with: .color(tint), style: stroke)
}

// 합승 — 택시(지붕 표시등 있는 자동차)
private func drawTaxiIcon(_ context: GraphicsContext, _ size: CGSize, _ tint: Color, _ stroke: StrokeStyle) {
    let w = size.width
    let h = size.height
    // 지붕 표시등 (작아서 스트로크 대신 채움)
    context.fill(
        Path(
            roundedRect: CGRect(x: w * 0.40, y: h * 0.14, width: w * 0.20, height: h * 0.12),
            cornerRadius: w * 0.03,
            style: .circular
        ),
        with: .color(tint)
    )
    // 캐빈
    let cabin = polyline([(w * 0.24, h * 0.48), (w * 0.33, h * 0.26), (w * 0.67, h * 0.26), (w * 0.76, h * 0.48)])
    context.stroke(cabin, with: .color(tint), style: stroke)
    // 차체
    context.stroke(
        Path(
            roundedRect: CGRect(x: w * 0.08, y: h * 0.46, width: w * 0.84, height: h * 0.28),
            cornerRadius: w * 0.08,
            style: .circular
        ),
        with: .color(tint),
        style: stroke
    )
    // 바퀴
    context.stroke(circlePath(radius: w * 0.075, center: CGPoint(x: w * 0.29, y: h * 0.80)), with: .color(tint), style: stroke)
    context.stroke(circlePath(radius: w * 0.075, center: CGPoint(x: w * 0.71, y: h * 0.80)), with: .color(tint), style: stroke)
}

// 채팅 — 꼬리 달린 말풍선 (모서리 라운드까지 한 붓으로)
private func drawChatIcon(_ context: GraphicsContext, _ size: CGSize, _ tint: Color, _ stroke: StrokeStyle) {
    let w = size.width
    let h = size.height
    let l = w * 0.10
    let t = h * 0.16
    let r = w * 0.90
    let b = h * 0.68
    let rx = w * 0.16
    let ry = h * 0.16
    // 그리드가 정사각형이라 rx == ry 다. 각도는 y 가 아래로 커지는 좌표계라 양수가 시계 방향이다(Compose arcTo 와 같다).
    var bubble = Path()
    bubble.move(to: CGPoint(x: l + rx, y: t))
    bubble.addLine(to: CGPoint(x: r - rx, y: t))
    bubble.addRelativeArc(center: CGPoint(x: r - rx, y: t + ry), radius: rx, startAngle: .degrees(-90), delta: .degrees(90))
    bubble.addLine(to: CGPoint(x: r, y: b - ry))
    bubble.addRelativeArc(center: CGPoint(x: r - rx, y: b - ry), radius: rx, startAngle: .degrees(0), delta: .degrees(90))
    bubble.addLine(to: CGPoint(x: w * 0.46, y: b))
    bubble.addLine(to: CGPoint(x: w * 0.24, y: h * 0.92))   // 꼬리 끝
    bubble.addLine(to: CGPoint(x: w * 0.34, y: b))
    bubble.addLine(to: CGPoint(x: l + rx, y: b))
    bubble.addRelativeArc(center: CGPoint(x: l + rx, y: b - ry), radius: rx, startAngle: .degrees(90), delta: .degrees(90))
    bubble.addLine(to: CGPoint(x: l, y: t + ry))
    bubble.addRelativeArc(center: CGPoint(x: l + rx, y: t + ry), radius: rx, startAngle: .degrees(180), delta: .degrees(90))
    bubble.closeSubpath()
    context.stroke(bubble, with: .color(tint), style: stroke)
}

// 마이 — 사람
private func drawPersonIcon(_ context: GraphicsContext, _ size: CGSize, _ tint: Color, _ stroke: StrokeStyle) {
    let w = size.width
    let h = size.height
    context.stroke(circlePath(radius: w * 0.17, center: CGPoint(x: w * 0.5, y: h * 0.32)), with: .color(tint), style: stroke)
    var shoulders = Path()
    shoulders.move(to: CGPoint(x: w * 0.17, y: h * 0.86))
    shoulders.addCurve(
        to: CGPoint(x: w * 0.83, y: h * 0.86),
        control1: CGPoint(x: w * 0.17, y: h * 0.50),
        control2: CGPoint(x: w * 0.83, y: h * 0.50)
    )
    context.stroke(shoulders, with: .color(tint), style: stroke)
}
