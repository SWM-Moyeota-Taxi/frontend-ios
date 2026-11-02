import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

// 와이어프레임 그레이·서페이스 (core token 미정의 색 — 화면 재현용)
private let CanvasBg = Color(argb: 0xFFF5F7FA)
private let GrayMute = Color(argb: 0xFF8A93A0)
private let GrayAsh = Color(argb: 0xFF9AA1AC)
private let GraySlateDeep = Color(argb: 0xFF54637D)
private let TextMuteWarm = Color(argb: 0xFF6B7280)
private let RouteCardBg = Color(argb: 0xFFF1F5FD)
private let FareCardBg = Color(argb: 0xFFF6F8FB)
private let PillBg = Color(argb: 0xFFF1F5FD)

// 모양은 전부 `style: .circular` 로 쓴다. 원본 `CircleShape`·`RoundedCornerShape` 는 원호인데 SwiftUI 기본값은
// `.continuous` 라 모서리가 달라지고, 알약(`Capsule`)은 좌우 끝이 뾰족해진다.

/// 원본 `"%,d원".format(amount)` — 천 단위 구분은 원본처럼 기기 로케일을 따른다.
func won(amount: Int, locale: Locale = .current) -> String {
    "\(amount.formatted(.number.locale(locale).grouping(.automatic)))원"
}

/// 20 · 합류 확인 [신규]
///
/// 진입: 18·19 목록/마커의 「합류」
///
/// 이동(디스크립션):
/// - 「닫기」 / 뒤로가기 → 직전 목록(18/19)으로 복귀 (onDismiss)
/// - 「이 탑승에 합류하기」 → 22 탑승 상세 (onConfirmJoin, 제출 중 loading)
/// - 동승자 행 탭 → 23 동승자 프로필 (onMemberClick)
///
/// 표시 값은 전부 방 상세(`Ride`)에서 나온다. 서버가 주지 않는 값(성별 조건·탑승 시각·서비스 요금)은
/// 지어내지 않고 그 요소를 아예 두지 않는다 — 출발 표기는 `Ride.departureLabel` 이 있을 때만,
/// 도착 쪽은 `Ride.estimatedMinutes` 가 있을 때만 「약 N분」으로 보이고, 1인 부담은 `Ride.farePerPerson` 그대로다.
///
/// 검증·상태 — **판정은 `joinGate` 하나**이고 배지·배너·CTA 가 모두 그 결과를 따른다:
/// - 상태 배지는 `Ride.status` 를 그대로 읽는다(`joinStatusBadge`) — 예전에는 문자열 리터럴이라
///   **취소된 방에도 「모집 중」**이 떠 있었다. 17 목록은 4초 주기라 방을 고르는 사이에 마지막 멤버가
///   나가 방이 닫힐 수 있다(`Party.leave` → `members.isEmpty()` → `cancel()`)
/// - 모집 중이 아니거나 정원이 찼으면 CTA 비활성 + CTA 위 NoticeBanner(ERROR) **한 줄**
///   (배너는 **하나만** 띄운다 — 예전에는 「방금 인원이 찼어요」와 서버 실패 문구가 거의 같은 말을
///   두 번 했다: `refreshQuietly()` 가 성공하면 둘이 함께 떴다)
/// - 내가 이미 그 방 멤버면 「이미 참여 중인 방이에요」 + CTA 는 그 방으로 돌아가기(`onOpenJoinedRide`)
/// - 서버 합류 실패(엔드포인트 부재 포함) 시 joinErrorMessage 를 같은 자리에 그대로 노출
public struct JoinConfirmScreen: View {
    private let ride: Ride
    private let pickupDistanceMeters: Double?
    private let joining: Bool
    private let joinErrorMessage: String?
    private let onDismiss: () -> Void
    private let onConfirmJoin: (Ride) -> Void
    private let onOpenJoinedRide: (Ride) -> Void
    private let onMemberClick: (User) -> Void

