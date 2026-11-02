import QuartzCore
import SwiftUI

/// `MapSheetScaffold` 가 슬롯에 넘겨 주는 값. 배경(지도)이 카메라를 맞추고 플로팅 UI 를
/// 시트 위에 띄우는 데 필요한 치수만 담는다.
public struct MapSheetState: Equatable, Sendable {
    /// 시트가 펼쳐져 있는가. 드래그 중에도 **정착 목표** 기준이라 값이 흔들리지 않는다
    public let expanded: Bool
    public let containerWidth: CGFloat
    public let containerHeight: CGFloat
    /// 앵커 기준 시트 높이. 드래그·정착 애니메이션 중에도 **목표값**이라 프레임마다 변하지 않는다.
    /// 카메라 fit·contentPadding 은 반드시 이 값을 써야 한다 — 실측값(`sheetHeight`)을 쓰면
    /// 애니메이션 매 프레임 카메라가 다시 잡혀 사용자의 팬·줌과 싸운다.
    public let settledSheetHeight: CGFloat
    /// 실측 시트 높이. 콘텐츠가 정하므로 `settledSheetHeight` 와 몇 dp 다를 수 있다.
    /// 지도 위 플로팅 버튼을 시트 **바로 위**에 붙일 때만 쓴다.
    public let sheetHeight: CGFloat

    public init(
        expanded: Bool,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        settledSheetHeight: CGFloat,
        sheetHeight: CGFloat
    ) {
        self.expanded = expanded
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
        self.settledSheetHeight = settledSheetHeight
        self.sheetHeight = sheetHeight
    }

    /// 시트에 가리지 않고 실제로 보이는 지도 높이(앵커 기준). `fitMapCamera` 의 heightDp 다.
    public var visibleMapHeight: CGFloat {
        max(containerHeight - settledSheetHeight, 1)
    }
}

public enum MapSheetDefaults {
    /// 펼친 시트 위로 남겨두는 지도 높이
    public static let MapRevealHeight: CGFloat = 160

    /// 접은 시트의 대략적인 높이. **추정치**다 — 실제 높이는 콘텐츠가 정한다(에러 배너가 뜨면 커진다).
    /// 드래그 앵커와 카메라 계산에만 쓰이므로 몇 dp 어긋나도 펼침 상태에서 남는 지도 높이가
    /// 그만큼 달라질 뿐 동작에는 영향이 없다. 화면마다 접힘 콘텐츠가 다르니 각자 넘긴다.
    public static let CollapsedSheetHeight: CGFloat = 176
}

/// 이 속도(px/s) 이상으로 던지면 위치와 무관하게 그 방향의 앵커로 붙는다.
/// 단위가 px 라 제스처 속도(pt/s)에 화면 배율을 곱해 비교한다.
let SheetFlingVelocity: CGFloat = 400

/// 접고 편 상세 영역의 최대 높이. 앵커는 0 ↔ 이 값이다.
func mapSheetDetailMax(containerHeight: CGFloat, mapRevealHeight: CGFloat, collapsedSheetHeight: CGFloat) -> CGFloat {
    max(containerHeight - mapRevealHeight - collapsedSheetHeight, 0)
}

/// 앵커 기준 시트 높이(`MapSheetState.settledSheetHeight`).
func mapSheetSettledHeight(
    expanded: Bool,
    containerHeight: CGFloat,
    mapRevealHeight: CGFloat,
    collapsedSheetHeight: CGFloat
) -> CGFloat {
    expanded ? max(containerHeight - mapRevealHeight, collapsedSheetHeight) : collapsedSheetHeight
}

/// 손을 뗀 뒤 어느 앵커로 갈지. `velocity` 는 아래로 양수(px/s), `from`·`detailMax` 는 같은 단위의 높이다.
func mapSheetSettlesExpanded(velocity: CGFloat, from: CGFloat, detailMax: CGFloat) -> Bool {
    if velocity > SheetFlingVelocity { return false } // 아래로 던짐 → 접기
    if velocity < -SheetFlingVelocity { return true }
    return from > detailMax / 2 // 가까운 앵커로
}

