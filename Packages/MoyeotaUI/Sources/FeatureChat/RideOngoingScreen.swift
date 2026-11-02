@preconcurrency import NMapsMap
import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

// 와이어프레임 색 (core token 미정의 — 화면 재현용)
private let ScreenBg = Color(argb: 0xFFF5F7FA)
private let RouteCardBg = Color(argb: 0xFFF1F5FD)
private let RouteLine = Color(argb: 0xFFC9D6EC)
private let RouteDotGray = Color(argb: 0xFFC3CCDA)
private let MuteGray = Color(argb: 0xFF8A93A0)
private let AshGray = Color(argb: 0xFF9AA1AC)
private let SlateGray = Color(argb: 0xFF4B5563)
private let ReportBg = Color(argb: 0xFFFDECEE) // Danger50 동일값 — 와이어프레임 신고 칩 배경
private let ReportRed = Color(argb: 0xFFDC2626) // 와이어프레임 신고 텍스트 (Safety500 동일값, 신고 요소 전용)
private let CardShadow = Color(argb: 0x1A1B2A4A)

/// 26 · 운행 중 — 안심 공유 [S15]
///
/// 이동(디스크립션):
/// - 뒤로 → **14 홈** (onBack). 25 가 아니다 — 25→26 전이가 스택을 걷어내 배차 화면이 남지 않는다.
///   되돌릴 화면이 없는 자리라 홈으로 보낸다(시스템 뒤로가기도 같은 곳에 모은다, `MainNavGraph`).
/// - 「채팅 열기」 → 24 채팅 (onOpenChat)
/// - 「신고」 / 「문제가 생기면 아래에서 바로 신고할 수 있어요」 → 27 긴급 신고 (onReport)
///
/// 33 도착 완료로의 전이는 이 화면에 없다. 기사측 운행 종료를 서버 status 로 관찰하는
/// `RideOngoingRoute` 가 넘긴다 — 화면은 수동 트리거를 두지 않는다(승객이 하차를 선언하는 개념이 아니다).
///
/// 시트 상단: 목적지와 예상 소요(`estimatedMinutes`)가 있으면 「{목적지}까지 약 N분」, 소요가 없으면
/// 「{목적지}(으)로 이동 중」. 경유 순서는 출발지 → 목적지만 시각 없이 보여 준다 — 탑승·도착
/// 시각은 서버가 주지 않는다. 보호자 공유 카드는 보호자 등록·공유 API 가 없어 두지 않는다.
/// 플로우 진행 화면 — 하단탭 없음 (공통 규칙).
///
/// 지도: 출발·도착 마커 + 서버 확정 경로(`routePath`) + 내 현재 위치(파란 점, `myLocation`).
/// 좌표는 `RideOngoingRoute` 가 읽는 방 상세와 기기 위치가 내려준다 — nil 이면 그 요소만 빠진 지도를 그린다.
public struct RideOngoingScreen: View {
    private let originName: String?
    private let destinationName: String?
    private let estimatedMinutes: Int?
    private let originPosition: LatLng?
    private let destinationPosition: LatLng?
    private let routePath: [LatLng]
    private let myLocation: UserCoordinates?
    private let onBack: () -> Void
    private let onOpenChat: () -> Void
    private let onReport: () -> Void

    /// - Parameters:
    ///   - originName: 방 상세의 출발지 이름(`Ride.origin`). nil 이면(방 상세 미수신) 경유 순서 카드를 그리지 않는다
    ///   - destinationName: 방 상세의 목적지 이름(`Ride.destination`)
    ///   - estimatedMinutes: 방 상세의 예상 소요 분(`Ride.estimatedMinutes`). nil 이면 「…(으)로 이동 중」만 보인다
    public init(
        originName: String? = nil,
        destinationName: String? = nil,
        estimatedMinutes: Int? = nil,
        originPosition: LatLng? = nil,
        destinationPosition: LatLng? = nil,
        routePath: [LatLng] = [],
        myLocation: UserCoordinates? = nil,
        onBack: @escaping () -> Void = {},
        onOpenChat: @escaping () -> Void = {},
        onReport: @escaping () -> Void = {}
    ) {
        self.originName = originName
        self.destinationName = destinationName
        self.estimatedMinutes = estimatedMinutes
        self.originPosition = originPosition
        self.destinationPosition = destinationPosition
        self.routePath = routePath
        self.myLocation = myLocation
        self.onBack = onBack
        self.onOpenChat = onOpenChat
        self.onReport = onReport
    }

