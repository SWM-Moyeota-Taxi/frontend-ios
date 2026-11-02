import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

// 와이어프레임 그레이 (core token 미정의 색 — 화면 재현용)
private let StageCanvasBg = Color(argb: 0xFFF5F7FA)
private let StageGraySlate = Color(argb: 0xFF4B5563)
private let StageGrayMute = Color(argb: 0xFF8A93A0)
private let StageGrayAsh = Color(argb: 0xFF9AA1AC)
private let StageChipBg = Color(argb: 0xFFF1F5FD)
private let StageCardSoft = Color(argb: 0xFFF6F8FB)
private let StageDividerGray = Color(argb: 0xFFE7EAF0)
private let StageSheetShadow = Color(argb: 0x141B2A4A)

/// 서버가 기사 매칭에 쓰는 제한 시간(분). 백엔드 `MATCHING_TIMEOUT` 과 같은 값이라
/// 문구에 그대로 쓴다 — 넘기면 서버가 방을 CANCELED 로 바꾼다(`RideStatus.canceled`).
private let MATCHING_TIMEOUT_MINUTES = 3

/// 도착 예정 시간을 어림할 때 쓰는 평균 시내 주행 속도(km/h).
///
/// 직선거리 기반이라 **어림값이다.** 서버가 기사→탑승지 ETA 를 주면 그 값으로 갈아 끼워야 한다
/// (지금은 그런 API 가 없다). 실도로는 직선보다 길고 신호가 있어, 25km/h 는 그 둘을 함께 눌러 담은 값이다.
private let PICKUP_SPEED_KMH = 25.0

/// 25b · 기사 찾는 중 (서버 status `MATCHING`)
///
/// 정원이 차서 서버가 주변 기사에게 요청을 돌리는 단계다. 앱이 할 일은 없고 **기다림 자체가 화면의
/// 내용**이라, 지도 대신 `RadarSearchArea` 를 쓴다(기사 위치는 아직 없고, 경로는 21 에서 이미 봤다).
///
/// **취소 버튼을 두지 않는다.** 서버가 MATCHING 상태에서 leave 를 허용하는지 확인되지 않았다 —
/// 눌리는 버튼을 두고 실패하는 것보다, 3분 뒤 타임아웃으로 `DriverSearchFailedScreen` 을 보여 주는 편이 낫다.
public struct DriverSearchScreen: View {
    /// 그릴 방. **기본값이 없다** — 예시 방이 프로덕션에 새는 길을 막는다.
    private let ride: Ride
    private let onOpenChat: (() -> Void)?
    private let onBack: () -> Void

    /// - Parameters:
    ///   - onOpenChat: 이 방의 채팅방을 연다(독립 목적지 push — 뒤로가기로 여기 복귀). 아직 방이 없으면 nil
    ///   - onBack: 헤더 뒤로가기. 배차 단계라 기본은 무동작이다(공통 규칙: 배차 후 되돌리기 차단)
    public init(
        ride: Ride,
        onOpenChat: (() -> Void)? = nil,
        onBack: @escaping () -> Void = {}
    ) {
        self.ride = ride
        self.onOpenChat = onOpenChat
        self.onBack = onBack
    }

    public var body: some View {
        StageScaffold(title: "기사님 찾는 중", onBack: onBack) {
            RadarSearchArea()
                .frame(maxWidth: .infinity)
                .frame(height: 220)

            StageSheet {
                Text("주변 기사님에게 요청하고 있어요")
                    .moyeotaText(inlineType(22, .bold), color: MoyeotaColor.InkPrimary)
                Spacer().frame(height: 4)
                // 「보통 1분 안에 배정돼요」는 지웠다 — 근거가 될 배차 소요 통계가 없다(21 의
                // 「보통 2분 안에 모여요」와 같은 이유). 최대 시간은 서버가 실제로 지킨다 —
                // `DispatchService.MATCHING_TIMEOUT = 3분`, `MatchingSweeper` 가 넘으면 취소한다.
                Text("최대 \(MATCHING_TIMEOUT_MINUTES)분까지 기다려요")
                    .moyeotaText(inlineType(13, .medium), color: StageGrayMute)
                Spacer().frame(height: 16)

                RideSummaryCard(ride: ride, showDestination: true)
                Spacer().frame(height: 16)

                NoticeBanner(kind: .waiting, text: "기사님이 수락하면 바로 알려드려요")

                // 정원이 찬 뒤라 동승자와 말을 맞출 일이 생기는 단계다 — 채팅방이 있으면 바로 연다.
                if let onOpenChat {
                    Spacer().frame(height: 16)
                    OpenChatButton(onClick: onOpenChat)
                }
            }
        }
    }
}

