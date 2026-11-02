import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

// 와이어프레임 그레이 (core token 미정의 색 — 화면 재현용)
private let CanvasBg = Color(argb: 0xFFF5F7FA)
private let GraySlate = Color(argb: 0xFF4B5563)
private let GrayMute = Color(argb: 0xFF8A93A0)
private let GrayAsh = Color(argb: 0xFF9AA1AC)
private let CardSoft = Color(argb: 0xFFF6F8FB)
private let GrayButtonBg = Color(argb: 0xFFEEF1F6)
private let DividerGray = Color(argb: 0xFFE7EAF0)
private let ProgressTrack = Color(argb: 0xFFE6EAF0)

/// 원본 `Text(fontSize = …, fontWeight = …)` 의 글자 모양.
///
/// `style` 을 주지 않은 Compose `Text` 는 `MaterialTheme` 의 `LocalTextStyle`(M3 기본 `bodyLarge`)에서
/// **줄 높이 24sp · 자간 0.5sp** 를 물려받는다. 그래서 12sp 글자도 줄 상자는 24 다 — 빼면 이 화면의 세로 간격이
/// 원본과 어긋난다(스크린샷 `21-match-waiting` 의 닉네임 줄과 탑승 횟수 줄 간격이 24dp 다).
///
/// 큰 글자는 24 를 넘는다. 원본의 한글은 대체 폰트로 그려지고 안드로이드 줄 상자가 그 폰트의 어센트·디센트까지 넓어지기
/// 때문이다. 값은 원본 UI 트리에서 쟀다(17sp 24.4, 18sp 26.3, 19sp 27.1, 20sp 28.5, 22sp 31.6, 24sp 34.6dp).
/// 16sp 이하는 24 그대로다.
func inlineType(_ fontSize: CGFloat, _ fontWeight: Font.Weight) -> MoyeotaType {
    MoyeotaType(fontSize: fontSize, fontWeight: fontWeight, lineHeight: .sp(max(24, fontSize * 1.44)), letterSpacing: 0.5)
}

/// `remember(key) { … }` 의 자리 — 키가 같으면 다시 계산하지 않는다.
///
/// 시트를 끄는 동안 지도 슬롯이 프레임마다 다시 평가되므로, 폴리라인 해석과 카메라 계산을 그때마다 돌리지 않는다.
@MainActor
final class Remembered<Key: Equatable, Value> {
    private var entry: (key: Key, value: Value)?

    func value(key: Key, compute: () -> Value) -> Value {
        if let entry, entry.key == key { return entry.value }
        let value = compute()
        entry = (key, value)
        return value
    }
}

private struct FitKey: Equatable {
    let origin: LatLng?
    let destination: LatLng?
    let routePath: [LatLng]
    let widthDp: Float
    let heightDp: Float
}

