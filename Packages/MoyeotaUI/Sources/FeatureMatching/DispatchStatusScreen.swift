import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

// 와이어프레임 그레이 (core token 미정의 색 — 화면 재현용)
private let CanvasBg = Color(argb: 0xFFF5F7FA)
private let GraySlate = Color(argb: 0xFF4B5563)
private let GrayMute = Color(argb: 0xFF8A93A0)
private let ChipBg = Color(argb: 0xFFF1F5FD)
private let CardSoft = Color(argb: 0xFFF6F8FB)
private let DividerGray = Color(argb: 0xFFE7EAF0)

/// 25 · 배차 상태 [S14]
///
/// 진입: 22 「이 인원으로 출발」 또는 21 매칭 대기의 status 전이(DISPATCHING)
/// — 공통 규칙상 배차 이후 스택 초기화, 화면은 콜백만 노출
///
/// 이동(디스크립션):
/// - 26 운행 중으로의 전이는 **이 화면이 하지 않는다**. 기사측 탑승 처리(서버 status IN_RIDE)를
///   `DispatchStatusRoute` 의 폴링이 잡아 자동으로 넘긴다. 임시 트리거였던 화면 전체 탭은
///   폴링이 실동작하게 되면서 걷어냈다(오탭하면 탑승 전에 26 으로 넘어갔다 — 결함 D-9 수정).
///   26 의 「경유 카드 탭」을 걷어낸 것과 같은 이유다(35 보고서).
/// - 「채팅 열기」 → 24 채팅방(독립 목적지 push — 뒤로가기로 여기 복귀). `onOpenChat` 이 nil 이면 그리지 않는다
/// - 차량 번호 롱프레스 → 복사 [미연결]
/// - 뒤로 → [미연결] 배차 후 되돌리기 차단 권장 (onBack — 무동작 기본값)
/// - 배차 실패 시 21 매칭 대기로 되돌리고 재탐색 (호출부 처리)
///
/// 서버 제약: 백엔드 `DriverSummary` 는 (좌석수 · 번호판 · 차종) 뿐이라
/// **기사 이름·별점·연락처를 내려주지 않는다**. 차량 카드는 서버 값(번호판 · 차종 · 좌석수)만 보여 주고,
/// 기사 정보 자리표시와 전화 버튼은 두지 않는다.
public struct DispatchStatusScreen: View {
    /// 그릴 방. **기본값이 없다** — 방을 모르는 호출부(구성 변경에 방 id 가 날아간 25)가 `ride` 없이 부르면
    /// 남의 가짜 배차 현황이 뜨던 사고(출시 차단 결함, 2026-10-15) 때문에 원본에서 걷어냈다.
    private let ride: Ride
    private let driver: AssignedDriver?
    private let driverLocation: DriverLocation?
    private let myLocation: UserCoordinates?
    private let onOpenChat: (() -> Void)?
    private let onBack: () -> Void

    @State private var routeMemo = Remembered<String?, [LatLng]>()

    /// - Parameters:
    ///   - myLocation: 내 실위치. 지도에 파란 점으로만 얹는다 — 없으면(권한 없음·fix 전) 점 없이 마커만
    ///   - onOpenChat: 이 방의 채팅방을 연다. 아직 방이 없으면 nil — 버튼 자체를 그리지 않는다
    ///   - onBack: 미연결 (배차 후 되돌리기 차단 권장)
    public init(
        ride: Ride,
        driver: AssignedDriver? = nil,
        driverLocation: DriverLocation? = nil,
        myLocation: UserCoordinates? = nil,
        onOpenChat: (() -> Void)? = nil,
        onBack: @escaping () -> Void = {}
    ) {
        self.ride = ride
        self.driver = driver
        self.driverLocation = driverLocation
        self.myLocation = myLocation
        self.onOpenChat = onOpenChat
        self.onBack = onBack
    }