/// 25b-실패 · 기사 매칭 타임아웃 (서버 status `CANCELED`)
///
/// 서버가 `MATCHING_TIMEOUT_MINUTES` 안에 기사를 못 찾으면 방을 스스로 취소한다. 그 방은 이미
/// 없어졌으므로 재시도는 **새 방을 만드는 것**뿐이다 — 그래서 「다시 찾기」는 홈으로 보낸다.
public struct DriverSearchFailedScreen: View {
    private let onRetry: () -> Void
    private let onBack: () -> Void

    public init(onRetry: @escaping () -> Void = {}, onBack: @escaping () -> Void = {}) {
        self.onRetry = onRetry
        self.onBack = onBack
    }

    public var body: some View {
        StageScaffold(title: "기사님 찾는 중", onBack: onBack) {
            ZStack {
                StageCanvasBg
                CarIcon()
                    .frame(width: 88, height: 88)
                    .background(StageChipBg, in: Circle())
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)

            StageSheet {
                Text("기사님을 찾지 못했어요")
                    .moyeotaText(inlineType(22, .bold), color: MoyeotaColor.InkPrimary)
                Spacer().frame(height: 4)
                Text("\(MATCHING_TIMEOUT_MINUTES)분 동안 수락한 기사님이 없어 요청이 취소됐어요")
                    .moyeotaText(inlineType(13, .medium), color: StageGrayMute)
                Spacer().frame(height: 16)
                NoticeBanner(kind: .info, text: "다시 찾으면 같은 조건으로 새 방을 만들어요")
                Spacer().frame(height: 20)
                PrimaryCtaButton(text: "다시 찾기", onClick: onRetry)
            }
        }
    }
}

/// 25c · 배정 완료 (서버 status `DRIVER_ASSIGNED` 진입 직후 1회)
///
/// 「배정됐다」는 사실만 확실히 전하고 25 배차 상태로 넘기는 **한 번짜리 확인 화면**이다.
/// 재진입 시에는 이 화면을 건너뛰고 25 로 직행한다(`DispatchStatusRoute` 의 플래그).
///
/// 기사 **이름·별점은 그리지 않는다** — 백엔드 `DriverSummary` 에 필드 자체가 없다.
/// 차량 번호·차종·인승만 서버가 준 값이며, 그 자리에 그럴듯한 이름을 지어내지 않는다.
public struct DriverAssignedScreen: View {
    /// 그릴 방. **기본값이 없다** — 예시 방이 프로덕션에 새는 길을 막는다.
    private let ride: Ride
    private let driver: AssignedDriver?
    private let driverLocation: DriverLocation?
    private let myLocation: UserCoordinates?
    private let pickupEtaMinutes: Int?
    private let onSeeDispatch: () -> Void
    private let onOpenChat: (() -> Void)?
    private let onBack: () -> Void

    /// - Parameters:
    ///   - driverLocation: 폴링으로 갱신되는 기사 위치. 아직 보고 전이면 nil — 마커 없이 탑승지·내 위치만 그린다
    ///   - myLocation: 내 실위치. 권한이 없거나 fix 전이면 nil
    ///   - pickupEtaMinutes: 기사 위치 → 탑승지 직선거리로 어림한 도착 예정(분). 위치를 아직
    ///     못 받았으면 nil 이고, 그때는 시간 대신 「탑승 위치로 오고 있어요」만 쓴다
    ///   - onOpenChat: 이 방의 채팅방을 연다(독립 목적지 push). 아직 방이 없으면 nil
    public init(
        ride: Ride,
        driver: AssignedDriver? = nil,
        driverLocation: DriverLocation? = nil,
        myLocation: UserCoordinates? = nil,
        pickupEtaMinutes: Int? = nil,
        onSeeDispatch: @escaping () -> Void = {},
        onOpenChat: (() -> Void)? = nil,
        onBack: @escaping () -> Void = {}
    ) {
        self.ride = ride
        self.driver = driver
        self.driverLocation = driverLocation
        self.myLocation = myLocation
        self.pickupEtaMinutes = pickupEtaMinutes
        self.onSeeDispatch = onSeeDispatch
        self.onOpenChat = onOpenChat
        self.onBack = onBack
    }