/// Compose 기본 스프링(`spring()`: 감쇠비 1, 강성 1500)의 위치. 초기 속도는 0 이다.
/// 임계 감쇠의 해석해: x(t) = T + (x₀−T)(1 + ωt)e^(−ωt), ω = √강성.
func criticallyDampedSpring(from: CGFloat, target: CGFloat, elapsed: TimeInterval) -> CGFloat {
    let omega = sqrt(1500.0)
    let t = max(elapsed, 0)
    return target + (from - target) * CGFloat((1 + omega * t) * exp(-omega * t))
}

/// Compose `Animatable` 자리. SwiftUI 애니메이션은 진행 중인 값을 읽을 수 없는데, 정착 중에 시트를 다시 잡으면
/// 그 순간의 높이에서 이어 가야 하므로(원본 `dragDetailPx ?: detail.value`) 값을 프레임마다 직접 계산한다.
@MainActor
@Observable
private final class SheetDetailAnimatable {
    /// nil 이면 앵커에 앉아 있다. 첫 프레임부터 목표 상태로 그리기 위한 값이다(깜빡임 없음).
    private(set) var value: CGFloat?

    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var from: CGFloat = 0
    @ObservationIgnored private var target: CGFloat = 0
    @ObservationIgnored private var startTime: CFTimeInterval = 0

    func snapTo(_ newValue: CGFloat?) {
        stop()
        value = newValue
    }

    func animateTo(_ newTarget: CGFloat) {
        stop()
        from = value ?? newTarget
        target = newTarget
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(
            target: DisplayLinkProxy { [weak self] in
                self?.tick()
                return self != nil
            },
            selector: #selector(DisplayLinkProxy.fire(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        let next = criticallyDampedSpring(from: from, target: target, elapsed: CACurrentMediaTime() - startTime)
        if abs(next - target) < 0.01 {
            value = target
            stop()
        } else {
            value = next
        }
    }
}

@MainActor
private final class DisplayLinkProxy: NSObject {
    // false 를 돌려주면 주인이 사라진 것이다. 런루프가 링크를 잡고 있어 직접 끊어야 한다.
    private let action: @MainActor () -> Bool

    init(action: @escaping @MainActor () -> Bool) {
        self.action = action
    }

    @objc func fire(_ link: CADisplayLink) {
        if !action() {
            link.invalidate()
        }
    }
}

/// 지도(또는 임의의 배경) 위에 **드래그로 접었다 펴는 시트**를 얹는 공용 레이아웃.
///
/// 앵커는 시트 전체의 오프셋이 아니라 **가운데 `sheetDetail` 영역의 높이**(0 ↔ detailMax)다.
/// 시트를 통째로 밀어 내리면 보이는 건 콘텐츠의 *윗부분*이라 하단에 고정된 CTA 가 화면 밖으로 나간다 —
/// 이 앱의 두 화면(16 도착지 확인, 21 매칭 대기) 모두 「같이 탈 사람 찾기」·「그만 찾기」가 접힘에서도
/// 보여야 해서 그 구조를 쓸 수 없다.
///
/// 시트 높이는 콘텐츠가 정한다. 에러 배너가 떠서 푸터가 커지면 시트가 그만큼 높아지고, 컨테이너보다 커지면
/// 원본 `Column` 처럼 컨테이너 높이에서 멈춰 위에서부터 쌓인 내용의 **아래쪽 푸터만** 잘린다(글자는 줄이지 않는다).
///
/// - Parameters:
///   - mapRevealHeight: 펼침 상태에서 시트 위로 남겨 둘 배경 높이
///   - collapsedSheetHeight: 접힘 높이 추정치 (`MapSheetDefaults.CollapsedSheetHeight` 설명 참고)
///   - background: 시트 뒤를 가득 채우는 내용(지도). 칩·버튼은 이 안에서 `frame(alignment:)` 로 얹는다
///   - sheetTop: 핸들 아래에 붙는 **항상 보이는** 내용. 핸들과 함께 실제 드래그 타깃이 된다
///   - sheetDetail: 접히면 높이가 0 이 되는 상세 영역. 내부는 세로 스크롤된다
///   - sheetFooter: 시트 하단에 **항상 보이는** 내용(CTA·요금 문구 등)
public struct MapSheetScaffold<Background: View, SheetTop: View, SheetDetail: View, SheetFooter: View>: View {
    private let mapRevealHeight: CGFloat
    private let collapsedSheetHeight: CGFloat
    private let background: (MapSheetState) -> Background
    private let sheetTop: SheetTop
    private let sheetDetail: SheetDetail
    private let sheetFooter: SheetFooter