    public var body: some View {
        let headline = ongoingHeadline(destination: destinationName, estimatedMinutes: estimatedMinutes)

        VStack(spacing: 0) {
            // 헤더 (흰 배경)
            VStack(spacing: 0) {
                StatusBarSpacer()
                HStack(spacing: 0) {
                    Button(action: onBack) {
                        BackArrowIcon(size: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NoIndicationStyle())
                    Spacer().frame(width: 8)
                    Text("운행 중")
                        .moyeotaText(bodyLargeText(18, .bold), color: MoyeotaColor.InkPrimary)
                    Spacer(minLength: 0)
                    ShieldIcon(tint: SlateGray)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .background(MoyeotaColor.SurfaceCanvas)

            // 지도(배경) + 드래그 시트(16·21·14 와 같은 MapSheetScaffold).
            // 펼침(기본) = 예전과 같은 지도 190dp + 목적지·예상 소요 · 경유 순서 · 신고/채팅.
            // 핸들을 내리면 경유 순서 카드가 접혀 **지도가 목적지 줄 위까지 전부** 보인다.
            // 신고·채팅 열기는 푸터라 접힘에서도 항상 보인다.
            MapSheetScaffold(
                mapRevealHeight: OngoingMapRevealHeight,
                collapsedSheetHeight: OngoingCollapsedSheetHeight,
                background: { sheet in
                    RideOngoingMap(
                        originPosition: originPosition,
                        destinationPosition: destinationPosition,
                        routePath: routePath,
                        myLocation: myLocation,
                        // 앵커 기준 시트 높이 — fitBounds·카메라 중심이 시트에 가리지 않는 영역을 쓰게 한다
                        bottomInset: sheet.settledSheetHeight
                    )
                },
                sheetTop: {
                    Text(headline)
                        .moyeotaText(bodyLargeText(20, .bold), color: MoyeotaColor.InkPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .padding(.horizontal, 16)
                    Spacer().frame(height: 12)
                },
                sheetDetail: {
                    sheetDetail
                },
                sheetFooter: {
                    sheetFooter
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ScreenBg)
    }

    @ViewBuilder
    private var sheetDetail: some View {
        // 경유 순서 카드 — 진행 상황 표시 전용. 탭 동작 없음(하차는 기사가 서버에 알린다).
        // 시각은 서버가 주지 않아 표기하지 않는다. 방 상세를 못 받았으면(이름 없음) 카드째 뺀다.
        if let originName, let destinationName {
            Spacer().frame(height: 6)
            ZStack(alignment: .topLeading) {
                // 타임라인 연결선
                RouteLine
                    .frame(width: 3, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .circular))
                    .offset(x: 30, y: 30)
                VStack(spacing: 0) {
                    RouteStepRow(label: "\(originName) · 탑승 완료", state: .done)
                    Spacer(minLength: 0)
                    RouteStepRow(label: "\(withDirectionParticle(word: destinationName)) 이동 중", state: .current)
                }
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(RouteCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .circular))
            .padding(.horizontal, 16)
        }
        Spacer().frame(height: 18)
    }

    @ViewBuilder
    private var sheetFooter: some View {
        // 신고 안내 문구 → 27
        Button(action: onReport) {
            Text("문제가 생기면 아래에서 바로 신고할 수 있어요")
                .moyeotaText(bodyLargeText(12, .medium), color: AshGray)
        }
        .buttonStyle(NoIndicationStyle())
        .frame(maxWidth: .infinity)
        Spacer().frame(height: 10)
        // 고정폭(112·176dp)이면 좁은 폰에서 Row 가 넘쳐 버튼이 찌그러진다 — 남는 폭을 비율로 나눈다
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: 16, style: .circular)
            let available = max(geometry.size.width - 12, 0)
            HStack(spacing: 12) {
                // 「신고」 → 27 긴급 신고
                Button(action: onReport) {
                    HStack(spacing: 0) {
                        WarnTriangleIcon(tint: ReportRed)
                        Spacer().frame(width: 6)
                        Text("신고")
                            .moyeotaText(bodyLargeText(15, .bold), color: ReportRed)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(ReportBg, in: shape)
                }
                .buttonStyle(PressOverlayStyle(shape: shape))
                .frame(width: available * 0.39)

                // 「채팅 열기」 → 24 채팅
                Button(action: onOpenChat) {
                    HStack(spacing: 0) {
                        ChatBubbleIcon(tint: SlateGray)
                        Spacer().frame(width: 7)
                        Text("채팅 열기")
                            .moyeotaText(bodyLargeText(15, .bold), color: SlateGray)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RouteCardBg)
                    .clipShape(shape)
                    .moyeotaShadow(elevation: 4, shape: shape, spotColor: CardShadow)
                }
                .buttonStyle(PressOverlayStyle(shape: shape))
                .frame(width: available * 0.61)
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 16)
        Spacer().frame(height: 14)
        NavigationBarSpacer()
    }
}

/// 펼친 시트 위로 남기는 지도 높이 — 예전 고정 지도(190dp)와 같다
private let OngoingMapRevealHeight: CGFloat = 190

/// 접힘 높이 추정치 = 핸들(36) + 목적지·예상 소요 줄(~60) + 푸터(안내 12 + 버튼 52 + 여백 40 + 내비바 ~24 ≈ 130).
/// 앵커·카메라 계산용 추정치다(실제 높이는 콘텐츠가 정한다).
private let OngoingCollapsedSheetHeight: CGFloat = 230

private enum RouteStepState {
    case done
    case current
}

private struct RouteStepRow: View {
    let label: String
    let state: RouteStepState

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                switch state {
                case .current:
                    Circle()
                        .fill(MoyeotaColor.Primary500)
                        .overlay(Circle().strokeBorder(MoyeotaColor.SurfaceCanvas, lineWidth: 3))
                        .frame(width: 20, height: 20)
                case .done:
                    Circle()
                        .fill(RouteDotGray)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 30)
            Spacer().frame(width: 16)
            Text(label)
                .moyeotaText(
                    bodyLargeText(14, state == .current ? .bold : .medium),
                    color: state == .current ? MoyeotaColor.InkPrimary : MuteGray
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .frame(maxWidth: .infinity)
    }
}

/// 시트 상단 한 줄. 목적지·예상 소요가 다 있으면 「{목적지}까지 약 N분」, 소요가 없으면 「{목적지}(으)로 이동 중」.
/// 방 상세를 아직 못 받았으면(목적지 nil) 「목적지로 이동 중」.
func ongoingHeadline(destination: String?, estimatedMinutes: Int?) -> String {
    guard let destination, !destination.isBlank else { return "목적지로 이동 중" }
    if let estimatedMinutes, estimatedMinutes > 0 {
        return "\(destination)까지 약 \(estimatedMinutes)분"
    }
    return "\(withDirectionParticle(word: destination)) 이동 중"
}

/// 방향 조사 「으로/로」를 붙인다 — 받침이 없거나 ㄹ 받침이면 「로」, 그 외 받침이면 「으로」. 한글이 아니면 「로」
func withDirectionParticle(word: String) -> String {
    // 원본 `trimEnd().lastOrNull()` — Kotlin 문자는 UTF-16 한 칸이고 공백 판정도 Kotlin 것이다.
    // Swift `Character` 로 보면 자모가 풀어 쓰인 글자(NFD)가 완성형으로 합쳐져 받침을 잘못 읽는다.
    guard let last = word.unicodeScalars.last(where: { !$0.isKotlinWhitespace }) else { return word }
    guard (0xAC00...0xD7A3).contains(last.value) else { return "\(word)로" }
    let jong = (last.value - 0xAC00) % 28
    return jong == 0 || jong == 8 ? "\(word)로" : "\(word)으로"
}

// ─── 지도 ────────────────────────────────────────────────────────────────────

/// 출발·도착이 모두 보이게 맞출 때 마커가 지도 가장자리에 붙지 않도록 두는 여백
private let FitBoundsPadding: CGFloat = 40

/// 서버 좌표가 오기 전, 내 위치만으로 카메라를 잡을 때의 줌 — 동네 단위가 보이는 수준
private let MyLocationZoom = 15.0

/// 지금 카메라를 어떻게 움직일까.
enum RideOngoingCameraStep: Equatable {
    case stay
    /// 출발·도착(+내 위치)이 다 보이게 맞춘다
    case fitBounds
    /// 서버 좌표보다 실위치가 먼저 잡혔다 — 우선 내 위치 중심으로
    case centerOnMe
}

/// 카메라는 딱 두 번만 움직인다 — ① 첫 실위치가 잡히면 내 위치 중심(서버 좌표 대기 중 폴백),
/// ② 출발·도착 좌표가 도착하면 내 위치까지 포함한 fitBounds. 그 뒤로는 사용자 팬·줌이 주인이다.
///
/// 둘이 같은 순간에 서면 ② 가 이긴다(원본은 ② 효과가 먼저 돌고 ① 은 `boundsFitted` 를 보고 물러난다).
func rideOngoingCameraStep(
    boundsFitted: Bool,
    centeredOnMe: Bool,
    hasBothEndpoints: Bool,
    hasMyPosition: Bool
) -> RideOngoingCameraStep {
    if boundsFitted { return .stay }
    if hasBothEndpoints { return .fitBounds }
    if hasMyPosition && !centeredOnMe { return .centerOnMe }
    return .stay
}

/// 운행 중 지도. `RouteMapView` 가 출발·도착 마커와 경로를 그리고, 이 뷰는
/// 내 위치 파란 점과 **초기 카메라**(세 지점이 다 보이는 fitBounds)만 얹는다.
///
/// 폴링(8초)·위치 갱신(1초)마다 카메라를 다시 맞추면 지도를 볼 수가 없다
/// (RouteMapView 의 driverPosition 을 center 로 쓰지 않는 것과 같은 이유).
/// 그래서 `RouteMapView` 의 center 도 **상수**로 고정한다 — 기본값(originPosition)을 쓰면
/// 폴링으로 좌표가 도착하는 순간 NaverMapView 가 카메라를 되돌려 fitBounds 를 덮어쓴다.
private struct RideOngoingMap: View {
    let originPosition: LatLng?
    let destinationPosition: LatLng?
    let routePath: [LatLng]
    let myLocation: UserCoordinates?
    /// 시트에 가리는 아래쪽 높이. 지도 contentPadding 으로 넘겨 fitBounds·중심이 보이는 영역 기준이 되게 한다
    let bottomInset: CGFloat

    @State private var map: NMFMapView?
    // 뷰가 살아 있으면 지도가 사용자가 보던 카메라를 들고 있다 —
    // 그 위에 fitBounds 를 또 걸면 보던 위치가 날아가므로 두 플래그를 남긴다
    @State private var boundsFitted = false
    @State private var centeredOnMe = false

    private struct CameraKey: Equatable {
        let map: ObjectIdentifier?
        let origin: LatLng?
        let destination: LatLng?
        let myPosition: LatLng?
    }

    var body: some View {
        let myPosition = latLngOrNull(latitude: myLocation?.latitude, longitude: myLocation?.longitude)
        ZStack {
            RouteMapView(
                routePath: routePath,
                originPosition: originPosition,
                destinationPosition: destinationPosition,
                center: MoyeotaDefaultCamera, // 상수 — 카메라는 아래 효과가 움직인다 (위 설명 참고)
                contentPadding: EdgeInsets(top: 0, leading: 0, bottom: bottomInset, trailing: 0),
                onMapReady: { map = $0 }
            )

            // 내 위치 파란 점 — 합승 탭과 같은 공용 오버레이다(1초 주기 좌표의 등속 보간, 방향을 아는 fix 에만
            // 화살표, 떠날 때 숨김). 오차 원은 넘기지 않는다 — 차량 이동 속도에서는 반경이 정보가 아니라 잡음이다.
            // 원본 렌더에 남는 SDK 기본 원(반경 18, 옅은 파랑)만 같게 그린다.
            if let myPosition {
                MyLocationOverlay(
                    map: map,
                    position: myPosition,
                    bearingDegrees: myLocation?.bearingDegrees,
                    sdkDefaultCircle: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 좌표는 서버가 방 생성 시 확정한 값이라 폴링 주기마다 같은 값이 온다 — 재실행 없음.
        // 위치는 1초마다 바뀌어 다시 들어오지만 카메라는 위 판정에 따라 움직이지 않는다.
        .onChange(
            of: CameraKey(
                map: map.map(ObjectIdentifier.init),
                origin: originPosition,
                destination: destinationPosition,
                myPosition: myPosition
            ),
            initial: true
        ) { _, _ in
            moveCamera(myPosition: myPosition)
        }
    }

    private func moveCamera(myPosition: LatLng?) {
        guard let map else { return }
        let step = rideOngoingCameraStep(
            boundsFitted: boundsFitted,
            centeredOnMe: centeredOnMe,
            hasBothEndpoints: originPosition != nil && destinationPosition != nil,
            hasMyPosition: myPosition != nil
        )
        switch step {
        case .stay:
            break
        case .fitBounds:
            guard let originPosition, let destinationPosition else { return }
            let points = [originPosition, destinationPosition] + (myPosition.map { [$0] } ?? [])
            let latitudes = points.map(\.latitude)
            let longitudes = points.map(\.longitude)
            let bounds = NMGLatLngBounds(
                southWest: NMGLatLng(lat: latitudes.min()!, lng: longitudes.min()!),
                northEast: NMGLatLng(lat: latitudes.max()!, lng: longitudes.max()!)
            )
            let update = NMFCameraUpdate(fit: bounds, padding: FitBoundsPadding)
            update.animation = .easeIn
            map.moveCamera(update)
            boundsFitted = true
        case .centerOnMe:
            guard let myPosition else { return }
            map.moveCamera(NMFCameraUpdate(scrollTo: myPosition.nmgLatLng, zoomTo: MyLocationZoom))
            centeredOnMe = true
        }
    }
}

// ─── 아이콘 (material-icons 미사용 — Canvas 직접 드로잉) ─────────────────────

private struct ShieldIcon: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke: CGFloat = 1.7
            var path = Path()
            path.move(to: CGPoint(x: w * 0.5, y: h * 0.08))
            path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.24))
            path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.52))
            path.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.94), control: CGPoint(x: w * 0.88, y: h * 0.78))
            path.addQuadCurve(to: CGPoint(x: w * 0.12, y: h * 0.52), control: CGPoint(x: w * 0.12, y: h * 0.78))
            path.addLine(to: CGPoint(x: w * 0.12, y: h * 0.24))
            path.closeSubpath()
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
            var check = Path()
            check.move(to: CGPoint(x: w * 0.34, y: h * 0.5))
            check.addLine(to: CGPoint(x: w * 0.46, y: h * 0.62))
            check.move(to: CGPoint(x: w * 0.46, y: h * 0.62))
            check.addLine(to: CGPoint(x: w * 0.68, y: h * 0.36))
            context.stroke(check, with: .color(tint), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
        }
        .frame(width: 20, height: 20)
    }
}