    public var body: some View {
        StageScaffold(title: "배정 완료", onBack: onBack) {
            PickupStageLayout {
                PickupMap(
                    pickupPosition: latLngOrNull(latitude: ride.originLat, longitude: ride.originLng),
                    driverPosition: latLngOrNull(latitude: driverLocation?.latitude, longitude: driverLocation?.longitude),
                    myPosition: latLngOrNull(latitude: myLocation?.latitude, longitude: myLocation?.longitude)
                )

                StageSheet {
                    Text("기사님이 배정됐어요")
                        .moyeotaText(inlineType(22, .bold), color: MoyeotaColor.InkPrimary)
                    Spacer().frame(height: 4)
                    Text(
                        pickupEtaMinutes.map { "약 \($0)분 뒤 탑승 위치 도착 예정" } ?? "탑승 위치로 오고 있어요"
                    )
                    .moyeotaText(inlineType(13, .medium), color: StageGrayMute)
                    Spacer().frame(height: 16)

                    // 차량 카드 — 서버가 주는 값(번호판·차종·인승)만 쓴다
                    VehicleCard(
                        vehicleNumber: driver?.plateNumber ?? "차량 번호 확인 중",
                        vehicleModel: vehicleLabel(driver: driver),
                        chipColor: StageChipBg,
                        modelColor: StageGraySlate
                    )
                    Spacer().frame(height: 16)

                    RideSummaryCard(ride: ride, showDestination: false)
                    Spacer().frame(height: 16)

                    Text("기사님 정보를 확인하고 탑승 위치로 이동하세요")
                        .moyeotaText(inlineType(12, .medium), color: StageGrayAsh)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Spacer().frame(height: 16)
                    PrimaryCtaButton(text: "배차 상태 보기", onClick: onSeeDispatch)
                    if let onOpenChat {
                        Spacer().frame(height: 10)
                        OpenChatButton(onClick: onOpenChat)
                    }
                }
            }
        }
    }
}

/// 25c 상단 지도 높이(dp). 시트(차량 카드·요약 카드·CTA)가 아래에 다 들어가는 선에서 최대
private let PickupMapHeightDp: CGFloat = 220

/// `PickupMapHeightDp` 주석의 규칙을 기기마다 지킨 지도 높이. 원본은 220 고정이고 그 렌더(높이 914dp)에서는 시트가 다 들어간다.
/// iPhone 은 더 낮아 220 이면 마지막 버튼이 홈 인디케이터 영역으로 내려가므로, 그만큼만 지도를 줄인다.
///
/// - Parameters:
///   - available: 헤더 아래 지도와 시트가 나눠 쓰는 높이
///   - sheetMinimum: 시트 내용과 아래 인셋을 합친 높이
func pickupMapHeight(available: CGFloat, sheetMinimum: CGFloat) -> CGFloat {
    min(PickupMapHeightDp, max(available - sheetMinimum, 0))
}

/// 25c 의 지도(첫째) + 시트(둘째) 세로 배치. 시트 최소 높이를 재서 지도 높이를 정하고, 나머지는 시트가 갖는다.
private struct PickupStageLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let sheetMinimum = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: 0)).height
        let mapHeight = pickupMapHeight(available: bounds.height, sheetMinimum: sheetMinimum)
        subviews[0].place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: mapHeight)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + mapHeight),
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height - mapHeight)
        )
    }
}

/// 어떤 점들이 있는가(있음/없음 조합)와 지도 높이 — `PickupMap` 카메라의 키.
/// 높이가 바뀌면 처음 구한 카메라로는 점이 지도 밖으로 나갈 수 있다(`pickupMapHeight`).
private struct PickupAvailability: Equatable {
    let pickup: Bool
    let driver: Bool
    let my: Bool
    let height: CGFloat
}

/// 25c 상단 지도 — **탑승지 · 기사님 · 내 위치** 세 점. 도착지·경로는 그리지 않는다(21 에서 이미 봤고,
/// 이 단계의 관심은 "기사님이 어디쯤 오고 있고 나는 탑승지에서 얼마나 떨어져 있나"뿐이다).
///
/// 카메라는 **점이 새로 생길 때만** 다시 맞춘다. 기사 위치는 폴링마다, 내 위치는 1초마다 바뀌는데
/// 그때마다 fit 을 다시 걸면 지도를 볼 수가 없다(26 RideOngoingMap 과 같은 이유). 그래서
/// "어떤 점들이 있는가"(있음/없음 조합)를 키로 삼아 — 탑승지만 → 기사 등장 → 내 위치 등장 —
/// 최대 세 번만 카메라를 옮기고, 그 뒤 마커는 자리를 옮겨도 카메라는 그대로 둔다.
///
/// 점이 하나뿐이면 fit 을 구할 수 없어 그 점을 중심으로 동네 단위 줌을 쓴다.
private struct PickupMap: View {
    let pickupPosition: LatLng?
    let driverPosition: LatLng?
    let myPosition: LatLng?

    // 같은 조합이 유지되는 동안은 처음 구한 카메라를 붙든다 (좌표 갱신은 마커만 움직인다)
    @State private var camera = Remembered<PickupAvailability, (first: LatLng, second: Double)?>()