    @State private var expanded: Bool
    @State private var detail = SheetDetailAnimatable()
    // 드래그 중에는 애니메이션을 건드리지 않고 이 값만 따라간다 — 손가락이 움직일 때마다 정착 값을 건드리면
    // 놓아준 뒤의 정착 애니메이션과 섞여 시트가 어중간한 높이에 멈춘다.
    @State private var drag = SheetDragTracker()
    // 시스템이 제스처를 취소하면(전화 수신·제어 센터·앱 전환) `onEnded` 가 불리지 않는다.
    // 끝났다는 신호를 받는 길은 이 값이 저절로 되돌아오는 것뿐이다.
    @GestureState private var dragging = false
    @State private var sheetHeight: CGFloat = 0

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    // 14 홈이 탭이라 원본 `rememberSaveable` 의 `expanded`·상세 스크롤이 탭을 다녀와도 남아야 한다. 탭이 아닌 화면에서는 nil 이다.
    @Environment(\.tabSavedState) private var tabSavedState

    public init(
        mapRevealHeight: CGFloat = MapSheetDefaults.MapRevealHeight,
        collapsedSheetHeight: CGFloat = MapSheetDefaults.CollapsedSheetHeight,
        initiallyExpanded: Bool = true,
        @ViewBuilder background: @escaping (MapSheetState) -> Background,
        @ViewBuilder sheetTop: () -> SheetTop,
        @ViewBuilder sheetDetail: () -> SheetDetail,
        @ViewBuilder sheetFooter: () -> SheetFooter
    ) {
        self.mapRevealHeight = mapRevealHeight
        self.collapsedSheetHeight = collapsedSheetHeight
        self.background = background
        self.sheetTop = sheetTop()
        self.sheetDetail = sheetDetail()
        self.sheetFooter = sheetFooter()
        _expanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        GeometryReader { geometry in
            content(containerSize: geometry.size)
        }
    }

    private func content(containerSize: CGSize) -> some View {
        let detailMax = mapSheetDetailMax(
            containerHeight: containerSize.height,
            mapRevealHeight: mapRevealHeight,
            collapsedSheetHeight: collapsedSheetHeight
        )
        let anchor = expanded ? detailMax : 0
        let detailHeight = drag.height ?? detail.value ?? anchor
        let state = MapSheetState(
            expanded: expanded,
            containerWidth: containerSize.width,
            containerHeight: containerSize.height,
            settledSheetHeight: mapSheetSettledHeight(
                expanded: expanded,
                containerHeight: containerSize.height,
                mapRevealHeight: mapRevealHeight,
                collapsedSheetHeight: collapsedSheetHeight
            ),
            sheetHeight: sheetHeight
        )
        let sheetShape = UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .circular)