/// 21 · 매칭 대기 [S11]
///
/// 이동(디스크립션):
/// - 「그만 찾기」 → 방 나가기(DELETE /matching/leave) 후 14 홈 (onCancelSearch — 뒤로가기도 동일 처리)
///   둘 다 **확인 다이얼로그를 거친다** — 뒤로가기 한 번에 방이 날아가면 사용자가 놀란다(QA O-1).
///   `onCancelSearch` 는 사용자가 「그만 찾기」를 확인한 뒤에만 호출된다.
///
///   **나가기는 모집 중(`RideStatus.recruiting` = 서버 ACTIVE)에서만 가능하다.** 서버 `Party.leave` 가
///   `ensureRecruiting()` 으로 막아, 정원이 차 기사 매칭이 시작되면 409 `PARTY_NOT_RECRUITING` 이 온다
///   (화면 문구는 `leaveFailureMessage` 가 「매칭이 시작돼 지금은 나갈 수 없어요」로 가른다).
///   폴링이 MATCHING 을 감지해 25b 로 넘어가기까지 한 주기가 비는데, 그 사이에도 누를 수 있으면
///   실패하는 버튼이 된다 — 그래서 status 를 보고 **즉시** 버튼을 비활성 문구로 바꾸고,
///   뒤로가기는 방을 유지한 채 홈으로만 보낸다(`onExitKeepingParty`).
///
///   반대로 **403 `NOT_PARTY_MEMBER`(= 이미 나갔다)는 실패로 보이지 않는다** — 데이터 계층이 성공으로
///   되돌려 나가기 성공과 같은 길로 보낸다. 204 응답이 유실된 사용자가 다시 눌러 같은 문구에 갇히지
///   않게 하려는 것이다(`PartyLeaveException` 주석).
/// - 카드 탭 → 22 탑승 상세 (onCardClick)
/// - 「채팅 열기」 → 24 채팅방(독립 목적지, 뒤로가기로 여기 복귀) — `onOpenChat` 이 nil 이 아닐 때만 그린다.
///   채팅방은 **정원이 찬 뒤에** 생기므로 모집 중에는 대개 nil 이다. 눌러도 열 것이 없는 버튼을 두지 않는다.
/// - 매칭 성사(서버 status 전이) → 25 배차 현황 — 화면이 아니라 Route 가 관찰해 넘긴다
/// - 매칭 조건(인원)은 **읽기 전용**이다. 방을 만들 때(16) 정해진 값이고 **바꾸는 API 가 없다** —
///   방장이 있더라도(서버 `MemberInfo.host`) 조건을 고치는 엔드포인트는 없다. 눌러도 아무 일 없는
///   「수정」 버튼을 두는 대신 카드 아래 한 줄로 이유를 적는다.
///   「탐색 반경」 행은 지웠다(2026-10-14) — 서버가 반경을 요청에서 빼고 고정값(500m)으로 정하면서
///   **사용자가 정한 값이 아니게 됐다.** 게다가 합류에 거리 검사가 없고 목록은 지도 뷰포트만 보므로
///   그 숫자는 아무것도 걸러내지 않는다. 바꿀 수도 없고 효과도 없는 값을 조건으로 보여 주지 않는다.
///
/// 도메인 변경(2026-08-30): 「전원 준비 → 방장이 출발」 흐름이 백엔드에서 사라졌다.
/// `/matching/ready`, `/matching/start` 가 삭제되고 **정원이 차면 서버가 스스로 기사 매칭을 시작**한다.
/// 그래서 이 화면에는 준비/매칭 시작 버튼이 없고, 인원 현황과 자동 매칭 안내만 남는다.
///
/// 서버 계약(2026-09): `members[]` 가 닉네임·탑승 횟수·publicId 를 함께 주면서, 기다리는 동안
/// **누가 모였는지**를 실제로 보여줄 수 있게 됐다. 내 줄은 `isMe`(publicId == 세션 uuid)로
/// 판정한다 — 예전처럼 고정 memberId 1 과 비교하지 않는다.
///
/// 방장 표시(2026-10-15): `members[]` 에 `host` 가 함께 오면서(Backend #240) **방장을 말할 수 있게
/// 됐다** — 2026-08-30 에 지운 「`joinedAt` 최소값 추정」과 달리 이건 **서버 값**이다. 그래서
/// ① 「합승 완료」를 방장에게만 보이고(서버가 그 API 를 방장 전용으로 좁혔다, Backend #237)
/// ② 멤버 목록에 「방장」 배지를 붙인다(`showsHostBadge` — 폴백 때문에 **내 줄에는 붙지 않는다**).
///
/// 레이아웃(2026-09-08): 배경이 레이더 애니메이션에서 **실지도**로 바뀌었다. 출발지·도착지 마커와
/// 경로, 내 위치 파란 점을 그린다. **탐색 반경 원은 2026-10-14 에 지웠다** — 서버가 반경을
/// 고정값으로 정하고 매칭은 그 값을 읽지 않으므로, 원은 「이 범위에서 찾는다」는 없는 약속이었다.
/// 시트는 16 도착지 확인과 같은 `MapSheetScaffold` 로 접었다 폈다 한다 —
/// 접힘 = 헤드라인 · 진행바 · 「그만 찾기」만 남고 지도가 넓어진다.
public struct MatchWaitingScreen: View {
    /// 그릴 방. **기본값이 없다** — 예시 방이 프로덕션에 새는 길을 막는다.
    ///
    /// 원본은 예전에 예시 방이 `ride` **기본 인자**이기도 했다. 그래서 호출부가 방을 모르는 상태(구성 변경에
    /// 방 id 가 날아간 21)에서 `ride` 를 빼고 부르면, 진짜 방에 들어 있던 사용자에게 센텀시티역→서면역 방이
    /// 떴다(출시 차단 결함, 2026-10-15). 기본값을 걷어내 호출부가 **반드시** 방을 넘기게 했다 — 같은 사고가
    /// 다시 나려면 컴파일이 먼저 깨진다.
    private let ride: Ride
    private let foundCount: Int
    private let conditionLabel: String
    private let myLocation: UserCoordinates?
    private let taxiEnabled: Bool
    private let actionInProgress: Bool
    private let actionErrorMessage: String?
    private let onCancelSearch: () -> Void
    private let onFinish: () -> Void
    private let onExitKeepingParty: () -> Void
    private let onCardClick: () -> Void
    private let onOpenChat: (() -> Void)?

    // 나가기 확인 다이얼로그. 화면 안에서만 쓰는 UI 상태라 뷰모델로 올리지 않는다
    // (12 마이페이지의 로그아웃 확인과 같은 패턴).
    @State private var cancelConfirming = false
    @State private var finishConfirming = false

    @State private var routeMemo = Remembered<String?, [LatLng]>()
    @State private var fitMemo = Remembered<FitKey, (first: LatLng, second: Double)?>()