    /// - Parameters:
    ///   - pickupDistanceMeters: 내 위치 → 이 방의 탑승 위치 거리(m). 모르면 nil 이고 그 줄을 감춘다.
    ///     「도보 N분」은 쓰지 않는다 — 보행 속도를 지어내야 하고, 거리와 달리 잰 값이 아니다.
    ///   - onOpenJoinedRide: 내가 이미 이 방 멤버일 때의 CTA — 호출부가 그 방의 진행 화면(21)으로 보낸다.
    ///     Route 는 합류 성공과 **같은 길**(`JoinConfirmRoute` 의 onJoined)로 넘긴다: 서버가 409
    ///     `ALREADY_JOINED` 를 돌려줄 때 이미 그렇게 처리하고 있어서
    ///     (`PartyJoinException.isAlreadyInThisParty`) 새 네비게이션이 필요 없다.
    ///     기본값은 방어용 빈 클로저다 — 연결하지 않은 호출부에서는 버튼이 아무 일도 하지 않는다.
    public init(
        ride: Ride,
        pickupDistanceMeters: Double? = nil,
        joining: Bool = false,
        joinErrorMessage: String? = nil,
        onDismiss: @escaping () -> Void = {},
        onConfirmJoin: @escaping (Ride) -> Void = { _ in },
        onOpenJoinedRide: @escaping (Ride) -> Void = { _ in },
        onMemberClick: @escaping (User) -> Void = { _ in }
    ) {
        self.ride = ride
        self.pickupDistanceMeters = pickupDistanceMeters
        self.joining = joining
        self.joinErrorMessage = joinErrorMessage
        self.onDismiss = onDismiss
        self.onConfirmJoin = onConfirmJoin
        self.onOpenJoinedRide = onOpenJoinedRide
        self.onMemberClick = onMemberClick
    }

    public var body: some View {
        let joinedCount = ride.members.count
        // 내가 이미 이 방의 멤버인가. 「나」 판정의 근거는 서버가 멤버마다 실어 주는 publicId 와 세션
        // uuid 의 비교 하나다(`PartyMappers` 의 `toUser` — 방장 판정과 달리 **폴백이 없어** 한쪽으로
        // 기울지 않는다). 20 은 방 상세를 읽어 그리므로 이 비교가 성립한다 — 식별자가 없는 목록·생성
        // 응답의 자리 표시용 멤버는 늘 false 다. 로그인 복원 전이면 세션 uuid 가 nil 이라 false 로
        // 떨어지는데, 그때 눌러도 서버 409 를 「이미 합류됨」으로 받아 21 로 보낸다
        // (JoinConfirmViewModel.join) — 문구는 덜 정확해지지만 갈 곳은 같다.
        let iAmMember = ride.members.contains { $0.isMe }
        // 배지·배너·CTA 를 **한 판정**에서 뽑는다 — 세 자리가 제각각 다른 조건을 보면 「모집 중」 배지 +
        // 활성 CTA + 「모집이 끝났어요」 배너처럼 서로 모순되는 화면이 나온다.
        let gate = joinGate(
            status: ride.status,
            joinedCount: joinedCount,
            capacity: ride.capacity,
            iAmMember: iAmMember
        )
        let badge = joinStatusBadge(status: ride.status)
        // 배너는 한 줄만 — 막힌 이유가 있으면 그것을, 없으면 서버가 돌려준 실패 문구를 보여 준다.
        let noticeMessage = joinGateMessage(gate: gate) ?? joinErrorMessage

        // 지도에 그릴 값 — 전부 방 상세(Ride)에서 나온다. 좌표가 못 쓸 값이면(서버 위경도 전치, QA D-1)
        // latLngOrNull 이 nil 을 돌려주고 지도는 자리표시자로 떨어진다.
        let originPosition = latLngOrNull(latitude: ride.originLat, longitude: ride.originLng)
        let destinationPosition = latLngOrNull(latitude: ride.destinationLat, longitude: ride.destinationLng)
        let routePath = ride.routePolyline.map { decodePolyline(encoded: $0) } ?? []
        // 거리는 서버가 주지 않아 **경로선에서 직접 잰다**. 경로가 없으면 거리 표기를 생략한다 —
        // 출발·도착 직선거리로 대체하면 실제 주행 거리보다 짧아 요금과 어긋나 보인다.
        let routeMeters = polylineDistanceMeters(points: routePath)
        let routeKm = routeMeters > 0.0 ? routeMeters / 1000.0 : nil
        let etaLabel = buildRouteChipLabel(estimatedMinutes: ride.estimatedMinutes, routeKm: routeKm)

        let sheetShape = UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .circular)

