import MoyeotaDesignSystem
import MoyeotaDomain
@preconcurrency import NMapsMap
import PresentationCore
import QuartzCore
import SwiftUI

// 와이어프레임 그레이 (core token 미정의 색 — 화면 재현용)
private let CanvasBg = Color(argb: 0xFFF5F7FA)
private let GrayMute = Color(argb: 0xFF8A93A0)
private let GrayAsh = Color(argb: 0xFF9AA1AC)
private let ChipBorder = Color(argb: 0xFFE2E7EE)

/// 원본 `Text` 는 `style` 을 주지 않고 `fontSize`·`fontWeight` 만 덮는다. 나머지는 머티리얼 테마가 깔아 둔
/// `bodyLarge` 에서 오므로 **줄 높이 24 · 자간 0.5** 가 그대로 남는다. 카드의 줄 간격이 이 값으로 정해진다
/// (스크린샷에서 출발지·목적지 두 줄의 간격이 24 + 3 이다).
func bodyLargeText(_ fontSize: CGFloat, _ fontWeight: Font.Weight) -> MoyeotaType {
    MoyeotaType(fontSize: fontSize, fontWeight: fontWeight, lineHeight: .sp(BodyLargeLineHeight), letterSpacing: 0.5)
}

private let BodyLargeLineHeight: CGFloat = 24

/// 17 접힘 제목(19sp)·18·19 목록 헤더(17sp)의 줄 상자. 24 를 넘는 이 두 글자만 한글 대체 글꼴이 줄 상자를 밀어 올린다
/// (원본 `Text` 는 `fontSize` 만 덮는다). `글자 크기 × 1.44` 근사로는 27.36·24.48 이라 모자라, 원본 렌더에서 쟀다(73px·66px, 2.625배).
/// 이 높이로 행 가운데가 정해져 점·화살표·부제와 그 아래 목록의 자리가 원본과 같아진다.
let PeekTitleLineBox: CGFloat = 27.8
let ListHeaderTitleLineBox: CGFloat = 25.1

let ExploreSheetStateKey = "explore.sheetState"
let ExplorePartyListScrollKey = "explore.partyList"

/// 바텀시트 3단계 — 17 지도(peek) / 18 지도+리스트(half) / 19 리스트(full)
public enum ExploreSheetState: CaseIterable, Hashable, Sendable {
    case peek, half, full
}

/// 지도에 그릴 기기 실위치 1건.
///
/// 좌표만으로는 「얼마나 믿을 수 있는 위치인지」를 그릴 수 없어 오차 반경·방향을 함께 받는다.
/// 세 값이 항상 같은 fix 에서 나와야 원과 점이 어긋나지 않으므로 하나로 묶는다.
///
/// - Parameters:
///   - accuracyMeters: 수평 오차 반경(m). nil 이면 정확도 원을 그리지 않는다
///   - bearingDegrees: 진행 방향(도, 0 = 북). nil 이면 방향 표시 없이 점만 그린다
public struct MyLocationFix: Equatable, Sendable {
    public var position: LatLng
    public var accuracyMeters: Float?
    public var bearingDegrees: Float?

    public init(position: LatLng, accuracyMeters: Float? = nil, bearingDegrees: Float? = nil) {
        self.position = position
        self.accuracyMeters = accuracyMeters
        self.bearingDegrees = bearingDegrees
    }
}

/// 조회 영역을 가시 영역보다 이만큼 넓힌다(각 변의 폭·높이 대비 비율).
///
/// 서버는 **출발지가 영역 안**인 방만 돌려주므로, 보이는 만큼만 물으면 카메라가 조금만 움직여도
/// 가장자리의 방이 목록에서 빠져 **마커가 깜빡인다**(실기 QA: 확대·축소 중 출발지가 화면에 있는데도
/// 사라졌다 나타남). 조회 영역이 화면보다 넓으면 그 경계가 화면 밖에 있어 눈에 띄지 않는다.
/// 지도 앱이 뷰포트보다 넓게 미리 받아 두는 것과 같은 이유다.
private let BoundsMarginRatio = 0.3

/// 지도에 지금 보이는 영역 — 방 목록 조회 범위.
///
/// 필드 순서를 서버 파라미터 순서(swLat → swLng → neLat → neLng)와 맞춰 둔다.
/// 위도·경도가 뒤바뀌어도 서버는 오류가 아니라 **빈 목록**을 돌려주므로,
/// 순서를 틀리면 「이 근처엔 방이 없네」로 보여 발견이 늦는다.
public struct MapBounds: Hashable, Sendable {
    public var swLat: Double
    public var swLng: Double
    public var neLat: Double
    public var neLng: Double

    public init(swLat: Double, swLng: Double, neLat: Double, neLng: Double) {
        self.swLat = swLat
        self.swLng = swLng
        self.neLat = neLat
        self.neLng = neLng
    }

    /// 가시 영역을 `BoundsMarginRatio` 만큼 넓힌 조회용 영역.
    /// 위도는 ±90, 경도는 ±180 을 넘지 않게 자른다.
    func expanded(ratio: Double = BoundsMarginRatio) -> MapBounds {
        let latMargin = (neLat - swLat) * ratio
        let lngMargin = (neLng - swLng) * ratio
        return MapBounds(
            swLat: max(swLat - latMargin, -90.0),
            swLng: max(swLng - lngMargin, -180.0),
            neLat: min(neLat + latMargin, 90.0),
            neLng: min(neLng + lngMargin, 180.0)
        )
    }
}

/// 지도 카메라 1건 (중심 + 줌)
private struct MapCamera: Equatable {
    var center: LatLng
    var zoom: Double
}

/// 지도 카메라 — **화면 레벨**에서 들고 있는다.
///
/// 지도는 시트 단계와 무관하게 하나지만, 스택 위 화면에서 돌아오는 등으로 지도 인스턴스가 다시 만들어질 수 있다.
/// 카메라를 지도 안에만 두면 그때마다 기준점으로 되돌아가 보던 목록이 통째로 사라진다.
///
/// 값이 바뀌어도 화면을 다시 그릴 일이 없어 관찰 대상으로 두지 않는다(원본도 지도를 만들 때 한 번만 읽는다).
@MainActor
private final class ExploreCameraState {
    /// 마지막으로 본 카메라. nil 이면 아직 지도가 한 번도 뜨지 않은 상태
    var camera: MapCamera?

    /// 첫 실위치로 한 번 옮겼는가. 매 fix 마다 따라가면 사용자가 지도를 팬할 수 없다
    var centeredOnMyLocation = false
}

/// 접힘(17) 시트 높이 — 핸들 + 한 줄 요약
private let PeekSheetHeight: CGFloat = 96