    /// - Parameters:
    ///   - myLocation: 내 현재 위치(파란 점). 권한이 없거나 아직 못 받았으면 nil — 지도에 점을 찍지 않는다
    ///   - taxiEnabled: 택시 모드(서버 설정). false = 1차 배포 — 정원이 차도 기사를 부르지 않는다.
    ///     문구(「기사님을 찾아요」 → 「채팅으로 만나요」)와 정원 찼을 때의 CTA(「합승 완료」)가 갈린다.
    ///   - onFinish: 1차 배포 모드 「합승 완료」 — 누르면 모두의 방이 닫힌다. 확인 다이얼로그 뒤에만 호출된다.
    ///     버튼은 **방장에게만** 보인다(서버가 방장 전용으로 좁혔다 — `canFinishParty`).
    ///     비방장에게는 같은 자리에 누가 끝내는지를 말하는 안내문이 들어가고 이 콜백은 쓰이지 않는다.
    ///   - onExitKeepingParty: 방을 **유지한 채** 화면만 벗어난다. 나가기가 막힌 단계의 뒤로가기가 여기로 온다
    ///   - onOpenChat: 이 방의 채팅방을 연다. **채팅방이 아직 없으면 nil** — 버튼 자체를 그리지 않는다
    public init(
        ride: Ride,
        foundCount: Int = 1,
        conditionLabel: String = "3인",
        myLocation: UserCoordinates? = nil,
        taxiEnabled: Bool = false,
        actionInProgress: Bool = false,
        actionErrorMessage: String? = nil,
        onCancelSearch: @escaping () -> Void = {},
        onFinish: @escaping () -> Void = {},
        onExitKeepingParty: @escaping () -> Void = {},
        onCardClick: @escaping () -> Void = {},
        onOpenChat: (() -> Void)? = nil
    ) {
        self.ride = ride
        self.foundCount = foundCount
        self.conditionLabel = conditionLabel
        self.myLocation = myLocation
        self.taxiEnabled = taxiEnabled
        self.actionInProgress = actionInProgress
        self.actionErrorMessage = actionErrorMessage
        self.onCancelSearch = onCancelSearch
        self.onFinish = onFinish
        self.onExitKeepingParty = onExitKeepingParty
        self.onCardClick = onCardClick
        self.onOpenChat = onOpenChat
    }