        return ZStack(alignment: .bottom) {
            background(state)
                .frame(width: containerSize.width, height: containerSize.height)

            VStack(alignment: .leading, spacing: 0) {
                // 드래그 손잡이 — 핸들과 그 아래 항상 보이는 줄 전체가 실제 드래그 타깃이다
                VStack(alignment: .leading, spacing: 0) {
                    SheetHandle()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    sheetTop
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(dragGesture(detailMax: detailMax))

                // 접히면 높이가 0 이 되는 상세 영역
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        sheetDetail
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .savedScrollOffset("mapSheet.detail")
                }
                .scrollBounceBehavior(.basedOnSize)
                // 원본 `verticalScroll` 은 스크롤 막대를 그리지 않는다.
                .scrollIndicators(.hidden)
                .frame(height: detailHeight)

                sheetFooter
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SheetColumnHeight())
            .background(MoyeotaColor.SurfaceCanvas)
            .clipShape(sheetShape)
            // 잘려 나간 푸터 아래쪽이 시트 밖의 터치를 가로채지 않게 한다(`clipShape` 는 터치를 자르지 않는다).
            .contentShape(sheetShape)
            .moyeotaShadow(elevation: 14, shape: sheetShape, spotColor: SheetShadow)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .onAppear {
            if let saved: Bool = tabSavedState?.value("mapSheet.expanded") { expanded = saved }
        }
        .onChange(of: expanded) { _, value in tabSavedState?.set("mapSheet.expanded", value) }
        // 회전 등으로 앵커가 바뀌면 현재 상태의 앵커로 다시 앉힌다
        .onChange(of: detailMax) { _, _ in detail.snapTo(nil) }
        // 떠나면 정착을 끝낸 것으로 친다. 돌아왔을 때 어중간한 높이에 머물지 않게 앵커로 앉힌다.
        .onDisappear {
            detail.snapTo(nil)
            drag.clear()
        }
        // 원본 `draggable` 의 `onDragStopped` 는 포인터 입력이 취소돼도 불린다. 같은 결과가 되게 여기서 정착시킨다.
        // 정상 종료에서는 `onEnded` 와 이 신호의 순서에 기대지 않는다 — 어느 순서로 불려도 같은 앵커에 닿는다.
        .onChange(of: dragging) { _, active in
            if !active { settleInterruptedDrag(detailMax: detailMax) }
        }
        // 앱이 전면에서 내려가면 드래그는 이어질 수 없다. `@GestureState` 가 되돌아오는 길과 겹쳐도 한 번만 정착한다.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { settleInterruptedDrag(detailMax: detailMax) }
        }
    }

    private func dragGesture(detailMax: CGFloat) -> some Gesture {
        // 시트가 드래그를 따라 움직이므로 지역 좌표로 재면 값이 되먹임된다. 전역 좌표로 잰다.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                // 아래로 끌면 상세 영역이 줄어 시트가 낮아진다
                drag.track(
                    y: value.location.y,
                    resting: detail.value ?? (expanded ? detailMax : 0),
                    range: 0...detailMax
                )
            }
            .onEnded { value in
                settleDrag(velocity: value.velocity.height, detailMax: detailMax)
            }
    }

    /// 취소된 드래그를 정착시킨다. 던진 속도를 알 수 없으니 가까운 앵커로 간다(원본도 취소 때 속도 0 이다).
    /// 이미 끝난 드래그면 아무것도 하지 않는다.
    private func settleInterruptedDrag(detailMax: CGFloat) {
        if drag.height != nil { settleDrag(velocity: 0, detailMax: detailMax) }
    }

    /// - Parameter velocity: 드래그 속도(pt/s)
    private func settleDrag(velocity: CGFloat, detailMax: CGFloat) {
        let from = drag.finish(resting: detail.value ?? (expanded ? detailMax : 0))
        let toExpanded = mapSheetSettlesExpanded(
            velocity: velocity * displayScale,
            from: from * displayScale,
            detailMax: detailMax * displayScale
        )
        expanded = toExpanded
        // 놓은 지점에서 이어서 정착시킨다(값을 먼저 옮기고 드래그 값을 비운다)
        detail.snapTo(from)
        detail.animateTo(toExpanded ? detailMax : 0)
    }
}

/// 원본 시트 `Column` 의 높이 규칙. 콘텐츠를 본래 높이로 재고(글자를 줄이지 않는다) **위에서부터** 놓되, 자기 크기는 부모
/// 높이를 넘지 않는다. 넘친 만큼은 아래쪽으로 나가 시트의 `clipShape` 에 잘린다.
///
/// `ZStack` 에 그대로 두면 큰 자식이 컨테이너 가운데에 놓여 넘친 만큼이 위아래로 나뉘고 VStack 은 글자를 줄이며,
/// `.frame(maxHeight:)` 는 제안 높이까지 늘어나 짧은 시트까지 컨테이너 높이가 된다.
private struct SheetColumnHeight: ViewModifier {
    func body(content: Content) -> some View {
        SheetColumnLayout { content }
    }
}