/// 반펼침(18)에서 시트 위로 남기는 지도 높이
private let HalfMapHeight: CGFloat = 300

/// 시트 앵커 사이를 오가는 정착 애니메이션(ms)
private let SheetAnimMs = 260.0

/// 이 속도(px/s) 이상으로 던지면 위치와 무관하게 그 방향의 다음 앵커로 붙는다 (`MapSheetScaffold` 와 같은 값).
/// 단위가 px 라 제스처 속도(pt/s)에 화면 배율을 곱해 비교한다.
private let SheetFlingVelocity: CGFloat = 400

/// 목록 헤더와 첫 카드 사이 간격 — 18·19 공통.
private let ListHeaderGap: CGFloat = 12

/// 타이틀 행 고정 높이 — 예전 「🗺 지도」 버튼(32dp) + 세로 여백(6dp×2) 과 같은 값이라 레이아웃이 그대로다
private let TitleRowHeight: CGFloat = 44

/// 앵커 = 시트 높이. HALF 는 지도 300 을 남기고, FULL 은 지도를 다 덮는다
func exploreSheetAnchor(_ state: ExploreSheetState, containerHeight: CGFloat) -> CGFloat {
    switch state {
    case .peek: PeekSheetHeight
    case .half: max(containerHeight - HalfMapHeight, PeekSheetHeight)
    case .full: containerHeight
    }
}

/// 17·18·19 · 근처 동승 찾기 [V07/V07b/V07c]
///
/// **지도는 하나다.** 시트 단계(PEEK/HALF/FULL)는 지도 위에 얹힌 시트의 **높이**만 바꾼다 —
/// 예전에는 단계마다 다른 화면(전체 지도 / 320dp 지도 / 지도 없음)으로 갈아끼워서
/// 단계를 바꿀 때마다 지도가 새로 만들어지고(타일 재로드·카메라 복원) 전환 애니메이션도 없었다(실기 QA).
/// 지금은 시트 높이가 앵커 사이를 애니메이션으로 오가고, 지도는 `contentPadding` 만 따라 바뀐다.
///
/// 시트 상태 전환:
/// - 핸들·헤더를 **드래그**하면 가까운 앵커(또는 던진 방향의 다음 앵커)로 정착 — 세 단계 모두
/// - PEEK 의 「⌃」 탭 → HALF · HALF/FULL 헤더의 「지도 접기 ⌄ / 지도 펼치기 ⌃」 → FULL/HALF
///   (접기·펼치기는 **이 한 버튼**뿐이다 — 타이틀 행의 「🗺 지도」는 행 높이를 흔들어 뺐다)
///
/// 이동(디스크립션):
/// - 「{단계} · {목적지} 보기 ›」 배너 → 진행 중인 방의 단계 화면 21/25/26 (onOngoingRideClick)
/// - 지도 마커 탭 / 카드 「합류」 → 20 합류 확인 (onJoinParty)
/// - 「＋ 새 합승 방 만들기」 → 15 목적지 입력 (onCreateRoomClick)
/// - 하단탭 홈 / 채팅 / 마이 → 14 / 24 / 35 (onTabSelect)
///
/// 검증·상태:
/// - 방 목록은 **지도에 보이는 범위**로 조회한 결과다(`onVisibleBoundsChange`) — 마커·리스트·**헤더의 N개**가 같은 목록
/// - 지도는 네이버 실지도. 내 위치는 기기 GPS(`myLocation`) — 못 받으면 기본 카메라(`MoyeotaDefaultCamera`) 범위를 보여준다
/// - 위치 권한 없으면 지도 대신 권한 요청 안내 + 「위치 권한 허용」 버튼 (locationGranted)
/// - 후보 0건이면 peek 문구 자리에 빈 상태 + 지도를 움직여 보라는 안내
///   (**내 방을 걸러내 0건이 된 경우**는 다른 문구다 — `myPartyHidden`)
/// - 내가 이미 참여 중인 방은 목록·마커에 **없다**(`ExploreRoute` 의 `exploreList`) — 돌아가는 길은
///   맨 위 진행 중 방 배너 한 번이고, 목록 카드는 20 을 거치는 더 긴 우회로였다
/// - 진행 중 탑승 없으면 상단 배너 숨김 (`activeRide` 가 nil). 배너가 있으면 지도 줌 컨트롤이 그 아래로 내려간다
/// - 정원 찬 방(3/3)은 「합류」 비활성 + 「마감」 표기
public struct ExploreScreen: View {
    private let parties: [Ride]
    private let activeRide: Ride?
    private let myPartyHidden: Bool
    private let stale: Bool
    private let locationGranted: Bool
    private let myLocation: MyLocationFix?
    private let onJoinParty: (Ride) -> Void
    private let onOngoingRideClick: () -> Void
    private let onCreateRoomClick: () -> Void
    private let onRequestLocationPermission: () -> Void
    private let onVisibleBoundsChange: (MapBounds) -> Void
    private let onTabSelect: (MoyeotaTab) -> Void

    @State private var sheetState: ExploreSheetState
    // 스택 위 화면에서 돌아와도 보던 자리를 유지한다 (시트 단계 변경으로는 이제 지도가 재생성되지 않는다)
    @State private var cameraState = ExploreCameraState()
    // 진행 배너 높이 — 지도 위 contentPadding 으로 넘겨 줌 컨트롤(+/−)이 배너 아래로 내려가게 한다
    // (작은 폰에서 배너와 줌 버튼이 겹치던 문제)
    @State private var bannerHeight: CGFloat = 0
    @Environment(\.tabSavedState) private var tabSavedState