private struct WarnTriangleIcon: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke: CGFloat = 1.6
            var path = Path()
            path.move(to: CGPoint(x: w * 0.5, y: h * 0.12))
            path.addLine(to: CGPoint(x: w * 0.92, y: h * 0.85))
            path.addLine(to: CGPoint(x: w * 0.08, y: h * 0.85))
            path.closeSubpath()
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
            var bar = Path()
            bar.move(to: CGPoint(x: w * 0.5, y: h * 0.4))
            bar.addLine(to: CGPoint(x: w * 0.5, y: h * 0.62))
            context.stroke(bar, with: .color(tint), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            let radius: CGFloat = 1.1
            context.fill(
                Path(ellipseIn: CGRect(
                    x: w * 0.5 - radius,
                    y: h * 0.74 - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(tint)
            )
        }
        .frame(width: 18, height: 18)
    }
}

private struct ChatBubbleIcon: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let stroke: CGFloat = 1.6
            let body = Path(
                roundedRect: CGRect(x: w * 0.08, y: h * 0.12, width: w * 0.84, height: h * 0.62),
                cornerRadius: 4,
                style: .circular
            )
            context.stroke(body, with: .color(tint), style: StrokeStyle(lineWidth: stroke))
            var tail = Path()
            tail.move(to: CGPoint(x: w * 0.28, y: h * 0.74))
            tail.addLine(to: CGPoint(x: w * 0.28, y: h * 0.92))
            tail.addLine(to: CGPoint(x: w * 0.46, y: h * 0.74))
            context.stroke(tail, with: .color(tint), style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
        }
        .frame(width: 19, height: 19)
    }
}