private struct SheetColumnLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(
            width: proposal.width ?? natural.width,
            height: min(natural.height, proposal.height ?? natural.height)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

/// 드래그 중인 시트 높이와 직전 손가락 위치.
///
/// 드래그가 어떻게 끝나든(`onEnded`·시스템 취소) `finish` 나 `clear` 로 **둘을 함께** 비워야 한다. 높이가 남으면
/// 시트가 어중간한 자리에 멈춰 단계를 바꿔도 움직이지 않고, 위치가 남으면 다음 드래그의 첫 값이 튄다.
public struct SheetDragTracker: Equatable {
    public private(set) var height: CGFloat?
    private var lastY: CGFloat?

    public init() {}

    /// - Parameters:
    ///   - y: 손가락의 전역 y
    ///   - resting: 드래그가 없을 때의 시트 높이. 첫 값이 여기서 시작한다
    ///   - range: 높이 범위(접힘 앵커…펼침 앵커)
    public mutating func track(y: CGFloat, resting: CGFloat, range: ClosedRange<CGFloat>) {
        // 터치 슬롭을 넘긴 첫 값은 이동으로 치지 않는다(시트가 튀지 않게).
        let delta = lastY.map { y - $0 } ?? 0
        lastY = y
        height = min(max((height ?? resting) - delta, range.lowerBound), range.upperBound)
    }

    /// 드래그를 끝내고 정착을 시작할 높이를 돌려준다.
    public mutating func finish(resting: CGFloat) -> CGFloat {
        defer { clear() }
        return height ?? resting
    }

    public mutating func clear() {
        height = nil
        lastY = nil
    }
}

public extension MapSheetScaffold where SheetTop == EmptyView, SheetDetail == EmptyView, SheetFooter == EmptyView {
    init(
        mapRevealHeight: CGFloat = MapSheetDefaults.MapRevealHeight,
        collapsedSheetHeight: CGFloat = MapSheetDefaults.CollapsedSheetHeight,
        initiallyExpanded: Bool = true,
        @ViewBuilder background: @escaping (MapSheetState) -> Background
    ) {
        self.init(
            mapRevealHeight: mapRevealHeight,
            collapsedSheetHeight: collapsedSheetHeight,
            initiallyExpanded: initiallyExpanded,
            background: background,
            sheetTop: { EmptyView() },
            sheetDetail: { EmptyView() },
            sheetFooter: { EmptyView() }
        )
    }
}

public extension MapSheetScaffold where SheetTop == EmptyView {
    init(
        mapRevealHeight: CGFloat = MapSheetDefaults.MapRevealHeight,
        collapsedSheetHeight: CGFloat = MapSheetDefaults.CollapsedSheetHeight,
        initiallyExpanded: Bool = true,
        @ViewBuilder background: @escaping (MapSheetState) -> Background,
        @ViewBuilder sheetDetail: () -> SheetDetail,
        @ViewBuilder sheetFooter: () -> SheetFooter
    ) {
        self.init(
            mapRevealHeight: mapRevealHeight,
            collapsedSheetHeight: collapsedSheetHeight,
            initiallyExpanded: initiallyExpanded,
            background: background,
            sheetTop: { EmptyView() },
            sheetDetail: sheetDetail,
            sheetFooter: sheetFooter
        )
    }
}

// 시트 그림자 — 16·21 이 함께 쓰던 값
private let SheetShadow = Color(argb: 0x141B2A4A)

/// 지도 위에 얹는 흰 알약 배지의 그림자 — 요약 칩·「위치 조정」 버튼이 함께 쓴다
public let MapOverlayShadow = Color(argb: 0x1A1B2A4A)

/// `MapSheetScaffold` 시트 안쪽 좌우 여백 — 16·21 이 같은 값을 쓴다
public let MapSheetContentPadding: CGFloat = 16

/// 배경(지도) 위에 떠 있는 알약 형태의 흰 배지 — 요약 칩·상태 배지에 쓴다
public struct MapOverlayPill<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .circular)
        content
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(MoyeotaColor.SurfaceCanvas, in: shape)
            .moyeotaShadow(elevation: 3, shape: shape, spotColor: MapOverlayShadow)
    }
}

/// 배경을 가득 채우는 자리표시자가 필요할 때 (지도 좌표가 없는 진입)
struct MapSheetBackgroundPlaceholder: View {
    var body: some View {
        MapPlaceholder()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