        VStack(spacing: 0) {
            // 상단 헤더 (흰 배경)
            VStack(spacing: 0) {
                StatusBarSpacer()
                HStack(spacing: 0) {
                    Button(action: onDismiss) {
                        BackArrowIcon()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFeedbackStyle())
                    Spacer().frame(width: 10)
                    Text("합류할까요?")
                        .moyeotaText(bodyLargeText(18, .bold), color: MoyeotaColor.InkPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity)
            .background(MoyeotaColor.SurfaceCanvas)

            ZStack(alignment: .top) {
                // 경로 지도 스트립
                ZStack(alignment: .topLeading) {
                    RouteStripMap(
                        originPosition: originPosition,
                        destinationPosition: destinationPosition,
                        routePath: routePath
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 시간·거리 둘 다 없으면 칩을 통째로 감춘다 — 틀린 값보다 없는 편이 낫다
                    if let etaLabel {
                        Text(etaLabel)
                            .moyeotaText(bodyLargeText(13, .bold), color: MoyeotaColor.InkPrimary)
                            .padding(.horizontal, 16)
                            .frame(height: 30)
                            .background(MoyeotaColor.SurfaceCanvas, in: Capsule(style: .circular))
                            .moyeotaShadow(elevation: 4, shape: Capsule(style: .circular), spotColor: Color(argb: 0x141B2A4A))
                            .padding(16)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 172)

                // 바텀시트
                VStack(spacing: 0) {
                    Spacer().frame(height: 10)
                    SheetHandle()
                        .frame(maxWidth: .infinity)

                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer().frame(height: 14)

                            // 상태 행
                            HStack(spacing: 0) {
                                StatusBadge(kind: badge.kind, text: badge.text)
                                    .fixedSize()
                                Spacer().frame(width: 10)
                                Text(
                                    joinHeadcountLine(
                                        joinedCount: joinedCount,
                                        capacity: ride.capacity,
                                        iAmMember: iAmMember
                                    )
                                )
                                .moyeotaText(bodyLargeText(13, .medium), color: GrayMute)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Spacer().frame(height: 16)
                            RouteCard(
                                origin: ride.origin,
                                destination: ride.destination,
                                departureLabel: ride.departureLabel.isBlank ? nil : ride.departureLabel,
                                pickupDistanceMeters: pickupDistanceMeters,
                                durationLabel: ride.estimatedMinutes.map { "약 \($0)분" }
                            )

                            Spacer().frame(height: 16)
                            FareCard(
                                totalFare: ride.totalFare,
                                farePerPerson: ride.farePerPerson,
                                capacity: ride.capacity
                            )

                            Spacer().frame(height: 16)
                            Text("이미 참여한 사람 · \(joinedCount)명")
                                .moyeotaText(bodyLargeText(13, .medium), color: GrayMute)
                            Spacer().frame(height: 8)
                            // 대표로 한 명만 노출한다 — 첫 멤버라는 것 외에 특별한 지위는 없다.
                            // 탈퇴 회원이 앞에 있으면 볼 것도 눌러 볼 것도 없어 실재하는 멤버를 앞세운다.
                            if let representative = ride.members.first(where: { !$0.isWithdrawn }) ?? ride.members.first {
                                MemberRow(
                                    member: representative,
                                    othersCount: joinedCount - 1,
                                    onClick: { onMemberClick(representative) } // → 23 동승자 프로필
                                )
                            }

                            Spacer().frame(height: 14)
                            Text("합류하면 바로 채팅방에 들어가요 · 1인 부담금은 정원 기준 예상 금액이에요")
                                .moyeotaText(bodyLargeText(12, .medium), color: GrayAsh)
                                .padding(.horizontal, 4)
                            Spacer().frame(height: 16)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: .infinity)

                    // 막힌 사유든 서버 실패든 **배너는 하나**다 (스펙 20). 전에는 「방금 인원이 찼어요」와
                    // 서버가 돌려준 「방이 가득 찼어요」가 거의 같은 말을 두 번 했다 — 합류 실패 뒤
                    // `refreshQuietly()` 가 성공하면 두 조건이 동시에 참이 된다.
                    if let noticeMessage {
                        NoticeBanner(
                            // 「이미 참여 중」은 실패가 아니라 안내다 — 빨간 배너로 띄우면 뭔가 잘못된
                            // 것처럼 보여 「방으로 돌아가기」 CTA 와 모순된다.
                            kind: gate == .alreadyJoined ? .info : .error,
                            text: noticeMessage
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }

                    HStack(spacing: 12) {
                        SecondaryButton(text: "닫기", onClick: onDismiss)
                            .frame(width: 112)
                        // 이미 멤버면 합류가 아니라 **그 방으로 돌아가는** 버튼이다 — 서버는 재합류를
                        // 409 로 막고, 그 409 는 이미 「이미 합류됨」으로 다뤄 21 로 보내고 있다
                        // (JoinConfirmViewModel.join). 같은 곳으로 가는 길을 버튼으로 당겨 둔 것뿐이다.
                        if gate == .alreadyJoined {
                            PrimaryCtaButton(
                                text: "방으로 돌아가기",
                                onClick: { onOpenJoinedRide(ride) }
                            )
                        } else {
                            PrimaryCtaButton(
                                text: "이 탑승에 합류하기",
                                onClick: { onConfirmJoin(ride) }, // 성공 시 → 22 탑승 상세
                                // 모집 중이 아니거나 정원이 찬 방은 **눌러도 409 뿐**이다. 전에는 상태를
                                // 보지 않아 취소된 방에서도 활성이었고, 누른 뒤에야 사유를 알 수 있었다.
                                enabled: gate == .joinable,
                                loading: joining
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    NavigationBarSpacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MoyeotaColor.SurfaceCanvas)
                .clipShape(sheetShape)
                .moyeotaShadow(elevation: 14, shape: sheetShape, spotColor: Color(argb: 0x141B2A4A))
                .padding(.top, 160)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CanvasBg)
    }
}

// ─── 단계·CTA 판정 (순수 함수 — 화면 없이 테스트한다) ───────────────────────

/// `joinStatusBadge` 가 돌려주는 배지 하나. 색과 문구는 항상 짝지어 움직인다.
struct JoinStatusBadge: Equatable {
    var kind: NoticeKind
    var text: String
}

/// 방 단계(`RideStatus`) → 상태 배지.
///
/// enum 을 **포괄하지 않으면 컴파일되지 않는** `switch` 다 — 새 단계가 도메인에 생길 때 「모집 중」이
/// 조용히 남는 일을 막아 주는 것이 여기 분기를 다 적어 둔 이유다.
///
/// 20 은 모집 중인 방을 고르려고 여는 화면이라, 다른 단계는 모두 **들어갈 수 없는 방**이라는 뜻이다
/// (17 목록이 4초 주기라 고르는 사이에 바뀐다). 그래서 문구를 「… 방」으로 적었다 — 지금 내가 들어갈
/// 수 있는 상황이 아니라는 사실이 배지에서 읽혀야 한다.
func joinStatusBadge(status: RideStatus) -> JoinStatusBadge {
    switch status {
    case .recruiting: JoinStatusBadge(kind: .success, text: "모집 중")
    case .matched: JoinStatusBadge(kind: .waiting, text: "모집 마감된 방")
    case .dispatching: JoinStatusBadge(kind: .waiting, text: "기사님 찾는 방")
    case .ongoing: JoinStatusBadge(kind: .info, text: "운행 중인 방")
    case .completed: JoinStatusBadge(kind: .info, text: "운행이 끝난 방")
    case .canceled: JoinStatusBadge(kind: .error, text: "취소된 방")
    }
}

/// 20 의 배너·CTA 를 정하는 판정 결과 — `joinGate`.
enum JoinGate {
    /// 지금 합류할 수 있다
    case joinable

    /// 이미 내가 이 방의 멤버다 — 합류가 아니라 돌아갈 자리다
    case alreadyJoined

    /// 모집 중이 아닌 방(마감·배차·운행·취소)
    case notRecruiting

    /// 상태는 모집 중인데 자리가 없다
    case full
}

/// 지금 합류할 수 있는가 — 20 의 **단일 판정**이다(배지 문구만 `joinStatusBadge` 가 따로 맡는다).
///
/// 위에서부터 읽는다 — 앞의 조건이 뒤를 가린다.
///
/// | 판정 | 조건 | 이 순서인 이유 |
/// |---|---|---|
/// | `alreadyJoined` | `iAmMember` | 서버 목록은 **내 방을 빼지 않는다.** 17 은 이제 `exploreList` 로 걸러내지만, 목록이 낡았을 때·알림으로 20 에 바로 들어올 때는 여전히 닿는다 — **그 경우의 방어로 남긴다**(걸러내기가 사라져도 20 이 거짓을 말하지 않게 하는 안전망이다). 그때 「내가 N+1번째」는 거짓이고 합류를 시도해도 409 뿐이다 |
/// | `notRecruiting` | 상태가 모집 중이 아니다 | **정원 비교보다 앞**이다: 취소된 방은 멤버가 0명이라 정원만 보면 「자리 있음」으로 읽힌다 |
/// | `full` | 인원 ≥ 정원 | 상태는 아직 ACTIVE 인데 목록이 낡아 자리가 없는 경우(기존 동작 그대로) |
/// | `joinable` | 그 밖 | |
///
/// - Parameters:
///   - status: 방 상세의 단계(`Ride.status`)
///   - joinedCount: 방 상세의 멤버 수 — **나도 포함된 수**다
///   - capacity: 방 정원(방장 포함)
///   - iAmMember: 멤버 중 `User.isMe` 가 있는가
func joinGate(
    status: RideStatus,
    joinedCount: Int,
    capacity: Int,
    iAmMember: Bool
) -> JoinGate {
    if iAmMember { return .alreadyJoined }
    if status != .recruiting { return .notRecruiting }
    if joinedCount >= capacity { return .full }
    return .joinable
}

/// 막힌 이유 한 줄. `joinable` 이면 nil — 띄울 배너가 없다는 뜻이다.
///
/// 문구를 서버 실패 문구(`joinFailureMessage`)와 일부러 같은 말로 적었다 — 같은 사정을 **눈으로 보고
/// 막히는 것**과 **눌러서 알게 되는 것**이 다른 말로 보이면, 사용자는 사정이 두 가지 있는 줄로 읽는다.
func joinGateMessage(gate: JoinGate) -> String? {
    switch gate {
    case .joinable: nil
    case .alreadyJoined: "이미 참여 중인 방이에요"
    case .notRecruiting: "모집이 끝난 방이에요. 목록에서 다른 동승을 선택해 주세요"
    case .full: "방금 인원이 찼어요. 목록에서 다른 동승을 선택해 주세요"
    }
}

/// 상태 행의 인원 문구.
///
/// 「내가 N번째」는 **내가 아직 멤버가 아닐 때만** 쓴다. `joinedCount` 는 방 상세의 멤버 수라 **나를
/// 포함**하므로, 내 방을 열었을 때도 +1 을 더하면 「1명 참여 · 목표 3명 · 내가 2번째」처럼 한 칸 밀린
/// 거짓이 된다(실제로는 내가 1번째다). 그 경우에는 순서를 고쳐 쓰지 않고 **이미 들어와 있다는 사실**만
/// 쓴다 — 「내가 1번째」로 바꿔 쓰면 지금 새로 합류하는 것처럼 읽힌다.
func joinHeadcountLine(joinedCount: Int, capacity: Int, iAmMember: Bool) -> String {
    let base = "\(joinedCount)명 참여 · 목표 \(capacity)명"
    return iAmMember ? "\(base) · 이미 참여 중" : "\(base) · 내가 \(joinedCount + 1)번째"
}

// ─── 조각 ───────────────────────────────────────────────────────────────────

private struct RouteCard: View {
    let origin: String
    let destination: String
    /// 서버 출발 표기. 비어 있으면 nil — 자리를 비워 둔다
    let departureLabel: String?
    let pickupDistanceMeters: Double?
    /// 예상 소요 시간 「약 N분」. 서버 값이 없으면 nil
    let durationLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                RouteDot(color: MoyeotaColor.MarkerOrigin)
                Spacer().frame(width: 12)
                Text(origin)
                    .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.InkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let departureLabel {
                    Text(departureLabel)
                        .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.InkPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            HStack(spacing: 0) {
                DashedVerticalLine()
                    .frame(width: 11)
                Spacer().frame(width: 12)
                // 내 위치를 모르면 점선만 남는다 — 보행 시간 같은 지어낸 값을 채우지 않는다
                if let pickupDistanceMeters {
                    Text("내 위치에서 \(pickupDistanceLabel(meters: pickupDistanceMeters))")
                        .moyeotaText(bodyLargeText(12, .medium), color: GrayMute)
                }
            }
            HStack(spacing: 0) {
                RouteDot(color: MoyeotaColor.MarkerDestination)
                Spacer().frame(width: 12)
                Text(destination)
                    .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.InkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let durationLabel {
                    Text(durationLabel)
                        .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.InkPrimary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RouteCardBg, in: RoundedRectangle(cornerRadius: 16, style: .circular))
    }
}

private struct RouteDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
    }
}

/// 원본의 점선 간격 `6f, 6f` 는 dp 가 아니라 **픽셀**이다. 그래서 화면 배율로 나눠 같은 픽셀을 쓴다.
///
/// 선 굵기(3)가 틈보다 커서 둥근 끝이 맞닿아, 원본 스크린샷처럼 점선이 아니라 이어진 선으로 보인다.
/// 둥근 끝은 위아래로 굵기 절반씩 칸을 벗어나는데 Compose `Canvas` 는 넘쳐 그리고 SwiftUI `Canvas` 는
/// 잘라 내므로, 그만큼 큰 캔버스에 그리고 레이아웃은 26 으로 둔다.
private struct DashedVerticalLine: View {
    private static let width: CGFloat = 3
    private static let height: CGFloat = 26

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let dash = 6 / displayScale
        Canvas { context, size in
            let overflow = Self.width / 2
            var path = Path()
            path.move(to: CGPoint(x: size.width / 2, y: overflow))
            path.addLine(to: CGPoint(x: size.width / 2, y: overflow + Self.height))
            context.stroke(
                path,
                with: .color(Color(argb: 0xFFC3CCDA)),
                style: StrokeStyle(lineWidth: Self.width, lineCap: .round, dash: [dash, dash])
            )
        }
        .frame(width: Self.width, height: Self.height + Self.width)
        .frame(width: Self.width, height: Self.height)
    }
}

private struct FareCard: View {
    let totalFare: Int
    let farePerPerson: Int
    let capacity: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FareRow(label: "총 예상 요금", value: won(amount: totalFare))
            Spacer().frame(height: 14)
            HStack(spacing: 0) {
                Text("합류 시 1인 부담")
                    .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.Primary600)
                Spacer(minLength: 0)
                Text(won(amount: farePerPerson))
                    .moyeotaText(bodyLargeText(19, .bold), color: MoyeotaColor.Primary500)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(MoyeotaColor.Primary50, in: RoundedRectangle(cornerRadius: 14, style: .circular))
            Spacer().frame(height: 6)
            HStack(spacing: 0) {
                CheckIcon(color: GrayMute)
                Spacer().frame(width: 6)
                Text("총 예상 요금을 정원 \(capacity)명으로 나눈 금액이에요")
                    .moyeotaText(bodyLargeText(12, .medium), color: GrayMute)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(FareCardBg, in: RoundedRectangle(cornerRadius: 16, style: .circular))
    }
}

private struct FareRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .moyeotaText(bodyLargeText(15, .medium), color: TextMuteWarm)
            Spacer(minLength: 0)
            Text(value)
                .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.InkPrimary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MemberRow: View {
    let member: User
    let othersCount: Int
    let onClick: () -> Void

    var body: some View {
        // 탈퇴 회원은 열어 볼 프로필이 없다 — 탭을 막는다
        if member.isWithdrawn {
            content(clickable: false)
        } else {
            Button(action: onClick) {
                content(clickable: true)
            }
            .buttonStyle(PressOverlayStyle(shape: RoundedRectangle(cornerRadius: 12, style: .circular)))
        }
    }

    private func content(clickable: Bool) -> some View {
        // 매너 %(별점 환산)는 지웠다 — 평가 API 가 없어 rating 은 항상 0.0 이고,
        // 그걸 환산하면 "매너 0%" 라는 없는 사실을 사람에 붙이게 된다.
        let othersLabel = othersCount > 0 ? " · 외 \(othersCount)명" : ""
        return HStack(spacing: 0) {
            MemberAvatar(user: member, size: 40)
            Spacer().frame(width: 10)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(member.displayNickname)
                        .moyeotaText(bodyLargeText(15, .bold), color: clickable ? MoyeotaColor.InkPrimary : GrayMute)
                    Spacer().frame(width: 8)
                    Group {
                        if member.isMe {
                            MeBadge()
                        } else {
                            GrayPill(text: "동승자")
                        }
                    }
                    .fixedSize()
                }
                Text(clickable ? "\(member.rideCountLabel)\(othersLabel)" : "탈퇴한 회원\(othersLabel)")
                    .moyeotaText(bodyLargeText(13, .medium), color: GrayMute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if clickable {
                ChevronRightIcon(color: GrayAsh)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
}

private struct GrayPill: View {
    let text: String

    var body: some View {
        Text(text)
            .moyeotaText(bodyLargeText(11, .bold), color: GraySlateDeep)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(PillBg, in: Capsule(style: .circular))
    }
}

// ─── Canvas 아이콘·경로 (머티리얼 아이콘 미사용) ─────────────────────────────

private struct CheckIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w * 0.15, y: h * 0.55))
            path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.8))
            path.move(to: CGPoint(x: w * 0.42, y: h * 0.8))
            path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.25))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        .frame(width: 14, height: 14)
    }
}

private struct ChevronRightIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w * 0.38, y: h * 0.22))
            path.addLine(to: CGPoint(x: w * 0.66, y: h * 0.5))
            path.move(to: CGPoint(x: w * 0.38, y: h * 0.78))
            path.addLine(to: CGPoint(x: w * 0.66, y: h * 0.5))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        .frame(width: 16, height: 16)
    }
}