    public var body: some View {
        let pickupSpot = ride.origin
        // 기사 위치는 값이 있어도 좌표로 못 쓸 수 있다(서버 위경도 전치 — QA D-1).
        // 지도 마커와 아래 안내 문구가 **같은 판정**을 쓰도록 여기서 한 번만 검증한다.
        let driverPosition = latLngOrNull(latitude: driverLocation?.latitude, longitude: driverLocation?.longitude)
        let vehicleNumber = driver?.plateNumber ?? "차량 번호 확인 중"
        let vehicleModel: String = {
            guard let driver else { return "차량 정보를 불러오는 중이에요" }
            if let seats = driver.seats { return "\(driver.vehicleType) · \(seats)인승" }
            return driver.vehicleType
        }()
        // 동승자 = 나를 뺀 멤버(isMe = publicId == 세션 uuid). 탈퇴 회원은 이름이 없어 그렇게 적는다.
        let partners = ride.members.filter { !$0.isMe }
        let partnerLabel = partners.isEmpty
            ? "나 혼자 탑승"
            : partners.map(\.displayNickname).joined(separator: ", ") + " · 나 포함 \(ride.members.count)명"
        // 지도 — 서버 경로 폴리라인 + 폴링으로 갱신되는 기사 위치 마커.
        // 경로는 방 상세의 routePolyline 을 쓴다. 방이 이미 만들어진 뒤라 서버가 확정한 경로가
        // 있으므로, 좌표만으로 추정하는 previewRoute(16 도착지 확인에서 쓴다)를 부를 이유가 없다.
        let routePath = routeMemo.value(key: ride.routePolyline) {
            ride.routePolyline.map { decodePolyline(encoded: $0) } ?? []
        }
        let sheetShape = UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .circular)