    /// - Parameters:
    ///   - parties: 지도에 보이는 범위의 방 목록. **기본값이 없다** — 예시 방이 프로덕션에 새는 길을 막는다.
    ///     **내가 참여 중인 방은 이미 빠져 있다**(`ExploreRoute` 의 `exploreList`) — 마커·카드·헤더의
    ///     N 이 모두 이 한 목록에서 나오므로 세 자리가 함께 빠진다.
    ///   - activeRide: 지금 진행 중인 내 방. nil 이면 상단 배너를 그리지 않는다
    ///   - myPartyHidden: `parties` 에서 **내 방을 실제로 빼냈는가**(`ExploreList.myPartyHidden`).
    ///     빈 목록 문구만 이 값으로 갈린다 — 주변에 방이 내 방뿐이면 걸러낸 뒤 목록이 0건이 되는데,
    ///     그때 「이 근처엔 동승이 없어요」는 **거짓말**이다(방은 있고, 그게 내 방이다).
    ///     목록이 비지 않았을 때는 아무것도 바꾸지 않는다: 「내 방 1개는 뺐어요」는 돌아갈 길이 이미
    ///     배너로 있는 상황에서 더해지는 소음이다.
    ///   - stale: 주기 갱신이 **연속으로** 실패해 목록이 낡았는가(`ExploreViewModel.UiState.success` 의 stale).
    ///     true 라도 보던 목록·마커는 그대로 둔다 — 지도를 에러 화면으로 바꾸지 않는다는 기존 판단을
    ///     지키고, 대신 타이틀 줄에 **비차단 표시**만 올린다. 기본값 false 는 「문제 없음」이다.
    ///   - myLocation: 기기 실위치. nil = 권한 없음 · 아직 fix 없음 → 지도는 기본 카메라 위치에서 시작한다
    ///   - onVisibleBoundsChange: 지도 카메라가 멈출 때마다 보이는 영역을 올려보낸다 → 그 범위의 방 목록으로 갱신
    public init(
        parties: [Ride],
        activeRide: Ride? = nil,
        myPartyHidden: Bool = false,
        stale: Bool = false,
        locationGranted: Bool = true,
        myLocation: MyLocationFix? = nil,
        initialSheetState: ExploreSheetState = .peek,
        onJoinParty: @escaping (Ride) -> Void = { _ in },
        onOngoingRideClick: @escaping () -> Void = {},
        onCreateRoomClick: @escaping () -> Void = {},
        onRequestLocationPermission: @escaping () -> Void = {},
        onVisibleBoundsChange: @escaping (MapBounds) -> Void = { _ in },
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in }
    ) {
        self.parties = parties
        self.activeRide = activeRide
        self.myPartyHidden = myPartyHidden
        self.stale = stale
        self.locationGranted = locationGranted
        self.myLocation = myLocation
        self.onJoinParty = onJoinParty
        self.onOngoingRideClick = onOngoingRideClick
        self.onCreateRoomClick = onCreateRoomClick
        self.onRequestLocationPermission = onRequestLocationPermission
        self.onVisibleBoundsChange = onVisibleBoundsChange
        self.onTabSelect = onTabSelect
        _sheetState = State(initialValue: initialSheetState)
    }

    public var body: some View {
        VStack(spacing: 0) {
            StatusBarSpacer()

            // 타이틀 행 — **고정 높이**. 단계에 따라 버튼이 생기고 사라지면 행 높이가 흔들려 제목이 움직였다
            ZStack(alignment: .leading) {
                Text("근처 동승 찾기")
                    .moyeotaText(bodyLargeText(18, .bold), color: MoyeotaColor.InkPrimary)
                // 낡은 목록 표시는 **고정 높이인 이 줄**에 둔다 — 지도 위에 띄우면 시트를 끝까지 올린
                // 상태(FULL, 지도가 통째로 가려짐)에서 보이지 않고, 시트 안에 두면 접힘(PEEK) 높이가
                // 흔들린다. 이 자리면 세 단계 모두에서 같은 자리에 보이고 레이아웃도 밀리지 않는다.
                if stale {
                    StaleListNotice()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .frame(height: TitleRowHeight)

            GeometryReader { geometry in
                mapAndSheet(containerHeight: geometry.size.height)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }

            MoyeotaBottomBar(selected: .explore, onSelect: onTabSelect)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBg)
        // 원본 `rememberSaveable` 의 `sheetState` 자리 — 탭을 다녀와도 같은 단계로 돌아온다(`ExploreRoute` 가 초깃값으로 넘긴다).
        .onChange(of: sheetState) { _, state in
            tabSavedState?.set(ExploreSheetStateKey, state)
            // 원본은 접힘에서 목록이 컴포지션에서 빠져 스크롤 위치가 사라진다. 탭 이동으로는 사라지면 안 되므로 여기서만 지운다.
            if state == .peek { tabSavedState?.remove(ExplorePartyListScrollKey) }
        }
    }

    private func mapAndSheet(containerHeight: CGFloat) -> some View {
        // 배경 지도 — 단계가 바뀌어도 같은 인스턴스. 시트에 덮이는 높이만 contentPadding 으로 알린다.
        // FULL 에서는 지도가 통째로 가려지므로 HALF 기준으로 고정한다(패딩이 뷰 높이를 넘으면 안 된다)
        let mapBottomInset = min(
            exploreSheetAnchor(sheetState, containerHeight: containerHeight),
            exploreSheetAnchor(.half, containerHeight: containerHeight)
        )
        return ZStack(alignment: .top) {
            if locationGranted {
                ExploreMap(
                    rides: parties,
                    myLocation: myLocation,
                    cameraState: cameraState,
                    onMarkerClick: onJoinParty,
                    onVisibleBoundsChange: onVisibleBoundsChange,
                    contentPadding: EdgeInsets(top: bannerHeight, leading: 0, bottom: mapBottomInset, trailing: 0)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LocationPermissionNotice(onRequestPermission: onRequestLocationPermission)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let activeRide {
                ActiveRideBanner(ride: activeRide, onClick: onOngoingRideClick)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
            }

            ExploreSheet(
                sheetState: $sheetState,
                containerHeight: containerHeight,
                parties: parties,
                myPartyHidden: myPartyHidden,
                onJoinParty: onJoinParty,
                onCreateRoomClick: onCreateRoomClick
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Compose `Animatable` + `tween(SheetAnimMs)` 자리. SwiftUI 애니메이션은 진행 중인 값을 읽을 수 없는데, 정착 중에
/// 시트를 다시 잡으면 그 순간의 높이에서 이어 가야 하므로(원본 `dragPx ?: sheetPx.value`) 값을 프레임마다 직접 계산한다.
@MainActor
@Observable
private final class ExploreSheetAnimatable {
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

    func animateTo(_ newTarget: CGFloat, from start: CGFloat) {
        stop()
        from = start
        target = newTarget
        value = start
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(
            target: SheetDisplayLinkProxy { [weak self] in
                self?.tick()
                return self != nil
            },
            selector: #selector(SheetDisplayLinkProxy.fire(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        let fraction = (CACurrentMediaTime() - startTime) * 1000 / SheetAnimMs
        if fraction >= 1 {
            value = target
            stop()
        } else {
            value = from + (target - from) * CGFloat(FastOutSlowIn.value(at: fraction))
        }
    }
}

/// Compose `FastOutSlowInEasing` — `tween` 의 기본 곡선이다.
private let FastOutSlowIn = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.4, y: 0),
    endControlPoint: UnitPoint(x: 0.2, y: 1)
)

@MainActor
private final class SheetDisplayLinkProxy: NSObject {
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

/// 시트 — 높이만 앵커 사이를 오간다. 내용은 **목표 단계** 기준이라 애니메이션 중에 흔들리지 않는다.
///
/// 원본은 한 함수 안에 있지만 프레임마다 바뀌는 높이를 이 뷰에 가둔다. 위로 새면 애니메이션 내내 지도까지 다시 계산된다.
private struct ExploreSheet: View {
    @Binding var sheetState: ExploreSheetState
    let containerHeight: CGFloat
    let parties: [Ride]
    let myPartyHidden: Bool
    let onJoinParty: (Ride) -> Void
    let onCreateRoomClick: () -> Void

    @State private var animatable = ExploreSheetAnimatable()
    // 드래그 중에는 이 값만 따라간다 (`MapSheetScaffold` 와 같은 이유 — 매 프레임 정착 값을 건드리면 정착을 끊는다)
    @State private var drag = SheetDragTracker()
    // 시스템이 제스처를 취소하면(전화 수신·제어 센터·앱 전환) `onEnded` 가 불리지 않는다.
    // 끝났다는 신호를 받는 길은 이 값이 저절로 되돌아오는 것뿐이다.
    @GestureState private var dragging = false

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    private func anchor(_ state: ExploreSheetState) -> CGFloat {
        exploreSheetAnchor(state, containerHeight: containerHeight)
    }

    /// 드래그가 없을 때의 시트 높이 — 정착 중이면 그 값, 아니면 앵커.
    private var restingHeight: CGFloat {
        animatable.value ?? anchor(sheetState)
    }

    var body: some View {
        let sheetHeight = drag.height ?? restingHeight
        // FULL 에서는 모서리를 각지게 — 둥근 모서리 틈으로 뒤의 지도가 비친다
        let radius: CGFloat = sheetState == .full ? 0 : 24
        let sheetShape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .circular)

        VStack(spacing: 0) {
            // 드래그 타깃 = 핸들 + 그 아래 한 줄(요약 또는 헤더)
            VStack(spacing: 0) {
                SheetHandle()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                if sheetState == .peek {
                    PeekSummaryRow(
                        count: parties.count,
                        myPartyHidden: myPartyHidden,
                        onRaise: { sheetState = .half }
                    )
                } else {
                    ListHeaderRow(
                        count: parties.count,
                        mapShown: sheetState == .half,
                        onToggleMap: { sheetState = sheetState == .half ? .full : .half }
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture)

            if sheetState != .peek {
                Spacer(minLength: 0).frame(height: ListHeaderGap)
                if sheetState == .full {
                    HorizontalDivider(color: ChipBorder)
                    Spacer(minLength: 0).frame(height: ListHeaderGap)
                }
                PartyList(
                    parties: parties,
                    myPartyHidden: myPartyHidden,
                    onJoinParty: onJoinParty,
                    showEndOfList: sheetState == .full
                )
                .frame(maxHeight: .infinity)
                CreateRoomButton(onClick: onCreateRoomClick)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: sheetHeight, alignment: .top)
        .background(MoyeotaColor.SurfaceCanvas)
        .clipShape(sheetShape)
        .moyeotaShadow(elevation: 14, shape: sheetShape, spotColor: Color(argb: 0x1A000000))
        // 단계가 바뀌면(탭·드래그 정착) 그 앵커로 애니메이션
        .onChange(of: sheetState) { oldState, newState in
            animatable.animateTo(anchor(newState), from: animatable.value ?? anchor(oldState))
        }
        // 컨테이너 높이가 바뀌면 다시 앉힌다. 앵커에 앉은 채라면(nil) 저절로 새 앵커를 따라간다.
        .onChange(of: containerHeight) { _, _ in
            guard let current = animatable.value else { return }
            animatable.animateTo(anchor(sheetState), from: current)
        }
        // 떠나면 정착을 끝낸 것으로 친다. 돌아왔을 때 어중간한 높이에 머물지 않게 앵커로 앉힌다.
        .onDisappear {
            animatable.snapTo(nil)
            drag.clear()
        }
        // 원본 `draggable` 의 `onDragStopped` 는 포인터 입력이 취소돼도 불린다. 같은 결과가 되게 여기서 정착시킨다.
        // 정상 종료에서는 `onEnded` 와 이 신호의 순서에 기대지 않는다 — `settleDrag` 는 어느 순서로 불려도 같은 곳에 닿는다.
        .onChange(of: dragging) { _, active in
            if !active { settleInterruptedDrag() }
        }
        // 앱이 전면에서 내려가면 드래그는 이어질 수 없다. `@GestureState` 가 되돌아오는 길과 겹쳐도 한 번만 정착한다.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { settleInterruptedDrag() }
        }
    }

    private var dragGesture: some Gesture {
        // 시트가 드래그를 따라 움직이므로 지역 좌표로 재면 값이 되먹임된다. 전역 좌표로 잰다.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                drag.track(y: value.location.y, resting: restingHeight, range: anchor(.peek)...anchor(.full))
            }
            .onEnded { value in
                settleDrag(velocity: value.velocity.height)
            }
    }

    /// 취소된 드래그를 정착시킨다. 던진 속도를 알 수 없으니 가까운 앵커로 간다(원본도 취소 때 속도 0 이다).
    /// 이미 끝난 드래그면 아무것도 하지 않는다.
    private func settleInterruptedDrag() {
        if drag.height != nil { settleDrag(velocity: 0) }
    }

    /// - Parameter velocity: 드래그 속도(pt/s)
    private func settleDrag(velocity: CGFloat) {
        let from = drag.finish(resting: restingHeight)
        let target = settleTarget(
            fromPx: from * displayScale,
            velocity: velocity * displayScale,
            anchorPx: { anchor($0) * displayScale }
        )
        // 단계가 그대로면 `onChange` 가 불리지 않으므로 늘 직접 정착시킨다.
        // 단계가 바뀌면 `onChange` 가 같은 값에서 다시 시작할 뿐이라 결과가 같다.
        animatable.animateTo(anchor(target), from: from)
        sheetState = target
    }
}

/// 손을 뗀 위치·속도로 정착할 앵커. 빠르게 던지면 그 방향의 **다음** 앵커, 아니면 가장 가까운 앵커.
func settleTarget(
    fromPx: CGFloat,
    velocity: CGFloat,
    anchorPx: (ExploreSheetState) -> CGFloat
) -> ExploreSheetState {
    let ordered = ExploreSheetState.allCases.sorted { anchorPx($0) < anchorPx($1) }
    if velocity > SheetFlingVelocity {
        // 아래로 던짐 → 현재 위치보다 낮은 앵커 중 가장 가까운 것
        return ordered.last { anchorPx($0) < fromPx - 1 } ?? ordered[0]
    }
    if velocity < -SheetFlingVelocity {
        return ordered.first { anchorPx($0) > fromPx + 1 } ?? ordered[ordered.count - 1]
    }
    return ordered.min { abs(anchorPx($0) - fromPx) < abs(anchorPx($1) - fromPx) } ?? ordered[0]
}

/// 목록이 0건일 때의 두 줄 — 접힘 요약(17)과 리스트 빈 상태(18·19)가 **같은 말**을 쓴다.
///
/// 걸러내기 전의 목록에 내 방이 있었는가(`myPartyHidden`)로 갈린다. 「이 근처엔 동승이 없어요」는
/// 주변에 내 방뿐일 때 **거짓말**이다 — 방은 있고 그게 내 방이며, 그래서 목록이 빈 것이다.
/// 그 경우 사실만 말한다: 이 범위에 남의 방이 없다.
///
/// 내 방으로 **돌아가는 길을 문구로 가리키지 않는다**(「위 배너를 누르세요」를 쓰지 않았다) —
/// 시트를 끝까지 올린 상태(FULL)에서는 그 배너가 시트에 가려 보이지 않아 위치를 말하는 문장이
/// 그 순간 틀린 말이 된다. 배너는 PEEK·HALF 에서 바로 보이고, 두 줄의 역할은 「왜 비었는지」까지다.
func emptyListCopy(myPartyHidden: Bool) -> (first: String, second: String) {
    myPartyHidden
        ? (first: "지금은 내 방뿐이에요", second: "지도를 움직여 다른 방을 찾아보세요")
        : (first: "이 근처엔 동승이 없어요", second: "지도를 움직여 보세요")
}

/// 17 접힘 요약 — 「주변 합승 N개」. N 은 헤더·마커와 같은 목록(지도 범위)의 방 수다
struct PeekSummaryRow: View {
    let count: Int
    let myPartyHidden: Bool
    let onRaise: () -> Void

    var body: some View {
        let isEmpty = count == 0
        let (emptyTitle, emptySubtitle) = emptyListCopy(myPartyHidden: myPartyHidden)
        HStack(spacing: 0) {
            if !isEmpty {
                Circle()
                    .fill(MoyeotaColor.Primary500)
                    .frame(width: 10, height: 10)
                Spacer(minLength: 0).frame(width: 8)
            }
            // 시트 높이(96)가 모자라도 말줄임하지 않고 줄을 바꾼다. 넘친 만큼은 시트가 자른다(원본과 같다)
            VStack(alignment: .leading, spacing: 0) {
                Text(isEmpty ? emptyTitle : "주변 동승 \(count)개 모집 중")
                    .moyeotaText(.inheritedBodyLarge(fontSize: 19, fontWeight: .bold), color: MoyeotaColor.InkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: PeekTitleLineBox)
                // 「목적지 정하면 바로 자동 매칭」은 지웠다 — 목적지를 정하면 **새 방이 만들어지고**
                // (16 「같이 탈 사람 찾기」 → `POST /matching/rooms`) 사람이 합류하기를 기다린다.
                // 목적지로 기존 방에 자동으로 넣어 주는 기능은 없다(2026-10-13).
                Text(isEmpty ? emptySubtitle : "위로 올리면 리스트, 목적지를 정하면 새 방을 만들어요")
                    .moyeotaText(bodyLargeText(13, .medium), color: GrayMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRaise) {
                ChevronUpIcon(color: GrayAsh)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackStyle())
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

/// 18·19 목록 헤더 — 「주변 합승 N개 · 가까운 순」 + 지도 접기/펼치기 **단일** 토글
struct ListHeaderRow: View {
    let count: Int
    let mapShown: Bool
    let onToggleMap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text("주변 동승 \(count)개 · 가까운 순")
                .moyeotaText(.inheritedBodyLarge(fontSize: 17, fontWeight: .bold), color: MoyeotaColor.InkPrimary)
                .frame(minHeight: ListHeaderTitleLineBox)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onToggleMap) {
                HStack(spacing: 0) {
                    Text(mapShown ? "지도 접기" : "지도 펼치기")
                        .moyeotaText(bodyLargeText(13, .medium), color: MoyeotaColor.Primary500)
                        .accessibilityLabel(mapShown ? "지도 접기 ⌄" : "지도 펼치기 ⌃")
                    // 글자와 화살표 사이는 원본 렌더의 잉크 간격에 맞춘다(6.5·6.1). 한글이 좁아 글자의 왼쪽 끝은 1.5~2.7pt 안쪽이다.
                    Spacer().frame(width: mapShown ? 4.5 : 3.8)
                    GlyphMark(mapShown ? .chevronDown : .chevronUp, color: MoyeotaColor.Primary500, lineWidth: 1)
                        .offset(y: mapShown ? 3.2 : -2.6)
                    Spacer().frame(width: 1.3)
                }
                // 원본 13sp 한글 잉크는 24 상자 가운데보다 내려간다(18·19 글자 가운데 41.5dp 대 40.4pt, 시트 위 끝 기준)
                .offset(y: 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressFeedbackStyle())
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

// ─── 공용 조각 ──────────────────────────────────────────────────────────────

private struct PartyList: View {
    let parties: [Ride]
    let myPartyHidden: Bool
    let onJoinParty: (Ride) -> Void
    let showEndOfList: Bool

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 12) {
                ForEach(Array(parties.enumerated()), id: \.offset) { _, ride in
                    PartyCard(ride: ride, onJoin: onJoinParty)
                }
                if parties.isEmpty {
                    EmptyListNotice(myPartyHidden: myPartyHidden)
                } else if showEndOfList {
                    // 스펙 19: 마지막 페이지면 목록의 끝을 알린다 (범위 기준)
                    Text("이 근처는 여기까지예요")
                        .moyeotaText(bodyLargeText(12, .medium), color: GrayAsh)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .savedScrollOffset(ExplorePartyListScrollKey)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

private struct PartyCard: View {
    let ride: Ride
    let onJoin: (Ride) -> Void

    var body: some View {
        // 정원을 모르면(0) 「마감」이라고 단정하지 않는다 — `0 >= 0` 이 참이라 전에는 인원·정원을 둘 다
        // 모르는 방이 **마감으로 보였다.** 인원 문구를 지우면서 버튼만 마감으로 남기면 같은 카드가 두
        // 가지 말을 한다. 실제로 찼는지는 탭해서 들어간 20 이 방 상세로 다시 판정한다(`joinGate`).
        let full = ride.capacity > 0 && ride.members.count >= ride.capacity
        // 인원 문구는 16 추천 카드와 **같은 함수**를 쓴다(`headcountLabel`) — 리터럴로 쓰던 동안
        // 인원을 모르는 방을 「0/3명」, 정원을 모르는 방을 「2/0명」으로 그렸다(없는 상태다).
        // 빈 문자열이면 배지째 지운다(그 판단은 `headcountLabel` 설명에 있다).
        let headcount = headcountLabel(joined: ride.members.count, capacity: ride.capacity)
        let shape = RoundedRectangle(cornerRadius: 16, style: .circular)
        HStack(spacing: 0) {
            AvatarStack(count: ride.members.count)
            Spacer(minLength: 0).frame(width: 10)
            VStack(alignment: .leading, spacing: 3) {
                // 출발지·목적지를 라벨 붙여 두 줄로 — 「A → B」 한 줄은 주소가 길면 어디서 갈리는지 읽기 어렵다
                PlaceLine(label: "출발지", place: ride.origin)
                PlaceLine(label: "목적지", place: ride.destination)
                // 목록 응답은 출발 문구가 비어 있다. 원본 `Text("")` 는 줄 높이를 그대로 차지하고
                // SwiftUI 는 0 이라, 줄 높이를 직접 지켜야 카드 높이가 같다.
                Text(ride.departureLabel)
                    .moyeotaText(bodyLargeText(12, .medium), color: GrayMute)
                    .frame(minHeight: BodyLargeLineHeight)
                if !headcount.isEmpty {
                    CapacityBadge(text: headcount)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0).frame(width: 8)
            JoinButton(full: full, onClick: { onJoin(ride) })
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(MoyeotaColor.SurfaceCanvas, in: shape)
        .overlay(shape.strokeBorder(ChipBorder, lineWidth: 1))
    }
}

/// 「출발지 : 장소」 한 줄. 라벨은 고정 폭이라 두 줄의 장소가 같은 x 에서 시작한다
private struct PlaceLine: View {
    let label: String
    let place: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(label) :")
                .moyeotaText(bodyLargeText(13, .medium), color: GrayMute)
                .frame(width: 52, alignment: .leading)
            Text(place)
                .moyeotaText(bodyLargeText(14, .bold), color: MoyeotaColor.InkPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 참여 인원만큼(최대 3개) 아바타를 겹쳐 그린다.
///
/// **`count` 가 0 이면 아무것도 그리지 않는다.** 0 은 「빈 방」이 아니라 「인원을 모른다」는 뜻이고
/// (`headcountLabel`), 예전처럼 최소 1 로 올려 한 개를 그리면 「최대 3명」이라고 쓰면서
/// 사람 1명을 그려 **숫자와 그림이 서로 다른 말**을 한다.
private struct AvatarStack: View {
    let count: Int

    var body: some View {
        let shown = min(max(count, 0), 3)
        if shown != 0 {
            ZStack(alignment: .leading) {
                ForEach(0..<shown, id: \.self) { i in
                    AvatarCircle(size: 30)
                        .offset(x: 18 * CGFloat(i))
                }
            }
            .frame(width: 30 + 18 * CGFloat(shown - 1), height: 30, alignment: .leading)
        }
    }
}

private struct CapacityBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .moyeotaText(bodyLargeText(11, .bold), color: MoyeotaColor.TextOnDark)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(MoyeotaColor.Waiting500, in: Capsule(style: .circular))
    }
}

// 정원 찬 방(3/3)은 「합류」 비활성 + 「마감」 표기 (스펙 18)
private struct JoinButton: View {
    let full: Bool
    let onClick: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .circular)
        if full {
            Text("마감")
                .moyeotaText(bodyLargeText(13, .bold), color: GrayAsh)
                .frame(width: 48, height: 34)
                .background(MoyeotaColor.SurfaceSoft, in: shape)
        } else {
            Button(action: onClick) {
                Text("합류")
                    .moyeotaText(bodyLargeText(13, .bold), color: MoyeotaColor.TextOnDark)
                    .frame(width: 48, height: 34)
                    .background(MoyeotaColor.Primary500, in: shape)
            }
            .buttonStyle(PressOverlayStyle(shape: shape))
        }
    }
}

private struct CreateRoomButton: View {
    let onClick: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .circular)
        Button(action: onClick) {
            HStack(spacing: 7) {
                GlyphMark(.plus, color: MoyeotaColor.TextOnDark, lineWidth: 1.5)
                Text("새 동승 방 만들기")
                    .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.TextOnDark)
                    .accessibilityLabel("＋ 새 동승 방 만들기")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(MoyeotaColor.Primary500, in: shape)
        }
        .buttonStyle(PressOverlayStyle(shape: shape))
    }
}

// 위치 권한 없을 때 지도 대신 안내 (스펙 17).
// 자동 요청을 한 번 거부한 뒤에도 여기서 다시 요청할 수 있어야 지도로 돌아올 길이 남는다
// (iOS 는 시스템이 한 번만 물으므로 두 번째부터 이 버튼이 설정 앱으로 보낸다 — `MyLocationController.requestPermission`).
private struct LocationPermissionNotice: View {
    let onRequestPermission: () -> Void

    var body: some View {
        ZStack {
            MoyeotaColor.SurfaceSoft
            VStack(spacing: 6) {
                Text("위치 권한이 필요해요")
                    .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.InkPrimary)
                Text("권한을 허용하면 내 주변 동승을 지도로 볼 수 있어요")
                    .moyeotaText(bodyLargeText(13, .medium), color: GrayMute)
                Spacer(minLength: 0).frame(height: 4)
                Button(action: onRequestPermission) {
                    Text("위치 권한 허용")
                        .moyeotaText(bodyLargeText(13, .bold), color: MoyeotaColor.SurfaceCanvas)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(MoyeotaColor.Primary500, in: Capsule(style: .circular))
                }
                .buttonStyle(PressOverlayStyle(shape: Capsule(style: .circular)))
            }
        }
    }
}

/// 「최신 정보를 받지 못했어요」 — 목록을 **덮지 않는** 표시.
///
/// 띄우는 조건은 `staleAfterPollFailures` 가 정한다(연속 실패 3회 = 12초). 여기서 하는 일은 그
/// 사실을 조용히 알리는 것뿐이고, 재시도 버튼을 달지 않는다 — 폴링이 4초마다 알아서 다시 읽고
/// 한 번 성공하면 이 표시가 사라진다. 사용자가 할 일이 없는 상태에 누를 것을 주면 더 헷갈린다.
private struct StaleListNotice: View {
    var body: some View {
        Text("최신 정보를 받지 못했어요")
            .moyeotaText(bodyLargeText(11, .bold), color: MoyeotaColor.Danger600)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(MoyeotaColor.Danger50, in: Capsule(style: .circular))
    }
}

private struct EmptyListNotice: View {
    let myPartyHidden: Bool

    var body: some View {
        // 접힘 요약(17)과 **같은 두 줄**이다 — 같은 상황을 두 자리가 다르게 말하지 않게 한 곳에서 뽑는다
        let (title, subtitle) = emptyListCopy(myPartyHidden: myPartyHidden)
        VStack(spacing: 6) {
            Text(title)
                .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.InkPrimary)
            Text(subtitle)
                .moyeotaText(bodyLargeText(13, .medium), color: GrayMute)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// ─── 지도 (네이버 실지도 + 내 위치·합승 마커) ────────────────────────────────

/// 내 주변 1km 남짓이 한 화면에 들어오는 줌 — 첫 범위 조회가 이 정도를 훑는다
private let ExploreZoom = 15.0

/// 지도가 아직 범위를 알려주지 못할 때 쓰는 기준 범위의 반변(도).
///
/// `ExploreZoom` 의 실제 가시 영역(Pixel 6 실측 위도 ±0.006 · 경도 ±0.004)에 맞춘 값이다.
/// 지도가 뜨면 곧바로 실제 `NMFMapView.contentBounds` 로 덮어쓰지만, 그 사이에 「지도에 없는
/// 방」이 리스트에 잠깐 떴다 사라지지 않도록 처음부터 비슷한 크기로 묻는다.
private let DefaultBoundsHalfSpanDeg = 0.006

/// 지도가 범위를 알려주기 전의 첫 조회 범위.
///
/// `center` 가 nil(위치 권한 거부·아직 fix 없음)이면 지도가 처음 보여주는 기본 카메라
/// (`MoyeotaDefaultCamera`) 주변을 조회한다 — 지도에 보이는 곳과 목록이 어긋나지 않게.
public func defaultExploreBounds(center: LatLng?) -> MapBounds {
    let origin = center ?? MoyeotaDefaultCamera
    return MapBounds(
        swLat: origin.latitude - DefaultBoundsHalfSpanDeg,
        swLng: origin.longitude - DefaultBoundsHalfSpanDeg,
        neLat: origin.latitude + DefaultBoundsHalfSpanDeg,
        neLng: origin.longitude + DefaultBoundsHalfSpanDeg
    )
}

/// `rememberUpdatedState` 자리. 이펙트가 잡아 둔 콜백이 낡지 않게 최신 참조를 들고 있다
/// — 이펙트 키에 넣으면 람다가 새로 생길 때마다 이펙트가 다시 돈다.
@MainActor
private final class LatestValue<Value> {
    var value: Value?
}

/// 합승 탐색 지도 — 내 위치를 중심으로 한 네이버 실지도.
///
/// 지도는 화면의 **바닥 레이어**다. 위에 얹히는 배너·시트는 자기 영역에서만 터치를 소비하므로
/// 남는 영역의 팬·줌은 그대로 지도로 전달된다 (홈 14 와 동일한 처리).
///
/// 합승 마커는 서버가 좌표를 준 방만 찍는다 — 좌표가 없거나 범위를 벗어난 값은
/// `latLngOrNull` 이 걸러 렌더를 건너뛴다. 마커가 없어도 리스트의 「합류」로 같은 곳에 갈 수 있다.
///
/// - Parameters:
///   - myLocation: 기기 실위치. nil 이면 기본 카메라(`MoyeotaDefaultCamera`)에서 시작하고 내 위치 표시는 없다
///   - onVisibleBoundsChange: 카메라가 멈출 때 보이는 영역. 이 범위로 방 목록을 다시 읽는다
///   - contentPadding: 시트가 지도를 덮는 영역. 카메라 중심이 시트 뒤로 밀리지 않게 한다
private struct ExploreMap: View {
    private let rides: [Ride]
    private let myLocation: MyLocationFix?
    private let cameraState: ExploreCameraState
    private let onMarkerClick: (Ride) -> Void
    private let onVisibleBoundsChange: (MapBounds) -> Void
    private let contentPadding: EdgeInsets

    @State private var map: NMFMapView?
    // `NaverMapView` 에 넘기는 카메라는 **이 지도 인스턴스를 만들 때 한 번** 정하고 그 뒤로는
    // 사용자 조작이 주인이다. idle 로 읽은 카메라를 그대로 center 로 돌려주면 안 된다 —
    // SDK 가 돌려주는 좌표가 우리가 넣은 값과 부동소수점 끝자리만큼 달라
    // 「적용 → idle → 적용」이 끝없이 돌고, 매 idle 이 조회를 재시작시켜 목록이 영영 갱신되지 않는다.
    // 사용자가 움직인 카메라는 `cameraState` 에만 적어 두고, 지도가 새로 만들어질 때 그 값에서 시작한다.
    @State private var mapCamera: MapCamera

    @Environment(\.mapCameraMemory) private var cameraMemory

    init(
        rides: [Ride],
        myLocation: MyLocationFix?,
        cameraState: ExploreCameraState,
        onMarkerClick: @escaping (Ride) -> Void,
        onVisibleBoundsChange: @escaping (MapBounds) -> Void,
        contentPadding: EdgeInsets
    ) {
        self.rides = rides
        self.myLocation = myLocation
        self.cameraState = cameraState
        self.onMarkerClick = onMarkerClick
        self.onVisibleBoundsChange = onVisibleBoundsChange
        self.contentPadding = contentPadding
        _mapCamera = State(
            initialValue: cameraState.camera
                ?? MapCamera(center: myLocation?.position ?? MoyeotaDefaultCamera, zoom: ExploreZoom)
        )
    }

    var body: some View {
        ZStack {
            NaverMapView(
                center: mapCamera.center,
                zoom: mapCamera.zoom,
                contentPadding: contentPadding,
                onMapReady: { map = $0 }
            )

            MapIdleReporter(
                map: map,
                cameraState: cameraState,
                onVisibleBoundsChange: onVisibleBoundsChange
            )

            if let myLocation {
                // 실위치가 있으면 SDK 내장 위치 오버레이(파란 점 + 오차 원 + 방향)를 쓴다 — 14 홈과 같은 컴포넌트
                MyLocationOverlay(
                    map: map,
                    position: myLocation.position,
                    accuracyMeters: myLocation.accuracyMeters,
                    bearingDegrees: myLocation.bearingDegrees
                )
            }

            // id 로 묶어야 범위 조회로 목록이 바뀔 때 마커 상태가 옆 항목으로 밀리지 않는다
            ForEach(rides, id: \.id) { ride in
                ExploreMarker(
                    map: map,
                    position: latLngOrNull(latitude: ride.originLat, longitude: ride.originLng),
                    tint: MoyeotaColor.Primary500,
                    // 캡션도 카드 배지와 **같은 함수**다(`headcountLabel`) — 리터럴로 쓰던 동안 인원을
                    // 모르는 방의 마커가 「0명」이라고 적혀 있었고, 같은 방의 카드는 「최대 3명」이었다.
                    // 둘 다 모르면 빈 문자열이 오고, 그때는 캡션을 아예 달지 않는다(`ExploreMarker`).
                    caption: headcountLabel(joined: ride.members.count, capacity: ride.capacity),
                    onClick: { onMarkerClick(ride) } // 마커 탭 → 20 합류 확인
                )
            }
        }
        // 카메라를 **처음 잡힌 실위치로 한 번만** 옮긴다.
        // 주기 갱신(1초)마다 center 를 바꾸면 그때마다 카메라가 되돌아가 사용자가 지도를 팬·줌할 수
        // 없다 (`RouteMapView` 의 driverPosition 과 같은 이유). 파란 점은 계속 최신 좌표를 따라간다.
        // 플래그는 `cameraState` 와 `cameraMemory` — 지도가 다시 만들어져도 이미 옮겼다는 사실이 남아야 한다.
        .task(id: myLocation?.position) {
            guard let fix = myLocation?.position else { return }
            if !cameraState.centeredOnMyLocation && cameraMemory?.centeredOnMyLocation != true {
                cameraState.centeredOnMyLocation = true
                cameraMemory?.centeredOnMyLocation = true
                let moved = MapCamera(center: fix, zoom: ExploreZoom)
                cameraState.camera = moved
                mapCamera = moved // 이 값의 변경만이 실제로 카메라를 움직인다
            }
        }
    }
}

/// 카메라가 멈출 때마다 「지금 보이는 영역」과 카메라 위치를 위로 올려보내는 부분.
///
/// 카메라가 **멈췄을 때**만(`mapViewCameraIdle`) 보고한다 — 드래그 중 매 프레임 보고하면
/// 손가락을 떼기도 전에 조회가 수십 번 나간다.
///
/// 범위는 `NMFMapView.contentBounds` 로 읽는다. 뷰 크기 기준이 아니라
/// **contentInset 을 뺀 실제로 보이는 영역**이라, 시트에 가린 방이 목록에 섞이지 않는다.
///
/// 지도가 준비된 직후에도 한 번 보고한다. idle 은 「카메라가 움직였다 멈춤」에만 오므로,
/// 사용자가 지도를 건드리지 않으면 첫 이벤트가 영영 오지 않을 수 있다.
private struct MapIdleReporter: View {
    let map: NMFMapView?
    let cameraState: ExploreCameraState
    let onVisibleBoundsChange: (MapBounds) -> Void

    @State private var currentCallback = LatestValue<(MapBounds) -> Void>()

    var body: some View {
        let _ = currentCallback.value = onVisibleBoundsChange
        DisposableEffect(key: map.map(ObjectIdentifier.init)) {
            guard let map else { return nil }
            let report: @MainActor () -> Void = {
                let position = map.cameraPosition
                cameraState.camera = MapCamera(center: LatLng(position.target), zoom: position.zoom)
                if let bounds = map.contentBounds.toMapBoundsOrNull() {
                    currentCallback.value?(bounds)
                }
            }
            report()
            let listener = MapCameraIdleListener(onIdle: report)
            map.addCameraDelegate(delegate: listener)
            return { map.removeCameraDelegate(delegate: listener) }
        }
    }
}

@MainActor
private final class MapCameraIdleListener: NSObject, @preconcurrency NMFMapViewCameraDelegate {
    private let onIdle: @MainActor () -> Void

    init(onIdle: @escaping @MainActor () -> Void) {
        self.onIdle = onIdle
    }

    func mapViewCameraIdle(_ mapView: NMFMapView) {
        onIdle()
    }
}

private extension NMGLatLngBounds {
    /// 조회에 쓸 수 있는 범위인지 확인하고 변환한다.
    ///
    /// 지도가 아직 레이아웃되지 않은 순간에는 두 모서리가 같은 점이거나 범위 밖 좌표가 나온다.
    /// 그대로 조회하면 항상 빈 목록이 돌아와 「주변에 방이 없다」로 잘못 보이므로, 거르고
    /// 다음 idle 을 기다린다.
    func toMapBoundsOrNull() -> MapBounds? {
        if !southWest.isValid || !northEast.isValid { return nil }
        if southWest.lat >= northEast.lat || southWest.lng >= northEast.lng { return nil }
        return MapBounds(
            swLat: southWest.lat,
            swLng: southWest.lng,
            neLat: northEast.lat,
            neLng: northEast.lng
        )
    }
}

/// 지도 마커 하나. 오버레이는 `mapView` 프로퍼티로 붙고 떨어지므로 값이 바뀌면 떼었다 다시 붙인다.
///
/// - Parameter caption: 마커 아래 글자. **빈 문자열이면 캡션을 달지 않는다** — `captionText` 의 SDK 기본값이
///   ""(캡션 없음)이므로 아예 세우지 않는 것과 같고, 빈 글자를 넣어 마커 아래에 빈 자리가 생기거나
///   SDK 버전에 따라 빈 라벨이 그려지는 일을 피한다. 호출부는 「인원·정원을 둘 다 모른다」를 이 빈
///   문자열로 넘긴다(`headcountLabel`) — 「0명」처럼 없는 사실을 지도에 박지 않기 위해서다.
private struct ExploreMarker: View {
    let map: NMFMapView?
    let position: LatLng?
    let tint: Color
    let caption: String
    var onClick: (() -> Void)?

    // 콜백은 최신 참조 유지 — 이펙트 키에 넣으면 람다가 새로 생길 때마다 마커가 재생성된다
    @State private var currentOnClick = LatestValue<() -> Void>()

    private struct Key: Equatable {
        let map: ObjectIdentifier?
        let position: LatLng?
        let tint: Color
        let caption: String
    }

    var body: some View {
        let _ = currentOnClick.value = onClick
        DisposableEffect(key: Key(map: map.map(ObjectIdentifier.init), position: position, tint: tint, caption: caption)) {
            guard let map, let position else { return nil }
            let marker = NMFMarker()
            marker.position = position.nmgLatLng
            marker.iconImage = NMF_MARKER_IMAGE_BLACK
            marker.iconTintColor = tint.toUIColor()
            if !caption.isEmpty { marker.captionText = caption }
            let holder = currentOnClick
            marker.touchHandler = { _ in
                // SDK 는 메인 스레드에서 터치를 알린다.
                MainActor.assumeIsolated {
                    let handler = holder.value
                    handler?()
                    return handler != nil // 처리한 클릭만 소비 (내 위치 마커는 지도로 흘려보낸다)
                }
            }
            marker.mapView = map
            return { marker.mapView = nil }
        }
    }
}

private struct ChevronUpIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w * 0.2, y: h * 0.62))
            path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.34))
            path.move(to: CGPoint(x: w * 0.8, y: h * 0.62))
            path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.34))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
            )
        }
        .frame(width: 18, height: 18)
    }
}