    public var body: some View {
        // 서버가 나가기를 허용하는 단계인가. 모드에 따라 다르다 — canLeaveParty 주석 참고.
        let canLeave = canLeaveParty(status: ride.status, taxiEnabled: taxiEnabled)
        // 1차 배포 모드에서 정원이 찼다 — **방을 손으로 닫는 단계**. 방장 여부와 무관한 표시가 이걸 본다.
        let finishStage = isFinishStage(status: ride.status, taxiEnabled: taxiEnabled)
        // 그 단계에서 **내가 방장일 때만** 「합승 완료」 버튼을 보여 준다(서버가 방장 전용으로 좁혔다).
        // 비방장에게는 비활성 버튼 대신 아래 footer 의 안내문이 간다 — canFinishParty 주석 참고.
        let canFinish = canFinishParty(ride: ride, taxiEnabled: taxiEnabled)

        // 정원 도달. 기사 모드에선 서버가 기사 매칭을 시작하는 시점이고, 1차 배포 모드에선 채팅으로 만나는 시점이다.
        // 문구·진행바가 이 경계로 갈린다.
        let isFull = foundCount >= ride.capacity
        // 나를 뺀 인원 — **내가 목록에 있을 때만** 센다(otherMemberCount 주석).
        let otherCount = otherMemberCount(ride: ride)
        let progress: CGFloat = ride.capacity > 0
            ? min(max(CGFloat(Float(foundCount) / Float(ride.capacity)), 0), 1)
            : 0

        ZStack {
            VStack(spacing: 0) {
                StatusBarSpacer()

                // 헤더 — 뒤로가기는 탐색 취소와 동일 (진행 화면 이탈 = 14 홈)
                HStack(spacing: 0) {
                    Button {
                        if canLeave { cancelConfirming = true } else { onExitKeepingParty() }
                    } label: {
                        // 머티리얼 `IconButton` 의 레이아웃 크기는 최소 터치 영역인 48dp 다.
                        BackArrowIcon()
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(IconPressStyle())
                    // 1차 배포 모드에서 정원이 찼으면 더는 「찾는 중」이 아니다 — 만나는 단계다.
                    // **방장 여부가 아니라 단계**를 본다: 비방장도 같은 방을 보고 있다.
                    Text(finishStage ? "같이 탈 사람이 모였어요" : "같이 탈 사람 찾는 중")
                        .moyeotaText(inlineType(18, .bold), color: MoyeotaColor.InkPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)

                // 지도(헤더 아래 전부) 위에 드래그 시트 — 16 도착지 확인과 같은 메커니즘
                MapSheetScaffold(
                    // 16 보다 지도를 더 남긴다. 21 의 펼침 콘텐츠(안내 · 모인 사람 · 조건 카드)는
                    // 16 의 매칭 조건 카드보다 짧아서, 16 과 같은 160dp 로 두면 상세 영역이 남아
                    // 조건 카드와 「그만 찾기」 사이가 휑하게 빈다. 남는 만큼 지도에 준다.
                    // 상세 콘텐츠(안내 배너 · 모인 사람 N줄 · 조건 카드 3줄 · 안내 문구)가 멤버가 늘수록
                    // 길어진다. 실기에서 2명일 때 조건 카드 마지막 줄과 안내 문구가 잘려 나가는 것을 확인해
                    // 16 과 같은 160dp 로 되돌렸다 — 펼침은 정보를 보는 상태이고, 지도는 접힘이 맡는다.
                    // (「탐색 반경」 줄이 빠져 카드가 한 줄 짧아졌다. 여유가 늘었을 뿐이라 값은 그대로 둔다.)
                    mapRevealHeight: 160,
                    // 접힘 = 핸들 + 헤드라인 + 인원 문구 + 진행바 + 「그만 찾기」
                    collapsedSheetHeight: 196,
                    background: { sheet in
                        mapBackground(sheet: sheet, isFull: isFull)
                    },
                    sheetTop: {
                        sheetTop(isFull: isFull, otherCount: otherCount, progress: progress)
                    },
                    sheetDetail: {
                        sheetDetail(isFull: isFull, canFinish: canFinish)
                    },
                    sheetFooter: {
                        sheetFooter(canLeave: canLeave, finishStage: finishStage, canFinish: canFinish)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CanvasBg)

            // 「합승 완료」 확인 — 나 혼자가 아니라 **모두의** 방이 닫히는 행동이라 반드시 한 번 묻는다
            if finishConfirming {
                ConfirmDialog(
                    title: "합승을 완료할까요?",
                    text: "같이 탄 사람 모두의 방이 종료돼요. 다 타고 나서 눌러 주세요",
                    confirmLabel: "합승 완료",
                    confirmColor: MoyeotaColor.Primary600,
                    dismissLabel: "아직이요",
                    onConfirm: {
                        finishConfirming = false
                        onFinish()
                    },
                    onDismiss: { finishConfirming = false }
                )
            }

            // 뒤로가기·「그만 찾기」 공통 확인 — 확인해야만 실제로 방을 나간다
            if cancelConfirming {
                ConfirmDialog(
                    title: "매칭을 그만둘까요?",
                    text: "지금 나가면 이 방에서 빠지고 처음부터 다시 찾아야 해요",
                    confirmLabel: "그만 찾기",
                    confirmColor: MoyeotaColor.Danger500,
                    dismissLabel: "계속 찾기",
                    onConfirm: {
                        cancelConfirming = false
                        onCancelSearch()
                    },
                    onDismiss: { cancelConfirming = false }
                )
            }
        }
        // 다이얼로그가 떠 있는 동안 시스템 뒤로가기는 다이얼로그만 닫는다(원본 `onDismissRequest` 의 뒤로가기).
        .moyeotaBackHandler(enabled: cancelConfirming || finishConfirming) {
            cancelConfirming = false
            finishConfirming = false
        }
        // 원본 `remember` 는 화면이 컴포지션에서 빠지면 사라진다. `@State` 는 스택에 있는 동안 남으므로 직접 비운다.
        .onDisappear {
            cancelConfirming = false
            finishConfirming = false
        }
    }

    /// 테스트가 확인창이 열린 상태를 만드는 입구. 창에 올린 화면이라도 코드로는 SwiftUI 버튼을 누를 수 없다.
    func seeded(cancelConfirming: Bool) -> Self {
        var copy = self
        copy._cancelConfirming = State(initialValue: cancelConfirming)
        return copy
    }

    // 지도에 그릴 값들. SSE·폴링마다 ride 인스턴스는 새로 오지만 좌표·폴리라인 값은 같으므로
    // 아래 계산이 다시 돌지 않는다 — 카메라가 갱신마다 튀지 않는 이유다.
    @ViewBuilder
    private func mapBackground(sheet: MapSheetState, isFull: Bool) -> some View {
        let originPosition = latLngOrNull(latitude: ride.originLat, longitude: ride.originLng)
        let destinationPosition = latLngOrNull(latitude: ride.destinationLat, longitude: ride.destinationLng)
        let myPosition = latLngOrNull(latitude: myLocation?.latitude, longitude: myLocation?.longitude)
        let routePath = routeMemo.value(key: ride.routePolyline) {
            ride.routePolyline.map { decodePolyline(encoded: $0) } ?? []
        }
        let widthDp = Float(sheet.containerWidth)
        let visibleMapHeightDp = Float(sheet.visibleMapHeight)
        // **출발–도착 전체**(경로 포함)가 들어오게 맞춘다. 펼침·접힘은 보이는 지도 높이만
        // 다르고(visibleMapHeight 가 그걸 알려 준다) 맞출 대상은 같다 —
        // 반경 원이 사라진 뒤로 펼침에서 따로 출발지 주변만 당겨 볼 이유가 없어졌다.
        // 앵커가 바뀔 때만 값이 변하므로 사용자가 손으로 잡아 둔 줌·중심을 덮어쓰지 않는다.
        let fitted = fitMemo.value(
            key: FitKey(
                origin: originPosition,
                destination: destinationPosition,
                routePath: routePath,
                widthDp: widthDp,
                heightDp: visibleMapHeightDp
            )
        ) {
            // 좌표가 하나뿐이면(목록 응답으로 만든 Ride 등) nil 이고, 아래에서
            // 출발지 중심 기본 줌으로 떨어진다 — 없는 범위를 그려 메우지 않는다.
            let points = routePath + [originPosition, destinationPosition].compactMap { $0 }
            return fitMapCamera(points: points, widthDp: widthDp, heightDp: visibleMapHeightDp)
        }

        ZStack(alignment: .topLeading) {
            if let originPosition {
                RouteMapView(
                    routePath: routePath,
                    originPosition: originPosition,
                    destinationPosition: destinationPosition,
                    myPosition: myPosition,
                    center: fitted?.first ?? originPosition,
                    zoom: fitted?.second ?? 14.0,
                    // 시트에 가리는 만큼을 지도에 알려 카메라 중심이 보이는 영역 기준으로 잡히게 한다
                    contentPadding: EdgeInsets(top: 0, leading: 0, bottom: sheet.settledSheetHeight, trailing: 0)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 좌표 없는 방(목록 응답으로 만든 Ride 등) — 지도 대신 자리표시자
                MapPlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 레이더 애니메이션을 대신하는 상태 배지. 지도가 배경이 된 이상 큰 레이더는
            // 지도를 가리기만 해서 「찾는 중」이라는 사실만 남긴다.
            MapOverlayPill {
                SearchingBadgeContent(isFull: isFull, taxiEnabled: taxiEnabled)
            }
            .padding(16)
        }
    }

    private func sheetTop(isFull: Bool, otherCount: Int, progress: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline(isFull: isFull))
                .moyeotaText(inlineType(22, .bold), color: MoyeotaColor.InkPrimary)
            Spacer().frame(height: 4)
            // 「나 제외」 인원은 isMe 로 센다 — 서버가 publicId 를 주기 전에는 셀 수 없던 값이다
            Text(
                otherCount > 0
                    ? "지금 같은 방향 \(foundCount)명(나 외 \(otherCount)명) · 목표 \(ride.capacity)명"
                    : "지금 같은 방향 \(foundCount)명 · 목표 \(ride.capacity)명"
            )
            .moyeotaText(inlineType(13, .medium), color: GrayMute)
            Spacer().frame(height: 14)

            // 진행 바 — 서버가 내려준 실제 인원/정원 비율
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .circular).fill(ProgressTrack)
                    if progress > 0 {
                        Capsule(style: .circular)
                            .fill(MoyeotaColor.Primary500)
                            .frame(width: geometry.size.width * progress)
                    }
                }
            }
            .frame(height: 6)
            Spacer().frame(height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    private func headline(isFull: Bool) -> String {
        if isFull && !taxiEnabled { return "같이 탈 사람이 다 모였어요" }
        if isFull { return "정원이 다 찼어요" }
        // 「보통 2분 안에 모여요」는 지웠다 — 근거가 될 매칭 소요 통계가 없다.
        // 기다리는 사람에게 지킬 수 없는 시각을 약속하는 자리다(2026-10-13).
        return "같이 탈 사람을 찾고 있어요"
    }

    private func sheetDetail(isFull: Bool, canFinish: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 정원이 찬 뒤 무슨 일이 일어나는지 알려주는 유일한 지점 — 모드에 따라 다르다.
            // 기사 모드: 서버가 스스로 기사 매칭을 시작한다(앱이 트리거하지 않는다).
            // 1차 배포 모드: 기사가 없다. 채팅으로 만날 곳을 정하고, 다 탔으면 「합승 완료」로 닫는다.
            NoticeBanner(
                kind: isFull ? .waiting : .info,
                text: noticeText(isFull: isFull, canFinish: canFinish)
            )
            Spacer().frame(height: 16)

            // 지금까지 모인 사람 — 서버 members[] 를 그대로 그린다(나 포함).
            // 대기 화면에서 가장 궁금한 것이 "누가 같이 타나"라 조건 카드보다 위에 둔다.
            if !ride.members.isEmpty {
                Text("지금 모인 사람")
                    .moyeotaText(inlineType(13, .medium), color: GrayMute)
                Spacer().frame(height: 8)
                // 빈 id 멤버가 겹칠 수 있어(요약 없음) id 가 아니라 자리로 구별한다 — 원본 forEach 도 키가 없다.
                ForEach(Array(ride.members.enumerated()), id: \.offset) { _, member in
                    WaitingMemberRow(member: member)
                }
                Spacer().frame(height: 14)
            }

            // 조건이 왜 고정인지 한 줄로. **카드 위**에 둔다 — 멤버가 늘면 상세 영역이
            // 스크롤되는데, 아래에 두면 이 설명이 가장 먼저 화면 밖으로 나가 「수정 버튼이
            // 왜 없지」에 답할 기회를 잃는다. 접힘 상태에서는 상세 영역째 사라진다.
            Text("매칭 조건은 방을 만들 때 정해지고 찾는 중엔 바꿀 수 없어요")
                .moyeotaText(inlineType(12, .medium), color: GrayAsh)
            Spacer().frame(height: 8)
            // 조건 카드 — 탭 시 22 탑승 상세
            let cardShape = RoundedRectangle(cornerRadius: 18, style: .circular)
            Button(action: onCardClick) {
                VStack(spacing: 0) {
                    ConditionRow(label: "출발지", value: ride.origin)
                    HorizontalDivider(color: DividerGray)
                    ConditionRow(label: "도착지", value: ride.destination)
                    HorizontalDivider(color: DividerGray)
                    ConditionRow(label: "매칭 조건", value: conditionLabel)
                    // 「탐색 반경」 행은 지웠다(2026-10-14) — 서버 고정값이고 매칭이 읽지 않는
                    // 숫자였다(주석 참고). 지금 카드에 남은 건 전부 실제로 방을 정하는 값이다.
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(CardSoft, in: cardShape)
            }
            .buttonStyle(PressOverlayStyle(shape: cardShape))
            Spacer().frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func noticeText(isFull: Bool, canFinish: Bool) -> String {
        // 「눌러 주세요」는 **버튼이 보이는 사람에게만** 하는 말이다 —
        // 비방장에게 하면 없는 버튼을 누르라고 시키는 셈이다.
        if canFinish { return "채팅으로 만날 곳을 정해요. 다 타면 「합승 완료」를 눌러 주세요" }
        // 비방장: 누가 끝내는지는 footer 안내문이 이름까지 말한다 — 여기서 겹쳐 쓰지 않는다.
        if isFull && !taxiEnabled { return "채팅으로 만날 곳을 정해요" }
        if isFull { return "곧 기사님을 찾기 시작해요" }
        if !taxiEnabled { return "정원이 차면 채팅으로 만날 곳을 정해요" }
        return "정원이 차면 기사님을 자동으로 찾아요"
    }

    @ViewBuilder
    private func sheetFooter(canLeave: Bool, finishStage: Bool, canFinish: Bool) -> some View {
        if let actionErrorMessage {
            NoticeBanner(kind: .error, text: actionErrorMessage)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }

        // 채팅방이 생긴 뒤에만 뜬다. 채팅 **탭**이 아니라 채팅방을 스택에 쌓아 열기 때문에
        // 뒤로가기 한 번이면 이 대기 화면으로 돌아온다.
        if let onOpenChat {
            OpenChatButton(onClick: onOpenChat)
                .padding(.horizontal, 16)
            Spacer().frame(height: 8)
        }

        // 1차 배포 모드 · 정원이 찼을 때 — 기사 없이 합승을 끝내는 자리. 접힘 상태에서도 보이게 시트 하단.
        //
        // **방장에게만 버튼**을 준다(서버가 방장 전용으로 좁혔다 — canFinishParty 주석).
        // 비방장에게는 **비활성 버튼을 두지 않는다**: 누를 수 없는 버튼은 왜 못 누르는지
        // 말해 주지 못한다. 대신 같은 자리에 누가 방을 끝내는지를 한 줄로 적는다 —
        // 숨기기만 하면 정원이 찬 뒤 할 일이 하나도 없는 화면이 된다.
        if canFinish {
            PrimaryCtaButton(
                text: actionInProgress ? "완료하는 중…" : "합승 완료",
                onClick: { finishConfirming = true },
                enabled: !actionInProgress
            )
            .padding(.horizontal, 16)
            Spacer().frame(height: 8)
        } else if finishStage {
            NoticeBanner(
                kind: .info,
                text: finishHostNotice(hostNickname: ride.members.hostDisplayNameOrNull())
            )
            .padding(.horizontal, 16)
            Spacer().frame(height: 8)
        }

        // 나가기 — 매칭 시작·준비 버튼은 도메인에서 사라졌다. 접힘 상태에서도 보이도록 시트 하단에 고정한다.
        // 기사 모드에서 정원이 차 매칭이 시작되면 서버가 나가기를 막으므로 버튼을 비활성 문구로 바꾼다.
        GrayActionButton(
            text: leaveLabel(canLeave: canLeave, finishStage: finishStage),
            onClick: { cancelConfirming = true },
            enabled: canLeave && !actionInProgress
        )
        .padding(.horizontal, 16)
        Spacer().frame(height: 12)
        NavigationBarSpacer()
    }

    private func leaveLabel(canLeave: Bool, finishStage: Bool) -> String {
        if !canLeave { return "기사님을 찾는 중…" }
        if actionInProgress { return "나가는 중…" }
        // 「그만 찾기」가 아닌 건 **단계** 때문이다 — 더는 찾는 중이 아니다.
        if finishStage { return "방 나가기" }
        return "그만 찾기"
    }
}

/// 머티리얼 잉크 리플 자리의 눌림 표시. 배경이 없는 아이콘 버튼에 쓴다(디자인 시스템의 아이콘 눌림과 같은 60%).
struct IconPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// 대기 화면의 멤버 한 줄 — 아바타(이니셜) · 닉네임(+나·방장 배지) · 탑승 횟수.
// 여기서는 프로필로 들어가지 않는다(23 진입은 20·22 에서만) — 대기 중 흐름을 끊지 않기 위해서다.
private struct WaitingMemberRow: View {
    let member: User

    var body: some View {
        HStack(spacing: 0) {
            MemberAvatar(user: member, size: 36)
            Spacer().frame(width: 10)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(member.displayNickname)
                        .moyeotaText(
                            inlineType(15, .bold),
                            color: member.isWithdrawn ? GrayMute : MoyeotaColor.InkPrimary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if member.isMe {
                        Spacer().frame(width: 6)
                        MeBadge()
                            .fixedSize()
                    }
                    // 「방장」 — 서버가 멤버마다 내려 주는 값이다(추정이 아니다). 내 줄에는 붙지 않는다:
                    // 서버가 host 를 빼먹었을 때의 폴백이 내 줄만 true 로 만들기 때문이다(showsHostBadge 주석).
                    if member.showsHostBadge {
                        Spacer().frame(width: 6)
                        HostBadge()
                            .fixedSize()
                    }
                }
                // 원본 숫자(Roboto)는 폭이 모두 같아 「탑승 11회」와 「탑승 25회」의 폭이 같다. SF 는 1 이 좁다.
                Text(member.isWithdrawn ? "탈퇴한 회원" : member.rideCountLabel)
                    .monospacedDigit()
                    .moyeotaText(inlineType(12, .medium), color: GrayMute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }
}

private struct ConditionRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .moyeotaText(inlineType(14, .medium), color: MoyeotaColor.TextMute)
                .fixedSize()
            Spacer().frame(width: 12)
            // 출발지·도착지 이름은 16 에서 역지오코딩된 전체 주소일 수 있다(「부산광역시 …63번길 2 …」).
            // 남는 폭을 다 쓰되 라벨을 밀어내지 않도록 폭을 채우고, 넘치면 말줄임한다.
            Text(value)
                .moyeotaText(inlineType(14, .bold), color: MoyeotaColor.InkPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
    }
}

/// 지도 위 「찾는 중」 배지 — 예전 220dp 레이더 애니메이션을 대신한다.
///
/// 레이더는 **삭제**했다. 배경이 실지도가 된 뒤로는 동심원이 지도를 가리기만 했고, 「어느 범위에서
/// 찾는지」는 애초에 앱이 말할 수 있는 것이 아니다 — 매칭은 반경을 보지 않는다(2026-10-14 에
/// 반경 원도 같은 이유로 지웠다). 남길 가치가 있던 건 「지금도 돌아가고 있다」는 신호 하나라,
/// 점 하나의 펄스로 줄였다.
private struct SearchingBadgeContent: View {
    let isFull: Bool
    let taxiEnabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isFull {
                Circle()
                    .fill(MoyeotaColor.Primary500)
                    .frame(width: 8, height: 8)
            } else {
                // 원본 `infiniteRepeatable(tween(900, LinearEasing))` — 0.25 → 1 로 오르고 되풀이(RepeatMode.Restart).
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    let fraction = elapsed.truncatingRemainder(dividingBy: 0.9) / 0.9
                    Circle()
                        .fill(MoyeotaColor.Primary500.copy(alpha: 0.25 + 0.75 * fraction))
                        .frame(width: 8, height: 8)
                }
                .frame(width: 8, height: 8)
            }
            Spacer().frame(width: 8)
            Text(label)
                .moyeotaText(inlineType(13, .bold), color: MoyeotaColor.InkPrimary)
        }
    }

    private var label: String {
        if isFull && !taxiEnabled { return "채팅으로 만나요" }
        if isFull { return "정원이 다 찼어요" }
        return "같이 탈 사람 찾는 중"
    }
}

// 와이어프레임의 회색 보조 버튼 (그만 찾기)
private struct GrayActionButton: View {
    let text: String
    let onClick: () -> Void
    let enabled: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .circular)
        Button(action: onClick) {
            Text(text)
                .moyeotaText(inlineType(15, .bold), color: enabled ? GraySlate : MoyeotaColor.TextAsh)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(GrayButtonBg, in: shape)
        }
        .buttonStyle(PressOverlayStyle(shape: shape))
        .disabled(!enabled)
    }
}

/// 머티리얼 `AlertDialog` 의 자리 — 시스템 알림은 글자 크기·색·버튼 모양을 원본대로 쓸 수 없어 직접 그린다.
///
/// 값은 M3 `AlertDialog` 기본값이다: 모서리 28, 안쪽 여백 24, 제목 아래 16, 본문 아래 24, 버튼 사이 8, 폭 최소 280.
/// 폭 상한 320 은 원본 렌더에서 잰 값이다(화면 폭 411.4dp·401.9dp 에서 모두 320dp).
/// 제목은 `headlineSmall`(줄 높이 32), 본문은 `bodyMedium`(줄 높이 20 · 자간 0.25 · `onSurfaceVariant`),
/// 버튼은 `TextButton`(`labelLarge`: 줄 높이 20 · 자간 0.1, 여백 12/8, 최소 58×40, 터치 영역 높이 48)의 글자 모양을 물려받는다.
private struct ConfirmDialog: View {
    let title: String
    let text: String
    let confirmLabel: String
    let confirmColor: Color
    let dismissLabel: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // 안드로이드 대화상자 창의 기본 어둡기(0.6)다. 앱의 `Scrim` 토큰(40%)은 시트용이라 쓰지 않는다.
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)

            // 원본 대화상자 창은 시스템 바를 뺀 영역의 가운데에 놓인다. 이 오버레이는 화면 전체라 두 바의 높이를 직접 뺀다.
            VStack(spacing: 0) {
                StatusBarSpacer()
                card.frame(maxHeight: .infinity)
                NavigationBarSpacer()
            }
        }
    }

    private var card: some View {
        ConfirmDialogLayout(minWidth: 280 - 48, maxWidth: 320 - 48) {
            Text(title)
                .moyeotaText(
                    MoyeotaType(fontSize: 17, fontWeight: .bold, lineHeight: .sp(32)),
                    color: MoyeotaColor.InkPrimary
                )
                .padding(.bottom, 16)
            Text(text)
                .moyeotaText(
                    MoyeotaType(fontSize: 14, fontWeight: .regular, lineHeight: .sp(20), letterSpacing: 0.25),
                    color: MoyeotaColor.TextMute
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)
            // 버튼 순서는 원본 그대로 — 닫기가 왼쪽, 확인이 오른쪽.
            HStack(spacing: 8) {
                dialogButton(label: dismissLabel, weight: .medium, color: MoyeotaColor.TextMute, action: onDismiss)
                dialogButton(label: confirmLabel, weight: .bold, color: confirmColor, action: onConfirm)
            }
        }
        .padding(24)
        .background(MoyeotaColor.SurfaceCanvas, in: RoundedRectangle(cornerRadius: 28, style: .circular))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
    }

    private func dialogButton(
        label: String,
        weight: Font.Weight,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .moyeotaText(
                    MoyeotaType(fontSize: 14, fontWeight: weight, lineHeight: .sp(20), letterSpacing: 0.1),
                    color: color
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 58, minHeight: 40)
        }
        .buttonStyle(DialogButtonStyle())
    }
}