        VStack(spacing: 0) {
            // 상단 흰색 헤더
            VStack(spacing: 0) {
                StatusBarSpacer()
                HStack(spacing: 0) {
                    MatchingBackButton(onBack: onBack)
                    Text("택시 오는 중")
                        .moyeotaText(inlineType(18, .bold), color: MoyeotaColor.InkPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .background(MoyeotaColor.SurfaceCanvas)

            RouteMapView(
                routePath: routePath,
                driverPosition: driverPosition, // 범위를 벗어난 좌표면 nil → 마커 미표시
                originPosition: latLngOrNull(latitude: ride.originLat, longitude: ride.originLng),
                destinationPosition: latLngOrNull(latitude: ride.destinationLat, longitude: ride.destinationLng),
                myPosition: latLngOrNull(latitude: myLocation?.latitude, longitude: myLocation?.longitude)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 176)

            // 바텀시트
            VStack(spacing: 0) {
                SheetHandle()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 10)
                    Text(driver == nil ? "기사님을 배정하고 있어요" : "기사님이 오고 있어요")
                        .moyeotaText(inlineType(22, .bold), color: MoyeotaColor.InkPrimary)
                    Spacer().frame(height: 4)
                    // 기사가 아직 위치를 보고하지 않았을 수 있다 — 정상 상황이라 에러로 다루지 않는다.
                    // 좌표가 못 쓸 값이어도(D-1) 마커를 못 그리므로 「받아오는 중」을 유지한다.
                    Text(
                        driverPosition == nil
                            ? "\(pickupSpot) 앞에서 만나요 · 기사님 위치를 받아오는 중"
                            : "\(pickupSpot) 앞에서 만나요"
                    )
                    .moyeotaText(inlineType(13, .medium), color: GrayMute)
                    Spacer().frame(height: 16)

                    // 차량 카드
                    VehicleCard(
                        vehicleNumber: vehicleNumber,
                        vehicleModel: vehicleModel,
                        chipColor: ChipBg,
                        modelColor: GraySlate
                    )
                    Spacer().frame(height: 16)

                    // 탑승 정보 카드
                    VStack(spacing: 0) {
                        DispatchInfoRow(label: "탑승 위치", value: pickupSpot)
                        HorizontalDivider(color: DividerGray)
                        DispatchInfoRow(label: "도착지", value: ride.destination)
                        HorizontalDivider(color: DividerGray)
                        // 서버가 닉네임을 주므로 "나 포함 N명" 대신 누구와 타는지를 쓴다 —
                        // 차에 타기 직전 화면이라 인원수보다 이름이 필요한 자리다.
                        DispatchInfoRow(label: "동승자", value: partnerLabel)
                        HorizontalDivider(color: DividerGray)
                        if let estimatedMinutes = ride.estimatedMinutes {
                            DispatchInfoRow(label: "예상 소요", value: "\(estimatedMinutes)분")
                            HorizontalDivider(color: DividerGray)
                        }
                        DispatchInfoRow(
                            label: "1인 부담",
                            value: wonLabel(amount: ride.farePerPerson),
                            valueColor: MoyeotaColor.Primary500
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(CardSoft, in: RoundedRectangle(cornerRadius: 18, style: .circular))
                    if let onOpenChat {
                        Spacer().frame(height: 16)
                        OpenChatButton(onClick: onOpenChat)
                    }
                    // 「기사님 도착 후 3분간 기다려요」는 지웠다(2026-10-13) — 그런 대기 정책이 없다.
                    // 백엔드에 승객 대기 시간 개념이 아예 없고(기사 도착 통보 → 운행 시작 두 단계뿐:
                    // `RideController`), 앱도 타이머를 돌리지 않았다. 지킬 주체가 없는 약속이라
                    // 대체 문구를 두지 않고 줄을 비웠다.
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                // 원본 `Column` 은 넘쳐도 줄이지 않고 잘라 낸다. SwiftUI 는 글자를 줄이려 들어 높이를 고정한다.
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            // `minHeight: 0` 이 없으면 넘치는 내용이 시트 높이를 밀어 화면 전체가 커지고, 가운데 정렬로 상단바가 상태바 밑으로 올라간다.
            // 원본 `weight(1f)` 는 남은 높이를 넘지 않아 위는 그대로이고 시트 아래만 잘린다.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .background(MoyeotaColor.SurfaceCanvas)
            .clipShape(sheetShape)
            .moyeotaShadow(elevation: 14, shape: sheetShape, spotColor: Color(argb: 0x141B2A4A))

            NavigationBarSpacer()
                .frame(maxWidth: .infinity)
                .background(MoyeotaColor.SurfaceCanvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBg)
    }
}

/// 머티리얼 `IconButton` 자리 — 레이아웃 크기는 최소 터치 영역인 48dp 다.
struct MatchingBackButton: View {
    let onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            BackArrowIcon()
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(IconPressStyle())
    }
}

/// 25·25c 의 차량 카드 — 서버가 주는 값(번호판·차종·인승)만 쓴다.
struct VehicleCard: View {
    let vehicleNumber: String
    let vehicleModel: String
    let chipColor: Color
    let modelColor: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .circular)
        HStack(spacing: 0) {
            CarIcon()
                .frame(width: 64, height: 64)
                .background(chipColor, in: RoundedRectangle(cornerRadius: 16, style: .circular))
            Spacer().frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(vehicleNumber)
                    .moyeotaText(inlineType(17, .bold), color: MoyeotaColor.InkPrimary)
                Text(vehicleModel)
                    .moyeotaText(inlineType(13, .medium), color: modelColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(MoyeotaColor.SurfaceCanvas)
        .clipShape(shape)
        .moyeotaShadow(elevation: 4, shape: shape, spotColor: Color(argb: 0x0F1B2A4A))
    }
}

struct DispatchInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = MoyeotaColor.InkPrimary

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .moyeotaText(inlineType(14, .medium), color: MoyeotaColor.TextMute)
                .fixedSize()
            Spacer().frame(width: 12)
            // 값 쪽이 길어질 수 있다(동승자 닉네임 나열·전체 주소) — 라벨을 밀어내는 대신 말줄임한다
            Text(value)
                .moyeotaText(inlineType(14, .bold), color: valueColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }
}

// ─── 아이콘 (머티리얼 아이콘 미사용 — Canvas 직접 드로잉) ─────────────────────

struct CarIcon: View {
    var tint: Color = Color(argb: 0xFF54637D)

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke = StrokeStyle(lineWidth: 1.8, lineCap: .round)
            // 차체
            context.stroke(
                Path(
                    roundedRect: CGRect(x: w * 0.05, y: h * 0.4, width: w * 0.9, height: h * 0.42),
                    cornerRadius: 4,
                    style: .circular
                ),
                with: .color(tint),
                style: stroke
            )
            // 지붕
            var roof = Path()
            roof.move(to: CGPoint(x: w * 0.28, y: h * 0.4))
            roof.addLine(to: CGPoint(x: w * 0.38, y: h * 0.1))
            roof.move(to: CGPoint(x: w * 0.38, y: h * 0.1))
            roof.addLine(to: CGPoint(x: w * 0.68, y: h * 0.1))
            roof.move(to: CGPoint(x: w * 0.68, y: h * 0.1))
            roof.addLine(to: CGPoint(x: w * 0.78, y: h * 0.4))
            context.stroke(roof, with: .color(tint), style: stroke)
            // 바퀴
            for x in [w * 0.25, w * 0.75] {
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 2.5, y: h * 0.86 - 2.5, width: 5, height: 5)),
                    with: .color(tint)
                )
            }
        }
        .frame(width: 40, height: 24)
    }
}