    var body: some View {
        GeometryReader { geometry in
            let availability = PickupAvailability(
                pickup: pickupPosition != nil,
                driver: driverPosition != nil,
                my: myPosition != nil,
                height: geometry.size.height
            )
            let fitted = camera.value(key: availability) {
                let points = [pickupPosition, driverPosition, myPosition].compactMap { $0 }
                return fitMapCamera(
                    points: points,
                    widthDp: Float(geometry.size.width),
                    heightDp: Float(geometry.size.height)
                ) ?? points.first.map { (first: $0, second: SinglePointZoom) }
            }
            RouteMapView(
                driverPosition: driverPosition,
                originPosition: pickupPosition,
                myPosition: myPosition,
                center: fitted?.first ?? (pickupPosition ?? driverPosition ?? myPosition ?? MoyeotaDefaultCamera),
                zoom: fitted?.second ?? SinglePointZoom
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(StageCanvasBg)
    }
}

/// 점이 하나뿐일 때의 줌 — 동네 단위가 보이는 수준 (26 의 MyLocationZoom 과 같은 값)
private let SinglePointZoom = 15.0

/// 기사 위치 → 탑승지 **직선거리**로 어림한 도착 예정(분). 좌표가 없으면 nil.
///
/// 서버에 기사 ETA API 가 없어 앱이 어림한다. 직선거리라 실제보다 짧게 나오므로
/// `PICKUP_SPEED_KMH` 를 실제 주행 속도보다 낮게 잡아 상쇄한다. 0분은 쓰지 않는다 —
/// 「약 0분 뒤 도착」은 정보가 아니라 오류처럼 읽힌다.
public func pickupEtaMinutes(distanceMeters: Double?) -> Int? {
    guard let distanceMeters, distanceMeters.isFinite, distanceMeters >= 0.0 else { return nil }
    let minutes = (distanceMeters / 1000.0) / PICKUP_SPEED_KMH * 60.0
    // 원본 `roundToInt` 는 Int(32비트) 범위에서 포화한다. Swift `Int(_:)` 는 넘치면 앱이 죽는다.
    return max(Int(min(minutes.rounded(), Double(Int32.max))), 1)
}

/// 차종 · 인승. 인승을 모르면 차종만 쓴다 — 「?인승」을 쓰지 않는다.
private func vehicleLabel(driver: AssignedDriver?) -> String {
    guard let driver else { return "차량 정보를 불러오는 중이에요" }
    if let seats = driver.seats { return "\(driver.vehicleType) · \(seats)인승" }
    return driver.vehicleType
}

/// 25b·25c 가 공유하는 정보 카드 — 탑승 위치 · (도착지) · 동승자 · 1인 부담
private struct RideSummaryCard: View {
    let ride: Ride
    let showDestination: Bool

    var body: some View {
        VStack(spacing: 0) {
            DispatchInfoRow(label: "탑승 위치", value: ride.origin)
            HorizontalDivider(color: StageDividerGray)
            if showDestination {
                DispatchInfoRow(label: "도착지", value: ride.destination)
                HorizontalDivider(color: StageDividerGray)
            }
            // 아직 차에 타기 전이라 「누구와」보다 「몇 명이」가 필요한 자리다(닉네임 나열은 25 에서 한다)
            DispatchInfoRow(label: "동승자", value: "나 포함 \(ride.members.count)명")
            HorizontalDivider(color: StageDividerGray)
            DispatchInfoRow(
                label: "1인 부담",
                value: wonLabel(amount: ride.farePerPerson),
                valueColor: MoyeotaColor.Primary500
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(StageCardSoft, in: RoundedRectangle(cornerRadius: 18, style: .circular))
    }
}

/// 25b·25c 공통 뼈대 — 흰 헤더 + 상단 그림 + 시트
private struct StageScaffold<Content: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                StatusBarSpacer()
                HStack(spacing: 0) {
                    MatchingBackButton(onBack: onBack)
                    Text(title)
                        .moyeotaText(inlineType(18, .bold), color: MoyeotaColor.InkPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .background(MoyeotaColor.SurfaceCanvas)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StageCanvasBg)
    }
}

private struct StageSheet<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .circular)
        VStack(spacing: 0) {
            SheetHandle()
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 10)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            // 원본 `Column` 은 넘쳐도 줄이지 않고 잘라 낸다. SwiftUI 는 글자를 줄이려 들어 높이를 고정한다.
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MoyeotaColor.SurfaceCanvas)
        .clipShape(shape)
        .moyeotaShadow(elevation: 14, shape: shape, spotColor: StageSheetShadow)
    }
}