/// 제목·본문은 왼쪽, 마지막(버튼 줄)은 오른쪽에 붙인다.
///
/// 폭이 **가장 넓은 내용**으로 정해지는 것이 원본과 같은 점이다(원본 로그아웃 확인창 스크린샷: 본문 폭 + 48).
/// `frame(maxWidth:)` 로 잡으면 짧은 문구에서도 대화상자가 화면 폭까지 늘어난다.
///
/// 폭은 줄바꿈 전 너비로 정한다. 본문이 접히면 원본 `Text` 는 상한까지 채우지만 SwiftUI `Text` 는 가장 긴 줄로 줄어들어,
/// 접힌 뒤의 너비로 정하면 문구마다 대화상자 폭이 달라진다.
private struct ConfirmDialogLayout: Layout {
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

/// 머티리얼 `TextButton` 의 눌림·터치 영역 자리. 줄 높이는 터치 영역 48 로 잡힌다(원본 스크린샷의 확인창 높이로 확인).
private struct DialogButtonStyle: ButtonStyle {
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

/// 「나 외 M명」에 쓰는 **나를 뺀** 인원 — 내가 목록에 있을 때만 센다.
///
/// 세지 않는 경우가 둘이다. 둘 다 `isMe` 가 아무 멤버에도 서지 않는 경우이고, 그때 "나를 뺀 인원"은
/// 전체 인원과 같아진다 — 그러면 화면이 **「지금 같은 방향 2명(나 외 2명)」** 이라는 자기모순을 말한다.
///
/// | 경우 | 왜 isMe 가 없나 |
/// |---|---|
/// | **내가 이 방 멤버가 아니다** | 유령 대기방 — 서버 목록에 내가 없다(`MatchWaitingViewModel.membershipLost` 가 화면을 떠나게 하지만, 그 전 한 프레임을 그린다) |
/// | 식별자가 없는 목록 | 목록·생성 응답으로 만든 `Ride` 는 자리 표시용 멤버라 publicId 가 없다(`placeholderMembers`) |
///
/// 0 을 돌려주면 호출부가 **괄호 없는 문구**(「지금 같은 방향 2명 · 목표 3명」)를 쓴다 — 모르는 값을
/// 지어내지 않고 **말하지 않는** 쪽이다. 문구 포맷 자체는 건드리지 않았다.
func otherMemberCount(ride: Ride) -> Int {
    if !ride.members.contains(where: { $0.isMe }) { return 0 }
    return ride.members.filter { !$0.isMe }.count
}
